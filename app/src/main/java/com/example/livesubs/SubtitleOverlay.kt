package com.example.livesubs

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView

/** 다른 앱 위에 떠 있는 자막 바. 위아래로 드래그해서 위치를 옮길 수 있다. */
class SubtitleOverlay(private val ctx: Context) {

    private val wm = ctx.getSystemService(WindowManager::class.java)

    private val koView = TextView(ctx).apply {
        setTextColor(Color.WHITE)
        textSize = 20f
        gravity = Gravity.CENTER
        setTypeface(typeface, Typeface.BOLD)
        setShadowLayer(4f, 0f, 0f, Color.BLACK)
    }
    private val enView = TextView(ctx).apply {
        setTextColor(0xFFCCCCCC.toInt())
        textSize = 13f
        gravity = Gravity.CENTER
    }
    private val root = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(0xB0000000.toInt())
        setPadding(dp(12), dp(8), dp(12), dp(8))
        addView(koView)
        addView(enView)
        visibility = View.GONE
    }
    private val params = WindowManager.LayoutParams(
        WindowManager.LayoutParams.MATCH_PARENT,
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
        PixelFormat.TRANSLUCENT
    ).apply {
        gravity = Gravity.BOTTOM
        y = dp(48)
    }

    private var ko = ""
    private var en = ""
    private var attached = false

    init {
        var lastY = 0f
        root.setOnTouchListener { _, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> lastY = e.rawY
                MotionEvent.ACTION_MOVE -> {
                    params.y = (params.y - (e.rawY - lastY).toInt()).coerceAtLeast(0)
                    lastY = e.rawY
                    if (attached) wm.updateViewLayout(root, params)
                }
            }
            true
        }
    }

    fun attach() {
        if (attached) return
        wm.addView(root, params)
        attached = true
    }

    fun detach() {
        if (!attached) return
        runCatching { wm.removeView(root) }
        attached = false
    }

    fun setKorean(text: String) { ko = text; render() }
    fun setEnglish(text: String) { en = text; render() }
    fun clear() { ko = ""; en = ""; render() }

    private fun render() {
        koView.text = ko
        koView.visibility = if (ko.isBlank()) View.GONE else View.VISIBLE
        enView.text = en
        enView.visibility = if (en.isBlank()) View.GONE else View.VISIBLE
        root.visibility = if (ko.isBlank() && en.isBlank()) View.GONE else View.VISIBLE
    }

    private fun dp(v: Int) = (v * ctx.resources.displayMetrics.density).toInt()
}
