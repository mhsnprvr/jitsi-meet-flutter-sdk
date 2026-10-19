#import "PodiumScreenRecorder.h"

#import <Accelerate/Accelerate.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <JitsiMeetSDK/JitsiMeetSDK.h>
#import <QuartzCore/QuartzCore.h>
#import <WebRTC/WebRTC.h>
#import <stdatomic.h>

static const double kMinFrameInterval = 0.1; // 10 fps
static const int kMaxWidth = 1280;
static const CGFloat kJpegQuality = 0.8;
static const int kSignatureCols = 32;
static const int kSignatureRows = 18;
static const int kBitRate = 700000;
static NSString *const kIndexFile = @"frames.idx";

static NSError *ScreenError(NSString *message) {
    return [NSError errorWithDomain:@"PodiumScreenRecorder"
                               code:-1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

static NSString *FrameName(int number) {
    return [NSString stringWithFormat:@"f_%06d.jpg", number];
}

@interface PodiumScreenRecorder () <RTC_OBJC_TYPE(RTCVideoRenderer)>
@end

@implementation PodiumScreenRecorder {
    NSString *_directory;
    dispatch_queue_t _queue;
    CFTimeInterval _startedAt;
    CFTimeInterval _lastAcceptedAt;
    atomic_bool _busy;
    atomic_bool _closed;
    FILE *_index;
    uint8_t _signature[kSignatureCols * kSignatureRows];
    BOOL _hasSignature;
    int _frames;
    int _width;
    int _height;
    vImage_YpCbCrToARGB _conversion;
}

static PodiumScreenRecorder *gCurrent;

+ (void)startWithPcId:(NSInteger)pcId
              trackId:(NSString *)trackId
            directory:(NSString *)directory
           completion:(void (^)(BOOL))completion {
    PodiumScreenRecorder *previous = gCurrent;
    gCurrent = nil;
    if (previous) {
        [PodiumVideoTap removeRenderer:previous];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [previous close]; });
    }
    PodiumScreenRecorder *recorder = [[PodiumScreenRecorder alloc] initWithDirectory:directory];
    if (!recorder) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
        return;
    }
    gCurrent = recorder;
    [PodiumVideoTap addRenderer:recorder pcId:pcId trackId:trackId completion:^(BOOL attached) {
        if (!attached && gCurrent == recorder) {
            gCurrent = nil;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [recorder close]; });
        }
        completion(attached);
    }];
}

+ (NSDictionary<NSString *, id> *)stop {
    __block PodiumScreenRecorder *recorder = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        recorder = gCurrent;
        gCurrent = nil;
        if (recorder) [PodiumVideoTap removeRenderer:recorder];
    });
    return [recorder close];
}

- (instancetype)initWithDirectory:(NSString *)directory {
    self = [super init];
    if (!self) return nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    _index = fopen([directory stringByAppendingPathComponent:kIndexFile].fileSystemRepresentation, "a");
    if (_index == NULL) return nil;
    _directory = [directory copy];
    _queue = dispatch_queue_create("PodiumScreenRecorder", DISPATCH_QUEUE_SERIAL);
    _startedAt = CACurrentMediaTime();
    _lastAcceptedAt = -1;
    vImage_YpCbCrPixelRange range = {16, 128, 235, 240, 255, 0, 255, 1};
    vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &range,
                                                  &_conversion, kvImage420Yp8_Cb8_Cr8,
                                                  kvImageARGB8888, kvImageNoFlags);
    return self;
}

- (NSDictionary<NSString *, id> *)close {
    atomic_store(&_closed, true);
    __block NSDictionary *result = nil;
    dispatch_sync(_queue, ^{
        if (self->_index != NULL) {
            fflush(self->_index);
            fsync(fileno(self->_index));
            fclose(self->_index);
            self->_index = NULL;
        }
        if (self->_frames > 0) {
            result = @{
                @"frames" : @(self->_frames),
                @"width" : @(self->_width),
                @"height" : @(self->_height),
                @"durationMs" : @((int64_t)((CACurrentMediaTime() - self->_startedAt) * 1000)),
            };
        }
    });
    return result;
}

#pragma mark - RTCVideoRenderer

- (void)setSize:(CGSize)size {
}

- (void)renderFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame {
    if (frame == nil || atomic_load(&_closed)) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (_lastAcceptedAt >= 0 && now - _lastAcceptedAt < kMinFrameInterval) return;
    // Drop rather than queue when the previous frame is still being saved.
    bool expected = false;
    if (!atomic_compare_exchange_strong(&_busy, &expected, true)) return;
    _lastAcceptedAt = now;
    int64_t atMs = (int64_t)((now - _startedAt) * 1000);
    dispatch_async(_queue, ^{
        @autoreleasepool {
            [self save:frame atMs:atMs];
        }
        atomic_store(&self->_busy, false);
    });
}

- (void)save:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame atMs:(int64_t)atMs {
    if (atomic_load(&_closed) || _index == NULL) return;
    id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)> source = frame.buffer;
    double scale = MIN(1.0, (double)kMaxWidth / MAX(source.width, source.height));
    int w = MAX(2, (int)(source.width * scale) & ~1);
    int h = MAX(2, (int)(source.height * scale) & ~1);
    id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)> scaled = source;
    if ((w != source.width || h != source.height)
        && [source respondsToSelector:@selector(cropAndScaleWith:offsetY:cropWidth:cropHeight:scaleWidth:scaleHeight:)]) {
        scaled = [source cropAndScaleWith:0 offsetY:0 cropWidth:source.width cropHeight:source.height
                               scaleWidth:w scaleHeight:h];
    }
    id<RTC_OBJC_TYPE(RTCI420Buffer)> i420 = [scaled toI420];
    if (i420 == nil) return;
    w = i420.width;
    h = i420.height;

    uint8_t signature[kSignatureCols * kSignatureRows];
    for (int r = 0; r < kSignatureRows; r++) {
        for (int c = 0; c < kSignatureCols; c++) {
            int px = (c * w + w / 2) / kSignatureCols;
            int py = (r * h + h / 2) / kSignatureRows;
            signature[r * kSignatureCols + c] = i420.dataY[py * i420.strideY + px];
        }
    }
    if (_hasSignature) {
        long diff = 0;
        for (int i = 0; i < kSignatureCols * kSignatureRows; i++) {
            diff += labs((long)signature[i] - (long)_signature[i]);
        }
        if ((double)diff / (kSignatureCols * kSignatureRows) < 1.0) return;
    }
    memcpy(_signature, signature, sizeof(signature));
    _hasSignature = YES;

    int number = _frames + 1;
    if (![self writeJpeg:i420 number:number]) return;
    _frames = number;
    BOOL rotated = frame.rotation == RTCVideoRotation_90 || frame.rotation == RTCVideoRotation_270;
    _width = rotated ? h : w;
    _height = rotated ? w : h;
    fprintf(_index, "%d %lld %d %d %d\n", number, atMs, w, h, (int)frame.rotation);
    fflush(_index);
}

- (BOOL)writeJpeg:(id<RTC_OBJC_TYPE(RTCI420Buffer)>)i420 number:(int)number {
    int w = i420.width;
    int h = i420.height;
    size_t rowBytes = (size_t)w * 4;
    void *argb = malloc(rowBytes * h);
    if (argb == NULL) return NO;
    vImage_Buffer y = {(void *)i420.dataY, (vImagePixelCount)h, (vImagePixelCount)w, (size_t)i420.strideY};
    vImage_Buffer cb = {(void *)i420.dataU, (vImagePixelCount)i420.chromaHeight, (vImagePixelCount)i420.chromaWidth, (size_t)i420.strideU};
    vImage_Buffer cr = {(void *)i420.dataV, (vImagePixelCount)i420.chromaHeight, (vImagePixelCount)i420.chromaWidth, (size_t)i420.strideV};
    vImage_Buffer dest = {argb, (vImagePixelCount)h, (vImagePixelCount)w, rowBytes};
    const uint8_t permute[4] = {0, 1, 2, 3};
    vImage_Error status = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&y, &cb, &cr, &dest, &_conversion,
                                                                 permute, 255, kvImageNoFlags);
    BOOL ok = NO;
    if (status == kvImageNoError) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(argb, w, h, 8, rowBytes, space,
                                                     kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Big);
        CGImageRef image = context ? CGBitmapContextCreateImage(context) : NULL;
        if (image) {
            NSURL *url = [NSURL fileURLWithPath:[_directory stringByAppendingPathComponent:FrameName(number)]];
            CGImageDestinationRef destination =
                CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.jpeg"), 1, NULL);
            if (destination) {
                NSDictionary *options = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(kJpegQuality)};
                CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)options);
                ok = CGImageDestinationFinalize(destination);
                CFRelease(destination);
            }
            CGImageRelease(image);
        }
        if (context) CGContextRelease(context);
        CGColorSpaceRelease(space);
    }
    free(argb);
    return ok;
}

#pragma mark - Encoding

typedef struct {
    int number;
    int64_t atMs;
    int width;
    int height;
    int rotation;
} FrameEntry;

/// Reads the index, skipping a line cut short by a crash and frames whose file is missing.
static NSData *ReadIndex(NSString *directory) {
    NSString *text = [NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:kIndexFile]
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    NSMutableData *entries = [NSMutableData data];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        FrameEntry e;
        long long atMs;
        if (sscanf(line.UTF8String, "%d %lld %d %d %d", &e.number, &atMs, &e.width, &e.height, &e.rotation) != 5) continue;
        e.atMs = atMs;
        if (![fm fileExistsAtPath:[directory stringByAppendingPathComponent:FrameName(e.number)]]) continue;
        [entries appendBytes:&e length:sizeof(e)];
    }
    return entries;
}

static BOOL WaitUntilReady(AVAssetWriterInput *input, AVAssetWriter *writer) {
    for (int i = 0; i < 2000 && !input.readyForMoreMediaData; i++) {
        if (writer.status != AVAssetWriterStatusWriting) return NO;
        usleep(5000);
    }
    return input.readyForMoreMediaData;
}

/// Draws the JPEG upright and fitted inside the pixel buffer, on black.
static BOOL DrawFrame(NSString *path, int rotation, CVPixelBufferRef buffer) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!source) return NO;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return NO;

    CVPixelBufferLockBaseAddress(buffer, 0);
    size_t width = CVPixelBufferGetWidth(buffer);
    size_t height = CVPixelBufferGetHeight(buffer);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), width, height, 8,
                                                 CVPixelBufferGetBytesPerRow(buffer), space,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    BOOL ok = context != NULL;
    if (context) {
        CGContextSetRGBFillColor(context, 0, 0, 0, 1);
        CGContextFillRect(context, CGRectMake(0, 0, width, height));
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        double iw = CGImageGetWidth(image);
        double ih = CGImageGetHeight(image);
        BOOL rotated = rotation == 90 || rotation == 270;
        double scale = MIN(width / (rotated ? ih : iw), height / (rotated ? iw : ih));
        CGContextTranslateCTM(context, width / 2.0, height / 2.0);
        // Core Graphics is y-up, so a clockwise rotation is a negative angle.
        CGContextRotateCTM(context, -rotation * M_PI / 180.0);
        CGContextScaleCTM(context, scale, scale);
        CGContextDrawImage(context, CGRectMake(-iw / 2, -ih / 2, iw, ih), image);
        CGContextRelease(context);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    CGImageRelease(image);
    return ok;
}

+ (NSDictionary<NSString *, id> *)encodeDirectory:(NSString *)directory
                                           toPath:(NSString *)path
                                            endMs:(int64_t)endMs
                                         progress:(void (^)(int, int))progress
                                            error:(NSError **)error {
    NSData *index = ReadIndex(directory);
    int count = (int)(index.length / sizeof(FrameEntry));
    const FrameEntry *entries = index.bytes;
    if (count == 0) {
        if (error) *error = ScreenError(@"No screen frames to encode");
        return nil;
    }
    BOOL firstRotated = entries[0].rotation == 90 || entries[0].rotation == 270;
    int width = MAX(16, (firstRotated ? entries[0].height : entries[0].width) / 16 * 16);
    int height = MAX(16, (firstRotated ? entries[0].width : entries[0].height) / 16 * 16);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tmp = [path stringByAppendingString:@".tmp.mp4"];
    [fm removeItemAtPath:tmp error:nil];
    NSError *writerError = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:tmp]
                                                     fileType:AVFileTypeMPEG4
                                                        error:&writerError];
    if (!writer) {
        if (error) *error = writerError;
        return nil;
    }
    NSDictionary *settings = @{
        AVVideoCodecKey : AVVideoCodecTypeH264,
        AVVideoWidthKey : @(width),
        AVVideoHeightKey : @(height),
        AVVideoCompressionPropertiesKey : @{
            AVVideoAverageBitRateKey : @(kBitRate),
            AVVideoMaxKeyFrameIntervalKey : @20,
            AVVideoMaxKeyFrameIntervalDurationKey : @2,
            AVVideoExpectedSourceFrameRateKey : @10,
            AVVideoProfileLevelKey : AVVideoProfileLevelH264HighAutoLevel,
        },
    };
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                   outputSettings:settings];
    input.expectsMediaDataInRealTime = NO;
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                   sourcePixelBufferAttributes:@{
                                       (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                                       (NSString *)kCVPixelBufferWidthKey : @(width),
                                       (NSString *)kCVPixelBufferHeightKey : @(height),
                                   }];
    if (![writer canAddInput:input]) {
        if (error) *error = ScreenError(@"Could not configure the video encoder");
        return nil;
    }
    [writer addInput:input];
    if (![writer startWriting]) {
        if (error) *error = writer.error ?: ScreenError(@"Could not start the video encoder");
        return nil;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    CVPixelBufferRef last = NULL;
    int64_t lastMs = -1;
    BOOL failed = NO;
    for (int i = 0; i < count && !failed; i++) {
        @autoreleasepool {
            CVPixelBufferRef buffer = NULL;
            if (adaptor.pixelBufferPool == NULL
                || CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) != kCVReturnSuccess) {
                failed = YES;
                break;
            }
            NSString *framePath = [directory stringByAppendingPathComponent:FrameName(entries[i].number)];
            if (DrawFrame(framePath, entries[i].rotation, buffer)) {
                // The clip starts when the share did, so the first picture is shown from 0.
                int64_t ms = lastMs < 0 ? 0 : MAX(entries[i].atMs, lastMs + 1);
                if (!WaitUntilReady(input, writer)
                    || ![adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(ms, 1000)]) {
                    failed = YES;
                } else {
                    lastMs = ms;
                    if (last) CVPixelBufferRelease(last);
                    last = CVPixelBufferRetain(buffer);
                }
            }
            CVPixelBufferRelease(buffer);
            if (progress) progress(i + 1, count);
        }
    }
    // Hold the last picture until the share ended.
    if (!failed && last && endMs > lastMs) {
        if (WaitUntilReady(input, writer)
            && [adaptor appendPixelBuffer:last withPresentationTime:CMTimeMake(endMs, 1000)]) {
            lastMs = endMs;
        }
    }
    if (last) CVPixelBufferRelease(last);

    if (failed || lastMs < 0) {
        [writer cancelWriting];
        [fm removeItemAtPath:tmp error:nil];
        if (error) *error = writer.error ?: ScreenError(@"Could not encode the screen frames");
        return nil;
    }
    [input markAsFinished];
    [writer endSessionAtSourceTime:CMTimeMake(lastMs, 1000)];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) {
        [fm removeItemAtPath:tmp error:nil];
        if (error) *error = writer.error ?: ScreenError(@"Could not finish the screen clip");
        return nil;
    }
    [fm removeItemAtPath:path error:nil];
    NSError *moveError = nil;
    if (![fm moveItemAtPath:tmp toPath:path error:&moveError]) {
        if (error) *error = moveError;
        return nil;
    }
    return @{@"width" : @(width), @"height" : @(height), @"durationMs" : @(lastMs)};
}

@end
