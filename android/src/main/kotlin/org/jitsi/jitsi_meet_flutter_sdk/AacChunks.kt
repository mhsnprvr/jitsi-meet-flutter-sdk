package org.jitsi.jitsi_meet_flutter_sdk

import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer

/**
 * AAC-LC audio stored as ADTS chunk files that are consecutive slices of one encoded stream.
 * ADTS needs no index, so a chunk cut short by a crash is still readable up to its last frame.
 */
object AacChunks {
    const val FILE_PREFIX = "chunk_"
    const val FILE_SUFFIX = ".aac"
    const val SAMPLES_PER_FRAME = 1024

    private val SAMPLE_RATES = intArrayOf(
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350
    )

    fun chunkFiles(dir: File): List<File> =
        dir.listFiles { f -> f.name.startsWith(FILE_PREFIX) && f.name.endsWith(FILE_SUFFIX) }
            ?.sortedBy { it.name }
            ?: emptyList()

    /** Writes raw AAC-LC frames as ADTS, starting a new chunk file every [framesPerChunk] frames. */
    class Writer(
        private val dir: File,
        private val framesPerChunk: Int,
        private val sampleRate: Int,
        private val channels: Int,
    ) {
        private val rateIndex = SAMPLE_RATES.indexOf(sampleRate).also {
            require(it >= 0) { "Unsupported ADTS sample rate $sampleRate" }
        }
        private val header = ByteArray(7)
        private var out: FileOutputStream? = null
        private var framesInChunk = 0

        var chunks = 0
            private set
        var frames = 0L
            private set
        val durationMs: Long
            get() = frames * SAMPLES_PER_FRAME * 1000 / sampleRate

        fun write(frame: ByteArray, size: Int) {
            val stream = out ?: open()
            val length = size + header.size
            header[0] = 0xFF.toByte()
            header[1] = 0xF1.toByte() // MPEG-4, no CRC
            header[2] = ((1 shl 6) or (rateIndex shl 2) or (channels shr 2)).toByte() // LC
            header[3] = (((channels and 3) shl 6) or (length shr 11)).toByte()
            header[4] = ((length shr 3) and 0xFF).toByte()
            header[5] = (((length and 7) shl 5) or 0x1F).toByte()
            header[6] = 0xFC.toByte()
            // Unbuffered, so every frame reaches the OS and survives the app being killed.
            stream.write(header)
            stream.write(frame, 0, size)
            frames++
            if (++framesInChunk >= framesPerChunk) closeChunk()
        }

        fun close() = closeChunk()

        private fun open(): FileOutputStream {
            chunks++
            val file = File(dir, FILE_PREFIX + "%05d".format(chunks) + FILE_SUFFIX)
            return FileOutputStream(file).also { out = it }
        }

        private fun closeChunk() {
            val stream = out ?: return
            out = null
            framesInChunk = 0
            try {
                stream.flush()
                stream.fd.sync()
            } catch (_: IOException) {
            } finally {
                stream.close()
            }
        }
    }

    /**
     * Joins the chunks in [dir] into an .m4a at [outPath] without re-encoding, and returns its
     * duration in milliseconds. A frame cut short at the end of a chunk is dropped.
     */
    fun join(dir: File, outPath: String): Long {
        val files = chunkFiles(dir)
        if (files.isEmpty()) throw IOException("No audio chunks in ${dir.path}")
        val tmp = File("$outPath.tmp")
        tmp.delete()
        var muxer: MediaMuxer? = null
        var track = -1
        var frames = 0L
        var sampleRate = 0
        var sample = ByteBuffer.allocateDirect(8192)
        val info = MediaCodec.BufferInfo()
        try {
            for (file in files) {
                val bytes = file.readBytes()
                var pos = 0
                while (pos + 7 <= bytes.size) {
                    val b1 = bytes[pos + 1].toInt() and 0xFF
                    if ((bytes[pos].toInt() and 0xFF) != 0xFF || (b1 and 0xF0) != 0xF0) break
                    val b2 = bytes[pos + 2].toInt() and 0xFF
                    val b3 = bytes[pos + 3].toInt() and 0xFF
                    val headerLength = if (b1 and 1 == 1) 7 else 9
                    val frameLength = ((b3 and 3) shl 11) or
                        ((bytes[pos + 4].toInt() and 0xFF) shl 3) or
                        ((bytes[pos + 5].toInt() and 0xFF) shr 5)
                    if (frameLength <= headerLength || pos + frameLength > bytes.size) break
                    if (muxer == null) {
                        val profile = ((b2 shr 6) and 3) + 1
                        val rateIndex = (b2 shr 2) and 0xF
                        val channels = ((b2 and 1) shl 2) or (b3 shr 6)
                        sampleRate = SAMPLE_RATES.getOrNull(rateIndex)
                            ?: throw IOException("Bad ADTS sample rate index $rateIndex")
                        val config = (profile shl 11) or (rateIndex shl 7) or (channels shl 3)
                        val format = MediaFormat.createAudioFormat(
                            MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channels
                        ).apply {
                            setByteBuffer(
                                "csd-0",
                                ByteBuffer.wrap(byteArrayOf((config shr 8).toByte(), config.toByte()))
                            )
                        }
                        muxer = MediaMuxer(tmp.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                        track = muxer.addTrack(format)
                        muxer.start()
                    }
                    val size = frameLength - headerLength
                    if (sample.capacity() < size) sample = ByteBuffer.allocateDirect(size)
                    sample.clear()
                    sample.put(bytes, pos + headerLength, size)
                    sample.flip()
                    info.set(
                        0, size, frames * SAMPLES_PER_FRAME * 1_000_000L / sampleRate,
                        MediaCodec.BUFFER_FLAG_KEY_FRAME
                    )
                    muxer!!.writeSampleData(track, sample, info)
                    frames++
                    pos += frameLength
                }
            }
            if (muxer == null || frames == 0L) throw IOException("No audio frames in ${dir.path}")
            muxer.stop()
        } catch (e: Exception) {
            tmp.delete()
            throw e
        } finally {
            muxer?.release()
        }
        val out = File(outPath)
        out.delete()
        if (!tmp.renameTo(out)) throw IOException("Could not move the joined audio to $outPath")
        return frames * SAMPLES_PER_FRAME * 1000 / sampleRate
    }
}
