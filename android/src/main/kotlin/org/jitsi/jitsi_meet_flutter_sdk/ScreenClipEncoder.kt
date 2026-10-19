package org.jitsi.jitsi_meet_flutter_sdk

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.io.IOException

/**
 * Encodes a frames directory written by [ScreenFrameRecorder] into an H.264 .mp4, showing each
 * frame from its recorded time until the next one, and the last one until [encode]'s `endMs`.
 */
object ScreenClipEncoder {
    private const val BIT_RATE = 700_000
    private const val FRAME_RATE = 10
    private const val KEY_FRAME_INTERVAL_S = 2
    private const val TIMEOUT_US = 10_000L

    class Result(val width: Int, val height: Int, val durationMs: Long)

    fun encode(dir: File, outPath: String, endMs: Long, progress: (done: Int, total: Int) -> Unit): Result {
        val entries = ScreenFrames.read(dir)
        if (entries.isEmpty()) throw IOException("No screen frames in ${dir.path}")
        val first = entries.first()
        val firstRotated = first.rotation == 90 || first.rotation == 270
        // Some encoders only accept sizes in multiples of 16.
        val width = maxOf(16, (if (firstRotated) first.height else first.width) / 16 * 16)
        val height = maxOf(16, (if (firstRotated) first.width else first.height) / 16 * 16)

        val tmp = File("$outPath.tmp")
        tmp.delete()
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
            setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, KEY_FRAME_INTERVAL_S)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val muxer = MediaMuxer(tmp.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val state = Drain(codec, muxer)
        var muxerStarted = false
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            val canvasBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(canvasBitmap)
            val paint = Paint(Paint.FILTER_BITMAP_FLAG)
            val pixels = IntArray(width * height)
            var lastPtsUs = -1L
            var drawn = false

            fun queue(ptsUs: Long, endOfStream: Boolean) {
                while (true) {
                    val index = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (index >= 0) {
                        if (endOfStream) {
                            codec.queueInputBuffer(index, 0, 0, ptsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        } else {
                            val image = codec.getInputImage(index)
                                ?: throw IOException("The encoder has no flexible YUV input")
                            fillYuv(image, pixels, width, height)
                            codec.queueInputBuffer(index, 0, width * height * 3 / 2, ptsUs, 0)
                        }
                        return
                    }
                    state.drain(waitForEnd = false)
                }
            }

            for ((i, entry) in entries.withIndex()) {
                val bitmap = BitmapFactory.decodeFile(File(dir, ScreenFrames.frameName(entry.number)).path)
                if (bitmap != null) {
                    draw(canvas, bitmap, entry.rotation, width, height, paint)
                    bitmap.recycle()
                    canvasBitmap.getPixels(pixels, 0, width, 0, 0, width, height)
                    drawn = true
                    // The clip starts when the share did, so the first picture is shown from 0.
                    val ptsUs = if (lastPtsUs < 0) 0L else maxOf(entry.atMs * 1000, lastPtsUs + 1000)
                    queue(ptsUs, endOfStream = false)
                    lastPtsUs = ptsUs
                    state.drain(waitForEnd = false)
                }
                progress(i + 1, entries.size)
            }
            if (!drawn) throw IOException("No readable screen frames in ${dir.path}")
            // Hold the last picture until the share ended.
            if (endMs * 1000 > lastPtsUs) {
                queue(endMs * 1000, endOfStream = false)
                lastPtsUs = endMs * 1000
            }
            queue(lastPtsUs + 1000, endOfStream = true)
            state.drain(waitForEnd = true)
            muxerStarted = state.started
            canvasBitmap.recycle()
            if (!muxerStarted) throw IOException("The encoder produced no video")
            muxer.stop()
            val out = File(outPath)
            out.delete()
            if (!tmp.renameTo(out)) throw IOException("Could not move the clip to $outPath")
            return Result(width, height, lastPtsUs / 1000)
        } catch (e: Exception) {
            tmp.delete()
            throw e
        } finally {
            try {
                codec.stop()
            } catch (_: Exception) {
            }
            codec.release()
            try {
                muxer.release()
            } catch (_: Exception) {
            }
        }
    }

    private class Drain(val codec: MediaCodec, val muxer: MediaMuxer) {
        private val info = MediaCodec.BufferInfo()
        private var track = -1
        var started = false
            private set

        fun drain(waitForEnd: Boolean) {
            var waits = 0
            while (true) {
                val index = codec.dequeueOutputBuffer(info, if (waitForEnd) TIMEOUT_US else 0)
                when {
                    index == MediaCodec.INFO_TRY_AGAIN_LATER ->
                        if (!waitForEnd || ++waits > 500) return
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        track = muxer.addTrack(codec.outputFormat)
                        muxer.start()
                        started = true
                    }
                    index >= 0 -> {
                        val buffer = codec.getOutputBuffer(index)!!
                        val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                        if (!isConfig && info.size > 0 && started) {
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
    }

    /** Draws [bitmap] upright and fitted inside the canvas, on black. */
    private fun draw(canvas: Canvas, bitmap: Bitmap, rotation: Int, width: Int, height: Int, paint: Paint) {
        canvas.drawColor(Color.BLACK)
        val rotated = rotation == 90 || rotation == 270
        val srcW = if (rotated) bitmap.height else bitmap.width
        val srcH = if (rotated) bitmap.width else bitmap.height
        val scale = minOf(width.toFloat() / srcW, height.toFloat() / srcH)
        val matrix = Matrix().apply {
            postTranslate(-bitmap.width / 2f, -bitmap.height / 2f)
            postRotate(rotation.toFloat())
            postScale(scale, scale)
            postTranslate(width / 2f, height / 2f)
        }
        canvas.drawBitmap(bitmap, matrix, paint)
    }

    /** Converts ARGB pixels to BT.601 limited range YUV 4:2:0 in the encoder's input image. */
    private fun fillYuv(image: Image, pixels: IntArray, width: Int, height: Int) {
        val planes = image.planes
        val yPlane = planes[0]
        val uPlane = planes[1]
        val vPlane = planes[2]
        val yBuffer = yPlane.buffer
        val uBuffer = uPlane.buffer
        val vBuffer = vPlane.buffer
        val yRow = ByteArray(width)
        for (row in 0 until height) {
            val base = row * width
            for (col in 0 until width) {
                val p = pixels[base + col]
                val r = (p shr 16) and 0xFF
                val g = (p shr 8) and 0xFF
                val b = p and 0xFF
                yRow[col] = (((66 * r + 129 * g + 25 * b + 128) shr 8) + 16).toByte()
            }
            if (yPlane.pixelStride == 1) {
                yBuffer.position(row * yPlane.rowStride)
                yBuffer.put(yRow, 0, width)
            } else {
                for (col in 0 until width) {
                    yBuffer.put(row * yPlane.rowStride + col * yPlane.pixelStride, yRow[col])
                }
            }
        }
        for (row in 0 until height / 2) {
            for (col in 0 until width / 2) {
                val p = pixels[(row * 2) * width + col * 2]
                val r = (p shr 16) and 0xFF
                val g = (p shr 8) and 0xFF
                val b = p and 0xFF
                val u = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                val v = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                uBuffer.put(row * uPlane.rowStride + col * uPlane.pixelStride, u.toByte())
                vBuffer.put(row * vPlane.rowStride + col * vPlane.pixelStride, v.toByte())
            }
        }
    }
}
