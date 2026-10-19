#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Saves the frames of a screen share track as JPEGs in a directory, with an index (`frames.idx`,
/// one `number atMs width height rotation` line per frame) of when each was shown. Frames are
/// thinned to 10 per second, scaled to at most 1280 wide, and skipped while the picture doesn't
/// change. Everything runs on the CPU, so it keeps working while the app is in the background;
/// `encodeDirectory:` turns the frames into a video later.
@interface PodiumScreenRecorder : NSObject

/// Starts capturing the track (`pcId` -1 for a local track), stopping a capture still running.
/// `completion` is called on the main queue with whether the track was found.
+ (void)startWithPcId:(NSInteger)pcId
              trackId:(NSString *)trackId
            directory:(NSString *)directory
           completion:(void (^)(BOOL attached))completion;

/// Stops capturing, returning `frames`, `width`, `height` and `durationMs`, or nil if no frame was
/// saved. Blocks until pending frames are written, so don't call it on the main queue.
+ (nullable NSDictionary<NSString *, id> *)stop;

/// Encodes a frames directory into an H.264 .mp4 at `path`, showing each frame from its recorded
/// time until the next one and the last one until `endMs`. Returns `width`, `height` and
/// `durationMs`, or nil on failure. Needs the app in the foreground for the hardware encoder.
+ (nullable NSDictionary<NSString *, id> *)encodeDirectory:(NSString *)directory
                                                    toPath:(NSString *)path
                                                     endMs:(int64_t)endMs
                                                  progress:(void (^_Nullable)(int done, int total))progress
                                                     error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
