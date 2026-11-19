package com.yourname.movietranslator

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedOutputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "audio_extractor")
            .setMethodCallHandler { call, result ->
                if (call.method == "extract") {
                    val input = call.argument<String>("input")!!
                    val output = call.argument<String>("output")!!
                    thread {
                        try {
                            extract(input, output)
                            runOnUiThread { result.success(true) }
                        } catch (e: Throwable) {
                            val msg = "${e.javaClass.simpleName}: ${e.message}"
                            runOnUiThread { result.error("EXTRACT", msg, null) }
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    // يطلّع الصوت من الفيديو كـ WAV مونو 16kHz 16-bit
    private fun extract(input: String, output: String) {
        val ex = MediaExtractor()
        ex.setDataSource(input)

        var idx = -1
        var fmt: MediaFormat? = null
        var mimeFound = ""
        for (i in 0 until ex.trackCount) {
            val f = ex.getTrackFormat(i)
            val m = f.getString(MediaFormat.KEY_MIME) ?: ""
            if (m.startsWith("audio/")) {
                idx = i
                fmt = f
                mimeFound = m
                break
            }
        }
        if (idx < 0 || fmt == null) {
            ex.release()
            throw Exception("الفيديو مفيهوش مسار صوت")
        }
        ex.selectTrack(idx)

        val codec: MediaCodec
        try {
            try {
                fmt.setInteger(
                    MediaFormat.KEY_PCM_ENCODING,
                    AudioFormat.ENCODING_PCM_16BIT
                )
            } catch (_: Throwable) {}
            codec = MediaCodec.createDecoderByType(mimeFound)
            codec.configure(fmt, null, null, 0)
            codec.start()
        } catch (e: Throwable) {
            ex.release()
            throw Exception("الموبايل مش بيفك صيغة الصوت ($mimeFound): ${e.message}")
        }

        var srcRate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val target = 16000

        val out = BufferedOutputStream(FileOutputStream(output))
        out.write(ByteArray(44)) // مكان الهيدر، هنكتبه في الآخر
        var dataBytes = 0L

        var acc = 0.0
        var cnt = 0
        var phase = 0.0

        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false

        try {
            while (!outputDone) {
                if (!inputDone) {
                    val ii = codec.dequeueInputBuffer(10000)
                    if (ii >= 0) {
                        val ib = codec.getInputBuffer(ii)!!
                        val size = ex.readSampleData(ib, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(
                                ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(ii, 0, size, ex.sampleTime, 0)
                            ex.advance()
                        }
                    }
                }

                val oi = codec.dequeueOutputBuffer(info, 10000)
                if (oi >= 0) {
                    val ob = codec.getOutputBuffer(oi)!!
                    ob.position(info.offset)
                    ob.limit(info.offset + info.size)
                    ob.order(ByteOrder.LITTLE_ENDIAN)
                    val sb = ob.asShortBuffer()

                    val ch = if (channels < 1) 1 else channels
                    val ratio = srcRate.toDouble() / target
                    val frames = sb.remaining() / ch
                    val bb = ByteBuffer.allocate(frames * 2 + 8)
                    bb.order(ByteOrder.LITTLE_ENDIAN)

                    for (f in 0 until frames) {
                        var sum = 0
                        for (c in 0 until ch) sum += sb.get().toInt()
                        acc += sum.toDouble() / ch
                        cnt++
                        phase += 1.0
                        if (phase >= ratio) {
                            var v = (acc / cnt).toInt()
                            if (v > 32767) v = 32767
                            if (v < -32768) v = -32768
                            bb.putShort(v.toShort())
                            acc = 0.0
                            cnt = 0
                            phase -= ratio
                        }
                    }
                    out.write(bb.array(), 0, bb.position())
                    dataBytes += bb.position()

                    codec.releaseOutputBuffer(oi, false)
                    if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        outputDone = true
                    }
                } else if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val nf = codec.outputFormat
                    srcRate = nf.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = nf.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                }
            }
        } finally {
            out.flush()
            out.close()
            try { codec.stop() } catch (_: Throwable) {}
            codec.release()
            ex.release()
        }

        // كتابة هيدر WAV
        val header = ByteBuffer.allocate(44)
        header.order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray())
        header.putInt((36 + dataBytes).toInt())
        header.put("WAVE".toByteArray())
        header.put("fmt ".toByteArray())
        header.putInt(16)
        header.putShort(1)            // PCM
        header.putShort(1)            // مونو
        header.putInt(target)
        header.putInt(target * 2)     // byte rate
        header.putShort(2)            // block align
        header.putShort(16)           // bits
        header.put("data".toByteArray())
        header.putInt(dataBytes.toInt())

        val raf = RandomAccessFile(output, "rw")
        raf.seek(0)
        raf.write(header.array())
        raf.close()
    }
}