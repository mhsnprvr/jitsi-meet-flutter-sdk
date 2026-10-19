#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Sample rate of the PCM PodiumAudioDevice exchanges with WebRTC and hands to the recorder.
extern const double PodiumAudioSampleRate;

/// Records the conference as heard on this device: the remote audio WebRTC plays out mixed with
/// the local microphone, encoded as mono AAC. Fed by PodiumAudioDevice.
///
/// One encoder runs for the whole recording and its ADTS frames are split into chunk files of
/// `chunk_NNNNN.aac`, so every finished chunk is playable on its own and the chunks join back into
/// one gapless stream (see `joinChunksInDirectory:`).
@interface PodiumCallRecorder : NSObject

+ (BOOL)startInDirectory:(NSString *)directory
            chunkSeconds:(NSInteger)chunkSeconds
                   error:(NSError **)error;

/// Stops the recording, returning `dir`, `chunks` and `durationMs`, or nil if nothing was
/// recorded. Blocks until the last chunk is written.
+ (nullable NSDictionary<NSString *, id> *)stop;

/// Whether the local participant is unmuted; WebRTC keeps capturing while muted.
+ (void)setMicEnabled:(BOOL)enabled;

/// Joins the chunks in `directory` into an .m4a at `path` without re-encoding, returning its
/// duration in milliseconds, or -1 on failure. A frame cut short at the end of a chunk is dropped.
+ (int64_t)joinChunksInDirectory:(NSString *)directory
                          toPath:(NSString *)path
                           error:(NSError **)error;

@end

/// Called on the audio IO thread with 16-bit mono PCM at the device sample rate.
void PodiumCallRecorderAppendMic(const int16_t *samples, uint32_t frames);
void PodiumCallRecorderAppendPlayout(const int16_t *samples, uint32_t frames);

NS_ASSUME_NONNULL_END
