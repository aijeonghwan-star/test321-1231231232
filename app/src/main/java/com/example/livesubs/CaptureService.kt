package com.example.livesubs

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.widget.Toast
import androidx.core.content.IntentCompat
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import org.json.JSONObject
import org.vosk.LibVosk
import org.vosk.LogLevel
import org.vosk.Model
import org.vosk.Recognizer
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * 폰에서 재생 중인 소리(다른 앱 포함)를 캡처 -> 영어 음성 인식(Vosk) -> 한국어 번역(ML Kit)
 * -> 화면 위 오버레이에 실시간 표시.
 */
class CaptureService : Service() {

    companion object {
        const val ACTION_START = "com.example.livesubs.START"
        const val ACTION_STOP = "com.example.livesubs.STOP"
        const val EXTRA_CODE = "code"
        const val EXTRA_DATA = "data"
        private const val CHANNEL = "capture"
        private const val NOTI_ID = 1
        private const val SAMPLE_RATE = 16_000
        private const val CLEAR_AFTER_MS = 5_000L
        private const val PARTIAL_INTERVAL_MS = 600L

        @Volatile
        var running = false
    }

    private val main = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var record: AudioRecord? = null
    private var worker: Thread? = null
    @Volatile private var stopFlag = false
    private var overlay: SubtitleOverlay? = null
    private var translator: Translator? = null
    private val seq = AtomicInteger()
    private val clearRunnable = Runnable { overlay?.clear() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent == null) return START_NOT_STICKY

        // startForegroundService()로 시작했으니 반드시 바로 호출해야 한다.
        startForeground(NOTI_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        if (running) return START_NOT_STICKY

        val code = intent.getIntExtra(EXTRA_CODE, 0)
        val data = IntentCompat.getParcelableExtra(intent, EXTRA_DATA, Intent::class.java)
        if (data == null ||
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
        ) {
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        try {
            setup(code, data)
        } catch (e: Exception) {
            fail(e.message)
        }
        return START_NOT_STICKY
    }

    @SuppressLint("MissingPermission")
    private fun setup(code: Int, data: Intent) {
        val mpm = getSystemService(MediaProjectionManager::class.java)
        val mp = mpm.getMediaProjection(code, data)
        // Android 14+ 에서는 캡처 시작 전에 콜백 등록이 필수
        mp.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                main.post { stopSelf() }
            }
        }, main)
        projection = mp

        val cfg = AudioPlaybackCaptureConfiguration.Builder(mp)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val fmt = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val ar = AudioRecord.Builder()
            .setAudioFormat(fmt)
            .setBufferSizeInBytes(maxOf(minBuf * 2, SAMPLE_RATE * 2))
            .setAudioPlaybackCaptureConfig(cfg)
            .build()
        if (ar.state != AudioRecord.STATE_INITIALIZED) {
            ar.release()
            throw IllegalStateException("오디오 캡처를 시작할 수 없어요")
        }
        record = ar

        translator = Translation.getClient(
            TranslatorOptions.Builder()
                .setSourceLanguage(TranslateLanguage.ENGLISH)
                .setTargetLanguage(TranslateLanguage.KOREAN)
                .build()
        )
        overlay = SubtitleOverlay(this).also { it.attach() }
        overlay?.setEnglish("자막 준비 중…")
        scheduleClear()

        worker = thread(name = "stt") { runRecognizer(ar) }
    }

    private fun runRecognizer(ar: AudioRecord) {
        var model: Model? = null
        var rec: Recognizer? = null
        try {
            LibVosk.setLogLevel(LogLevel.WARNINGS)
            val m = Model(ModelManager.modelDir(this).absolutePath)
            model = m
            val r = Recognizer(m, SAMPLE_RATE.toFloat())
            rec = r

            ar.startRecording()
            val buf = ShortArray(SAMPLE_RATE / 4) // 250ms
            var lastPartial = ""
            var lastAt = 0L

            while (!stopFlag) {
                val n = ar.read(buf, 0, buf.size)
                if (n < 0) throw IllegalStateException("오디오 읽기 오류($n)")
                if (n == 0) continue

                if (r.acceptWaveForm(buf, n)) {
                    // 문장(또는 구절) 확정
                    val text = JSONObject(r.result).optString("text")
                    lastPartial = ""
                    if (text.isNotBlank()) present(text)
                } else {
                    // 말하는 중간 결과도 번역해서 보여줌 (너무 자주 갱신하지 않게 제한)
                    val p = JSONObject(r.partialResult).optString("partial")
                    val now = SystemClock.elapsedRealtime()
                    if (p.isNotBlank() && p != lastPartial && now - lastAt >= PARTIAL_INTERVAL_MS) {
                        lastPartial = p
                        lastAt = now
                        present(p)
                    }
                }
            }
        } catch (e: Exception) {
            if (!stopFlag) main.post { fail(e.message) }
        } finally {
            rec?.close()
            model?.close()
        }
    }

    private fun present(text: String) {
        val id = seq.incrementAndGet()
        main.post {
            overlay?.setEnglish(text)
            scheduleClear()
        }
        translator?.translate(text)
            ?.addOnSuccessListener { ko ->
                // 더 최신 문장이 이미 들어왔으면 오래된 번역은 버린다
                if (id == seq.get()) {
                    overlay?.setKorean(ko)
                    scheduleClear()
                }
            }
            ?.addOnFailureListener {
                if (id == seq.get()) overlay?.setKorean("")
            }
    }

    private fun scheduleClear() {
        main.removeCallbacks(clearRunnable)
        main.postDelayed(clearRunnable, CLEAR_AFTER_MS)
    }

    private fun fail(msg: String?) {
        Toast.makeText(this, "자막 오류: ${msg ?: "알 수 없음"}", Toast.LENGTH_LONG).show()
        stopSelf()
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "실시간 자막", NotificationManager.IMPORTANCE_LOW)
        )
        val stop = PendingIntent.getService(
            this, 0,
            Intent(this, CaptureService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CHANNEL)
            .setContentTitle("실시간 자막 실행 중")
            .setContentText("재생 중인 영어 음성을 한국어로 번역하고 있어요")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "중지", stop)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        stopFlag = true
        runCatching { record?.stop() }
        worker?.join(2000)
        runCatching { record?.release() }
        record = null
        projection?.stop()
        main.removeCallbacksAndMessages(null)
        overlay?.detach()
        translator?.close()
        running = false
        super.onDestroy()
    }
}
