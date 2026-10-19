import Flutter
import UIKit
import JitsiMeetSDK

public class JitsiMeetPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    var flutterViewController: UIViewController
    var jitsiMeetViewController: JitsiMeetViewController?
    var backgroundSession: JitsiMeetBackgroundSession?
    var eventSink: FlutterEventSink?
    var channel: FlutterMethodChannel?

    var activeJitsiMeetView: JitsiMeetView? {
        backgroundSession?.jitsiMeetView ?? jitsiMeetViewController?.jitsiMeetView
    }

    init(flutterViewController: UIViewController) {
        self.flutterViewController = flutterViewController
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "jitsi_meet_flutter_sdk", binaryMessenger: registrar.messenger())
        let flutterViewController: UIViewController = (UIApplication.shared.delegate?.window??.rootViewController)!
        let instance = JitsiMeetPlugin(flutterViewController: flutterViewController)
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)

        // Read by the SDK when it creates the React Native bridge, on the first conference.
        JitsiMeet.sharedInstance().rtcAudioDevice = PodiumAudioDevice.sharedInstance()

        let eventChannel = FlutterEventChannel(name: "jitsi_meet_flutter_sdk_events", binaryMessenger: registrar.messenger())
        eventChannel.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)
            return
        case "join":
            join(call, result: result)
            return
        case "hangUp":
            hangUp(call, result: result)
            return
        case "setAudioMuted":
            setAudioMuted(call, result: result)
            return
        case "setVideoMuted":
            setVideoMuted(call, result: result)
            return
        case "sendEndpointTextMessage":
            sendEndpointTextMessage(call, result: result)
            return
        case "toggleScreenShare":
            toggleScreenShare(call, result: result)
            return
        case "openChat":
            openChat(call, result: result)
            return
        case "sendChatMessage":
            sendChatMessage(call, result: result)
            return
        case "closeChat":
            closeChat(call, result: result)
            return
        case "retrieveParticipantsInfo":
            retrieveParticipantsInfo(call, result: result)
            return
        case "enterPiP":
            enterPiP(call, result: result)
            return
        case "sendPodiumCommand":
            sendPodiumCommand(call, result: result)
            return
        case "setStage":
            setStage(call, result: result)
            return
        case "startCallRecording":
            startCallRecording(call, result: result)
            return
        case "stopCallRecording":
            DispatchQueue.global(qos: .userInitiated).async {
                let stopped = PodiumCallRecorder.stop()
                DispatchQueue.main.async { result(stopped) }
            }
            return
        case "setCallRecordingMicEnabled":
            let arguments = call.arguments as? [String: Any]
            PodiumCallRecorder.setMicEnabled(arguments?["enabled"] as? Bool ?? false)
            result(nil)
            return
        case "joinAudioChunks":
            joinAudioChunks(call, result: result)
            return
        case "startScreenCapture":
            startScreenCapture(call, result: result)
            return
        case "stopScreenCapture":
            DispatchQueue.global(qos: .userInitiated).async {
                let stopped = PodiumScreenRecorder.stop()
                DispatchQueue.main.async { result(stopped) }
            }
            return
        case "encodeScreenClip":
            encodeScreenClip(call, result: result)
            return
        case "freeDiskBytes":
            let path = (call.arguments as? [String: Any])?["path"] as? String ?? NSHomeDirectory()
            let values = try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            result(values?.volumeAvailableCapacityForImportantUsage ?? -1)
            return
        default:
          result(FlutterMethodNotImplemented)
        }
    }

    private func join(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as! [String: Any]
        let serverURL = arguments["serverURL"] as? String
        let room = arguments["room"] as? String
        let token = arguments["token"] as? String
        let configOverrides = arguments["configOverrides"] as? Dictionary<String, Any>
        let featureFlags = arguments["featureFlags"] as? Dictionary<String, Any>
        let rawUserInfo = arguments["userInfo"] as! [String: Any]
        let displayName = rawUserInfo["displayName"] as? String
        let email = rawUserInfo["email"] as? String
        var avatar: URL? = nil
        if rawUserInfo["avatar"] as? String != nil {
            avatar = URL(string: rawUserInfo["avatar"] as! String)
        }
        var userInfo: JitsiMeetUserInfo? = nil
        if (displayName != nil || email != nil || avatar != nil) {
            userInfo = JitsiMeetUserInfo(displayName: displayName, andEmail: email, andAvatar: avatar)
        }

        let options = JitsiMeetConferenceOptions.fromBuilder { (builder) in
            if (serverURL != nil) {
                builder.serverURL = URL(string: serverURL as! String)
            }
            if (room != nil) {
                builder.room = room;
            }
            if (token != nil) {
                builder.token = token;
            }
            configOverrides?.forEach { key, value in
                builder.setConfigOverride(key, withValue: value);
            }
            featureFlags?.forEach { key, value in
                builder.setFeatureFlag(key, withValue: value);
            }
            if (userInfo != nil) {
                builder.userInfo = userInfo
            }
        }

        if (arguments["runInBackground"] as? Bool) ?? true {
            let session = backgroundSession ?? JitsiMeetBackgroundSession(eventSink: eventSink!) { [weak self] in
                self?.backgroundSession = nil
            }
            backgroundSession = session
            let container: UIView = flutterViewController.view.window ?? flutterViewController.view
            session.join(options, in: container)
        } else {
            jitsiMeetViewController = JitsiMeetViewController.init(options: options, eventSink: eventSink!)
            jitsiMeetViewController!.modalPresentationStyle = .overFullScreen
            flutterViewController.present(jitsiMeetViewController!, animated: true)
        }
        result("Successfully joined meeting \(room)")
    }

    private func hangUp(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        activeJitsiMeetView?.hangUp()
        result("Successfully hung up")
    }

    private func setAudioMuted(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as! [String: Any]
        let muted = arguments["muted"] as! Bool
        activeJitsiMeetView?.setAudioMuted(muted)
        result("Successfully set audio \(muted)")
    }

    private func setVideoMuted(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as! [String: Any]
        let muted = arguments["muted"] as! Bool
        activeJitsiMeetView?.setVideoMuted(muted)
        result("Successfully set video \(muted)")
    }

    private func sendEndpointTextMessage(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as! [String: Any]
        let to = arguments["to"] as? String
        let message: String = arguments["message"] as! String
        activeJitsiMeetView?.sendEndpointTextMessage(message, to)
        result("Successfully send endpoint text message \(to)")
    }

    private func sendPodiumCommand(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any]
        guard let name = arguments?["name"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "name is required", details: nil))
            return
        }
        let payload = arguments?["payload"] as? String ?? "{}"
        activeJitsiMeetView?.sendPodiumCommand(name, payload)
        result("Successfully sent podium command \(name)")
    }

    private func toggleScreenShare(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as! [String: Any]
        let enabled = arguments["enabled"] as! Bool
        // iOS can only capture the screen through the broadcast extension, which the SDK starts
        // sharing from once the user starts the broadcast in the system picker.
        if enabled, let session = backgroundSession {
            session.showScreenSharePicker()
            result("Opened the screen share picker")
            return
        }
        activeJitsiMeetView?.toggleScreenShare(enabled)
        result("Successfully toggled screen share \(enabled)")
    }

    private func setStage(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any] ?? [:]
        backgroundSession?.setStage(
            visible: arguments["visible"] as? Bool ?? false,
            left: arguments["left"] as? Int ?? 0,
            top: arguments["top"] as? Int ?? 0,
            width: arguments["width"] as? Int ?? 0,
            height: arguments["height"] as? Int ?? 0,
            pcId: arguments["pcId"] as? Int ?? -1,
            trackId: arguments["trackId"] as? String,
            flutterView: flutterViewController.view
        )
        result("Stage updated")
    }

    private func startCallRecording(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any]
        guard let dir = arguments?["dir"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "dir is required", details: nil))
            return
        }
        do {
            try PodiumCallRecorder.start(inDirectory: dir, chunkSeconds: arguments?["chunkSeconds"] as? Int ?? 5)
            result(dir)
        } catch {
            result(FlutterError(code: "RECORDING_FAILED", message: error.localizedDescription, details: nil))
        }
    }

    private func joinAudioChunks(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any]
        guard let dir = arguments?["dir"] as? String, let outPath = arguments?["outPath"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "dir and outPath are required", details: nil))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSError?
            let durationMs = PodiumCallRecorder.joinChunks(inDirectory: dir, toPath: outPath, error: &error)
            DispatchQueue.main.async {
                if durationMs < 0 {
                    result(FlutterError(code: "FAILED", message: error?.localizedDescription ?? "Could not join the audio", details: nil))
                } else {
                    result(durationMs)
                }
            }
        }
    }

    private func startScreenCapture(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any]
        guard let trackId = arguments?["trackId"] as? String, let dir = arguments?["dir"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "trackId and dir are required", details: nil))
            return
        }
        PodiumScreenRecorder.start(withPcId: arguments?["pcId"] as? Int ?? -1, trackId: trackId, directory: dir) { attached in
            result(attached)
        }
    }

    private func encodeScreenClip(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any]
        guard let dir = arguments?["dir"] as? String,
              let outPath = arguments?["outPath"] as? String,
              let endMs = (arguments?["endMs"] as? NSNumber)?.int64Value else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "dir, outPath and endMs are required", details: nil))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let clip = try PodiumScreenRecorder.encodeDirectory(dir, toPath: outPath, endMs: endMs) { done, total in
                    guard done == total || done % 10 == 0 else { return }
                    DispatchQueue.main.async {
                        self?.channel?.invokeMethod("screenClipProgress", arguments: ["outPath": outPath, "done": done, "total": total])
                    }
                }
                DispatchQueue.main.async { result(clip) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func openChat(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as! [String: Any]
        let to = arguments["to"] as? String
        activeJitsiMeetView?.openChat(to)
        result("Successfully opened chat \(to)")
    }

    private func sendChatMessage(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as! [String: Any]
        let to = arguments["to"] as? String
        let message: String = arguments["message"] as! String
        activeJitsiMeetView?.sendChatMessage(message, to)
        result("Successfully sent chat message \(to)")
    }

    private func closeChat(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        activeJitsiMeetView?.closeChat()
        result("Successfully closed chat")
    }

    private func retrieveParticipantsInfo(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        activeJitsiMeetView?.retrieveParticipantsInfo({ (data:[Any]?) in self.eventSink!(["event": "participantsInfoRetrieved", "data": data])})
        result("Successfully retrieved participants info")
    }

    private func enterPiP(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        jitsiMeetViewController?.enterPicture(inPicture: [:])
        result("Successfully entered Picture in Picture")
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        return nil
    }
}
