#import "ObjCExceptionCatcher.h"

BOOL RoamttyTryObjC(void (NS_NOESCAPE ^block)(void), NSError * _Nullable * _Nullable outError) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (outError != NULL) {
            NSString *reason = exception.reason ?: @"unknown";
            NSString *detail = [NSString stringWithFormat:@"%@: %@", exception.name, reason];
            *outError = [NSError errorWithDomain:@"com.roamtty.objc-exception"
                                            code:1
                                        userInfo:@{NSLocalizedDescriptionKey: detail}];
        }
        return NO;
    }
}
