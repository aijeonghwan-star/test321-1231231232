package com.example.livesubs

import android.content.Context
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipInputStream

/**
 * Vosk 영어 음성 인식 모델을 내려받아 앱 내부 저장소에 풀어 둔다.
 * 더 정확한 모델을 쓰려면 MODEL_NAME만 바꾸면 된다.
 * 예) "vosk-model-en-us-0.22-lgraph" (약 128MB, 정확도 높음)
 * 모델 목록: https://alphacephei.com/vosk/models
 */
object ModelManager {
    const val MODEL_NAME = "vosk-model-small-en-us-0.15"
    private const val MODEL_URL = "https://alphacephei.com/vosk/models/$MODEL_NAME.zip"

    fun modelDir(ctx: Context) = File(ctx.filesDir, MODEL_NAME)

    fun isReady(ctx: Context) = File(modelDir(ctx), "am").isDirectory

    /** 블로킹 호출. 백그라운드 스레드에서 실행할 것. */
    fun download(ctx: Context, onProgress: (Int) -> Unit) {
        val zip = File(ctx.cacheDir, "$MODEL_NAME.zip")
        val conn = URL(MODEL_URL).openConnection() as HttpURLConnection
        conn.connectTimeout = 15_000
        conn.readTimeout = 30_000
        val total = conn.contentLengthLong
        conn.inputStream.use { input ->
            zip.outputStream().use { out ->
                val buf = ByteArray(64 * 1024)
                var done = 0L
                var last = -1
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    done += n
                    if (total > 0) {
                        val p = (done * 100 / total).toInt()
                        if (p != last) {
                            last = p
                            onProgress(p)
                        }
                    }
                }
            }
        }

        // 임시 폴더에 풀고 완료되면 한 번에 옮겨서, 중간에 실패해도 반쪽짜리 모델이 남지 않게 한다.
        val tmp = File(ctx.filesDir, "model_tmp")
        tmp.deleteRecursively()
        tmp.mkdirs()
        val base = tmp.canonicalFile
        ZipInputStream(zip.inputStream().buffered()).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                val f = File(base, entry.name).canonicalFile
                if (!f.path.startsWith(base.path + File.separator)) {
                    throw SecurityException("잘못된 zip 항목: ${entry.name}")
                }
                if (entry.isDirectory) {
                    f.mkdirs()
                } else {
                    f.parentFile?.mkdirs()
                    f.outputStream().use { zis.copyTo(it) }
                }
                entry = zis.nextEntry
            }
        }
        zip.delete()

        val target = modelDir(ctx)
        target.deleteRecursively()
        if (!File(base, MODEL_NAME).renameTo(target)) {
            throw IllegalStateException("모델 폴더를 옮기지 못했어요")
        }
        tmp.deleteRecursively()
    }
}
