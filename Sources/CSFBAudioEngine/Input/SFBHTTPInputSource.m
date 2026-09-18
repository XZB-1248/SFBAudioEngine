//
// SPDX-FileCopyrightText: 2026 Stephen F. Booth <contact@sbooth.dev>
// SPDX-License-Identifier: MIT
//
// Part of https://github.com/sbooth/SFBAudioEngine
//

#import "SFBHTTPInputSource.h"

#import "SFBInputSource+Internal.h"

/// Sentinel for a length the server did not disclose.
static const int64_t SFBHTTPInputSourceUnknownLength = -1;
/// Buffered bytes ahead of the read head at which the transfer is suspended.
static const NSInteger SFBHTTPInputSourceHighWaterMark = 4 * 1024 * 1024;
/// Buffered bytes ahead of the read head at which a suspended transfer resumes.
static const NSInteger SFBHTTPInputSourceLowWaterMark = 1 * 1024 * 1024;
/// Bytes retained behind the read head so short backward seeks avoid a new request.
static const NSInteger SFBHTTPInputSourceRewindSize = 512 * 1024;
static const NSInteger SFBHTTPInputSourceCompactionThreshold = 512 * 1024;
/// Forward seeks no farther than this drain the current transfer instead of reconnecting.
static const NSInteger SFBHTTPInputSourceForwardSeekLimit = 256 * 1024;
/// Bytes of a departing window kept aside for a return. A container header, not a second cache.
static const NSInteger SFBHTTPInputSourceParkSize = 1 * 1024 * 1024;
/// What a transfer started by a distant seek asks for, so an excursion cannot drag the rest of
/// the resource behind it.
static const NSInteger SFBHTTPInputSourceExcursionBytes = 1 * 1024 * 1024;
/// Asks for everything from the start offset onward.
static const NSInteger SFBHTTPInputSourceUnboundedRequest = 0;
/// Consecutive failed transfers tolerated before a read gives up.
static const NSInteger SFBHTTPInputSourceMaximumRetryCount = 5;
/// Backoff before the first retry, doubled on each subsequent attempt.
static const NSTimeInterval SFBHTTPInputSourceInitialRetryDelay = 0.25;
/// Ceiling for the retry backoff.
static const NSTimeInterval SFBHTTPInputSourceMaximumRetryDelay = 4.0;
/// Seconds a request may stall before it is considered failed.
static const NSTimeInterval SFBHTTPInputSourceResponseTimeout = 30.0;

/// Extracts the total resource length from a `Content-Range` header value.
static int64_t SFBParseContentRangeTotal(NSString *contentRange) {
    if (!contentRange) {
        return SFBHTTPInputSourceUnknownLength;
    }

    NSRange slash = [contentRange rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound) {
        return SFBHTTPInputSourceUnknownLength;
    }

    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *total = [[contentRange substringFromIndex:NSMaxRange(slash)] stringByTrimmingCharactersInSet:whitespace];
    if (total.length == 0 || [total isEqualToString:@"*"]) {
        return SFBHTTPInputSourceUnknownLength;
    }

    return (int64_t)total.longLongValue;
}

@interface SFBHTTPInputSource () <NSURLSessionDataDelegate> {
  @private
    NSDictionary<NSString *, NSString *> *_headers;
    NSURLSession *_session;
    NSURLSessionDataTask *_task;
    /// Guards every ivar below and wakes readers blocked on the network.
    NSCondition *_condition;
    /// Bytes received for the current transfer, not yet discarded.
    NSMutableData *_buffer;
    /// Resource offset of the first byte in `_buffer`.
    int64_t _bufferOffset;
    /// Resource offset the next read consumes from.
    int64_t _readOffset;
    /// Resource offset the current request started at.
    int64_t _requestOffset;
    /// Resource offset just past what the current request asked for, or unknown when unbounded.
    int64_t _requestEnd;
    /// A window kept aside across a distant seek, so returning into it needs no transfer.
    NSMutableData *_parkedBuffer;
    /// Resource offset of the first byte in `_parkedBuffer`.
    int64_t _parkedOffset;
    /// Total resource length, or `SFBHTTPInputSourceUnknownLength`.
    int64_t _length;
    NSInteger _retryCount;
    NSError *_taskError;
    BOOL _isOpen;
    BOOL _supportsSeeking;
    BOOL _responseReceived;
    BOOL _taskComplete;
    BOOL _suspended;
}
@end

@implementation SFBHTTPInputSource

- (instancetype)initWithURL:(NSURL *)url {
    return [self initWithURL:url headers:nil];
}

- (instancetype)initWithURL:(NSURL *)url headers:(NSDictionary<NSString *, NSString *> *)headers {
    NSParameterAssert(url != nil);

    if ((self = [super initWithURL:url])) {
        _headers = [headers copy];
        _condition = [[NSCondition alloc] init];
        _buffer = [NSMutableData data];
        _parkedBuffer = [NSMutableData data];
        _length = SFBHTTPInputSourceUnknownLength;
        _requestEnd = SFBHTTPInputSourceUnknownLength;
    }
    return self;
}

- (void)dealloc {
    [_task cancel];
    [_session invalidateAndCancel];
}

// MARK: - SFBInputSource

- (BOOL)openReturningError:(NSError **)error {
    if (_isOpen) {
        return YES;
    }

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = SFBHTTPInputSourceResponseTimeout;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    _session = [NSURLSession sessionWithConfiguration:configuration];

    [_condition lock];

    [_buffer setLength:0];
    [_parkedBuffer setLength:0];
    _bufferOffset = 0;
    _parkedOffset = 0;
    _readOffset = 0;
    _length = SFBHTTPInputSourceUnknownLength;
    _requestEnd = SFBHTTPInputSourceUnknownLength;
    _retryCount = 0;
    _supportsSeeking = NO;
    _isOpen = YES;

    [self startTaskLocked:SFBHTTPInputSourceUnboundedRequest];
    BOOL opened = [self waitForResponseLocked];
    NSError *taskError = _taskError;

    if (!opened) {
        _isOpen = NO;
        [self cancelTaskLocked];
    }

    [_condition unlock];

    if (!opened) {
        [_session invalidateAndCancel];
        _session = nil;
        os_log_error(gSFBInputSourceLog, "Unable to open %{public}@: %{public}@", _url, taskError);
        if (error) {
            *error = taskError ?: [NSError errorWithDomain:NSURLErrorDomain
                                                      code:NSURLErrorCannotOpenFile
                                                  userInfo:nil];
        }
        return NO;
    }

    return YES;
}

- (BOOL)closeReturningError:(NSError **)error {
    [_condition lock];
    _isOpen = NO;
    [self cancelTaskLocked];
    [_buffer setLength:0];
    [_parkedBuffer setLength:0];
    [_condition broadcast];
    [_condition unlock];

    [_session invalidateAndCancel];
    _session = nil;

    return YES;
}

- (BOOL)isOpen {
    [_condition lock];
    BOOL isOpen = _isOpen;
    [_condition unlock];
    return isOpen;
}

- (BOOL)readBytes:(void *)buffer length:(NSInteger)length bytesRead:(NSInteger *)bytesRead error:(NSError **)error {
    NSParameterAssert(buffer != NULL);
    NSParameterAssert(length >= 0);
    NSParameterAssert(bytesRead != NULL);

    *bytesRead = 0;
    if (length == 0) {
        return YES;
    }

    [_condition lock];

    if (!_isOpen) {
        [_condition unlock];
        if (error) {
            *error = [self posixErrorWithCode:EBADF];
        }
        return NO;
    }

    // Short reads confuse decoders written against fread(), so satisfy the full request unless the resource ends.
    NSInteger totalRead = 0;
    while (totalRead < length && _isOpen) {
        NSInteger available = [self availableLocked];
        if (available > 0) {
            NSInteger count = MIN(available, length - totalRead);
            NSRange range = NSMakeRange((NSUInteger)(_readOffset - _bufferOffset), (NSUInteger)count);
            [_buffer getBytes:(uint8_t *)buffer + totalRead range:range];
            _readOffset += count;
            totalRead += count;
            [self trimBufferLocked];
            [self updateFlowControlLocked];
            continue;
        }

        if ([self atEndLocked]) {
            break;
        }

        if (_taskComplete) {
            // A bounded request that delivered all it asked for is a handoff, not a failure: the
            // reader has outlasted the excursion, so what follows is sequential again.
            if (_taskError == nil && _requestEnd != SFBHTTPInputSourceUnknownLength
                && _bufferOffset + (int64_t)_buffer.length >= _requestEnd) {
                [self cancelTaskLocked];
                [self startTaskLocked:SFBHTTPInputSourceUnboundedRequest];
                continue;
            }
            if (![self restartTransferLocked]) {
                break;
            }
            continue;
        }

        [_condition wait];
    }

    [_condition unlock];

    *bytesRead = totalRead;
    return YES;
}

- (BOOL)atEOF {
    [_condition lock];
    BOOL atEOF = [self atEndLocked];
    [_condition unlock];
    return atEOF;
}

- (BOOL)getOffset:(NSInteger *)offset error:(NSError **)error {
    NSParameterAssert(offset != NULL);

    [_condition lock];
    *offset = (NSInteger)_readOffset;
    [_condition unlock];

    return YES;
}

- (BOOL)getLength:(NSInteger *)length error:(NSError **)error {
    NSParameterAssert(length != NULL);

    [_condition lock];
    int64_t resourceLength = _length;
    [_condition unlock];

    if (resourceLength == SFBHTTPInputSourceUnknownLength) {
        os_log_info(gSFBInputSourceLog, "Length unavailable for %{public}@", _url);
        if (error) {
            *error = [self posixErrorWithCode:ENOTSUP];
        }
        return NO;
    }

    *length = (NSInteger)resourceLength;
    return YES;
}

- (BOOL)supportsSeeking {
    [_condition lock];
    BOOL supportsSeeking = _supportsSeeking;
    [_condition unlock];
    return supportsSeeking;
}

- (BOOL)seekToOffset:(NSInteger)offset error:(NSError **)error {
    NSParameterAssert(offset >= 0);

    [_condition lock];

    if (!_isOpen) {
        [_condition unlock];
        if (error) {
            *error = [self posixErrorWithCode:EBADF];
        }
        return NO;
    }

    if (!_supportsSeeking) {
        [_condition unlock];
        os_log_error(gSFBInputSourceLog, "Seek unsupported for %{public}@", _url);
        if (error) {
            *error = [self posixErrorWithCode:ESPIPE];
        }
        return NO;
    }

    if (_length != SFBHTTPInputSourceUnknownLength && offset > _length) {
        [_condition unlock];
        if (error) {
            *error = [self posixErrorWithCode:EINVAL];
        }
        return NO;
    }

    // Landing inside the retained window costs nothing.
    int64_t bufferEnd = _bufferOffset + (int64_t)_buffer.length;
    BOOL withinBuffer = offset >= _bufferOffset && offset <= bufferEnd;
    BOOL shortForwardSeek = !_taskComplete && offset > bufferEnd &&
                            (offset - bufferEnd) <= SFBHTTPInputSourceForwardSeekLimit;
    if (withinBuffer || shortForwardSeek) {
        _readOffset = offset;
        [self trimBufferLocked];
        [self updateFlowControlLocked];
        [_condition unlock];
        return YES;
    }

    // An excursion usually comes back: a container reads its header, jumps to a trailing tag,
    // then returns. Dropping the window makes it fetch that header a second time.
    NSMutableData *window = _buffer;
    int64_t windowOffset = _bufferOffset;
    int64_t parkedEnd = _parkedOffset + (int64_t)_parkedBuffer.length;
    BOOL resumingParked = _parkedBuffer.length > 0 && offset >= _parkedOffset && offset <= parkedEnd;

    [self cancelTaskLocked];

    // One slot, and the window just left is the one worth keeping. Its head is what a return
    // wants, and a copy rather than a truncation, since `setLength:` keeps the larger allocation.
    NSMutableData *parked = _parkedBuffer;
    int64_t parkedOffset = _parkedOffset;
    if (window.length > (NSUInteger)SFBHTTPInputSourceParkSize) {
        window = [NSMutableData dataWithBytes:window.bytes length:(NSUInteger)SFBHTTPInputSourceParkSize];
    }
    _parkedBuffer = window;
    _parkedOffset = windowOffset;
    _readOffset = offset;
    _retryCount = 0;

    // Reading on from a parked window needs no transfer to succeed first, and is sequential again.
    if (resumingParked) {
        _buffer = parked;
        _bufferOffset = parkedOffset;
        [self startTaskLocked:SFBHTTPInputSourceUnboundedRequest];
        [self updateFlowControlLocked];
        [_condition unlock];
        return YES;
    }

    _buffer = [NSMutableData data];
    _bufferOffset = offset;
    [self startTaskLocked:SFBHTTPInputSourceExcursionBytes];

    BOOL seeked = [self waitForResponseLocked];
    NSError *taskError = _taskError;

    [_condition unlock];

    if (!seeked) {
        os_log_error(gSFBInputSourceLog, "Unable to seek to %ld in %{public}@", (long)offset, _url);
        if (error) {
            *error = taskError ?: [NSError errorWithDomain:NSURLErrorDomain
                                                      code:NSURLErrorBadServerResponse
                                                  userInfo:nil];
        }
        return NO;
    }

    return YES;
}

// MARK: - Transfer Management

/// Starts a transfer at the first unbuffered byte. `maxBytes` caps what this one request asks
/// for; `SFBHTTPInputSourceUnboundedRequest` asks for everything left. `_condition` must be held.
- (void)startTaskLocked:(NSInteger)maxBytes {
    int64_t start = _bufferOffset + (int64_t)_buffer.length;

    // A range request at or past the end draws a 416, so treat that position as an exhausted transfer.
    if (_length != SFBHTTPInputSourceUnknownLength && start >= _length) {
        _requestOffset = start;
        _requestEnd = SFBHTTPInputSourceUnknownLength;
        _responseReceived = YES;
        _taskComplete = YES;
        _taskError = nil;
        _suspended = NO;
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_url
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:SFBHTTPInputSourceResponseTimeout];
    for (NSString *field in _headers) {
        [request setValue:_headers[field] forHTTPHeaderField:field];
    }
    // Transparent decompression would decouple byte offsets from the resource.
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    // Bounding needs a server that honors ranges and a length to clamp against.
    int64_t end = SFBHTTPInputSourceUnknownLength;
    if (maxBytes > 0 && _supportsSeeking && _length != SFBHTTPInputSourceUnknownLength) {
        end = MIN(start + maxBytes, _length);
    }
    if (end != SFBHTTPInputSourceUnknownLength) {
        [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", start, end - 1]
               forHTTPHeaderField:@"Range"];
    } else {
        [request setValue:[NSString stringWithFormat:@"bytes=%lld-", start] forHTTPHeaderField:@"Range"];
    }

    _requestOffset = start;
    _requestEnd = end;
    _responseReceived = NO;
    _taskComplete = NO;
    _taskError = nil;
    _suspended = NO;

    _task = [_session dataTaskWithRequest:request];
    // NSURLSessionTask holds its delegate weakly, so this does not retain a cycle.
    _task.delegate = self;
    [_task resume];
}

/// Detaches the current transfer so its remaining callbacks are ignored. `_condition` must be held.
- (void)cancelTaskLocked {
    if (!_task) {
        return;
    }

    NSURLSessionDataTask *task = _task;
    _task = nil;
    _responseReceived = NO;
    _taskComplete = NO;
    _taskError = nil;
    _suspended = NO;
    [task cancel];
}

/// Blocks until the current transfer produces response headers or fails. `_condition` must be held.
- (BOOL)waitForResponseLocked {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:SFBHTTPInputSourceResponseTimeout];
    while (!_responseReceived && _isOpen) {
        if (![_condition waitUntilDate:deadline]) {
            break;
        }
    }

    if (!_responseReceived) {
        return NO;
    }

    return _taskError == nil;
}

/// Reconnects after a dropped or truncated transfer. `_condition` must be held.
- (BOOL)restartTransferLocked {
    int64_t fetchOffset = _bufferOffset + (int64_t)_buffer.length;

    if (_length != SFBHTTPInputSourceUnknownLength && fetchOffset >= _length) {
        return NO;
    }

    // Resuming mid-resource is only possible when the server honors range requests.
    if (fetchOffset > 0 && !_supportsSeeking) {
        os_log_error(gSFBInputSourceLog, "Transfer of %{public}@ ended early and cannot resume", _url);
        return NO;
    }

    if (_retryCount >= SFBHTTPInputSourceMaximumRetryCount) {
        os_log_error(gSFBInputSourceLog, "Giving up on %{public}@ after %ld retries", _url,
                     (long)SFBHTTPInputSourceMaximumRetryCount);
        return NO;
    }

    NSTimeInterval delay = SFBHTTPInputSourceInitialRetryDelay * (NSTimeInterval)(1 << _retryCount);
    _retryCount += 1;
    [_condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:MIN(delay, SFBHTTPInputSourceMaximumRetryDelay)]];

    if (!_isOpen) {
        return NO;
    }

    os_log_info(gSFBInputSourceLog, "Resuming %{public}@ at %lld", _url, fetchOffset);
    [self cancelTaskLocked];
    [self startTaskLocked:SFBHTTPInputSourceUnboundedRequest];

    return YES;
}

// MARK: - Buffer Accounting

/// Bytes buffered at or after the read head. `_condition` must be held.
- (NSInteger)availableLocked {
    int64_t bufferEnd = _bufferOffset + (int64_t)_buffer.length;
    if (_readOffset >= bufferEnd) {
        return 0;
    }
    return (NSInteger)(bufferEnd - _readOffset);
}

/// `YES` once the read head has consumed the whole resource. `_condition` must be held.
- (BOOL)atEndLocked {
    if (_length != SFBHTTPInputSourceUnknownLength) {
        return _readOffset >= _length;
    }
    return _taskComplete && _taskError == nil && [self availableLocked] <= 0;
}

/// Drops consumed bytes beyond the rewind window. `_condition` must be held.
- (void)trimBufferLocked {
    int64_t consumed = _readOffset - _bufferOffset;
    if (consumed <= SFBHTTPInputSourceRewindSize) {
        return;
    }

    NSInteger drop = MIN((NSInteger)(consumed - SFBHTTPInputSourceRewindSize), (NSInteger)_buffer.length);
    // Compacting is an O(length) memmove, so amortize it over a window instead of paying it every read.
    if (drop < SFBHTTPInputSourceCompactionThreshold) {
        return;
    }

    [_buffer replaceBytesInRange:NSMakeRange(0, (NSUInteger)drop) withBytes:NULL length:0];
    _bufferOffset += drop;
}

/// Applies backpressure so the read-ahead stays bounded. `_condition` must be held.
- (void)updateFlowControlLocked {
    if (!_task) {
        return;
    }

    NSInteger available = [self availableLocked];
    if (!_suspended && available >= SFBHTTPInputSourceHighWaterMark) {
        [_task suspend];
        _suspended = YES;
    } else if (_suspended && available <= SFBHTTPInputSourceLowWaterMark) {
        [_task resume];
        _suspended = NO;
    }
}

// MARK: - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    [_condition lock];

    if (dataTask != _task) {
        [_condition unlock];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    NSHTTPURLResponse *httpResponse = nil;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        httpResponse = (NSHTTPURLResponse *)response;
    }
    NSInteger statusCode = httpResponse ? httpResponse.statusCode : 200;

    NSError *responseError = nil;
    if (statusCode < 200 || statusCode > 299) {
        os_log_error(gSFBInputSourceLog, "HTTP %ld for %{public}@", (long)statusCode, _url);
        responseError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil];
    } else if (statusCode == 206) {
        _supportsSeeking = YES;
        int64_t total = SFBParseContentRangeTotal([httpResponse valueForHTTPHeaderField:@"Content-Range"]);
        if (total > 0) {
            _length = total;
        }
    } else if (_requestOffset > 0) {
        // The server ignored the range and would restart the body at zero.
        os_log_error(gSFBInputSourceLog, "Range request for %{public}@ was ignored", _url);
        responseError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil];
    } else {
        NSString *acceptRanges = [httpResponse valueForHTTPHeaderField:@"Accept-Ranges"];
        _supportsSeeking = [acceptRanges caseInsensitiveCompare:@"bytes"] == NSOrderedSame;
        if (response.expectedContentLength != NSURLResponseUnknownLength) {
            _length = response.expectedContentLength;
        }
    }

    if (responseError) {
        _taskError = responseError;
        _taskComplete = YES;
    }

    _responseReceived = YES;
    [_condition broadcast];
    [_condition unlock];

    completionHandler(responseError ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    [_condition lock];

    if (dataTask != _task) {
        [_condition unlock];
        return;
    }

    [_buffer appendData:data];
    // Progress means the connection is healthy, so the next stall gets a full retry budget.
    _retryCount = 0;
    [self updateFlowControlLocked];
    [_condition broadcast];
    [_condition unlock];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [_condition lock];

    if (task != _task) {
        [_condition unlock];
        return;
    }

    if (error && !_taskError) {
        _taskError = error;
    }
    _taskComplete = YES;
    _responseReceived = YES;
    [_condition broadcast];
    [_condition unlock];
}

@end
