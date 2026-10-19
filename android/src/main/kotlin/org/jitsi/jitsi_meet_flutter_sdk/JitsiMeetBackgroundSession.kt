package org.jitsi.jitsi_meet_flutter_sdk

import android.app.Activity
import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import io.flutter.embedding.android.FlutterView
import org.jitsi.meet.sdk.BroadcastEvent
import org.jitsi.meet.sdk.JitsiMeetActivityDelegate
import org.jitsi.meet.sdk.JitsiMeetConferenceOptions
import org.jitsi.meet.sdk.JitsiMeetOngoingConferenceService
import org.jitsi.meet.sdk.JitsiMeetView
import org.jitsi.meet.sdk.PodiumStageView

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
    private var stageView: PodiumStageView? = null

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

    /**
     * Places a remote video track (a screen share) over the Flutter UI. [left]/[top]/[width]/[height]
     * are physical pixels relative to the Flutter view. A null [trackId] clears the stage.
     */
    fun setStage(visible: Boolean, left: Int, top: Int, width: Int, height: Int, pcId: Int, trackId: String?) {
        if (jitsiView == null) return
        val content = activity.findViewById<ViewGroup>(android.R.id.content)
        val stage = stageView ?: PodiumStageView(activity).also { view ->
            view.visibility = View.GONE
            view.elevation = 1000f
            view.outlineProvider = null
            view.setListener { w, h ->
                eventStreamHandler.podiumEvent(
                    mutableMapOf<String, Any>(
                        "name" to "stageVideoSize",
                        "payload" to "{\"width\":$w,\"height\":$h}"
                    )
                )
            }
            content.addView(view, FrameLayout.LayoutParams(1, 1))
            stageView = view
        }
        stage.setTrack(pcId, trackId)
        if (!visible || trackId == null || width <= 0 || height <= 0) {
            stage.visibility = View.GONE
            return
        }
        val origin = flutterOrigin(content)
        val params = (stage.layoutParams as? FrameLayout.LayoutParams)
            ?: FrameLayout.LayoutParams(width, height)
        params.width = width
        params.height = height
        params.leftMargin = origin.first + left
        params.topMargin = origin.second + top
        params.gravity = Gravity.TOP or Gravity.START
        stage.layoutParams = params
        stage.visibility = View.VISIBLE
    }

    private fun flutterOrigin(content: ViewGroup): Pair<Int, Int> {
        val flutterView = findFlutterView(content) ?: return Pair(0, 0)
        val a = IntArray(2)
        val b = IntArray(2)
        flutterView.getLocationInWindow(a)
        content.getLocationInWindow(b)
        return Pair(a[0] - b[0], a[1] - b[1])
    }

    private fun findFlutterView(group: ViewGroup): View? {
        for (i in 0 until group.childCount) {
            val child = group.getChildAt(i)
            if (child is FlutterView) return child
            if (child is ViewGroup && child !is JitsiMeetView && child !is PodiumStageView) {
                findFlutterView(child)?.let { return it }
            }
        }
        return null
    }

    fun dispose() {
        stageView?.let { stage ->
            stage.release()
            (stage.parent as? ViewGroup)?.removeView(stage)
        }
        stageView = null
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
