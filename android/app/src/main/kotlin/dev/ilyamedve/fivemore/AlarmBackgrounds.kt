package dev.ilyamedve.fivemore

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID

object BackgroundRules {
    fun frame(value: Any?): Map<String, Any> {
        val raw = value as? Map<*, *> ?: emptyMap<Any, Any>()
        fun number(key: String, fallback: Double, min: Double, max: Double): Double =
            (raw[key] as? Number)?.toDouble()?.takeIf { it.isFinite() }?.coerceIn(min, max) ?: fallback
        return mapOf("x" to number("x", .5, 0.0, 1.0), "y" to number("y", .5, 0.0, 1.0),
            "zoom" to number("zoom", 1.0, 1.0, 4.0), "turns" to number("turns", 0.0, 0.0, 3.0).toInt())
    }
    const val MAX_INPUT_BYTES = 20 * 1024 * 1024
    const val MAX_STORED_BYTES = 4 * 1024 * 1024
    fun validName(name: String) = Regex("[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}\\.jpg").matches(name)
    fun sampleSize(width: Int, height: Int): Int {
        require(width > 0 && height > 0) { "Не удалось прочитать изображение." }
        var sample = 1
        while (maxOf(width, height).toLong() > 1600L * sample) sample *= 2
        return sample
    }
}

/** Optional UI media. A locked or missing photo never participates in scheduling. */
object AlarmBackgrounds {
    private fun directory(context: Context) = File(context.filesDir, "alarm_backgrounds").apply { mkdirs() }
    fun read(context: Context, name: String): ByteArray? {
        require(BackgroundRules.validName(name)) { "Неверное имя фона." }
        val file = File(directory(context), name)
        if (!file.exists() || file.length() !in 1..BackgroundRules.MAX_STORED_BYTES.toLong()) return null
        return file.readBytes()
    }

    fun importImage(context: Context, uri: Uri): String {
        val bytes = context.contentResolver.openInputStream(uri)?.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                require(output.size() + count <= BackgroundRules.MAX_INPUT_BYTES) { "Выбери изображение до 20 МБ." }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        } ?: error("Не удалось открыть изображение.")
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        options.inSampleSize = BackgroundRules.sampleSize(options.outWidth, options.outHeight)
        options.inJustDecodeBounds = false
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: error("Формат изображения не поддерживается.")
        var oriented = bitmap
        val file = File(directory(context), "${UUID.randomUUID()}.jpg")
        try {
            val orientation = try { ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) } catch (_: Exception) { 1 }
            val matrix = Matrix().apply {
                when (orientation) {
                    2 -> setScale(-1f, 1f)
                    3 -> setRotate(180f)
                    4 -> setScale(1f, -1f)
                    5 -> { setRotate(90f); postScale(-1f, 1f) }
                    6 -> setRotate(90f)
                    7 -> { setRotate(270f); postScale(-1f, 1f) }
                    8 -> setRotate(270f)
                }
            }
            oriented = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
            // Re-encode pixels only: no EXIF, location or source path is retained.
            file.outputStream().use { check(oriented.compress(Bitmap.CompressFormat.JPEG, 85, it)) }
            check(file.length() in 1..BackgroundRules.MAX_STORED_BYTES.toLong()) { "Не удалось сохранить изображение." }
            return file.name
        } catch (error: Exception) { file.delete(); throw error }
        finally { if (oriented !== bitmap) oriented.recycle(); bitmap.recycle() }
    }
}
