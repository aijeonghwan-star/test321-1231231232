package com.example.voice_match

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import androidx.annotation.RequiresApi
import java.io.ByteArrayOutputStream

/**
 * 다른 앱(유튜브, 브라우저 등)이 재생하는 소리를 녹음하는 포그라운드 서비스.
 * Android 10(API 29)+ 의 AudioPlaybackCapture 사용. 최대 2분.
 * 소리 녹음을 막아 둔 앱(일부 음악/DRM 앱)의 소리는 녹음되지 않습니다.
 */
@RequiresApi(29)
class CaptureService : Service() {
    companion object {
        private const val SR = 16000
        private const val MAX_BYTES = SR * 2 * 120
        private const val CHANNEL_ID = "capture"

        @Volatile
        var isRecording = false
            private set

        private val pcm = ByteArrayOutputStream()
        private var instance: CaptureService? = null

        fun start(ctx: Context, resultCode: Int, data: Intent) {
            synchronized(pcm) { pcm.reset() }
            val i = Intent(ctx, CaptureService::class.java)
                .putExtra("code", resultCode)
                .putExtra("data", data)
            ctx.startForegroundService(i)
        }

        /** 녹음을 멈추고 지금까지 녹음된 16kHz 모노 PCM16 바이트를 돌려줍니다. */
        fun stopAndCollect(): ByteArray {
            instance?.finish()
            synchronized(pcm) { return pcm.toByteArray() }
        }
    }

    private var projection: MediaProjection? = null
    private var record: AudioRecord? = null
    private var thread: Thread? = null

    override fun onBind(intent: Intent?): IBinder? = null

    @SuppressLint("MissingPermission")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "소리 녹음", NotificationManager.IMPORTANCE_LOW)
        )
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        val n = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("폰 소리를 녹음하는 중")
            .setContentText("녹음을 끝내려면 눌러서 앱으로 돌아오세요")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)

        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra("data", Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra("data")
        }
        val mpm = getSystemService(MediaProjectionManager::class.java)
        val proj = mpm.getMediaProjection(intent.getIntExtra("code", 0), data!!)
        projection = proj
        proj.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                isRecording = false
            }
        }, null)

        val cfg = AudioPlaybackCaptureConfiguration.Builder(proj)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SR)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()
        val rec = AudioRecord.Builder()
            .setAudioFormat(format)
            .setBufferSizeInBytes(SR * 2)
            .setAudioPlaybackCaptureConfig(cfg)
            .build()
        record = rec
        rec.startRecording()
        isRecording = true
        instance = this
        thread = Thread {
            val buf = ByteArray(3200)
            while (isRecording) {
                val read = rec.read(buf, 0, buf.size)
                if (read > 0) {
                    synchronized(pcm) {
                        pcm.write(buf, 0, read)
                        if (pcm.size() >= MAX_BYTES) isRecording = false
                    }
                }
            }
        }.also { it.start() }
        return START_NOT_STICKY
    }

    fun finish() {
        isRecording = false
        thread?.join(1500)
        thread = null
        try {
            record?.stop()
        } catch (_: Exception) {
        }
        record?.release()
        record = null
        projection?.stop()
        projection = null
        instance = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (instance === this) finish()
        super.onDestroy()
    }
}
