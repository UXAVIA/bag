package com.bagapp.bag

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader

/**
 * Renders a decorative sparkline bitmap for the large widget background.
 *
 * Design intent:
 *  - Full-bleed background image (no axes, no labels, no grid)
 *  - Dark scrim at the top so price/net-worth text remains readable
 *  - Coloured line + translucent fill: green for positive, red for negative
 *  - Works in any Kotlin context — no Flutter engine required
 */
object NativeChartRenderer {

    private const val POSITIVE_COLOR = 0xFF00C896.toInt()
    private const val NEGATIVE_COLOR = 0xFFFF4757.toInt()

    /**
     * @param prices  Close prices oldest → newest. Must contain at least 2 values.
     * @param width   Bitmap width in pixels.
     * @param height  Bitmap height in pixels.
     * @return        Rendered ARGB_8888 bitmap.
     */
    fun render(prices: List<Double>, width: Int, height: Int): Bitmap {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        if (prices.size < 2) return bitmap

        val minP = prices.min()
        val maxP = prices.max()
        val range = if (maxP > minP) maxP - minP else 1.0

        val isPositive = prices.last() >= prices.first()
        val lineColor = if (isPositive) POSITIVE_COLOR else NEGATIVE_COLOR
        val fillColorTop = if (isPositive) 0x2800C896.toInt() else 0x28FF4757.toInt()

        // Vertical padding keeps the line away from the very top/bottom edges.
        val padTop = height * 0.12f
        val padBottom = height * 0.08f
        val drawHeight = height - padTop - padBottom

        fun priceToY(p: Double): Float =
            padTop + drawHeight * (1f - ((p - minP) / range).toFloat())

        fun indexToX(i: Int): Float =
            if (prices.size == 1) 0f
            else i.toFloat() / (prices.size - 1) * width

        // ── Build line path ───────────────────────────────────────────────────
        val linePath = Path()
        prices.forEachIndexed { i, p ->
            val x = indexToX(i)
            val y = priceToY(p)
            if (i == 0) linePath.moveTo(x, y) else linePath.lineTo(x, y)
        }

        // ── Fill under the line ───────────────────────────────────────────────
        val fillPath = Path(linePath).apply {
            lineTo(width.toFloat(), height.toFloat())
            lineTo(0f, height.toFloat())
            close()
        }
        canvas.drawPath(fillPath, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
            shader = LinearGradient(
                0f, padTop,
                0f, height.toFloat(),
                fillColorTop, 0x00000000,
                Shader.TileMode.CLAMP,
            )
        })

        // ── Sparkline ─────────────────────────────────────────────────────────
        canvas.drawPath(linePath, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            color = lineColor
            strokeWidth = 3f
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        })

        // ── Dark scrim at top — keeps text readable ───────────────────────────
        // Gradient: 85% black at top → fully transparent at ~60% height.
        val scrimPaint = Paint().apply {
            shader = LinearGradient(
                0f, 0f,
                0f, height * 0.62f,
                0xD9000000.toInt(), 0x00000000,
                Shader.TileMode.CLAMP,
            )
        }
        canvas.drawRect(0f, 0f, width.toFloat(), height * 0.62f, scrimPaint)

        return bitmap
    }
}
