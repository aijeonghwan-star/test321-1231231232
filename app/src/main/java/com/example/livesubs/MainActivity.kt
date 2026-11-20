package com.example.livesubs

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.TranslatorOptions
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import kotlin.concurrent.thread

class MainActivity : ComponentActivity() {

    private companion object {
        const val KEY_TRANSLATOR_READY = "translator_ready"
        const val VERSION = "v1.1"
    }

    private lateinit var status: TextView
    private lateinit var logView: TextView
    private lateinit var progress: ProgressBar
    private lateinit var prepareBtn: Button
    private lateinit var startBtn: Button
    private val prefs by lazy { getSharedPreferences("app", MODE_PRIVATE) }

    @Volatile private var preparing = false

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
        installCrashLogger()

        val pad = (16 * resources.displayMetrics.density).toInt()

        status = TextView(this).apply {
            textSize = 16f
            setTextColor(Color.BLACK)
        }
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
                startService(
                    Intent(this@MainActivity, CaptureService::class.java)
                        .setAction(CaptureService.ACTION_STOP)
                )
            }
        }
        val help = TextView(this).apply {
            textSize = 13f
            setTextColor(0xFF444444.toInt())
            text = "사용법\n" +
                "• 자막 시작 후 YouTube 등 영상 앱에서 재생하면 화면 아래에 한국어 자막이 떠요.\n" +
                "• 화면 공유 팝업에서는 '전체 화면'을 선택하세요.\n" +
                "• 자막 바를 위아래로 끌어서 위치를 옮길 수 있어요.\n" +
                "• Netflix 등 소리 캡처를 막아 둔 앱은 동작하지 않아요."
        }
        logView = TextView(this).apply {
            textSize = 12f
            setTextColor(0xFF666666.toInt())
            setTextIsSelectable(true)
        }

        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
            addView(TextView(this@MainActivity).apply {
                text = "실시간 자막 $VERSION"
                textSize = 20f
                setTextColor(Color.BLACK)
            })
            addView(status)
            addView(progress)
            addView(prepareBtn)
            addView(startBtn)
            addView(stopBtn)
            addView(help)
            addView(logView)
        }
        val scroll = ScrollView(this).apply {
            setBackgroundColor(Color.WHITE)
            isFillViewport = true
            addView(content)
        }
        // 상태바/내비게이션바/제목 막대에 내용이 가려지지 않도록 안전 영역만큼 띄운다
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { v, insets ->
            val b = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
            )
            v.setPadding(b.left, b.top, b.right, b.bottom)
            insets
        }
        setContentView(scroll)

        showPreviousCrash()
        log("앱 시작 ($VERSION, Android ${Build.VERSION.SDK_INT}, ${Build.SUPPORTED_ABIS.joinToString()})")
        refresh()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun isPrepared() =
        ModelManager.isReady(this) && prefs.getBoolean(KEY_TRANSLATOR_READY, false)

    private fun refresh() {
        if (preparing) return
        status.text = if (isPrepared()) "준비 완료. 아래 '실시간 자막 시작'을 누르세요."
        else "먼저 '모델 준비'를 눌러 주세요."
        prepareBtn.isEnabled = !isPrepared()
    }

    /** 음성 인식 모델(Vosk) + 번역 모델(ML Kit) 다운로드 */
    private fun prepare() {
        if (preparing) return
        preparing = true
        prepareBtn.isEnabled = false
        progress.visibility = View.VISIBLE
        progress.isIndeterminate = false
        progress.progress = 0
        status.text = "준비 시작…"
        log("모델 준비 시작")
        thread {
            try {
                if (!ModelManager.isReady(this)) {
                    runOnUiThread { status.text = "음성 인식 모델 다운로드 중… (약 40MB)" }
                    var lastLogged = -10
                    ModelManager.download(this) { p ->
                        runOnUiThread {
                            progress.progress = p
                            status.text = "음성 인식 모델 다운로드 중… $p%"
                        }
                        if (p - lastLogged >= 25) { lastLogged = p; log("음성 모델 $p%") }
                    }
                    log("음성 모델 설치 완료")
                } else {
                    log("음성 모델은 이미 설치됨")
                }
                runOnUiThread {
                    status.text = "번역 모델 다운로드 중… (약 30MB)"
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
                        log("번역 모델 설치 완료")
                        preparing = false
                        progress.visibility = View.GONE
                        refresh()
                    }
                    .addOnFailureListener { e ->
                        tr.close()
                        onPrepareFailed(e)
                    }
            } catch (t: Throwable) {
                runOnUiThread { onPrepareFailed(t) }
            }
        }
    }

    private fun onPrepareFailed(t: Throwable) {
        preparing = false
        progress.visibility = View.GONE
        status.text = "준비 실패: ${t.message ?: t.javaClass.simpleName}\n다시 눌러 재시도하세요."
        prepareBtn.isEnabled = true
        log("실패: " + stackOf(t))
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

    // ---- 진단용 로그 -------------------------------------------------------

    private fun log(msg: String) {
        runOnUiThread { logView.append(msg + "\n") }
    }

    private fun stackOf(t: Throwable): String {
        val sw = StringWriter()
        t.printStackTrace(PrintWriter(sw))
        return sw.toString().lines().take(8).joinToString("\n")
    }

    private fun crashFile() = File(filesDir, "last_crash.txt")

    /** 앱이 죽으면 원인을 파일에 남겨 두었다가 다음 실행 때 화면에 보여준다 */
    private fun installCrashLogger() {
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { th, e ->
            runCatching { crashFile().writeText("[${th.name}]\n" + stackOf(e)) }
            prev?.uncaughtException(th, e)
        }
    }

    private fun showPreviousCrash() {
        val f = crashFile()
        if (f.exists()) {
            log("이전 실행에서 앱이 종료된 원인:\n" + f.readText())
            f.delete()
        }
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
}
