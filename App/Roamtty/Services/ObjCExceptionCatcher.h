#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Pure Objective-C wrappers around CoreAudio / `AVAudioEngine` operations that can raise
/// Objective-C `NSException`s (e.g. `com.apple.coreaudio.avfaudio`).
///
/// Keeping `@try/@catch` strictly inside Objective-C frames ensures an `NSException` NEVER
/// unwinds across a Swift frame (which would corrupt Swift ARC / autorelease pool ownership).

BOOL RoamttyAudioSetVoiceProcessing(AVAudioIONode *node, BOOL enabled, NSError * _Nullable * _Nullable outError);
BOOL RoamttyAudioEngineAttach(AVAudioEngine *engine, AVAudioNode *node, NSError * _Nullable * _Nullable outError);
BOOL RoamttyAudioEngineDetach(AVAudioEngine *engine, AVAudioNode *node, NSError * _Nullable * _Nullable outError);
BOOL RoamttyAudioEngineConnect(AVAudioEngine *engine, AVAudioNode *fromNode, AVAudioNode *toNode, AVAudioFormat * _Nullable format, NSError * _Nullable * _Nullable outError);
BOOL RoamttyAudioEngineStart(AVAudioEngine *engine, NSError * _Nullable * _Nullable outError);
BOOL RoamttyAudioEngineStop(AVAudioEngine *engine, BOOL reset, NSError * _Nullable * _Nullable outError);
AVAudioFormat * _Nullable RoamttyAudioNodeOutputFormat(AVAudioNode *node, AVAudioNodeBus bus, NSError * _Nullable * _Nullable outError);
BOOL RoamttyAudioNodeInstallTap(AVAudioNode *node, AVAudioNodeBus bus, AVAudioFrameCount bufferSize, AVAudioFormat * _Nullable format, AVAudioNodeTapBlock block, NSError * _Nullable * _Nullable outError);
BOOL RoamttyAudioNodeRemoveTap(AVAudioNode *node, AVAudioNodeBus bus, NSError * _Nullable * _Nullable outError);
BOOL RoamttyAudioPlayerPlay(AVAudioPlayerNode *player, NSError * _Nullable * _Nullable outError);
BOOL RoamttyAudioPlayerStop(AVAudioPlayerNode *player, NSError * _Nullable * _Nullable outError);
BOOL RoamttyAudioPlayerScheduleBuffer(AVAudioPlayerNode *player, AVAudioPCMBuffer *buffer, void (^ _Nullable completionHandler)(void), NSError * _Nullable * _Nullable outError);
AVAudioConverter * _Nullable RoamttyAudioConverterCreate(AVAudioFormat *fromFormat, AVAudioFormat *toFormat, NSError * _Nullable * _Nullable outError);
BOOL RoamttyAudioConverterConvert(AVAudioConverter *converter, AVAudioPCMBuffer *input, AVAudioPCMBuffer *output, AVAudioConverterOutputStatus *outStatus, NSError * _Nullable * _Nullable outError);

NS_ASSUME_NONNULL_END
