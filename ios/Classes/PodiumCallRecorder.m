#import "PodiumCallRecorder.h"

#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdio.h>
#import <unistd.h>

const double PodiumAudioSampleRate = 48000;

static const UInt32 kBitRate = 96000;
static const UInt32 kSamplesPerFrame = 1024;
static const UInt32 kMicRingFrames = 48000;      // 1 s
static const UInt32 kMaxMicBacklogFrames = 9600; // 200 ms
static const UInt32 kMixChunkFrames = 4096;
static const UInt32 kPcmRingFrames = 48000 * 4;  // 4 s between the IO thread and the encoder
static const UInt32 kEncodeInputFrames = 4096;
static const OSStatus kNeedMoreInput = 'more';
/// How long playout may be missing before the wall clock takes over the timeline.
static const uint64_t kPlayoutTimeoutNs = 300 * NSEC_PER_MSEC;

static const int kAdtsSampleRates[] = {
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350
};

// Shared with the audio IO thread and guarded by `gLock`, which the IO thread only ever
// try-locks so it never waits on start/stop.
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static int16_t gMicRing[kMicRingFrames];
static UInt32 gMicRead = 0;
static UInt32 gMicCount = 0;
static int16_t gMix[kMixChunkFrames];

// Single consumer (encoder queue) PCM ring. Producers (the IO thread, or the encoder queue
// writing silence) push only while holding `gLock`.
static int16_t gPcmRing[kPcmRingFrames];
static _Atomic uint64_t gPcmWritten = 0;
static _Atomic uint64_t gPcmRead = 0;

static atomic_bool gActive = false;
static atomic_bool gMicEnabled = false;

// Playout only runs once WebRTC has a media connection, so a muted host alone in the room has
// none; the encoder queue then writes silence by the wall clock instead.
static _Atomic uint64_t gLastPlayoutNs = 0;
static uint64_t gSilenceNs = 0; // Timeline written as silence, only touched on gQueue.
static int16_t gSilence[kMixChunkFrames];

/// Encoder state, only touched on `gQueue` (and by start/stop around it).
typedef struct {
    AudioConverterRef converter;
    UInt32 maxPacketSize;
    uint8_t *packet;
    int16_t input[kEncodeInputFrames];
    BOOL draining;
    FILE *file;
    UInt32 framesPerChunk;
    UInt32 framesInChunk;
    int chunks;
    int64_t frames;
    char directory[PATH_MAX];
} Encoder;

static Encoder gEncoder;
static dispatch_queue_t gQueue;
static dispatch_source_t gTimer;

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

static AudioStreamBasicDescription AACFormat(double sampleRate, UInt32 channels) {
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = sampleRate;
    format.mFormatID = kAudioFormatMPEG4AAC;
    format.mFormatFlags = kMPEG4Object_AAC_LC;
    format.mFramesPerPacket = kSamplesPerFrame;
    format.mChannelsPerFrame = channels;
    return format;
}

/// A software encoder, since the hardware one can be unavailable while other audio is running.
static OSStatus CreateEncoder(double sampleRate, UInt32 channels, AudioConverterRef *converter) {
    AudioStreamBasicDescription pcm = PCMFormat();
    pcm.mSampleRate = sampleRate;
    AudioStreamBasicDescription aac = AACFormat(sampleRate, channels);
    AudioClassDescription software = {
        kAudioEncoderComponentType, kAudioFormatMPEG4AAC, kAppleSoftwareAudioCodecManufacturer
    };
    OSStatus status = AudioConverterNewSpecific(&pcm, &aac, 1, &software, converter);
    if (status != noErr) return status;
    UInt32 bitRate = kBitRate;
    AudioConverterSetProperty(*converter, kAudioConverterEncodeBitRate, sizeof(bitRate), &bitRate);
    return noErr;
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

static void PushPcm(const int16_t *samples, UInt32 frames) {
    uint64_t written = atomic_load_explicit(&gPcmWritten, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&gPcmRead, memory_order_acquire);
    UInt32 space = kPcmRingFrames - (UInt32)(written - read);
    UInt32 n = MIN(frames, space);
    for (UInt32 i = 0; i < n; i++) {
        gPcmRing[(written + i) % kPcmRingFrames] = samples[i];
    }
    atomic_store_explicit(&gPcmWritten, written + n, memory_order_release);
}

/// Mixes the microphone into [samples] and queues them for encoding. Call with `gLock` held.
static void MixAndPush(const int16_t *samples, uint32_t frames) {
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
        PushPcm(gMix, n);
        offset += n;
    }
}

void PodiumCallRecorderAppendPlayout(const int16_t *samples, uint32_t frames) {
    if (!atomic_load_explicit(&gActive, memory_order_relaxed)) return;
    atomic_store_explicit(&gLastPlayoutNs, clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
                          memory_order_relaxed);
    if (!os_unfair_lock_trylock(&gLock)) return;
    MixAndPush(samples, frames);
    os_unfair_lock_unlock(&gLock);
}

/// Runs on gQueue. Writes silence for the time since playout stopped, if it has.
static void FillSilenceWithoutPlayout(void) {
    if (!atomic_load_explicit(&gActive, memory_order_relaxed)) return;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    uint64_t last = atomic_load_explicit(&gLastPlayoutNs, memory_order_relaxed);
    if (now - last < kPlayoutTimeoutNs) {
        gSilenceNs = last;
        return;
    }
    if (gSilenceNs < last) gSilenceNs = last;
    uint64_t frames = (now - gSilenceNs) * (uint64_t)PodiumAudioSampleRate / NSEC_PER_SEC;
    if (frames == 0) return;
    gSilenceNs += frames * NSEC_PER_SEC / (uint64_t)PodiumAudioSampleRate;
    os_unfair_lock_lock(&gLock);
    while (frames > 0) {
        uint32_t n = (uint32_t)MIN(frames, (uint64_t)kMixChunkFrames);
        MixAndPush(gSilence, n);
        frames -= n;
    }
    os_unfair_lock_unlock(&gLock);
}

#pragma mark - Encoding (on gQueue)

static OSStatus ProvideInput(AudioConverterRef converter,
                             UInt32 *ioNumberDataPackets,
                             AudioBufferList *ioData,
                             AudioStreamPacketDescription **outDescriptions,
                             void *userData) {
    Encoder *encoder = (Encoder *)userData;
    uint64_t read = atomic_load_explicit(&gPcmRead, memory_order_relaxed);
    uint64_t written = atomic_load_explicit(&gPcmWritten, memory_order_acquire);
    UInt32 n = MIN(MIN(*ioNumberDataPackets, kEncodeInputFrames), (UInt32)(written - read));
    if (n == 0) {
        *ioNumberDataPackets = 0;
        ioData->mBuffers[0].mDataByteSize = 0;
        ioData->mBuffers[0].mData = NULL;
        // No data and no error ends the stream, which flushes the encoder.
        return encoder->draining ? noErr : kNeedMoreInput;
    }
    for (UInt32 i = 0; i < n; i++) {
        encoder->input[i] = gPcmRing[(read + i) % kPcmRingFrames];
    }
    atomic_store_explicit(&gPcmRead, read + n, memory_order_release);
    *ioNumberDataPackets = n;
    ioData->mBuffers[0].mNumberChannels = 1;
    ioData->mBuffers[0].mDataByteSize = n * sizeof(int16_t);
    ioData->mBuffers[0].mData = encoder->input;
    return noErr;
}

static void CloseChunk(Encoder *encoder) {
    if (encoder->file == NULL) return;
    fflush(encoder->file);
    fsync(fileno(encoder->file));
    fclose(encoder->file);
    encoder->file = NULL;
    encoder->framesInChunk = 0;
}

static void WriteFrame(Encoder *encoder, const uint8_t *data, UInt32 size) {
    if (encoder->file == NULL) {
        encoder->chunks++;
        char path[PATH_MAX];
        snprintf(path, sizeof(path), "%s/chunk_%05d.aac", encoder->directory, encoder->chunks);
        encoder->file = fopen(path, "wb");
        if (encoder->file == NULL) {
            NSLog(@"PodiumCallRecorder: could not open %s", path);
            return;
        }
    }
    UInt32 length = size + 7;
    uint8_t header[7] = {
        0xFF,
        0xF1, // MPEG-4, no CRC
        (uint8_t)((1 << 6) | (3 << 2)), // LC, 48 kHz, channel config high bit 0
        (uint8_t)((1 << 6) | (length >> 11)), // mono
        (uint8_t)((length >> 3) & 0xFF),
        (uint8_t)(((length & 7) << 5) | 0x1F),
        0xFC,
    };
    fwrite(header, 1, sizeof(header), encoder->file);
    fwrite(data, 1, size, encoder->file);
    // Hand every frame to the OS so it survives the app being killed.
    fflush(encoder->file);
    encoder->frames++;
    if (++encoder->framesInChunk >= encoder->framesPerChunk) CloseChunk(encoder);
}

static void Encode(Encoder *encoder) {
    if (encoder->converter == NULL) return;
    while (true) {
        uint64_t available = atomic_load_explicit(&gPcmWritten, memory_order_acquire)
            - atomic_load_explicit(&gPcmRead, memory_order_relaxed);
        if (!encoder->draining && available < kSamplesPerFrame) return;
        UInt32 packets = 1;
        AudioBufferList output;
        output.mNumberBuffers = 1;
        output.mBuffers[0].mNumberChannels = 1;
        output.mBuffers[0].mDataByteSize = encoder->maxPacketSize;
        output.mBuffers[0].mData = encoder->packet;
        AudioStreamPacketDescription description = {0};
        OSStatus status = AudioConverterFillComplexBuffer(encoder->converter, ProvideInput, encoder,
                                                          &packets, &output, &description);
        if (packets > 0) {
            WriteFrame(encoder, encoder->packet + description.mStartOffset,
                       description.mDataByteSize ?: output.mBuffers[0].mDataByteSize);
        }
        if (status == kNeedMoreInput) return;
        if (status != noErr) {
            NSLog(@"PodiumCallRecorder: encoding failed (%d)", (int)status);
            return;
        }
        if (packets == 0) return; // Flushed.
    }
}

@implementation PodiumCallRecorder

+ (BOOL)startInDirectory:(NSString *)directory chunkSeconds:(NSInteger)chunkSeconds error:(NSError **)error {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gQueue = dispatch_queue_create("PodiumCallRecorder.encoder",
                                       dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    if (atomic_load(&gActive) || gTimer != nil) {
        if (error) *error = RecorderError(-1, @"A recording is already in progress");
        return NO;
    }
    if (strlen(directory.fileSystemRepresentation) >= PATH_MAX - 32) {
        if (error) *error = RecorderError(-1, @"The recording directory path is too long");
        return NO;
    }
    NSError *dirError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&dirError]) {
        if (error) *error = RecorderError(-1, dirError.localizedDescription ?: @"Could not create the recording directory");
        return NO;
    }

    AudioConverterRef converter = NULL;
    OSStatus status = CreateEncoder(PodiumAudioSampleRate, 1, &converter);
    if (status != noErr) {
        if (error) *error = RecorderError(status, @"Could not create the audio encoder");
        return NO;
    }
    UInt32 maxPacketSize = 0;
    UInt32 size = sizeof(maxPacketSize);
    AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxPacketSize);
    if (maxPacketSize == 0) maxPacketSize = 2048;

    dispatch_sync(gQueue, ^{
        memset(&gEncoder, 0, sizeof(gEncoder));
        gEncoder.converter = converter;
        gEncoder.maxPacketSize = maxPacketSize;
        gEncoder.packet = malloc(maxPacketSize);
        gEncoder.framesPerChunk = (UInt32)MAX(1, chunkSeconds * (NSInteger)PodiumAudioSampleRate / kSamplesPerFrame);
        strlcpy(gEncoder.directory, directory.fileSystemRepresentation, sizeof(gEncoder.directory));
    });

    os_unfair_lock_lock(&gLock);
    gMicRead = 0;
    gMicCount = 0;
    atomic_store(&gPcmWritten, 0);
    atomic_store(&gPcmRead, 0);
    os_unfair_lock_unlock(&gLock);
    uint64_t startNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    atomic_store(&gLastPlayoutNs, startNs);
    dispatch_sync(gQueue, ^{ gSilenceNs = startNs; });

    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 20 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gTimer, ^{
        FillSilenceWithoutPlayout();
        Encode(&gEncoder);
    });
    dispatch_resume(gTimer);
    atomic_store(&gActive, true);
    return YES;
}

+ (NSDictionary<NSString *, id> *)stop {
    atomic_store(&gActive, false);
    // Waits for an IO callback that is still pushing audio.
    os_unfair_lock_lock(&gLock);
    os_unfair_lock_unlock(&gLock);
    if (gTimer == nil) return nil;
    dispatch_source_cancel(gTimer);
    gTimer = nil;

    __block NSDictionary *result = nil;
    dispatch_sync(gQueue, ^{
        gEncoder.draining = YES;
        Encode(&gEncoder);
        CloseChunk(&gEncoder);
        if (gEncoder.converter != NULL) AudioConverterDispose(gEncoder.converter);
        free(gEncoder.packet);
        if (gEncoder.frames > 0) {
            result = @{
                @"dir" : [NSString stringWithUTF8String:gEncoder.directory],
                @"chunks" : @(gEncoder.chunks),
                @"durationMs" : @(gEncoder.frames * kSamplesPerFrame * 1000 / (int64_t)PodiumAudioSampleRate),
            };
        }
        memset(&gEncoder, 0, sizeof(gEncoder));
    });
    return result;
}

+ (void)setMicEnabled:(BOOL)enabled {
    atomic_store(&gMicEnabled, enabled);
}

+ (int64_t)joinChunksInDirectory:(NSString *)directory toPath:(NSString *)path error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *name in [fm contentsOfDirectoryAtPath:directory error:nil] ?: @[]) {
        if ([name hasPrefix:@"chunk_"] && [name hasSuffix:@".aac"]) [names addObject:name];
    }
    [names sortUsingSelector:@selector(compare:)];
    if (names.count == 0) {
        if (error) *error = RecorderError(-1, @"No audio chunks to join");
        return -1;
    }

    NSString *tmp = [path stringByAppendingString:@".tmp"];
    [fm removeItemAtPath:tmp error:nil];
    AudioFileID file = NULL;
    double sampleRate = 0;
    SInt64 packetIndex = 0;
    OSStatus status = noErr;

    for (NSString *name in names) {
        NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
        const uint8_t *bytes = data.bytes;
        NSUInteger length = data.length;
        NSUInteger pos = 0;
        NSMutableData *payload = [NSMutableData dataWithCapacity:length];
        NSMutableData *descriptions = [NSMutableData data];
        while (pos + 7 <= length) {
            if (bytes[pos] != 0xFF || (bytes[pos + 1] & 0xF0) != 0xF0) break;
            NSUInteger headerLength = (bytes[pos + 1] & 1) ? 7 : 9;
            NSUInteger frameLength = ((bytes[pos + 3] & 3) << 11) | (bytes[pos + 4] << 3) | (bytes[pos + 5] >> 5);
            if (frameLength <= headerLength || pos + frameLength > length) break;
            if (file == NULL) {
                int rateIndex = (bytes[pos + 2] >> 2) & 0xF;
                UInt32 channels = ((bytes[pos + 2] & 1) << 2) | (bytes[pos + 3] >> 6);
                if (rateIndex >= (int)(sizeof(kAdtsSampleRates) / sizeof(int)) || channels == 0) {
                    if (error) *error = RecorderError(-1, @"Unsupported audio chunk format");
                    return -1;
                }
                sampleRate = kAdtsSampleRates[rateIndex];
                AudioStreamBasicDescription aac = AACFormat(sampleRate, channels);
                status = AudioFileCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:tmp],
                                                kAudioFileM4AType, &aac, kAudioFileFlags_EraseFile, &file);
                if (status != noErr) {
                    if (error) *error = RecorderError(status, @"Could not create the audio file");
                    return -1;
                }
                // The file needs the encoder's magic cookie (an MPEG-4 ES descriptor).
                AudioConverterRef converter = NULL;
                if (CreateEncoder(sampleRate, channels, &converter) == noErr) {
                    UInt32 cookieSize = 0;
                    if (AudioConverterGetPropertyInfo(converter, kAudioConverterCompressionMagicCookie,
                                                      &cookieSize, NULL) == noErr && cookieSize > 0) {
                        void *cookie = malloc(cookieSize);
                        if (AudioConverterGetProperty(converter, kAudioConverterCompressionMagicCookie,
                                                      &cookieSize, cookie) == noErr) {
                            AudioFileSetProperty(file, kAudioFilePropertyMagicCookieData, cookieSize, cookie);
                        }
                        free(cookie);
                    }
                    AudioConverterDispose(converter);
                }
            }
            AudioStreamPacketDescription description = {
                .mStartOffset = (SInt64)payload.length,
                .mVariableFramesInPacket = 0,
                .mDataByteSize = (UInt32)(frameLength - headerLength),
            };
            [payload appendBytes:bytes + pos + headerLength length:frameLength - headerLength];
            [descriptions appendBytes:&description length:sizeof(description)];
            pos += frameLength;
        }
        UInt32 packets = (UInt32)(descriptions.length / sizeof(AudioStreamPacketDescription));
        if (packets == 0) continue;
        status = AudioFileWritePackets(file, false, (UInt32)payload.length, descriptions.bytes,
                                       packetIndex, &packets, payload.bytes);
        if (status != noErr) break;
        packetIndex += packets;
    }

    if (file != NULL) AudioFileClose(file);
    if (file == NULL || status != noErr || packetIndex == 0) {
        [fm removeItemAtPath:tmp error:nil];
        if (error) *error = RecorderError(status, @"Could not join the audio chunks");
        return -1;
    }
    [fm removeItemAtPath:path error:nil];
    NSError *moveError = nil;
    if (![fm moveItemAtPath:tmp toPath:path error:&moveError]) {
        if (error) *error = moveError;
        return -1;
    }
    return packetIndex * kSamplesPerFrame * 1000 / (int64_t)sampleRate;
}

@end
