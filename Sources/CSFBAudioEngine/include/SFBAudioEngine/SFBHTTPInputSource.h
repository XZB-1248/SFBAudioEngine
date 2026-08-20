//
// SPDX-FileCopyrightText: 2026 Stephen F. Booth <contact@sbooth.dev>
// SPDX-License-Identifier: MIT
//
// Part of https://github.com/sbooth/SFBAudioEngine
//

#import <SFBAudioEngine/SFBInputSource.h>

NS_ASSUME_NONNULL_BEGIN

/// An input source that streams audio over HTTP or HTTPS
///
/// Reads block the calling thread until data arrives, so this class is intended for use on
/// a decoding thread and never on the main thread. Transient network failures are retried
/// internally and are not reported to the caller.
///
/// Seeking requires the server to support HTTP range requests.
NS_SWIFT_NAME(HTTPInputSource)
@interface SFBHTTPInputSource : SFBInputSource

/// Returns an initialized `SFBHTTPInputSource` object for the given URL
/// - parameter url: The URL
/// - returns: An initialized `SFBHTTPInputSource` object
- (instancetype)initWithURL:(NSURL *)url;

/// Returns an initialized `SFBHTTPInputSource` object for the given URL
/// - parameter url: The URL
/// - parameter headers: Optional additional HTTP header fields sent with every request
/// - returns: An initialized `SFBHTTPInputSource` object
- (instancetype)initWithURL:(NSURL *)url
                    headers:(nullable NSDictionary<NSString *, NSString *> *)headers NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
