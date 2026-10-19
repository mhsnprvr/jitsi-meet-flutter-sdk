#import "PodiumAudioDevice.h"
#import "PodiumCallRecorder.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <WebRTC/WebRTC.h>
#import <stdatomic.h>

static const AudioUnitElement kOutputBus = 0;
static const AudioUnitElement kInputBus = 1;

@interface PodiumAudioDevice () <RTC_OBJC_TYPE(RTCAudioDevice), RTC_OBJC_TYPE(RTCAudioSessionDelegate)>
@end

// Everything except the IO callbacks runs on the WebRTC audio device thread: the native ADM calls
// the RTCAudioDevice methods there, and session events are forwarded to it with dispatchAsync.
@implementation PodiumAudioDevice {
    id<RTC_OBJC_TYPE(RTCAudioDeviceDelegate)> _delegate;
    RTC_OBJC_TYPE(RTCAudioDeviceGetPlayoutDataBlock) _getPlayoutData;
    RTC_OBJC_TYPE(RTCAudioDeviceDeliverRecordedDataBlock) _deliverRecordedData;
    AudioUnit _unit;
    BOOL _unitStarted;
    BOOL _sessionActivated;
    BOOL _playoutInitialized;
    BOOL _recordingInitialized;
    atomic_bool _playing;
    atomic_bool _recording;
}

+ (instancetype)sharedInstance {
    static PodiumAudioDevice *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[PodiumAudioDevice alloc] init];
    });
    return instance;
}

#pragma mark - IO callbacks (real-time thread)

static OSStatus RenderPlayout(void *refCon,
                              AudioUnitRenderActionFlags *flags,
                              const AudioTimeStamp *timestamp,
                              UInt32 bus,
                              UInt32 frames,
                              AudioBufferList *data) {
    __unsafe_unretained PodiumAudioDevice *device = (__bridge PodiumAudioDevice *)refCon;
    __unsafe_unretained RTC_OBJC_TYPE(RTCAudioDeviceGetPlayoutDataBlock) getPlayoutData = device->_getPlayoutData;
    if (!atomic_load_explicit(&device->_playing, memory_order_relaxed) || getPlayoutData == nil) {
        for (UInt32 i = 0; i < data->mNumberBuffers; i++) {
            memset(data->mBuffers[i].mData, 0, data->mBuffers[i].mDataByteSize);
        }
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
    OSStatus status = getPlayoutData(flags, timestamp, bus, frames, data);
    if (status == noErr && data->mNumberBuffers > 0) {
        PodiumCallRecorderAppendPlayout(data->mBuffers[0].mData, frames);
    }
    return status;
}

static OSStatus DeliverRecorded(void *refCon,
                                AudioUnitRenderActionFlags *flags,
                                const AudioTimeStamp *timestamp,
                                UInt32 bus,
                                UInt32 frames,
                                AudioBufferList *unused) {
    __unsafe_unretained PodiumAudioDevice *device = (__bridge PodiumAudioDevice *)refCon;
    __unsafe_unretained RTC_OBJC_TYPE(RTCAudioDeviceDeliverRecordedDataBlock) deliver = device->_deliverRecordedData;
    if (!atomic_load_explicit(&device->_recording, memory_order_relaxed) || deliver == nil) {
        return noErr;
    }
    AudioUnit unit = device->_unit;
    return deliver(flags, timestamp, bus, frames, NULL, NULL,
                   ^OSStatus(AudioUnitRenderActionFlags *renderFlags,
                             const AudioTimeStamp *renderTimestamp,
                             NSInteger renderBus,
                             UInt32 renderFrames,
                             AudioBufferList *inputData,
                             void *context) {
        OSStatus status = AudioUnitRender(unit, renderFlags, renderTimestamp, (UInt32)renderBus,
                                          renderFrames, inputData);
        if (status == noErr) {
            PodiumCallRecorderAppendMic(inputData->mBuffers[0].mData, renderFrames);
        }
        return status;
    });
}

#pragma mark - RTCAudioDevice

- (double)deviceInputSampleRate {
    return PodiumAudioSampleRate;
}

- (NSTimeInterval)inputIOBufferDuration {
    return AVAudioSession.sharedInstance.IOBufferDuration;
}

- (NSInteger)inputNumberOfChannels {
    return 1;
}

- (NSTimeInterval)inputLatency {
    return AVAudioSession.sharedInstance.inputLatency;
}

- (double)deviceOutputSampleRate {
    return PodiumAudioSampleRate;
}

- (NSTimeInterval)outputIOBufferDuration {
    return AVAudioSession.sharedInstance.IOBufferDuration;
}

- (NSInteger)outputNumberOfChannels {
    return 1;
}

- (NSTimeInterval)outputLatency {
    return AVAudioSession.sharedInstance.outputLatency;
}

- (BOOL)isInitialized {
    return _delegate != nil;
}

- (BOOL)initializeWithDelegate:(id<RTC_OBJC_TYPE(RTCAudioDeviceDelegate)>)delegate {
    _delegate = delegate;
    _getPlayoutData = delegate.getPlayoutData;
    _deliverRecordedData = delegate.deliverRecordedData;
    [[RTC_OBJC_TYPE(RTCAudioSession) sharedInstance] addDelegate:self];
    return YES;
}

- (BOOL)terminateDevice {
    [[RTC_OBJC_TYPE(RTCAudioSession) sharedInstance] removeDelegate:self];
    atomic_store(&_playing, false);
    atomic_store(&_recording, false);
    _playoutInitialized = NO;
    _recordingInitialized = NO;
    [self disposeUnit];
    [self deactivateSession];
    _getPlayoutData = nil;
    _deliverRecordedData = nil;
    _delegate = nil;
    return YES;
}

- (BOOL)isPlayoutInitialized {
    return _playoutInitialized;
}

- (BOOL)initializePlayout {
    _playoutInitialized = [self prepareUnit];
    return _playoutInitialized;
}

- (BOOL)isPlaying {
    return atomic_load(&_playing);
}

- (BOOL)startPlayout {
    atomic_store(&_playing, true);
    return [self startUnit];
}

- (BOOL)stopPlayout {
    atomic_store(&_playing, false);
    _playoutInitialized = NO;
    [self stopUnitIfIdle];
    return YES;
}

- (BOOL)isRecordingInitialized {
    return _recordingInitialized;
}

- (BOOL)initializeRecording {
    _recordingInitialized = [self prepareUnit];
    return _recordingInitialized;
}

- (BOOL)isRecording {
    return atomic_load(&_recording);
}

- (BOOL)startRecording {
    atomic_store(&_recording, true);
    return [self startUnit];
}

- (BOOL)stopRecording {
    atomic_store(&_recording, false);
    _recordingInitialized = NO;
    [self stopUnitIfIdle];
    return YES;
}

#pragma mark - Audio unit

- (BOOL)isActive {
    return atomic_load(&_playing) || atomic_load(&_recording);
}

- (BOOL)activateSession {
    if (_sessionActivated) return YES;
    RTC_OBJC_TYPE(RTCAudioSession) *session = [RTC_OBJC_TYPE(RTCAudioSession) sharedInstance];
    NSError *error = nil;
    [session lockForConfiguration];
    BOOL ok = YES;
    // Jitsi's AudioMode applies its own PlayAndRecord configuration; this only covers the case
    // where WebRTC starts audio before it does.
    if (![session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        ok = [session setConfiguration:[RTC_OBJC_TYPE(RTCAudioSessionConfiguration) webRTCConfiguration]
                                 error:&error];
    }
    if (ok) {
        ok = [session setActive:YES error:&error];
    }
    [session unlockForConfiguration];
    if (!ok) {
        NSLog(@"[PodiumAudioDevice] Failed to activate the audio session: %@", error);
        return NO;
    }
    _sessionActivated = YES;
    return YES;
}

- (void)deactivateSession {
    if (!_sessionActivated) return;
    RTC_OBJC_TYPE(RTCAudioSession) *session = [RTC_OBJC_TYPE(RTCAudioSession) sharedInstance];
    [session lockForConfiguration];
    [session setActive:NO error:nil];
    [session unlockForConfiguration];
    _sessionActivated = NO;
}

- (BOOL)prepareUnit {
    if (_unit != NULL) return YES;
    if (![self activateSession]) return NO;

    AudioComponentDescription description = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_VoiceProcessingIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    AudioUnit unit = NULL;
    OSStatus status = component ? AudioComponentInstanceNew(component, &unit) : kAudio_ParamError;
    if (status != noErr) {
        NSLog(@"[PodiumAudioDevice] Failed to create the voice processing unit: %d", (int)status);
        return NO;
    }

    UInt32 enable = 1;
    UInt32 disable = 0;
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = PodiumAudioSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 16;
    format.mBytesPerFrame = 2;
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = 2;
    AURenderCallbackStruct render = {.inputProc = RenderPlayout, .inputProcRefCon = (__bridge void *)self};
    AURenderCallbackStruct input = {.inputProc = DeliverRecorded, .inputProcRefCon = (__bridge void *)self};

    OSStatus results[] = {
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                             kInputBus, &enable, sizeof(enable)),
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                             kOutputBus, &enable, sizeof(enable)),
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                             kInputBus, &format, sizeof(format)),
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                             kOutputBus, &format, sizeof(format)),
        // WebRTC provides the buffer the microphone is rendered into.
        AudioUnitSetProperty(unit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output,
                             kInputBus, &disable, sizeof(disable)),
        AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                             kOutputBus, &render, sizeof(render)),
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global,
                             kInputBus, &input, sizeof(input)),
    };
    for (size_t i = 0; i < sizeof(results) / sizeof(results[0]); i++) {
        if (results[i] != noErr) {
            NSLog(@"[PodiumAudioDevice] Failed to configure the voice processing unit (step %zu): %d",
                  i, (int)results[i]);
            AudioComponentInstanceDispose(unit);
            return NO;
        }
    }

    status = AudioUnitInitialize(unit);
    if (status != noErr) {
        NSLog(@"[PodiumAudioDevice] Failed to initialize the voice processing unit: %d", (int)status);
        AudioComponentInstanceDispose(unit);
        return NO;
    }
    _unit = unit;
    return YES;
}

- (BOOL)startUnit {
    if (_unitStarted) return YES;
    if (![self prepareUnit] || ![self activateSession]) return NO;
    OSStatus status = AudioOutputUnitStart(_unit);
    if (status != noErr) {
        NSLog(@"[PodiumAudioDevice] Failed to start the voice processing unit: %d", (int)status);
        return NO;
    }
    _unitStarted = YES;
    return YES;
}

- (void)stopUnitIfIdle {
    if ([self isActive]) return;
    if (_unitStarted) {
        AudioOutputUnitStop(_unit);
        _unitStarted = NO;
    }
    [self deactivateSession];
}

- (void)disposeUnit {
    if (_unit == NULL) return;
    if (_unitStarted) {
        AudioOutputUnitStop(_unit);
        _unitStarted = NO;
    }
    AudioUnitUninitialize(_unit);
    AudioComponentInstanceDispose(_unit);
    _unit = NULL;
}

/// Restarts IO after an interruption or a media services reset; callbacks may then arrive on a
/// different thread, which WebRTC has to be told about first.
- (void)restartUnit:(BOOL)recreate {
    id<RTC_OBJC_TYPE(RTCAudioDeviceDelegate)> delegate = _delegate;
    if (delegate == nil) return;
    [delegate notifyAudioInputInterrupted];
    [delegate notifyAudioOutputInterrupted];
    if (recreate) {
        [self disposeUnit];
    } else if (_unitStarted) {
        AudioOutputUnitStop(_unit);
        _unitStarted = NO;
    }
    if (![self isActive]) return;
    // Reactivated directly: RTCAudioSession counts setActive:YES calls and ours is still held.
    if (_sessionActivated) {
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
    }
    [self startUnit];
}

#pragma mark - RTCAudioSessionDelegate (system notification thread)

- (void)audioSessionDidBeginInterruption:(RTC_OBJC_TYPE(RTCAudioSession) *)session {
    [_delegate dispatchAsync:^{
        self->_unitStarted = NO;
    }];
}

- (void)audioSessionDidEndInterruption:(RTC_OBJC_TYPE(RTCAudioSession) *)session
                   shouldResumeSession:(BOOL)shouldResumeSession {
    [_delegate dispatchAsync:^{
        [self restartUnit:NO];
    }];
}

- (void)audioSessionMediaServerReset:(RTC_OBJC_TYPE(RTCAudioSession) *)session {
    [_delegate dispatchAsync:^{
        [self restartUnit:YES];
    }];
}

- (void)audioSessionDidChangeRoute:(RTC_OBJC_TYPE(RTCAudioSession) *)session
                            reason:(AVAudioSessionRouteChangeReason)reason
                     previousRoute:(AVAudioSessionRouteDescription *)previousRoute {
    id<RTC_OBJC_TYPE(RTCAudioDeviceDelegate)> delegate = _delegate;
    [delegate dispatchAsync:^{
        [delegate notifyAudioInputParametersChange];
        [delegate notifyAudioOutputParametersChange];
    }];
}

@end
