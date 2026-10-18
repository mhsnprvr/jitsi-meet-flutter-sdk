import Flutter
import UIKit
import JitsiMeetSDK

/// Runs a conference without presenting any Jitsi UI: the JitsiMeetView is kept hidden
/// behind the app's content so the conference stays alive while the app is used normally.
class JitsiMeetBackgroundSession: NSObject {
    private(set) var jitsiMeetView: JitsiMeetView?
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

    func dispose() {
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
