#import "ObjCExceptionCatcher.h"

static NSError *RoamttyMakeExceptionError(NSException *exception) {
    NSString *reason = exception.reason ?: @"unknown";
    NSString *detail = [NSString stringWithFormat:@"%@: %@", exception.name, reason];
    return [NSError errorWithDomain:@"com.roamtty.objc-exception"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: detail}];
}

BOOL RoamttyAudioSetVoiceProcessing(AVAudioIONode *node, BOOL enabled, NSError * _Nullable * _Nullable outError) {
    @try {
        return [node setVoiceProcessingEnabled:enabled error:outError];
    } @catch (NSException *exception) {
        if (outError != NULL) { *outError = RoamttyMakeExceptionError(exception); }
        return NO;
    }
}

BOOL RoamttyAudioEngineAttach(AVAudioEngine *engine, AVAudioNode *node, NSError * _Nullable * _Nullable outError) {
    @try {
        [engine attachNode:node];
        return YES;
    } @catch (NSException *exception) {
        if (outError != NULL) { *outError = RoamttyMakeExceptionError(exception); }
        return NO;
    }
}

BOOL RoamttyAudioEngineDetach(AVAudioEngine *engine, AVAudioNode *node, NSError * _Nullable * _Nullable outError) {
    @try {
        [engine detachNode:node];
        return YES;
    } @catch (NSException *exception) {
        if (outError != NULL) { *outError = RoamttyMakeExceptionError(exception); }
        return NO;
    }
}

BOOL RoamttyAudioEngineConnect(AVAudioEngine *engine, AVAudioNode *fromNode, AVAudioNode *toNode, AVAudioFormat * _Nullable format, NSError * _Nullable * _Nullable outError) {
    @try {
        [engine connect:fromNode to:toNode format:format];
        return YES;
    } @catch (NSException *exception) {
        if (outError != NULL) { *outError = RoamttyMakeExceptionError(exception); }
        return NO;
    }
}

BOOL RoamttyAudioEngineStart(AVAudioEngine *engine, NSError * _Nullable * _Nullable outError) {
    @try {
        [engine prepare];
        return [engine startAndReturnError:outError];
    } @catch (NSException *exception) {
        if (outError != NULL) { *outError = RoamttyMakeExceptionError(exception); }
        return NO;
    }
}

BOOL RoamttyAudioEngineStop(AVAudioEngine *engine, BOOL reset, NSError * _Nullable * _Nullable outError) {
    @try {
        [engine stop];
        if (reset) { [engine reset]; }
        return YES;
    } @catch (NSException *exception) {
        if (outError != NULL) { *outError = RoamttyMakeExceptionError(exception); }
        return NO;
    }
}

AVAudioFormat * _Nullable RoamttyAudioNodeOutputFormat(AVAudioNode *node, AVAudioNodeBus bus, NSError * _Nullable * _Nullable outError) {
    @try {
        return [node outputFormatForBus:bus];
    } @catch (NSException *exception) {
        if (outError != NULL) { *outError = RoamttyMakeExceptionError(exception); }
        return nil;
    }
}

BOOL RoamttyAudioNodeInstallTap(AVAudioNode *node, AVAudioNodeBus bus, AVAudioFrameCount bufferSize, AVAudioFormat * _Nullable format, AVAudioNodeTapBlock block, NSError * _Nullable * _Nullable outError) {
    @try {
        [node removeTapOnBus:bus];
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        if (outError != NULL) { *outError = RoamttyMakeExceptionError(exception); }
        return NO;
    }
}

BOOL RoamttyAudioNodeRemoveTap(AVAudioNode *node, AVAudioNodeBus bus, NSError * _Nullable * _Nullable outError) {
    @try {
        [node removeTapOnBus:bus];
        return YES;
    } @catch (NSException *exception) {
        if (outError != NULL) { *outError = RoamttyMakeExceptionError(exception); }
        return NO;
    }
}

BOOL RoamttyAudioPlayerPlay(AVAudioPlayerNode *player, NSError * _Nullable * _Nullable outError) {
    @try {
        if (!player.isPlaying) { [player play]; }
        return YES;
    } @catch (NSException *exception) {
        if (outError != NULL) { *outError = RoamttyMakeExceptionError(exception); }
        return NO;
    }
}

BOOL RoamttyAudioPlayerStop(AVAudioPlayerNode *player, NSError * _Nullable * _Nullable outError) {
    @try {
        [player stop];
        return YES;
    } @catch (NSException *exception) {
        if (outError != NULL) { *outError = RoamttyMakeExceptionError(exception); }
        return NO;
    }
}

BOOL RoamttyAudioPlayerScheduleBuffer(AVAudioPlayerNode *player, AVAudioPCMBuffer *buffer, void (^ _Nullable completionHandler)(void), NSError * _Nullable * _Nullable outError) {
    @try {
        if (!player.isPlaying) { [player play]; }
        [player scheduleBuffer:buffer completionHandler:completionHandler];
        return YES;
    } @catch (NSException *exception) {
        if (outError != NULL) { *outError = RoamttyMakeExceptionError(exception); }
        return NO;
    }
}

AVAudioConverter * _Nullable RoamttyAudioConverterCreate(AVAudioFormat *fromFormat, AVAudioFormat *toFormat, NSError * _Nullable * _Nullable outError) {
    @try {
        return [[AVAudioConverter alloc] initFromFormat:fromFormat toFormat:toFormat];
    } @catch (NSException *exception) {
        if (outError != NULL) { *outError = RoamttyMakeExceptionError(exception); }
        return nil;
    }
}

BOOL RoamttyAudioConverterConvert(AVAudioConverter *converter, AVAudioPCMBuffer *input, AVAudioPCMBuffer *output, AVAudioConverterOutputStatus *outStatus, NSError * _Nullable * _Nullable outError) {
    @try {
        __block BOOL supplied = NO;
        NSError *convertError = nil;
        AVAudioConverterOutputStatus status = [converter convertToBuffer:output error:&convertError withInputFromBlock:^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus *inStatus) {
            (void)inNumberOfPackets;
            if (supplied) {
                *inStatus = AVAudioConverterInputStatus_NoDataNow;
                return nil;
            }
            supplied = YES;
            *inStatus = AVAudioConverterInputStatus_HaveData;
            return input;
        }];
        if (outStatus != NULL) { *outStatus = status; }
        if (convertError != nil && outError != NULL) { *outError = convertError; }
        return status != AVAudioConverterOutputStatus_Error;
    } @catch (NSException *exception) {
        if (outStatus != NULL) { *outStatus = AVAudioConverterOutputStatus_Error; }
        if (outError != NULL) { *outError = RoamttyMakeExceptionError(exception); }
        return NO;
    }
}
