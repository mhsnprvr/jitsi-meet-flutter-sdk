package org.jitsi.jitsi_meet_flutter_sdk

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.util.Log
import org.webrtc.audio.PodiumAudioTap
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Records the conference as heard on this device: the remote audio WebRTC plays out mixed with
 * the local microphone, encoded as mono AAC.
 *
 * One encoder runs for the whole recording and its ADTS frames are split into chunk files of
 * [AacChunks.FILE_PREFIX]NNNNN.aac, so every finished chunk is playable on its own and the chunks
 * join back into one gapless stream (see [AacChunks.join]).
 *
 * The playout stream drives the timeline (it runs continuously once WebRTC has a media
 * connection, as silence when nobody talks); microphone audio is mixed into it as it arrives.
 * Before that connection exists, e.g. a muted host alone in the room, there is no playout, so
 * silence is written by the wall clock instead.
 */
object CallAudioRecorder {
    private const val TAG = "CallAudioRecorder"
    private const val SAMPLE_RATE = 48_000
    private const val BIT_RATE = 96_000
    private const val QUEUE_CHUNKS = 500 // 5 s of 10 ms chunks
    private const val MAX_MIC_BACKLOG_MS = 200
    private const val POLL_MS = 100L

    /** How long playout may be missing before the wall clock takes over the timeline. */
    private const val PLAYOUT_TIMEOUT_MS = 300L

    /** Whether the local participant is unmuted; WebRTC keeps capturing while muted. */
    @Volatile
    var micEnabled = false

    class Result(val dir: String, val chunks: Int, val durationMs: Long)

    private class Chunk(val samples: ShortArray, val sampleRate: Int)

    private var session: Session? = null

    val isRecording: Boolean
        @Synchronized get() = session != null

    @Synchronized
    fun start(dir: String, chunkSeconds: Int) {
        check(session == null) { "A recording is already in progress" }
        val directory = File(dir)
        directory.mkdirs()
        check(directory.isDirectory) { "Could not create $dir" }
        val framesPerChunk = maxOf(1, chunkSeconds * SAMPLE_RATE / AacChunks.SAMPLES_PER_FRAME)
        val s = Session(directory, framesPerChunk)
        session = s
        PodiumAudioTap.setRecordListener { data, size, rate, channels ->
            if (micEnabled) s.mic.offer(Chunk(toMono(data, size, channels), rate))
        }
        PodiumAudioTap.setPlayoutListener { data, size, rate, channels ->
            s.playout.offer(Chunk(toMono(data, size, channels), rate))
        }
        s.thread.start()
    }

    /** Stops the recording, or returns null if nothing was recorded. Blocks. */
    fun stop(): Result? {
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

    private class Session(val dir: File, framesPerChunk: Int) {
        val playout = ArrayBlockingQueue<Chunk>(QUEUE_CHUNKS)
        val mic = ArrayBlockingQueue<Chunk>(QUEUE_CHUNKS)

        @Volatile
        var running = true
        var result: Result? = null
        val thread = Thread({ run() }, "CallAudioRecorder")

        private val writer = AacChunks.Writer(dir, framesPerChunk, SAMPLE_RATE, 1)
        private val micRing = ShortArray(SAMPLE_RATE) // 1 s
        private var micRead = 0
        private var micCount = 0
        private var codec: MediaCodec? = null
        private var framesQueued = 0L
        private val info = MediaCodec.BufferInfo()
        private var payload = ByteArray(2048)

        private fun run() {
            var lastPlayoutNs = System.nanoTime()
            var timelineNs = lastPlayoutNs
            try {
                while (running || playout.isNotEmpty()) {
                    val chunk = playout.poll(POLL_MS, TimeUnit.MILLISECONDS)
                    val now = System.nanoTime()
                    val samples = if (chunk != null) {
                        lastPlayoutNs = now
                        timelineNs = now
                        resample(chunk.samples, chunk.sampleRate, SAMPLE_RATE)
                    } else {
                        if (!running || now - lastPlayoutNs < PLAYOUT_TIMEOUT_MS * 1_000_000) {
                            continue
                        }
                        val count = ((now - timelineNs) * SAMPLE_RATE / 1_000_000_000).toInt()
                        timelineNs += count * 1_000_000_000L / SAMPLE_RATE
                        ShortArray(count)
                    }
                    if (samples.isEmpty()) continue
                    if (codec == null) open()
                    mixMic(samples)
                    encode(samples, endOfStream = false)
                }
                if (codec != null) encode(ShortArray(0), endOfStream = true)
            } catch (e: Exception) {
                Log.e(TAG, "Recording failed", e)
            } finally {
                release()
                writer.close()
                result = if (writer.frames > 0) {
                    Result(dir.path, writer.chunks, writer.durationMs)
                } else {
                    null
                }
            }
        }

        private fun open() {
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16 * 1024)
            }
            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply {
                configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                start()
            }
        }

        private fun mixMic(out: ShortArray) {
            while (true) {
                val chunk = mic.poll() ?: break
                for (s in resample(chunk.samples, chunk.sampleRate, SAMPLE_RATE)) pushMic(s)
            }
            // Keep the microphone close to the playout clock if the two drift apart.
            val maxBacklog = SAMPLE_RATE * MAX_MIC_BACKLOG_MS / 1000
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
                    val ptsUs = framesQueued * 1_000_000L / SAMPLE_RATE
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
            var waits = 0
            while (true) {
                val index = codec.dequeueOutputBuffer(info, if (waitForEnd) 10_000 else 0)
                when {
                    index == MediaCodec.INFO_TRY_AGAIN_LATER ->
                        if (!waitForEnd || ++waits > 200) return
                    index >= 0 -> {
                        val buffer = codec.getOutputBuffer(index)!!
                        val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                        if (!isConfig && info.size > 0) {
                            if (payload.size < info.size) payload = ByteArray(info.size)
                            buffer.position(info.offset)
                            buffer.get(payload, 0, info.size)
                            writer.write(payload, info.size)
                        }
                        codec.releaseOutputBuffer(index, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                    }
                }
            }
        }

        private fun release() {
            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            codec?.release()
            codec = null
        }
    }
}
