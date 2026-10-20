package org.jitsi.jitsi_meet_flutter_sdk

import android.app.Activity
import androidx.annotation.NonNull
import androidx.fragment.app.FragmentActivity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.localbroadcastmanager.content.LocalBroadcastManager

import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import org.jitsi.meet.sdk.BroadcastIntentHelper
import org.jitsi.meet.sdk.JitsiMeetConferenceOptions
import org.jitsi.meet.sdk.JitsiMeetUserInfo
import org.jitsi.meet.sdk.BroadcastAction
import org.jitsi.meet.sdk.*
import java.net.URL

/** JitsiMeetPlugin */
class JitsiMeetPlugin: FlutterPlugin, MethodCallHandler, ActivityAware {
  private lateinit var methodChannel : MethodChannel
  private lateinit var eventChannel: EventChannel
  private val eventStreamHandler = JitsiMeetEventStreamHandler.instance
  private var activity: Activity? = null
  private var activityBinding: ActivityPluginBinding? = null
  private var backgroundSession: JitsiMeetBackgroundSession? = null

  private val requestPermissionsResultListener = PluginRegistry.RequestPermissionsResultListener { requestCode, permissions, grantResults ->
    backgroundSession?.onRequestPermissionsResult(requestCode, permissions, grantResults)
    false
  }

  private val activityResultListener = PluginRegistry.ActivityResultListener { requestCode, resultCode, data ->
    backgroundSession?.onActivityResult(requestCode, resultCode, data)
    false
  }

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "jitsi_meet_flutter_sdk")
    methodChannel.setMethodCallHandler(this)

    eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "jitsi_meet_flutter_sdk_events")
    eventChannel.setStreamHandler(eventStreamHandler)
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "getPlatformVersion" -> {result.success("Android ${android.os.Build.VERSION.RELEASE}")}
      "join" -> join(call, result)
      "hangUp" -> hangUp(call, result)
      "setAudioMuted" -> setAudioMuted(call, result)
      "setVideoMuted" -> setVideoMuted(call, result)
      "sendEndpointTextMessage" -> sendEndpointTextMessage(call, result)
      "toggleScreenShare" -> toggleScreenShare(call, result)
      "openChat" -> openChat(call, result)
      "sendChatMessage" -> sendChatMessage(call, result)
      "closeChat" -> closeChat(call, result)
      "retrieveParticipantsInfo" -> retrieveParticipantsInfo(call, result)
      "enterPiP" -> enterPiP(call, result)
      "sendPodiumCommand" -> sendPodiumCommand(call, result)
      "setStage" -> setStage(call, result)
      "startCallRecording" -> startCallRecording(call, result)
      "stopCallRecording" -> stopCallRecording(result)
      "setCallRecordingMicEnabled" -> {
        CallAudioRecorder.micEnabled = call.argument<Boolean>("enabled") ?: false
        result.success(null)
      }
      "setOngoingNotification" -> {
        JitsiMeetOngoingConferenceService.setNotificationContent(
          call.argument<String>("title"),
          call.argument<String>("text")
        )
        result.success(null)
      }
      "joinAudioChunks" -> joinAudioChunks(call, result)
      "startScreenCapture" -> startScreenCapture(call, result)
      "stopScreenCapture" -> stopScreenCapture(result)
      "encodeScreenClip" -> encodeScreenClip(call, result)
      "freeDiskBytes" -> {
        val path = call.argument<String>("path") ?: ""
        result.success(try { android.os.StatFs(path).availableBytes } catch (e: IllegalArgumentException) { -1L })
      }
      else -> result.notImplemented()
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    methodChannel.setMethodCallHandler(null)
  }

  override fun onDetachedFromActivity() {
    backgroundSession?.dispose()
    activityBinding?.removeRequestPermissionsResultListener(requestPermissionsResultListener)
    activityBinding?.removeActivityResultListener(activityResultListener)
    activityBinding = null
    this.activity = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    onAttachedToActivity(binding)
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    this.activity = binding.activity
    activityBinding = binding
    binding.addRequestPermissionsResultListener(requestPermissionsResultListener)
    binding.addActivityResultListener(activityResultListener)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    onDetachedFromActivity()
  }
  private fun join(call: MethodCall, result: Result) {
    val serverURL = if (call.argument<String?>("serverURL") != null) URL(call.argument<String?>("serverURL")) else null
    val room: String? = call.argument("room")
    val token: String? = call.argument("token")
    val featureFlags = call.argument<HashMap<String, Any?>>("featureFlags")
    val configOverrides = call.argument<HashMap<String, Any?>>("configOverrides")
    val rawUserInfo = call.argument<HashMap<String, String?>>("userInfo")
    val displayName = rawUserInfo?.get("displayName")
    val email = rawUserInfo?.get("email")
    val avatar = if (rawUserInfo?.get("avatar") != null) URL(rawUserInfo.get("avatar")) else null
    val userInfo = JitsiMeetUserInfo().apply {
      if (displayName != null) this.displayName = displayName
      if (email != null) this.email = email
      if (avatar != null) this.avatar = avatar
    }

    val options = JitsiMeetConferenceOptions.Builder().run {
      if (serverURL != null) setServerURL(serverURL)
      if (room != null) setRoom(room)
      if (token != null) setToken(token)

      configOverrides?.forEach { (key, value) ->
        when (value) {
          is Boolean -> setConfigOverride(key, value)
          is Int -> setConfigOverride(key, value)
          is Map<*, *> -> {
            val bundle = Bundle()
            value.forEach { (k, v) ->
              when (v) {
                is Boolean -> bundle.putBoolean(k.toString(), v)
                is Int -> bundle.putInt(k.toString(), v)
                is Long -> bundle.putLong(k.toString(), v)
                is Double -> bundle.putDouble(k.toString(), v)
                is Float -> bundle.putFloat(k.toString(), v)
                is String -> bundle.putString(k.toString(), v)
                else -> bundle.putString(k.toString(), v.toString())
              }
            }
            setConfigOverride(key, bundle)
          }
          is Array<*> -> setConfigOverride(key, value as Array<out String>)
          is List<*> -> {
            if (value.isNotEmpty() && value[0] is Map<*, *>) {
              val bundles = ArrayList<Bundle>()
              for (map in value) {
                val bundle = Bundle()
                (map as Map<*, *>).forEach { (k, v) ->
                  bundle.putString(k.toString(), v.toString())
                }
                bundles.add(bundle)
              }
              setConfigOverride(key, bundles)
            } else if (value.isNotEmpty() && value[0] is String) {
              val stringArray = value.map { it.toString() }.toTypedArray()
              setConfigOverride(key, stringArray)
            } else {
              setConfigOverride(key, value.toString())
            }
          }
          else -> setConfigOverride(key, value.toString())
        }
      }
      featureFlags?.forEach { (key, value) ->
        when (value) {
          is Boolean -> setFeatureFlag(key, value)
          is Int -> setFeatureFlag(key, value)
          else -> setFeatureFlag(key, value.toString())
        }
      }
      if (userInfo != null) setUserInfo(userInfo)
      build()
    }

    if (call.argument<Boolean>("runInBackground") != false) {
      val hostActivity = activity
      if (hostActivity !is FragmentActivity || hostActivity !is JitsiMeetActivityInterface) {
        result.error(
          "HOST_ACTIVITY_UNSUPPORTED",
          "runInBackground requires the host activity to extend FlutterFragmentActivity " +
            "and implement JitsiMeetActivityInterface",
          null
        )
        return
      }
      val session = backgroundSession
        ?: JitsiMeetBackgroundSession(hostActivity) { backgroundSession = null }
      backgroundSession = session
      session.join(options)
    } else {
      WrapperJitsiMeetActivity.launch(activity!!, options)
    }
    result.success("Successfully joined meeting $room")
  }

  private fun hangUp(call: MethodCall, result: Result) {
    val hangUpBroadcastIntent = BroadcastIntentHelper.buildHangUpIntent();
    LocalBroadcastManager.getInstance(activity!!.applicationContext).sendBroadcast(hangUpBroadcastIntent)
    result.success("Succesfullly hung up")
  }

  private fun setAudioMuted(call: MethodCall, result: Result) {
    val muted = call.argument<Boolean>("muted") ?: false
    val audioMuteBroadcastIntent: Intent = BroadcastIntentHelper.buildSetAudioMutedIntent(muted)
    LocalBroadcastManager.getInstance(activity!!.applicationContext).sendBroadcast(audioMuteBroadcastIntent)
    result.success("Successfully set audio $muted")
  }

  private fun setVideoMuted(call: MethodCall, result: Result) {
    val muted = call.argument<Boolean>("muted") ?: false
    val videoMuteBroadcastIntent: Intent = BroadcastIntentHelper.buildSetVideoMutedIntent(muted)
    LocalBroadcastManager.getInstance(activity!!.applicationContext).sendBroadcast(videoMuteBroadcastIntent)
    result.success("Successfully set video $muted")
  }

  private fun sendEndpointTextMessage(call: MethodCall, result: Result) {
    val to = call.argument<String?>("to")
    val message = call.argument<String>("message")
    val sendEndpointTextMessageBroadcastIntent: Intent = BroadcastIntentHelper.buildSendEndpointTextMessageIntent(to, message)
    LocalBroadcastManager.getInstance(activity!!.applicationContext).sendBroadcast(sendEndpointTextMessageBroadcastIntent)
    result.success("Successfully send endpoint text message $to")
  }

  private fun toggleScreenShare(call: MethodCall, result: Result) {
    val enabled = call.argument<Boolean>("enabled") ?: false
    val toggleScreenShareIntent: Intent = BroadcastIntentHelper.buildToggleScreenShareIntent(enabled)
    LocalBroadcastManager.getInstance(activity!!.applicationContext).sendBroadcast(toggleScreenShareIntent)
    result.success("Successfully toggled screen share $enabled")
  }

  private fun openChat(call: MethodCall, result: Result) {
    val to = call.argument<String?>("to")
    val openChatIntent: Intent = BroadcastIntentHelper.buildOpenChatIntent(to)
    LocalBroadcastManager.getInstance(activity!!.applicationContext).sendBroadcast(openChatIntent)
    result.success("Successfully opened chat $to")
  }

  private fun sendChatMessage(call: MethodCall, result: Result) {
    val to = call.argument<String?>("to")
    val message = call.argument<String>("message")
    val sendChatMessageIntent: Intent = BroadcastIntentHelper.buildSendChatMessageIntent(to, message)
    LocalBroadcastManager.getInstance(activity!!.applicationContext).sendBroadcast(sendChatMessageIntent)
    result.success("Successfully sent chat message $to")

  }

  private fun closeChat(call: MethodCall, result: Result) {
    val closeChatIntent: Intent = BroadcastIntentHelper.buildCloseChatIntent()
    LocalBroadcastManager.getInstance(activity!!.applicationContext).sendBroadcast(closeChatIntent)
    result.success("Successfully closed chat")
  }

  private fun retrieveParticipantsInfo(call: MethodCall, result: Result) {
    val retrieveParticipantsInfoIntent: Intent = Intent("org.jitsi.meet.RETRIEVE_PARTICIPANTS_INFO");
    LocalBroadcastManager.getInstance(activity!!.applicationContext).sendBroadcast(retrieveParticipantsInfoIntent)
    result.success("Successfully retrieved participants info")
  }

  private fun sendPodiumCommand(call: MethodCall, result: Result) {
    val name = call.argument<String>("name")
    if (name == null) {
      result.error("INVALID_ARGUMENT", "name is required", null)
      return
    }
    val payload = call.argument<String>("payload") ?: "{}"
    val intent = BroadcastIntentHelper.buildPodiumCommandIntent(name, payload)
    LocalBroadcastManager.getInstance(activity!!.applicationContext).sendBroadcast(intent)
    result.success("Successfully sent podium command $name")
  }

  private fun setStage(call: MethodCall, result: Result) {
    backgroundSession?.setStage(
      visible = call.argument<Boolean>("visible") ?: false,
      left = call.argument<Int>("left") ?: 0,
      top = call.argument<Int>("top") ?: 0,
      width = call.argument<Int>("width") ?: 0,
      height = call.argument<Int>("height") ?: 0,
      pcId = call.argument<Int>("pcId") ?: -1,
      trackId = call.argument<String>("trackId")
    )
    result.success("Stage updated")
  }

  private fun startCallRecording(call: MethodCall, result: Result) {
    val dir = call.argument<String>("dir")
    if (dir == null) {
      result.error("INVALID_ARGUMENT", "dir is required", null)
      return
    }
    try {
      CallAudioRecorder.start(dir, call.argument<Int>("chunkSeconds") ?: 5)
      result.success(dir)
    } catch (e: Exception) {
      result.error("RECORDING_FAILED", e.message, null)
    }
  }

  private fun stopCallRecording(result: Result) {
    inBackground(result) {
      CallAudioRecorder.stop()?.let {
        mapOf("dir" to it.dir, "chunks" to it.chunks, "durationMs" to it.durationMs)
      }
    }
  }

  private fun joinAudioChunks(call: MethodCall, result: Result) {
    val dir = call.argument<String>("dir")
    val outPath = call.argument<String>("outPath")
    if (dir == null || outPath == null) {
      result.error("INVALID_ARGUMENT", "dir and outPath are required", null)
      return
    }
    inBackground(result) { AacChunks.join(java.io.File(dir), outPath) }
  }

  private fun startScreenCapture(call: MethodCall, result: Result) {
    val trackId = call.argument<String>("trackId")
    val dir = call.argument<String>("dir")
    if (trackId == null || dir == null) {
      result.error("INVALID_ARGUMENT", "trackId and dir are required", null)
      return
    }
    try {
      result.success(ScreenFrameRecorder.start(call.argument<Int>("pcId") ?: -1, trackId, dir))
    } catch (e: Exception) {
      result.error("SCREEN_CAPTURE_FAILED", e.message, null)
    }
  }

  private fun stopScreenCapture(result: Result) {
    val finish = ScreenFrameRecorder.detach()
    if (finish == null) {
      result.success(null)
      return
    }
    inBackground(result) {
      finish()?.let {
        mapOf(
          "frames" to it.frames,
          "width" to it.width,
          "height" to it.height,
          "durationMs" to it.durationMs
        )
      }
    }
  }

  private fun encodeScreenClip(call: MethodCall, result: Result) {
    val dir = call.argument<String>("dir")
    val outPath = call.argument<String>("outPath")
    val endMs = call.argument<Number>("endMs")?.toLong()
    if (dir == null || outPath == null || endMs == null) {
      result.error("INVALID_ARGUMENT", "dir, outPath and endMs are required", null)
      return
    }
    val main = Handler(Looper.getMainLooper())
    inBackground(result) {
      val clip = ScreenClipEncoder.encode(java.io.File(dir), outPath, endMs) { done, total ->
        if (done == total || done % 10 == 0) {
          main.post {
            methodChannel.invokeMethod(
              "screenClipProgress",
              mapOf("outPath" to outPath, "done" to done, "total" to total)
            )
          }
        }
      }
      mapOf("width" to clip.width, "height" to clip.height, "durationMs" to clip.durationMs)
    }
  }

  /** Runs [work] on a background thread and reports its value, or its exception, on the main thread. */
  private fun inBackground(result: Result, work: () -> Any?) {
    val main = Handler(Looper.getMainLooper())
    Thread {
      try {
        val value = work()
        main.post { result.success(value) }
      } catch (e: Exception) {
        main.post { result.error("FAILED", e.message ?: e.toString(), null) }
      }
    }.start()
  }

  private fun enterPiP(call: MethodCall, result: Result) {
    val enterPiPIntent = Intent("org.jitsi.meet.ENTER_PICTURE_IN_PICTURE");
    LocalBroadcastManager.getInstance(activity!!.applicationContext).sendBroadcast(enterPiPIntent)
    result.success("Successfully entered PiP")
  }
}
