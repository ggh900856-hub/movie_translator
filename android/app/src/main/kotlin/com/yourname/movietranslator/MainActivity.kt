package com.yourname.movietranslator

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
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

    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "audio_extractor")
        channel!!.setMethodCallHandler { call, result ->
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

    private fun report(pct: Int) {
        runOnUiThread { channel?.invokeMethod("progress", pct) }
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

        // مدة الصوت بالميكروثانية (عشان نحسب النسبة)
        var durUs: Long =
            if (fmt.containsKey(MediaFormat.KEY_DURATION)) fmt.getLong(MediaFormat.KEY_DURATION)
            else 0L
        if (durUs <= 0L) {
            // لو مسار الصوت مش قايل مدته، ناخدها من الفيديو نفسه
            try {
                val r = MediaMetadataRetriever()
                r.setDataSource(input)
                val ms = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull() ?: 0L
                durUs = ms * 1000L
                r.release()
            } catch (_: Throwable) {}
        }
        var lastPct = -1
        report(0)

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

        val out = BufferedOutputStream(FileOutputStream(output), 1 shl 20)
        out.write(ByteArray(44)) // مكان الهيدر، هنكتبه في الآخر
        var dataBytes = 0L

        var accSum = 0L
        var cnt = 0
        var phase = 0.0

        var tmp = ShortArray(0)
        var outBytes = ByteArray(0)

        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false

        try {
            while (!outputDone) {
                var progressed = false

                // 1) غذّي المفكك بكل المساحات الفاضية من غير انتظار
                while (!inputDone) {
                    val ii = codec.dequeueInputBuffer(0)
                    if (ii < 0) break
                    val ib = codec.getInputBuffer(ii)!!
                    val size = ex.readSampleData(ib, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(
                            ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                        )
                        inputDone = true
                    } else {
                        val t = ex.sampleTime
                        codec.queueInputBuffer(ii, 0, size, t, 0)
                        ex.advance()

                        // تقرير النسبة (بس لو اتغيرت)
                        if (durUs > 0 && t >= 0) {
                            var pct = (t * 100 / durUs).toInt()
                            if (pct > 99) pct = 99
                            if (pct != lastPct) {
                                lastPct = pct
                                report(pct)
                            }
                        }
                    }
                    progressed = true
                }

                // 2) اسحب كل الناتج الجاهز من غير انتظار
                while (true) {
                    val oi = codec.dequeueOutputBuffer(info, 0)
                    if (oi >= 0) {
                        progressed = true
                        val ob = codec.getOutputBuffer(oi)!!
                        ob.position(info.offset)
                        ob.limit(info.offset + info.size)
                        ob.order(ByteOrder.LITTLE_ENDIAN)
                        val sb = ob.asShortBuffer()
                        val n = sb.remaining()
                        if (tmp.size < n) tmp = ShortArray(n)
                        sb.get(tmp, 0, n)

                        val ch = if (channels < 1) 1 else channels
                        val ratio = srcRate.toDouble() / target
                        val frames = n / ch
                        val maxOut = (frames / ratio).toInt() + 4
                        if (outBytes.size < maxOut * 2) outBytes = ByteArray(maxOut * 2)

                        var o = 0
                        for (f in 0 until frames) {
                            val base = f * ch
                            var sum = 0
                            for (c in 0 until ch) sum += tmp[base + c].toInt()
                            accSum += sum.toLong()
                            cnt += ch
                            phase += 1.0
                            if (phase >= ratio && o + 2 <= outBytes.size) {
                                var v = (accSum / cnt).toInt()
                                if (v > 32767) v = 32767
                                if (v < -32768) v = -32768
                                outBytes[o++] = (v and 0xFF).toByte()
                                outBytes[o++] = ((v shr 8) and 0xFF).toByte()
                                accSum = 0L
                                cnt = 0
                                phase -= ratio
                            }
                        }
                        if (o > 0) {
                            out.write(outBytes, 0, o)
                            dataBytes += o
                        }

                        codec.releaseOutputBuffer(oi, false)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            outputDone = true
                            break
                        }
                    } else if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        progressed = true
                        val nf = codec.outputFormat
                        srcRate = nf.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = nf.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    } else {
                        break
                    }
                }

                // 3) لو مفيش شغل دلوقتي، نرتاح لحظة ونرجع
                if (!progressed && !outputDone) {
                    Thread.sleep(2)
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

        report(100)
    }
}