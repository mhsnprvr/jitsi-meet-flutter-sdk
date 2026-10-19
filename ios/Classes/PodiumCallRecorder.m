#import "PodiumCallRecorder.h"

#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>
#import <stdatomic.h>

const double PodiumAudioSampleRate = 48000;

static const UInt32 kBitRate = 96000;
static const UInt32 kMicRingFrames = 48000;      // 1 s
static const UInt32 kMaxMicBacklogFrames = 9600; // 200 ms
static const UInt32 kMixChunkFrames = 4096;

// Everything below is shared with the audio IO thread and guarded by `gLock`. The IO thread
// only ever try-locks it, so it never waits on start/stop.
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static ExtAudioFileRef gFile = NULL;
static NSString *gPath = nil;
static int64_t gFramesWritten = 0;
static int16_t gMicRing[kMicRingFrames];
static UInt32 gMicRead = 0;
static UInt32 gMicCount = 0;
static int16_t gMix[kMixChunkFrames];

static atomic_bool gActive = false;
static atomic_bool gMicEnabled = false;

static NSError *RecorderError(OSStatus status, NSString *message) {
    return [NSError errorWithDomain:@"PodiumCallRecorder"
                               code:status
                           userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"%@ (%d)", message, (int)status]}];
}

static AudioStreamBasicDescription PCMFormat(void) {
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = PodiumAudioSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 16;
    format.mBytesPerFrame = 2;
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = 2;
    return format;
}

void PodiumCallRecorderAppendMic(const int16_t *samples, uint32_t frames) {
    if (!atomic_load_explicit(&gActive, memory_order_relaxed)) return;
    if (!atomic_load_explicit(&gMicEnabled, memory_order_relaxed)) return;
    if (!os_unfair_lock_trylock(&gLock)) return;
    for (uint32_t i = 0; i < frames; i++) {
        if (gMicCount == kMicRingFrames) {
            gMicRead = (gMicRead + 1) % kMicRingFrames;
            gMicCount--;
        }
        gMicRing[(gMicRead + gMicCount) % kMicRingFrames] = samples[i];
        gMicCount++;
    }
    os_unfair_lock_unlock(&gLock);
}

void PodiumCallRecorderAppendPlayout(const int16_t *samples, uint32_t frames) {
    if (!atomic_load_explicit(&gActive, memory_order_relaxed)) return;
    if (!os_unfair_lock_trylock(&gLock)) return;
    if (gFile == NULL) {
        os_unfair_lock_unlock(&gLock);
        return;
    }
    // Keep the microphone close to the playout clock if the two drift apart.
    if (gMicCount > kMaxMicBacklogFrames) {
        UInt32 drop = gMicCount - kMaxMicBacklogFrames;
        gMicRead = (gMicRead + drop) % kMicRingFrames;
        gMicCount -= drop;
    }
    uint32_t offset = 0;
    while (offset < frames) {
        UInt32 n = MIN(frames - offset, kMixChunkFrames);
        for (UInt32 i = 0; i < n; i++) {
            int32_t mixed = samples[offset + i];
            if (gMicCount > 0) {
                mixed += gMicRing[gMicRead];
                gMicRead = (gMicRead + 1) % kMicRingFrames;
                gMicCount--;
            }
            gMix[i] = (int16_t)MAX(INT16_MIN, MIN(INT16_MAX, mixed));
        }
        AudioBufferList list;
        list.mNumberBuffers = 1;
        list.mBuffers[0].mNumberChannels = 1;
        list.mBuffers[0].mDataByteSize = n * sizeof(int16_t);
        list.mBuffers[0].mData = gMix;
        if (ExtAudioFileWriteAsync(gFile, n, &list) == noErr) {
            gFramesWritten += n;
        }
        offset += n;
    }
    os_unfair_lock_unlock(&gLock);
}

@implementation PodiumCallRecorder

+ (BOOL)startWithPath:(NSString *)path error:(NSError **)error {
    os_unfair_lock_lock(&gLock);
    BOOL busy = gFile != NULL;
    os_unfair_lock_unlock(&gLock);
    if (busy) {
        if (error) *error = RecorderError(-1, @"A recording is already in progress");
        return NO;
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    AudioStreamBasicDescription aac = {0};
    aac.mSampleRate = PodiumAudioSampleRate;
    aac.mFormatID = kAudioFormatMPEG4AAC;
    aac.mChannelsPerFrame = 1;

    ExtAudioFileRef file = NULL;
    OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                kAudioFileM4AType, &aac, NULL,
                                                kAudioFileFlags_EraseFile, &file);
    if (status != noErr) {
        if (error) *error = RecorderError(status, @"Could not create the recording file");
        return NO;
    }

    // The hardware encoder can be unavailable while other audio is running.
    UInt32 codec = kAppleSoftwareAudioCodecManufacturer;
    ExtAudioFileSetProperty(file, kExtAudioFileProperty_CodecManufacturer, sizeof(codec), &codec);

    AudioStreamBasicDescription pcm = PCMFormat();
    status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(pcm), &pcm);
    if (status != noErr) {
        ExtAudioFileDispose(file);
        if (error) *error = RecorderError(status, @"Could not configure the recording file");
        return NO;
    }

    AudioConverterRef converter = NULL;
    UInt32 size = sizeof(converter);
    if (ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr
        && converter != NULL) {
        UInt32 bitRate = kBitRate;
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, sizeof(bitRate), &bitRate);
        CFArrayRef config = NULL;
        ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig, sizeof(config), &config);
    }

    // Primes the async writer so the IO thread never allocates.
    ExtAudioFileWriteAsync(file, 0, NULL);

    os_unfair_lock_lock(&gLock);
    gFile = file;
    gPath = [path copy];
    gFramesWritten = 0;
    gMicRead = 0;
    gMicCount = 0;
    os_unfair_lock_unlock(&gLock);
    atomic_store(&gActive, true);
    return YES;
}

+ (NSString *)stop {
    atomic_store(&gActive, false);
    os_unfair_lock_lock(&gLock);
    ExtAudioFileRef file = gFile;
    NSString *path = gPath;
    int64_t frames = gFramesWritten;
    gFile = NULL;
    gPath = nil;
    os_unfair_lock_unlock(&gLock);

    if (file == NULL) return nil;
    ExtAudioFileDispose(file);
    if (frames == 0) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return nil;
    }
    return path;
}

+ (void)setMicEnabled:(BOOL)enabled {
    atomic_store(&gMicEnabled, enabled);
}

@end
