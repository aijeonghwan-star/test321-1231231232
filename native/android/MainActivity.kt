package com.example.voice_match

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Flutter <-> 안드로이드 연결
 *  - pickAudio: 파일 선택 창을 열고 고른 오디오/영상 파일을 16kHz 모노 PCM16으로 디코딩
 *  - startCapture / stopCapture: 다른 앱(유튜브 등)에서 나는 소리 녹음 (Android 10+)
 */
class MainActivity : FlutterActivity() {
    private val channelName = "voice_match/native"
    private val reqPick = 4101
    private val reqCapture = 4102
    private var pendingPick: MethodChannel.Result? = null
    private var pendingCapture: MethodChannel.Result? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickAudio" -> {
                        pendingPick = result
                        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("audio/*", "video/*"))
                        }
                        startActivityForResult(i, reqPick)
                    }
                    "captureSupported" -> result.success(Build.VERSION.SDK_INT >= 29)
                    "startCapture" -> {
                        if (Build.VERSION.SDK_INT < 29) {
                            result.error("unsupported", "안드로이드 10 이상에서만 내부 소리를 녹음할 수 있어요", null)
                        } else {
                            pendingCapture = result
                            val mpm = getSystemService(MediaProjectionManager::class.java)
                            startActivityForResult(mpm.createScreenCaptureIntent(), reqCapture)
                        }
                    }
                    "stopCapture" -> {
                        if (Build.VERSION.SDK_INT < 29) {
                            result.success(null)
                        } else {
                            executor.execute {
                                val pcm = CaptureService.stopAndCollect()
                                main.post { result.success(pcm) }
                            }
                        }
                    }
                    "isCapturing" -> result.success(Build.VERSION.SDK_INT >= 29 && CaptureService.isRecording)
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            reqPick -> {
                val r = pendingPick
                pendingPick = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    r?.success(null)
                    return
                }
                executor.execute {
                    try {
                        val pcm = AudioDecoder.decode(this, uri)
                        val name = displayName(uri)
                        main.post { r?.success(mapOf("name" to name, "pcm" to pcm)) }
                    } catch (e: Exception) {
                        main.post { r?.error("decode", e.message ?: "디코딩 실패", null) }
                    }
                }
            }
            reqCapture -> {
                val r = pendingCapture
                pendingCapture = null
                if (resultCode != Activity.RESULT_OK || data == null || Build.VERSION.SDK_INT < 29) {
                    r?.success(false)
                    return
                }
                CaptureService.start(this, resultCode, data)
                r?.success(true)
            }
        }
    }

    private fun displayName(uri: Uri): String {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val n = c.getString(0) ?: ""
                return n.substringBeforeLast('.')
            }
        }
        return "새 목소리"
    }
}
