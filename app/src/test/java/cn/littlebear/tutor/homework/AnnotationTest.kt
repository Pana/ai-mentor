package cn.littlebear.tutor.homework

import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AnnotationTest {
    private val line = listOf(Offset(0.1f, 0.1f), Offset(0.5f, 0.5f))

    @Test fun undoRemovesTheLastMarkOnThatPageOnly() {
        val marks = AnnotationModel()
        marks.add(0, line); marks.add(0, line.reversed()); marks.add(1, line)
        marks.undo(0)
        assertEquals(listOf(line), marks.strokes[0])
        assertEquals(listOf(line), marks.strokes[1])
        marks.undo(0)
        assertEquals(emptyList<List<Offset>>(), marks.strokes[0])
        assertFalse(marks.canUndo(0))
        assertTrue(marks.canUndo(1))
    }

    /** The 撤销 button reads canUndo while composing; it only turns on if that read is snapshot state Compose can observe. */
    @Test fun canUndoIsObservableSoTheUndoButtonUpdates() {
        val marks = AnnotationModel()
        val reads = mutableListOf<Any>()
        Snapshot.observe(readObserver = { reads += it }) { marks.canUndo(0) }
        assertTrue("canUndo must read snapshot state", reads.isNotEmpty())
    }

    @Test fun pinchZoomsAroundTheFingersAndStaysInBounds() {
        val viewport = Size(1000f, 1000f); val page = Size(750f, 1000f)
        val zoom = PageZoom()
        val target = Offset(700f, 300f)
        val before = zoom.toPage(target, viewport, page)
        zoom.pinch(target, 2f, Offset.Zero, viewport, page)
        assertEquals(2f, zoom.scale, 0.001f)
        // The point under the fingers is still under the fingers.
        val after = zoom.toPage(target, viewport, page)
        assertEquals(before.x, after.x, 0.001f); assertEquals(before.y, after.y, 0.001f)

        zoom.pan(Offset(-10_000f, 10_000f), viewport, page)
        assertEquals(-(750f * 2 - 1000f) / 2, zoom.offset.x, 0.001f)
        assertEquals((1000f * 2 - 1000f) / 2, zoom.offset.y, 0.001f)

        zoom.pinch(target, 0.01f, Offset.Zero, viewport, page)
        assertEquals(1f, zoom.scale, 0.001f); assertEquals(0f, zoom.offset.x, 0.001f); assertEquals(0f, zoom.offset.y, 0.001f)
        assertFalse(zoom.zoomed)
    }

    @Test fun unzoomedPageMapsScreenToPageCoordinates() {
        val zoom = PageZoom()
        val p = zoom.toPage(Offset(125f, 0f), Size(1000f, 1000f), Size(750f, 1000f))
        assertEquals(0f, p.x, 0.001f); assertEquals(0f, p.y, 0.001f)
    }
}
