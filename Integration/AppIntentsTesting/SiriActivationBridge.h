#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Keeps XCTest's Objective-C interruption from unwinding through Swift after a
/// specifically recognized activation timeout. All other exceptions are rethrown.
FOUNDATION_EXPORT NSString * _Nullable IntentLabActivateSiri(
    NSString *request,
    BOOL (NS_NOESCAPE ^shouldRecover)(void)
);

NS_ASSUME_NONNULL_END
