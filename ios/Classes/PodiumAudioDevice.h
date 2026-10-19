#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// WebRTC audio device (RTCAudioDevice) built on the VoiceProcessingIO unit, like WebRTC's own,
/// that also hands the echo-cancelled microphone and the played out audio to PodiumCallRecorder.
/// Must be set as JitsiMeet's rtcAudioDevice before the first conference starts.
@interface PodiumAudioDevice : NSObject

+ (instancetype)sharedInstance;

@end

NS_ASSUME_NONNULL_END
