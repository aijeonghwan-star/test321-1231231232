package com.example.livesubs

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.TranslatorOptions
import kotlin.concurrent.thread

class MainActivity : ComponentActivity() {

    private companion object {
        const val KEY_TRANSLATOR_READY = "translator_ready"
    }

    private lateinit var status: TextView
    private lateinit var progress: ProgressBar
    private lateinit var prepareBtn: Button
    private lateinit var startBtn: Button
    private val prefs by lazy { getSharedPreferences("app", MODE_PRIVATE) }

    private val overlayLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { proceed() }

    private val permLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                launchProjection()
            } else {
                toast("소리 캡처에는 '녹음' 권한이 필요해요 (마이크는 사용하지 않아요)")
            }
        }

    private val projectionLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { res ->
            val data = res.data
            if (res.resultCode == RESULT_OK && data != null) {
                startForegroundService(
                    Intent(this, CaptureService::class.java)
                        .setAction(CaptureService.ACTION_START)
                        .putExtra(CaptureService.EXTRA_CODE, res.resultCode)
                        .putExtra(CaptureService.EXTRA_DATA, data)
                )
                toast("자막 시작! 영상 앱으로 이동해서 재생하세요")
                moveTaskToBack(true)
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (16 * resources.displayMetrics.density).toInt()

        status = TextView(this).apply { textSize = 16f }
        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            visibility = View.GONE
        }
        prepareBtn = Button(this).apply {
            text = "1. 모델 준비 (최초 1회)"
            setOnClickListener { prepare() }
        }
        startBtn = Button(this).apply {
            text = "2. 실시간 자막 시작"
            setOnClickListener { proceed() }
        }
        val stopBtn = Button(this).apply {
            text = "자막 중지"
            setOnClickListener {
                startService(Intent(this@MainActivity, CaptureService::class.java).setAction(CaptureService.ACTION_STOP))
            }
        }
        val help = TextView(this).apply {
            textSize = 13f
            text = "사용법\n" +
                "• 자막 시작 후 YouTube 등 영상 앱에서 재생하면 화면 아래에 한국어 자막이 떠요.\n" +
                "• 화면 공유 팝업에서는 '전체 화면'을 선택하세요.\n" +
                "• 자막 바를 위아래로 끌어서 위치를 옮길 수 있어요.\n" +
                "• Netflix 등 소리 캡처를 막아 둔 앱은 동작하지 않아요."
        }

        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad * 2, pad, pad)
            addView(status)
            addView(progress)
            addView(prepareBtn)
            addView(startBtn)
            addView(stopBtn)
            addView(help)
        })
        refresh()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun isPrepared() =
        ModelManager.isReady(this) && prefs.getBoolean(KEY_TRANSLATOR_READY, false)

    private fun refresh() {
        status.text = if (isPrepared()) "준비 완료. 시작 버튼을 누르세요." else "먼저 '모델 준비'를 눌러 주세요."
        prepareBtn.isEnabled = !isPrepared()
    }

    /** 음성 인식 모델(Vosk) + 번역 모델(ML Kit) 다운로드 */
    private fun prepare() {
        prepareBtn.isEnabled = false
        progress.visibility = View.VISIBLE
        progress.isIndeterminate = false
        thread {
            try {
                if (!ModelManager.isReady(this)) {
                    runOnUiThread { status.text = "음성 인식 모델 다운로드 중…" }
                    ModelManager.download(this) { p -> runOnUiThread { progress.progress = p } }
                }
                runOnUiThread {
                    status.text = "번역 모델 다운로드 중…"
                    progress.isIndeterminate = true
                }
                val tr = Translation.getClient(
                    TranslatorOptions.Builder()
                        .setSourceLanguage(TranslateLanguage.ENGLISH)
                        .setTargetLanguage(TranslateLanguage.KOREAN)
                        .build()
                )
                tr.downloadModelIfNeeded(DownloadConditions.Builder().build())
                    .addOnSuccessListener {
                        prefs.edit().putBoolean(KEY_TRANSLATOR_READY, true).apply()
                        tr.close()
                        progress.visibility = View.GONE
                        refresh()
                    }
                    .addOnFailureListener { e ->
                        tr.close()
                        onPrepareFailed(e)
                    }
            } catch (e: Exception) {
                runOnUiThread { onPrepareFailed(e) }
            }
        }
    }

    private fun onPrepareFailed(e: Exception) {
        progress.visibility = View.GONE
        status.text = "준비 실패: ${e.message}"
        prepareBtn.isEnabled = true
    }

    /** 오버레이 권한 -> 녹음/알림 권한 -> 화면 캡처 승인 순서로 하나씩 확인 */
    private fun proceed() {
        if (!isPrepared()) {
            toast("먼저 모델을 준비해 주세요")
            return
        }
        if (!Settings.canDrawOverlays(this)) {
            toast("'다른 앱 위에 표시' 권한을 허용해 주세요")
            overlayLauncher.launch(
                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
            )
            return
        }
        val missing = mutableListOf<String>()
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            missing += Manifest.permission.RECORD_AUDIO
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            missing += Manifest.permission.POST_NOTIFICATIONS
        }
        if (missing.isNotEmpty()) {
            permLauncher.launch(missing.toTypedArray())
            return
        }
        launchProjection()
    }

    private fun launchProjection() {
        val mpm = getSystemService(MediaProjectionManager::class.java)
        projectionLauncher.launch(mpm.createScreenCaptureIntent())
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
}
