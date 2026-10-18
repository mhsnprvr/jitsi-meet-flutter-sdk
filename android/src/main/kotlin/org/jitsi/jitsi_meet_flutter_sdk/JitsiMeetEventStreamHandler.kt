package org.jitsi.jitsi_meet_flutter_sdk

import io.flutter.plugin.common.EventChannel
import org.jitsi.meet.sdk.BroadcastEvent
import java.io.Serializable

class JitsiMeetEventStreamHandler private constructor() : EventChannel.StreamHandler {
    companion object {
        val instance = JitsiMeetEventStreamHandler()
    }

    private var eventSink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        this.eventSink = eventSink
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun conferenceJoined(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "conferenceJoined", "data" to data))
    }

    ///custom event
    fun like(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "like", "data" to data))
    }
    fun dislike(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "dislike", "data" to data))
    }
    fun cheer(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "cheer", "data" to data))
    }
    fun boo(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "boo", "data" to data))
    }
/// end of custom event

    fun conferenceTerminated(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "conferenceTerminated", "data" to data))
    }

    fun conferenceWillJoin(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "conferenceWillJoin", "data" to data))
    }

    fun participantJoined(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "participantJoined", "data" to data))
    }

    fun participantLeft(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "participantLeft", "data" to data))
    }

    fun audioMutedChanged(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "audioMutedChanged", "data" to data))
    }

    fun videoMutedChanged(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "videoMutedChanged", "data" to data))
    }

    fun endpointTextMessageReceived(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "endpointTextMessageReceived", "data" to data))
    }

    fun screenShareToggled(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "screenShareToggled", "data" to data))
    }

    fun chatMessageReceived(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "chatMessageReceived", "data" to data))
    }

    fun chatToggled(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "chatToggled", "data" to data))
    }

    fun participantsInfoRetrieved(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "participantsInfoRetrieved", "data" to data))
    }

    fun readyToClose() {
        eventSink?.success(mapOf("event" to "readyToClose"))
    }

    fun onOpened() {
        eventSink?.success(mapOf("event" to "opened"))
    }

    fun customButtonPressed(data: MutableMap<String, Any>?) {
        eventSink?.success(mapOf("event" to "customButtonPressed", "data" to data))
    }

    fun onBroadcastEvent(event: BroadcastEvent) {
        val data = event.data
        when (event.type) {
            BroadcastEvent.Type.CONFERENCE_JOINED -> conferenceJoined(data)
            BroadcastEvent.Type.CONFERENCE_TERMINATED -> conferenceTerminated(data)
            BroadcastEvent.Type.CONFERENCE_WILL_JOIN -> conferenceWillJoin(data)
            BroadcastEvent.Type.PARTICIPANT_JOINED -> participantJoined(data)
            BroadcastEvent.Type.PARTICIPANT_LEFT -> participantLeft(data)
            BroadcastEvent.Type.AUDIO_MUTED_CHANGED -> audioMutedChanged(data)
            BroadcastEvent.Type.VIDEO_MUTED_CHANGED -> videoMutedChanged(data)
            BroadcastEvent.Type.ENDPOINT_TEXT_MESSAGE_RECEIVED -> endpointTextMessageReceived(data)
            BroadcastEvent.Type.SCREEN_SHARE_TOGGLED -> screenShareToggled(data)
            BroadcastEvent.Type.CHAT_MESSAGE_RECEIVED -> chatMessageReceived(data)
            BroadcastEvent.Type.CHAT_TOGGLED -> chatToggled(data)
            BroadcastEvent.Type.PARTICIPANTS_INFO_RETRIEVED -> participantsInfoRetrieved(data)
            BroadcastEvent.Type.READY_TO_CLOSE -> readyToClose()
            else -> {}
        }
    }
}
