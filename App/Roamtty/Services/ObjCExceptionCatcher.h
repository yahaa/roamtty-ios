#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C `@try/@catch` so CoreAudio / `AVAudioEngine`
/// `NSException`s are turned into a recoverable `NSError` instead of aborting the app.
BOOL RoamttyTryObjC(void (NS_NOESCAPE ^block)(void), NSError * _Nullable * _Nullable outError);

NS_ASSUME_NONNULL_END
