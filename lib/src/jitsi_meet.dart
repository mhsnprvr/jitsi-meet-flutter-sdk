import 'jitsi_meet_conference_options.dart';
import 'jitsi_meet_event_listener.dart';
import 'jitsi_meet_platform_interface.dart';
import 'method_response.dart';

/// The entry point for the sdk. It is used to launch the meeting screen,
/// to send and receive all the events.
class JitsiMeet {
  Future<String?> getPlatformVersion() {
    return JitsiMeetPlatform.instance.getPlatformVersion();
  }

  /// Joins a meeting with the given meeting [options] and
  /// optionally a [listener] is given for listening to events triggered by the native sdks.
  Future<MethodResponse> join(JitsiMeetConferenceOptions options,
      [JitsiMeetEventListener? listener]) async {
    return await JitsiMeetPlatform.instance
        .join(options, listener ?? JitsiMeetEventListener());
  }

  /// The localParticipant leaves the current meeting.
  Future<MethodResponse> hangUp() async {
    return await JitsiMeetPlatform.instance.hangUp();
  }

  /// Sets the state of the localParticipant audio [muted] according to the muted parameter.
  Future<MethodResponse> setAudioMuted(bool muted) async {
    return await JitsiMeetPlatform.instance.setAudioMuted(muted);
  }

  /// Sets the state of the localParticipant video [muted] according to the muted parameter.
  Future<MethodResponse> setVideoMuted(bool muted) async {
    return await JitsiMeetPlatform.instance.setVideoMuted(muted);
  }

  /// Sends a message via the data channel [to] one particular participant or to all of them.
  /// If the [to] param is empty, the [message] will be sent to all the participants in the conference.
  ///
  /// In order to get the participantId for the [to] parameter, the [JitsiMeetEventListener.participantsJoined]
  /// event should be listened for, which have as a parameter the participantId and this should be stored somehow.
  Future<MethodResponse> sendEndpointTextMessage(
      {String? to, required String message}) async {
    return await JitsiMeetPlatform.instance
        .sendEndpointTextMessage(to: to, message: message);
  }

  /// Sets the state of the localParticipant screen sharing according to the [enabled] parameter.
  Future<MethodResponse> toggleScreenShare(bool enabled) async {
    return await JitsiMeetPlatform.instance.toggleScreenShare(enabled);
  }

  /// Opens the chat dialog. If [to] contains a valid participantId, the private chat with that
  /// particular participant will be opened.
  Future<MethodResponse> openChat([String? to]) async {
    return await JitsiMeetPlatform.instance.openChat(to);
  }

  /// Sends a chat message via [to] one particular participant or to all of them.
  /// If the [to] param is empty, the [message] will be sent to all the participants in the conference.
  ///
  /// In order to get the participantId for the [to] parameter, the [JitsiMeetEventListener.participantsJoined]
  /// event should be listened for, which have as a parameter the participantId and this should be stored somehow.
  Future<MethodResponse> sendChatMessage(
      {String? to, required String message}) async {
    return await JitsiMeetPlatform.instance
        .sendChatMessage(to: to, message: message);
  }

  /// Closes the chat dialog.
  Future<MethodResponse> closeChat() async {
    return await JitsiMeetPlatform.instance.closeChat();
  }

  /// Sends and event that will trigger the [JitsiMeetEventListener.participantsInfoRetrieved] event
  /// which will contain participants information.
  Future<MethodResponse> retrieveParticipantsInfo() async {
    return await JitsiMeetPlatform.instance.retrieveParticipantsInfo();
  }

  /// Enters Picture in Picture mode.
  Future<MethodResponse> enterPiP() async {
    return await JitsiMeetPlatform.instance.enterPiP();
  }

  /// Sends a command over the Podium channel of the conference, e.g.
  /// `raiseHand`, `lowerHand`, `muteParticipant`, `kickParticipant`.
  /// Results arrive through [JitsiMeetEventListener.podiumEvent].
  Future<MethodResponse> sendPodiumCommand(String name,
      [Map<String, dynamic> data = const {}]) async {
    return await JitsiMeetPlatform.instance.sendPodiumCommand(name, data);
  }

  /// Shows a remote video track (from the `screenShare` podium event) in a
  /// native window over the app, at [left]/[top]/[width]/[height] physical
  /// pixels relative to the Flutter view. Native views can't be drawn over by
  /// Flutter, so hide the stage while sheets or dialogs are open.
  /// Pass a null [trackId] to clear it.
  Future<MethodResponse> setStage({
    required bool visible,
    int left = 0,
    int top = 0,
    int width = 0,
    int height = 0,
    int? pcId,
    String? trackId,
  }) async {
    return await JitsiMeetPlatform.instance.setStage({
      'visible': visible,
      'left': left,
      'top': top,
      'width': width,
      'height': height,
      'pcId': pcId ?? -1,
      'trackId': trackId,
    });
  }

  /// Starts recording what this device hears of the conference, the remote
  /// audio mixed with the local microphone, as AAC chunk files of
  /// [chunkSeconds] in [dir] (`chunk_00001.aac`, ...). Each chunk is a slice
  /// of one encoded stream, written as it is encoded, so a crash loses at most
  /// the frame being written; [joinAudioChunks] joins them without gaps.
  /// The microphone is only included while enabled through
  /// [setCallRecordingMicEnabled], since WebRTC keeps capturing while muted.
  /// Throws a [PlatformException] if the recording can't be started.
  Future<void> startCallRecording({
    required String dir,
    int chunkSeconds = 5,
  }) async {
    await JitsiMeetPlatform.instance.startCallRecording(dir, chunkSeconds);
  }

  /// Stops the conference recording, or returns null if nothing was recorded.
  Future<CallRecordingResult?> stopCallRecording() async {
    final result = await JitsiMeetPlatform.instance.stopCallRecording();
    return result == null ? null : CallRecordingResult.fromMap(result);
  }

  /// Whether the microphone is mixed into the conference recording; set it to
  /// follow the local participant's mute state.
  Future<void> setCallRecordingMicEnabled(bool enabled) async {
    await JitsiMeetPlatform.instance.setCallRecordingMicEnabled(enabled);
  }

  /// Sets the title and text of the ongoing conference notification, updating
  /// it if it is showing. Null restores the default strings. Android only.
  Future<void> setOngoingNotification({String? title, String? text}) async {
    await JitsiMeetPlatform.instance.setOngoingNotification(title, text);
  }

  /// Joins the audio chunks in [dir] into an .m4a at [outPath] without
  /// re-encoding, returning its duration in milliseconds. Works on the chunks
  /// of a recording cut short by a crash too.
  Future<int> joinAudioChunks({
    required String dir,
    required String outPath,
  }) async {
    return await JitsiMeetPlatform.instance.joinAudioChunks(dir, outPath);
  }

  /// Starts saving the frames of a video track (from the `screenShare` or
  /// `localScreenShare` podium events; [pcId] -1 for a local track) into
  /// [dir], stopping a capture still running. Returns whether the track was
  /// found.
  Future<bool> startScreenCapture({
    required int pcId,
    required String trackId,
    required String dir,
  }) async {
    return await JitsiMeetPlatform.instance
        .startScreenCapture(pcId, trackId, dir);
  }

  /// Stops the screen capture, or returns null if no frame was saved.
  Future<ScreenCaptureResult?> stopScreenCapture() async {
    final result = await JitsiMeetPlatform.instance.stopScreenCapture();
    return result == null ? null : ScreenCaptureResult.fromMap(result);
  }

  /// Encodes the frames saved in [dir] into an H.264 .mp4 at [outPath] that
  /// lasts until [endMs]. Needs the app in the foreground on iOS.
  Future<ScreenClipResult> encodeScreenClip({
    required String dir,
    required String outPath,
    required int endMs,
    void Function(int done, int total)? onProgress,
  }) async {
    final result = await JitsiMeetPlatform.instance
        .encodeScreenClip(dir, outPath, endMs, onProgress);
    return ScreenClipResult.fromMap(result);
  }

  /// Bytes free on the volume holding [path], or -1 if unknown.
  Future<int> freeDiskBytes(String path) async {
    return await JitsiMeetPlatform.instance.freeDiskBytes(path);
  }
}

class CallRecordingResult {
  final String dir;
  final int chunks;
  final int durationMs;

  const CallRecordingResult({
    required this.dir,
    required this.chunks,
    required this.durationMs,
  });

  factory CallRecordingResult.fromMap(Map<String, dynamic> map) =>
      CallRecordingResult(
        dir: map['dir'] as String,
        chunks: (map['chunks'] as num).toInt(),
        durationMs: (map['durationMs'] as num).toInt(),
      );
}

class ScreenCaptureResult {
  final int frames;
  final int width;
  final int height;
  final int durationMs;

  const ScreenCaptureResult({
    required this.frames,
    required this.width,
    required this.height,
    required this.durationMs,
  });

  factory ScreenCaptureResult.fromMap(Map<String, dynamic> map) =>
      ScreenCaptureResult(
        frames: (map['frames'] as num).toInt(),
        width: (map['width'] as num).toInt(),
        height: (map['height'] as num).toInt(),
        durationMs: (map['durationMs'] as num).toInt(),
      );
}

class ScreenClipResult {
  final int width;
  final int height;
  final int durationMs;

  const ScreenClipResult({
    required this.width,
    required this.height,
    required this.durationMs,
  });

  factory ScreenClipResult.fromMap(Map<String, dynamic> map) =>
      ScreenClipResult(
        width: (map['width'] as num).toInt(),
        height: (map['height'] as num).toInt(),
        durationMs: (map['durationMs'] as num).toInt(),
      );
}
