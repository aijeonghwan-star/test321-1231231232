package com.example.voice_match

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** 오디오/영상 파일을 16kHz 모노 PCM16(little endian) 바이트로 디코딩합니다. */
object AudioDecoder {
    private const val OUT_SR = 16000

    fun decode(ctx: Context, uri: Uri, maxSeconds: Int = 600): ByteArray {
        val ex = MediaExtractor()
        ex.setDataSource(ctx, uri, null)
        var track = -1
        for (i in 0 until ex.trackCount) {
            val mime = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: ""
            if (mime.startsWith("audio/")) {
                track = i
                break
            }
        }
        if (track < 0) {
            ex.release()
            throw IllegalArgumentException("파일에 오디오가 없어요")
        }
        ex.selectTrack(track)
        val fmt = ex.getTrackFormat(track)
        val codec = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(fmt, null, null, 0)
        codec.start()

        var sr = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var ch = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var isFloat = false
        val mono = FloatBuilder()
        val info = MediaCodec.BufferInfo()
        var inDone = false
        var outDone = false
        try {
            while (!outDone) {
                if (!inDone) {
                    val ii = codec.dequeueInputBuffer(10000)
                    if (ii >= 0) {
                        val buf = codec.getInputBuffer(ii)!!
                        val n = ex.readSampleData(buf, 0)
                        if (n < 0) {
                            codec.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inDone = true
                        } else {
                            codec.queueInputBuffer(ii, 0, n, ex.sampleTime, 0)
                            ex.advance()
                        }
                    }
                }
                val oi = codec.dequeueOutputBuffer(info, 10000)
                if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val of = codec.outputFormat
                    sr = of.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    ch = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    isFloat = Build.VERSION.SDK_INT >= 24 &&
                        of.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        of.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                } else if (oi >= 0) {
                    val ob: ByteBuffer = codec.getOutputBuffer(oi)!!
                    ob.position(info.offset)
                    ob.limit(info.offset + info.size)
                    ob.order(ByteOrder.nativeOrder())
                    if (isFloat) {
                        val fb = ob.asFloatBuffer()
                        val frames = fb.remaining() / ch
                        for (f in 0 until frames) {
                            var s = 0f
                            for (c in 0 until ch) s += fb.get()
                            mono.add(s / ch)
                        }
                    } else {
                        val sb = ob.asShortBuffer()
                        val frames = sb.remaining() / ch
                        for (f in 0 until frames) {
                            var s = 0f
                            for (c in 0 until ch) s += sb.get()
                            mono.add(s / ch / 32768f)
                        }
                    }
                    codec.releaseOutputBuffer(oi, false)
                    if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) outDone = true
                    if (mono.size > maxSeconds.toLong() * sr) outDone = true
                }
            }
        } finally {
            codec.stop()
            codec.release()
            ex.release()
        }
        return toPcm16(resample(mono.toArray(), sr, OUT_SR))
    }

    /** 구간 평균(간단한 저역 통과) + 선형 보간 리샘플링 */
    fun resample(x: FloatArray, from: Int, to: Int): FloatArray {
        if (from == to || x.isEmpty()) return x
        val ratio = from.toDouble() / to
        val n = (x.size / ratio).toInt()
        val out = FloatArray(n)
        val half = (ratio / 2).coerceAtLeast(0.5)
        for (i in 0 until n) {
            val center = i * ratio
            val a = (center - half).toInt().coerceAtLeast(0)
            val b = (center + half).toInt().coerceAtMost(x.size - 1)
            var s = 0f
            for (j in a..b) s += x[j]
            out[i] = s / (b - a + 1)
        }
        return out
    }

    fun toPcm16(x: FloatArray): ByteArray {
        val bb = ByteBuffer.allocate(x.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (v in x) bb.putShort((v.coerceIn(-1f, 1f) * 32767).toInt().toShort())
        return bb.array()
    }

    private class FloatBuilder {
        private var data = FloatArray(1 shl 16)
        var size = 0
            private set

        fun add(v: Float) {
            if (size == data.size) data = data.copyOf(data.size * 2)
            data[size++] = v
        }

        fun toArray(): FloatArray = data.copyOf(size)
    }
}
