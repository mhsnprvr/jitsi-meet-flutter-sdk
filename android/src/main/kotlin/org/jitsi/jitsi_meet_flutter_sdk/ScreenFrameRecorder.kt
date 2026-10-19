package org.jitsi.jitsi_meet_flutter_sdk

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.os.SystemClock
import android.util.Log
import org.jitsi.meet.sdk.PodiumVideoTap
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs

/**
 * Saves the frames of a screen share track as JPEGs in a directory, with an index of when each
 * was shown ([ScreenFrames]). Frames are thinned to [MAX_FPS], scaled to at most [MAX_WIDTH] wide,
 * and skipped while the picture doesn't change. Everything runs on the CPU, so it keeps working
 * while the app is in the background; [ScreenClipEncoder] turns the frames into a video later.
 */
object ScreenFrameRecorder {
    private const val TAG = "ScreenFrameRecorder"
    private const val MAX_FPS = 10
    private const val MAX_WIDTH = 1280
    private const val JPEG_QUALITY = 80

    class Result(val frames: Int, val width: Int, val height: Int, val durationMs: Long)

    private var session: Session? = null

    /**
     * Must be called on the main thread. Returns whether the track was found. A capture still
     * running is detached and finishes in the background.
     */
    fun start(pcId: Int, trackId: String, dir: String): Boolean {
        detach()?.let { finish -> Thread { finish() }.start() }
        val directory = File(dir)
        directory.mkdirs()
        val s = Session(directory)
        if (!PodiumVideoTap.addSink(pcId, trackId, s)) {
            s.close()
            return false
        }
        session = s
        return true
    }

    /**
     * Must be called on the main thread. Stops receiving frames and returns a function that waits
     * for pending frames to be written (call it off the main thread), or null if not capturing.
     */
    fun detach(): (() -> Result?)? {
        val s = session ?: return null
        session = null
        PodiumVideoTap.removeSink(s)
        return { s.close() }
    }

    private class Session(val dir: File) : VideoSink {
        private val startedAt = SystemClock.elapsedRealtime()
        private val executor = Executors.newSingleThreadExecutor { Thread(it, TAG) }
        private val busy = AtomicBoolean(false)
        private val index = FileOutputStream(File(dir, ScreenFrames.INDEX_FILE), true)
        @Volatile private var closed = false
        @Volatile private var lastAcceptedAt = -1L
        private var lastSignature: IntArray? = null
        private var frames = 0
        private var width = 0
        private var height = 0
        private var nv21 = ByteArray(0)

        override fun onFrame(frame: VideoFrame) {
            if (closed) return
            val now = SystemClock.elapsedRealtime()
            if (lastAcceptedAt >= 0 && now - lastAcceptedAt < 1000 / MAX_FPS) return
            // Drop rather than queue when the previous frame is still being saved.
            if (!busy.compareAndSet(false, true)) return
            lastAcceptedAt = now
            frame.retain()
            executor.execute {
                try {
                    save(frame, now - startedAt)
                } catch (e: Exception) {
                    Log.w(TAG, "Could not save a frame", e)
                } finally {
                    frame.release()
                    busy.set(false)
                }
            }
        }

        private fun save(frame: VideoFrame, atMs: Long) {
            if (closed) return
            val source = frame.buffer
            val scale = minOf(1.0, MAX_WIDTH.toDouble() / maxOf(source.width, source.height))
            val w = maxOf(2, (source.width * scale).toInt() and 1.inv())
            val h = maxOf(2, (source.height * scale).toInt() and 1.inv())
            val scaled = source.cropAndScale(0, 0, source.width, source.height, w, h)
            val i420 = try {
                scaled.toI420()
            } finally {
                scaled.release()
            } ?: return
            try {
                val signature = signatureOf(i420)
                val previous = lastSignature
                if (previous != null && unchanged(previous, signature)) return
                lastSignature = signature
                writeJpeg(i420, frames + 1)
            } finally {
                i420.release()
            }
            frames++
            val rotation = frame.rotation
            val rotated = rotation == 90 || rotation == 270
            width = if (rotated) h else w
            height = if (rotated) w else h
            index.write("$frames $atMs $w $h $rotation\n".toByteArray())
        }

        /** Luma averages over a coarse grid, to tell whether the picture changed. */
        private fun signatureOf(buffer: VideoFrame.I420Buffer): IntArray {
            val cols = 32
            val rows = 18
            val out = IntArray(cols * rows)
            val y = buffer.dataY
            val stride = buffer.strideY
            for (r in 0 until rows) {
                for (c in 0 until cols) {
                    val px = (c * buffer.width + buffer.width / 2) / cols
                    val py = (r * buffer.height + buffer.height / 2) / rows
                    out[r * cols + c] = y.get(py * stride + px).toInt() and 0xFF
                }
            }
            return out
        }

        private fun unchanged(a: IntArray, b: IntArray): Boolean {
            var diff = 0L
            for (i in a.indices) diff += abs(a[i] - b[i])
            return diff.toDouble() / a.size < 1.0
        }

        private fun writeJpeg(buffer: VideoFrame.I420Buffer, number: Int) {
            val w = buffer.width
            val h = buffer.height
            val size = w * h * 3 / 2
            if (nv21.size < size) nv21 = ByteArray(size)
            val y = buffer.dataY
            val u = buffer.dataU
            val v = buffer.dataV
            for (row in 0 until h) {
                y.position(row * buffer.strideY)
                y.get(nv21, row * w, w)
            }
            var out = w * h
            for (row in 0 until h / 2) {
                for (col in 0 until w / 2) {
                    nv21[out++] = v.get(row * buffer.strideV + col)
                    nv21[out++] = u.get(row * buffer.strideU + col)
                }
            }
            val file = File(dir, ScreenFrames.frameName(number))
            FileOutputStream(file).use { stream ->
                YuvImage(nv21, ImageFormat.NV21, w, h, null)
                    .compressToJpeg(Rect(0, 0, w, h), JPEG_QUALITY, stream)
            }
        }

        fun close(): Result? {
            closed = true
            executor.shutdown()
            executor.awaitTermination(5, TimeUnit.SECONDS)
            try {
                index.flush()
                index.fd.sync()
            } catch (_: Exception) {
            }
            index.close()
            if (frames == 0) return null
            return Result(frames, width, height, SystemClock.elapsedRealtime() - startedAt)
        }
    }
}

/** Layout of a frames directory written by [ScreenFrameRecorder]. */
object ScreenFrames {
    const val INDEX_FILE = "frames.idx"

    fun frameName(number: Int) = "f_%06d.jpg".format(number)

    class Entry(val number: Int, val atMs: Long, val width: Int, val height: Int, val rotation: Int)

    /** Reads the index, skipping a line cut short by a crash and frames whose file is missing. */
    fun read(dir: File): List<Entry> {
        val file = File(dir, INDEX_FILE)
        if (!file.exists()) return emptyList()
        return file.readLines().mapNotNull { line ->
            val parts = line.trim().split(' ')
            if (parts.size != 5) return@mapNotNull null
            val entry = Entry(
                parts[0].toIntOrNull() ?: return@mapNotNull null,
                parts[1].toLongOrNull() ?: return@mapNotNull null,
                parts[2].toIntOrNull() ?: return@mapNotNull null,
                parts[3].toIntOrNull() ?: return@mapNotNull null,
                parts[4].toIntOrNull() ?: return@mapNotNull null,
            )
            if (File(dir, frameName(entry.number)).exists()) entry else null
        }
    }
}
