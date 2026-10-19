package org.webrtc.audio;

import androidx.annotation.Nullable;
import java.nio.ByteBuffer;

/**
 * Exposes the 16-bit little-endian PCM that WebRTC captures from the microphone and the mixed
 * remote audio it plays out, so the app can record the call.
 *
 * Listeners run on WebRTC's real-time audio threads and must return quickly. The buffer belongs
 * to WebRTC: read it with absolute gets only (never change its position, limit or order) and
 * don't keep it after returning.
 */
public final class PodiumAudioTap {
  public interface Listener {
    void onSamples(ByteBuffer data, int sizeInBytes, int sampleRate, int channels);
  }

  @Nullable private static volatile Listener recordListener;
  @Nullable private static volatile Listener playoutListener;

  private PodiumAudioTap() {}

  public static void setRecordListener(@Nullable Listener listener) {
    recordListener = listener;
  }

  public static void setPlayoutListener(@Nullable Listener listener) {
    playoutListener = listener;
  }

  static void deliverRecorded(ByteBuffer data, int sizeInBytes, int sampleRate, int channels) {
    Listener listener = recordListener;
    if (listener != null) {
      listener.onSamples(data, sizeInBytes, sampleRate, channels);
    }
  }

  static void deliverPlayout(ByteBuffer data, int sizeInBytes, int sampleRate, int channels) {
    Listener listener = playoutListener;
    if (listener != null) {
      listener.onSamples(data, sizeInBytes, sampleRate, channels);
    }
  }
}
