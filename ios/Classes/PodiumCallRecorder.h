#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Sample rate of the PCM PodiumAudioDevice exchanges with WebRTC and hands to the recorder.
extern const double PodiumAudioSampleRate;

/// Records the conference as heard on this device: the remote audio WebRTC plays out mixed with
/// the local microphone, encoded as mono AAC into an .m4a file. Fed by PodiumAudioDevice.
@interface PodiumCallRecorder : NSObject

+ (BOOL)startWithPath:(NSString *)path error:(NSError **)error;

/// Returns the recorded file path, or nil if nothing was recorded.
+ (nullable NSString *)stop;

/// Whether the local participant is unmuted; WebRTC keeps capturing while muted.
+ (void)setMicEnabled:(BOOL)enabled;

@end

/// Called on the audio IO thread with 16-bit mono PCM at the device sample rate.
void PodiumCallRecorderAppendMic(const int16_t *samples, uint32_t frames);
void PodiumCallRecorderAppendPlayout(const int16_t *samples, uint32_t frames);

NS_ASSUME_NONNULL_END
