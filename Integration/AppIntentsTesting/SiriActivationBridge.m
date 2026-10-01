#import "SiriActivationBridge.h"
#import <XCTest/XCTest.h>

NSString * _Nullable IntentLabActivateSiri(NSString *request, BOOL (^shouldRecover)(void)) {
    @try {
        [XCUIDevice.sharedDevice.siriService activateWithVoiceRecognitionText:request];
        return nil;
    } @catch (NSException *exception) {
        // The caller authorizes recovery only after XCTest matched the exact
        // driver issue and the app exposed this invocation's completed action.
        NSLog(@"Intent Lab Siri interruption: %@: %@", exception.name, exception.reason);
        if (![exception.name isEqualToString:@"_XCTestCaseInterruptionException"]
            || ![exception.reason isEqualToString:@"Interrupting test"]
            || !shouldRecover()) {
            @throw;
        }
        return exception.name;
    }
}
