package org.jitsi.jitsi_meet_flutter_sdk

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import org.webrtc.audio.PodiumAudioTap
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Records the conference as heard on this device: the remote audio WebRTC plays out mixed with
 * the local microphone, encoded as mono AAC into an .m4a file.
 *
 * The playout stream drives the timeline (it runs continuously while in a conference, as silence
 * when nobody talks); microphone audio is mixed into it as it arrives.
 */
object CallAudioRecorder {
    private const val TAG = "CallAudioRecorder"
    private const val BIT_RATE = 96_000
    private const val QUEUE_CHUNKS = 500 // 5 s of 10 ms chunks
    private const val MAX_MIC_BACKLOG_MS = 200

    /** Whether the local participant is unmuted; WebRTC keeps capturing while muted. */
    @Volatile
    var micEnabled = false

    private class Chunk(val samples: ShortArray, val sampleRate: Int)

    private var session: Session? = null

    val isRecording: Boolean
        @Synchronized get() = session != null

    @Synchronized
    fun start(path: String) {
        check(session == null) { "A recording is already in progress" }
        File(path).parentFile?.mkdirs()
        val s = Session(path)
        session = s
        PodiumAudioTap.setRecordListener { data, size, rate, channels ->
            if (micEnabled) s.mic.offer(Chunk(toMono(data, size, channels), rate))
        }
        PodiumAudioTap.setPlayoutListener { data, size, rate, channels ->
            s.playout.offer(Chunk(toMono(data, size, channels), rate))
        }
        s.thread.start()
    }

    /** Stops the recording and returns the file path, or null if nothing was recorded. Blocks. */
    fun stop(): String? {
        val s = synchronized(this) {
            val current = session ?: return null
            session = null
            PodiumAudioTap.setRecordListener(null)
            PodiumAudioTap.setPlayoutListener(null)
            current
        }
        s.running = false
        s.thread.join()
        return s.result
    }

    private fun toMono(data: ByteBuffer, sizeInBytes: Int, channels: Int): ShortArray {
        val frameBytes = 2 * channels
        val frames = sizeInBytes / frameBytes
        val out = ShortArray(frames)
        for (f in 0 until frames) {
            var sum = 0
            for (c in 0 until channels) {
                val i = f * frameBytes + c * 2
                sum += (data.get(i).toInt() and 0xff) or (data.get(i + 1).toInt() shl 8)
            }
            out[f] = (sum / channels).toShort()
        }
        return out
    }

    private fun resample(src: ShortArray, srcRate: Int, dstRate: Int): ShortArray {
        if (srcRate == dstRate || src.isEmpty()) return src
        val outLen = (src.size.toLong() * dstRate / srcRate).toInt()
        val out = ShortArray(outLen)
        val step = srcRate.toDouble() / dstRate
        for (i in 0 until outLen) {
            val pos = i * step
            val i0 = pos.toInt().coerceAtMost(src.size - 1)
            val i1 = (i0 + 1).coerceAtMost(src.size - 1)
            val frac = pos - i0
            out[i] = (src[i0] + (src[i1] - src[i0]) * frac).toInt().toShort()
        }
        return out
    }

    private class Session(val path: String) {
        val playout = ArrayBlockingQueue<Chunk>(QUEUE_CHUNKS)
        val mic = ArrayBlockingQueue<Chunk>(QUEUE_CHUNKS)

        @Volatile
        var running = true
        var result: String? = null
        val thread = Thread({ run() }, "CallAudioRecorder")

        private var sampleRate = 0
        private var micRing = ShortArray(0)
        private var micRead = 0
        private var micCount = 0
        private var codec: MediaCodec? = null
        private var muxer: MediaMuxer? = null
        private var track = -1
        private var framesQueued = 0L
        private val info = MediaCodec.BufferInfo()

        private fun run() {
            try {
                while (running || playout.isNotEmpty()) {
                    val chunk = playout.poll(100, TimeUnit.MILLISECONDS) ?: continue
                    if (codec == null) open(chunk.sampleRate)
                    val samples = resample(chunk.samples, chunk.sampleRate, sampleRate)
                    mixMic(samples)
                    encode(samples, endOfStream = false)
                }
                if (codec != null) encode(ShortArray(0), endOfStream = true)
                result = finish()
            } catch (e: Exception) {
                Log.e(TAG, "Recording failed", e)
                release()
                File(path).delete()
            }
        }

        private fun open(rate: Int) {
            sampleRate = rate
            micRing = ShortArray(rate) // 1 s
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16 * 1024)
            }
            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply {
                configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                start()
            }
            muxer = MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        }

        private fun mixMic(out: ShortArray) {
            while (true) {
                val chunk = mic.poll() ?: break
                for (s in resample(chunk.samples, chunk.sampleRate, sampleRate)) pushMic(s)
            }
            // Keep the microphone close to the playout clock if the two drift apart.
            val maxBacklog = sampleRate * MAX_MIC_BACKLOG_MS / 1000
            if (micCount > maxBacklog) {
                val drop = micCount - maxBacklog
                micRead = (micRead + drop) % micRing.size
                micCount -= drop
            }
            val n = minOf(out.size, micCount)
            for (i in 0 until n) {
                val mixed = out[i] + micRing[micRead]
                out[i] = mixed.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
                micRead = (micRead + 1) % micRing.size
            }
            micCount -= n
        }

        private fun pushMic(sample: Short) {
            if (micCount == micRing.size) {
                micRead = (micRead + 1) % micRing.size
                micCount--
            }
            micRing[(micRead + micCount) % micRing.size] = sample
            micCount++
        }

        private fun encode(samples: ShortArray, endOfStream: Boolean) {
            val codec = codec ?: return
            var offset = 0
            do {
                val index = codec.dequeueInputBuffer(10_000)
                if (index >= 0) {
                    val buffer = codec.getInputBuffer(index)!!
                    buffer.clear()
                    val count = minOf(samples.size - offset, buffer.remaining() / 2)
                    buffer.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(samples, offset, count)
                    offset += count
                    val last = endOfStream && offset == samples.size
                    val ptsUs = framesQueued * 1_000_000L / sampleRate
                    framesQueued += count
                    codec.queueInputBuffer(
                        index, 0, count * 2, ptsUs,
                        if (last) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0
                    )
                }
                drain(waitForEnd = false)
            } while (offset < samples.size || (endOfStream && index < 0))
            if (endOfStream) drain(waitForEnd = true)
        }

        private fun drain(waitForEnd: Boolean) {
            val codec = codec ?: return
            val muxer = muxer ?: return
            var waits = 0
            while (true) {
                val index = codec.dequeueOutputBuffer(info, if (waitForEnd) 10_000 else 0)
                when {
                    index == MediaCodec.INFO_TRY_AGAIN_LATER ->
                        if (!waitForEnd || ++waits > 200) return
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        track = muxer.addTrack(codec.outputFormat)
                        muxer.start()
                    }
                    index >= 0 -> {
                        val buffer = codec.getOutputBuffer(index)!!
                        val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                        if (!isConfig && info.size > 0 && track >= 0) {
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            muxer.writeSampleData(track, buffer, info)
                        }
                        codec.releaseOutputBuffer(index, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                    }
                }
            }
        }

        private fun finish(): String? {
            val wroteSamples = track >= 0 && framesQueued > 0
            release()
            if (!wroteSamples) {
                File(path).delete()
                return null
            }
            return path
        }

        private fun release() {
            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            codec?.release()
            codec = null
            try {
                if (track >= 0) muxer?.stop()
            } catch (e: Exception) {
                Log.e(TAG, "Muxer stop failed", e)
            }
            muxer?.release()
            muxer = null
        }
    }
}
