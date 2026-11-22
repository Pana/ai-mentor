package cn.littlebear.tutor.homework

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.nio.file.Files
import kotlin.math.abs
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Homework pages and their thumbnails with real JPEG encoding (Robolectric's native graphics, the same Skia encoder
 * as on a phone). Sizes are printed to the test report's standard output.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34])
class PhotosTest {
    private fun bounds(data: ByteArray) = BitmapFactory.Options().apply { inJustDecodeBounds = true }.also { BitmapFactory.decodeByteArray(data, 0, data.size, it) }

    /**
     * Something like a 12 MP phone photo of a written page: uneven lamp light, ruled paper, printed questions,
     * handwriting and sensor noise, saved at camera quality with an EXIF orientation.
     */
    private fun cameraPhoto(dir: File, width: Int = 4000, height: Int = 3000, orientation: Int = ExifInterface.ORIENTATION_ROTATE_90): File {
        val random = Random(7)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val light = Paint().apply {
            shader = android.graphics.RadialGradient(width * 0.35f, height * 0.3f, width * 0.9f,
                android.graphics.Color.rgb(246, 240, 226), android.graphics.Color.rgb(170, 160, 140), android.graphics.Shader.TileMode.CLAMP)
        }
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), light)
        val rule = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.rgb(150, 175, 205); strokeWidth = 4f }
        for (y in 260 until height step 150) canvas.drawLine(160f, y.toFloat(), width - 160f, y + 18f, rule)
        val print = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.rgb(45, 45, 50); textSize = 92f }
        val questions = listOf("数学口算练习 第 12 页", "1. 36 + 27 = 63", "2. 58 - 19 = 39", "3. 45 + 38 = 83", "4. 72 - 45 = 27",
            "5. 90 - 26 = 64", "6. 17 + 48 = 65", "7. 66 + 25 = 91", "8. 81 - 37 = 44", "9. 29 + 54 = 83", "要求：写出计算过程")
        questions.forEachIndexed { i, line -> canvas.drawText(line, 240f, 240f + i * 150f, print) }
        // Pencil handwriting: wobbly strokes next to every question.
        val pen = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.rgb(70, 70, 85); style = Paint.Style.STROKE; strokeWidth = 7f; strokeCap = Paint.Cap.ROUND }
        for (row in 1 until questions.size) {
            var x = 1700f + random.nextFloat() * 200
            val base = 240f + row * 150f
            repeat(14) {
                val path = Path().apply {
                    moveTo(x, base - random.nextFloat() * 70)
                    repeat(6) { lineTo(x + random.nextFloat() * 50, base - random.nextFloat() * 80) }
                }
                canvas.drawPath(path, pen)
                x += 60 + random.nextFloat() * 40
            }
        }
        // Sensor noise, a band at a time.
        val band = IntArray(width * 50)
        for (top in 0 until height step 50) {
            val rows = minOf(50, height - top)
            bitmap.getPixels(band, 0, width, 0, top, width, rows)
            for (i in 0 until width * rows) {
                val p = band[i]
                val n = (random.nextInt(13) - 6)
                fun c(v: Int) = (v + n + random.nextInt(5) - 2).coerceIn(0, 255)
                band[i] = (0xFF shl 24) or (c((p shr 16) and 0xFF) shl 16) or (c((p shr 8) and 0xFF) shl 8) or c(p and 0xFF)
            }
            bitmap.setPixels(band, 0, width, 0, top, width, rows)
        }
        val file = File(dir, "camera.jpg")
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 92, it) }
        bitmap.recycle()
        ExifInterface(file.absolutePath).apply { setAttribute(ExifInterface.TAG_ORIENTATION, orientation.toString()); saveAttributes() }
        return file
    }

    @Test fun aCameraPhotoBecomesASmallUprightPageAndThumbnail() {
        val dir = Files.createTempDirectory("photos").toFile()
        val original = cameraPhoto(dir)
        val photo = Photos.prepare { original.inputStream() }
        assertNotNull(photo); photo!!
        val page = bounds(photo.data)
        // Turned upright by the EXIF orientation (landscape sensor, portrait page), 1400 px on the long side.
        assertEquals(1050, page.outWidth); assertEquals(1400, page.outHeight)
        val thumb = bounds(photo.thumb!!)
        assertEquals(360, thumb.outWidth); assertEquals(480, thumb.outHeight)
        assertTrue("page ${photo.data.size} B", photo.data.size in 50_000..600_000)
        assertTrue("thumbnail ${photo.thumb!!.size} B", photo.thumb!!.size in 5_000..60_000)
        assertTrue(photo.thumb!!.size <= Photos.THUMB_MAX_BYTES)
        println("PHOTO-SIZES camera ${original.length()} B 4000x3000 -> page ${photo.data.size} B ${page.outWidth}x${page.outHeight}, thumb ${photo.thumb!!.size} B ${thumb.outWidth}x${thumb.outHeight}")

        // What the old settings (2000 px, quality 86) made of the same photo, for comparison.
        val old = Photos.page({ original.inputStream() }, 2000)!!
        val oldJpeg = Photos.jpeg(old, 86)!!
        println("PHOTO-SIZES camera old settings -> ${oldJpeg.size} B ${old.width}x${old.height}")
        assertTrue(photo.data.size * 2 < oldJpeg.size)
    }

    /** The fixture worksheet already in the repository (2400×1600, clean scan). */
    @Test fun theRepositoryWorksheetFixture() {
        val fixture = File(System.getProperty("user.dir"), "../scripts/fixtures/homework.jpg")
        assumeTrue("fixture not found at $fixture", fixture.exists())
        val photo = Photos.prepare { fixture.inputStream() }!!
        val page = bounds(photo.data); val thumb = bounds(photo.thumb!!)
        assertEquals(1400, page.outWidth); assertEquals(933, page.outHeight)
        assertEquals(480, thumb.outWidth); assertEquals(320, thumb.outHeight)
        println("PHOTO-SIZES fixture ${fixture.length()} B 2400x1600 -> page ${photo.data.size} B, thumb ${photo.thumb!!.size} B")
    }

    @Test fun smallPicturesAreNotEnlarged() {
        val bitmap = Bitmap.createBitmap(300, 200, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.WHITE) }
        val file = File(Files.createTempDirectory("small").toFile(), "s.jpg").apply { outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) } }
        val photo = Photos.prepare { file.inputStream() }!!
        assertEquals(300, bounds(photo.data).outWidth)
        assertEquals(300, bounds(photo.thumb!!).outWidth)
        assertEquals(null, Photos.prepare { "not a picture".byteInputStream() })
    }

    /** The red-pen overlay is drawn over the full page; over a thumbnail it must land in the same place. */
    @Test fun thumbnailsKeepThePageAspectSoTheOverlayLinesUp() {
        for ((w, h) in listOf(1050 to 1400, 1400 to 1050, 1400 to 933, 1400 to 1867, 1120 to 1400, 1400 to 700, 640 to 1400)) {
            val (tw, th) = Photos.fit(w, h, Photos.THUMB_SIDE)
            assertEquals(Photos.THUMB_SIDE, maxOf(tw, th))
            val drift = abs(tw.toDouble() / th - w.toDouble() / h) / (w.toDouble() / h)
            // Under half a pixel of a 480 px thumbnail: the aspect-fit frames of photo and overlay coincide.
            assertTrue("$w x $h -> $tw x $th drifts $drift", drift < 0.5 / 480 * 2)
        }
        assertEquals(1400 to 1050, Photos.fit(4000, 3000, Photos.PAGE_SIDE))
        assertEquals(800 to 600, Photos.fit(800, 600, Photos.PAGE_SIDE))
    }
}
