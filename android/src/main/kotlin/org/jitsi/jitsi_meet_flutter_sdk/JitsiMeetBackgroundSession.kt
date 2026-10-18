package org.jitsi.jitsi_meet_flutter_sdk

import android.app.Activity
import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import org.jitsi.meet.sdk.BroadcastEvent
import org.jitsi.meet.sdk.JitsiMeetActivityDelegate
import org.jitsi.meet.sdk.JitsiMeetConferenceOptions
import org.jitsi.meet.sdk.JitsiMeetOngoingConferenceService
import org.jitsi.meet.sdk.JitsiMeetView

/**
 * Runs a conference without showing any Jitsi UI: the [JitsiMeetView] is attached invisibly
 * behind the Flutter view of the host activity, which acts as the React Native host.
 *
 * The host activity must be a FragmentActivity (react-native-screens hosts its screens in the
 * activity's fragment manager) and implement [org.jitsi.meet.sdk.JitsiMeetActivityInterface].
 * The view has to stay attached to the window, since [JitsiMeetView] tears down its React
 * root when detached.
 */
class JitsiMeetBackgroundSession(
    private val activity: Activity,
    private val onClosed: () -> Unit,
) : Application.ActivityLifecycleCallbacks {
    private val eventStreamHandler = JitsiMeetEventStreamHandler.instance
    private var jitsiView: JitsiMeetView? = null

    private val broadcastReceiver: BroadcastReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            onBroadcastReceived(intent)
        }
    }

    fun join(options: JitsiMeetConferenceOptions) {
        (jitsiView ?: attach()).join(options)
    }

    private fun attach(): JitsiMeetView {
        val view = JitsiMeetView(activity).apply {
            visibility = View.INVISIBLE
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        }
        activity.findViewById<ViewGroup>(android.R.id.content).addView(
            view,
            0,
            ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        )
        jitsiView = view

        val intentFilter = IntentFilter()
        for (eventType in BroadcastEvent.Type.values()) {
            intentFilter.addAction(eventType.action)
        }
        LocalBroadcastManager.getInstance(activity).registerReceiver(broadcastReceiver, intentFilter)
        activity.application.registerActivityLifecycleCallbacks(this)
        JitsiMeetActivityDelegate.onHostResume(activity)
        return view
    }

    fun dispose() {
        val view = jitsiView ?: return
        jitsiView = null

        activity.application.unregisterActivityLifecycleCallbacks(this)
        LocalBroadcastManager.getInstance(activity).unregisterReceiver(broadcastReceiver)
        view.abort()
        (view.parent as? ViewGroup)?.removeView(view)
        JitsiMeetOngoingConferenceService.abort(activity)
        JitsiMeetActivityDelegate.onHostDestroy(activity)
        onClosed()
    }

    fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        if (jitsiView == null) return
        JitsiMeetActivityDelegate.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (jitsiView == null) return
        JitsiMeetActivityDelegate.onActivityResult(activity, requestCode, resultCode, data)
    }

    private fun onBroadcastReceived(intent: Intent?) {
        if (intent == null) return
        val event = BroadcastEvent(intent)
        eventStreamHandler.onBroadcastEvent(event)
        when (event.type) {
            BroadcastEvent.Type.CONFERENCE_JOINED ->
                JitsiMeetOngoingConferenceService.launch(activity, event.data)
            BroadcastEvent.Type.READY_TO_CLOSE -> dispose()
            else -> {}
        }
    }

    override fun onActivityResumed(activity: Activity) {
        if (activity === this.activity) JitsiMeetActivityDelegate.onHostResume(activity)
    }

    override fun onActivityStopped(activity: Activity) {
        if (activity === this.activity) JitsiMeetActivityDelegate.onHostPause(activity)
    }

    override fun onActivityDestroyed(activity: Activity) {
        if (activity === this.activity) dispose()
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
    override fun onActivityStarted(activity: Activity) {}
    override fun onActivityPaused(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
}
