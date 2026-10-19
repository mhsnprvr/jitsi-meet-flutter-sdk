import Flutter
import ReplayKit
import UIKit
import JitsiMeetSDK

/// Runs a conference without presenting any Jitsi UI: the JitsiMeetView is kept hidden
/// behind the app's content so the conference stays alive while the app is used normally.
class JitsiMeetBackgroundSession: NSObject {
    private(set) var jitsiMeetView: JitsiMeetView?
    private var stageView: PodiumStageView?
    private var broadcastPicker: RPSystemBroadcastPickerView?
    private let eventSink: FlutterEventSink
    private let onClosed: () -> Void

    init(eventSink: @escaping FlutterEventSink, onClosed: @escaping () -> Void) {
        self.eventSink = eventSink
        self.onClosed = onClosed
        super.init()
    }

    func join(_ options: JitsiMeetConferenceOptions, in container: UIView) {
        let view = jitsiMeetView ?? attach(to: container)
        view.join(options)
    }

    private func attach(to container: UIView) -> JitsiMeetView {
        let view = JitsiMeetView(frame: container.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.delegate = self
        container.insertSubview(view, at: 0)
        jitsiMeetView = view
        return view
    }

    /// Places a remote video track (a screen share) over the Flutter UI. `left`/`top`/`width`/`height`
    /// are physical pixels relative to `flutterView`. A nil `trackId` clears the stage.
    func setStage(visible: Bool, left: Int, top: Int, width: Int, height: Int,
                  pcId: Int, trackId: String?, flutterView: UIView) {
        guard let container = jitsiMeetView?.superview else { return }
        let stage = stageView ?? {
            let view = PodiumStageView(frame: .zero)
            view.isHidden = true
            view.isUserInteractionEnabled = false
            view.onVideoSizeChanged = { [weak self] size in
                self?.eventSink([
                    "event": "podiumEvent",
                    "data": [
                        "name": "stageVideoSize",
                        "payload": "{\"width\":\(Int(size.width)),\"height\":\(Int(size.height))}"
                    ]
                ])
            }
            container.addSubview(view)
            stageView = view
            return view
        }()
        stage.setTrack(pcId, trackId: trackId)
        guard visible, trackId != nil, width > 0, height > 0 else {
            stage.isHidden = true
            return
        }
        let scale = flutterView.window?.screen.scale ?? UIScreen.main.scale
        let rect = CGRect(
            x: CGFloat(left) / scale,
            y: CGFloat(top) / scale,
            width: CGFloat(width) / scale,
            height: CGFloat(height) / scale
        )
        stage.frame = flutterView.convert(rect, to: container)
        container.bringSubviewToFront(stage)
        stage.isHidden = false
    }

    /// Opens the system picker for the app's broadcast upload extension. Once the user starts the
    /// broadcast, the SDK picks it up and starts sharing in the conference.
    func showScreenSharePicker() {
        guard let container = jitsiMeetView?.superview else { return }
        let picker = broadcastPicker ?? {
            let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            view.preferredExtension = Bundle.main.object(forInfoDictionaryKey: "RTCScreenSharingExtension") as? String
            view.showsMicrophoneButton = false
            view.alpha = 0.01
            view.isUserInteractionEnabled = false
            container.insertSubview(view, at: 0)
            broadcastPicker = view
            return view
        }()
        let button = picker.subviews.compactMap { $0 as? UIButton }.first
        button?.sendActions(for: .touchUpInside)
    }

    func dispose() {
        stageView?.releaseTrack()
        stageView?.removeFromSuperview()
        stageView = nil
        broadcastPicker?.removeFromSuperview()
        broadcastPicker = nil
        guard let view = jitsiMeetView else { return }
        jitsiMeetView = nil
        view.delegate = nil
        view.removeFromSuperview()
        onClosed()
    }
}

extension JitsiMeetBackgroundSession: JitsiMeetViewDelegate {
    func conferenceJoined(_ data: [AnyHashable : Any]) {
        eventSink(["event": "conferenceJoined", "data": data])
    }

    func conferenceTerminated(_ data: [AnyHashable : Any]) {
        eventSink(["event": "conferenceTerminated", "data": data])
    }

    func conferenceWillJoin(_ data: [AnyHashable : Any]) {
        eventSink(["event": "conferenceWillJoin", "data": data])
    }

    func participantJoined(_ data: [AnyHashable : Any]) {
        eventSink(["event": "participantJoined", "data": data])
    }

    func participantLeft(_ data: [AnyHashable : Any]) {
        eventSink(["event": "participantLeft", "data": data])
    }

    func audioMutedChanged(_ data: [AnyHashable : Any]) {
        eventSink(["event": "audioMutedChanged", "data": data])
    }

    func videoMutedChanged(_ data: [AnyHashable : Any]) {
        eventSink(["event": "videoMutedChanged", "data": data])
    }

    func endpointTextMessageReceived(_ data: [AnyHashable : Any]) {
        eventSink(["event": "endpointTextMessageReceived", "data": data])
    }

    func screenShareToggled(_ data: [AnyHashable : Any]) {
        eventSink(["event": "screenShareToggled", "data": data])
    }

    func chatMessageReceived(_ data: [AnyHashable : Any]) {
        eventSink(["event": "chatMessageReceived", "data": data])
    }

    func chatToggled(_ data: [AnyHashable : Any]) {
        eventSink(["event": "chatToggled", "data": data])
    }

    @objc func podiumEvent(_ data: [AnyHashable : Any]) {
        eventSink(["event": "podiumEvent", "data": data])
    }

    func customButtonPressed(_ data: [AnyHashable : Any]) {
        eventSink(["event": "customButtonPressed", "data": data])
    }

    func ready(toClose data: [AnyHashable : Any]) {
        eventSink(["event": "readyToClose"])
        DispatchQueue.main.async {
            self.dispose()
        }
    }
}
