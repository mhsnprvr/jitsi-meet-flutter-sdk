import 'jitsi_meet_user_info.dart';

/// This object encapsulates all the options that can be tweaked when joining a conference.
class JitsiMeetConferenceOptions {
  /// Server where the conference should take place.
  final String? serverURL;

  /// Room name.
  final String room;

  /// JWT token used for authentication.
  final String? token;

  /// Config overrides See: https://github.com/jitsi/jitsi-meet/blob/master/config.js.
  late final Map<String, Object?>? configOverrides;

  /// Feature flags. See: https://github.com/jitsi/jitsi-meet/blob/master/react/features/base/flags/constants.ts.
  final Map<String, Object?>? featureFlags;

  /// Information about the local user. It will be used in absence of a token.
  final JitsiMeetUserInfo? userInfo;

  /// Runs the conference without presenting any Jitsi UI (the default). The
  /// conference is controlled only through the [JitsiMeet] API and its events.
  /// Set to `false` to present the regular Jitsi meeting screen instead.
  ///
  /// On Android the host activity must extend `FlutterFragmentActivity` and
  /// implement `JitsiMeetActivityInterface`.
  final bool runInBackground;

  JitsiMeetConferenceOptions(
      {this.serverURL,
      required this.room,
      this.token,
      this.configOverrides,
      this.featureFlags,
      this.userInfo,
      this.runInBackground = true});
}
