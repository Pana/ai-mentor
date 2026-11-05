package cn.littlebear.tutor

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class FamilyTest {
    private val demo = demoFamily()
    private val child = demo.children.first()
    private val other = demo.children.last()
    private val math = demo.tasksFor(child.id).first { it.subject == Subject.MATH }

    @Test fun learningEvidenceBelongsOnlyToTheActiveChild() {
        val next = demo.check(child.id, math.id, "42")
        assertEquals(1, next.evidenceFor(child.id).size)
        assertTrue(next.evidenceFor(other.id).isEmpty())
        assertEquals(demo.tasksFor(other.id), next.tasksFor(other.id))
    }

    @Test fun cannotWriteToAnotherChildsTask() {
        assertThrows(IllegalStateException::class.java) { demo.check(other.id, math.id, "42") }
        assertThrows(IllegalStateException::class.java) { demo.hint(other.id, math.id) }
    }

    @Test fun correctAfterHintIsNotIndependentMastery() {
        val next = demo.hint(child.id, math.id).check(child.id, math.id, "42")
        assertFalse(next.evidence.last().independent)
        assertEquals("学习中", next.knowledge(child.id).single().state)
        assertEquals(WorkStatus.DONE, next.task(child.id, math.id).status)
    }

    @Test fun correctionKeepsTheEarlierErrorEvidence() {
        val wrong = demo.check(child.id, math.id, "32")
        assertEquals(WorkStatus.CORRECTION, wrong.task(child.id, math.id).status)
        val next = wrong.check(child.id, math.id, "42")
        assertEquals(2, next.evidence.size)
        assertFalse(next.evidence.last().independent)
        assertEquals(1, next.evidence.last().priorFailures)
    }

    @Test fun cannotFarmEvidenceBySubmittingCompletedTaskAgain() {
        val next = demo.check(child.id, math.id, "42")
        assertThrows(IllegalArgumentException::class.java) { next.check(child.id, math.id, "42") }
    }

    @Test fun twoDistinctIndependentProblemsGiveOnlyInitialMastery() {
        val task = Homework(childID = child.id, subject = Subject.MATH, title = "新题", exerciseID = "addition-53")
        val next = demo.check(child.id, math.id, "42").addTask(task).check(child.id, task.id, "53")
        assertEquals("初步掌握", next.knowledge(child.id).single().state)
    }

    @Test fun sameExerciseInDifferentTasksIsNotTwoDistinctPiecesOfMastery() {
        val repeated = math.copy(id = newID())
        val next = demo.check(child.id, math.id, "42").addTask(repeated).check(child.id, repeated.id, "42")
        assertEquals("学习中", next.knowledge(child.id).single().state)
    }

    @Test fun realHomeworkCannotBeGradedUsingDemoAnswers() {
        val actual = Homework(childID = child.id, subject = Subject.MATH, title = "课本第 20 页")
        val next = demo.addTask(actual)
        assertThrows(IllegalStateException::class.java) { next.check(child.id, actual.id, "42") }
        val marked = next.update(child.id, actual.id) { it.copy(status = WorkStatus.DONE) }
        assertTrue(marked.evidence.isEmpty())
    }

    @Test fun deletingOneChildPreservesTheOtherAndDoesNotReseedDemo() {
        val next = demo.check(child.id, math.id, "42").deleteChild(child.id)
        assertEquals(listOf(other), next.children)
        assertTrue(next.evidence.isEmpty())
        assertTrue(next.tasks.all { it.childID == other.id })
        assertTrue(next.deleteChild(other.id).children.isEmpty())
    }

    @Test fun localSerializationPreservesDraftsCorrectionsAndOwnership() {
        val next = demo.hint(child.id, math.id).check(child.id, math.id, "32")
        val encoded = Json.encodeToString(next)
        assertEquals(next, Json.decodeFromString<Family>(encoded))
        assertEquals("32", Json.decodeFromString<Family>(encoded).task(child.id, math.id).draft)
    }

    @Test fun blankAnswerDoesNotProduceFailureEvidence() {
        assertThrows(IllegalArgumentException::class.java) { demo.check(child.id, math.id, "   ") }
        assertTrue(demo.evidence.isEmpty())
    }

    @Test fun hintsAreBoundedAndEmptyProfilesAreRejected() {
        var next = demo
        repeat(8) { next = next.hint(child.id, math.id) }
        assertEquals(3, next.task(child.id, math.id).hints)
        assertThrows(IllegalArgumentException::class.java) { demo.addChild("  ", 2) }
        assertThrows(IllegalArgumentException::class.java) { demo.addChild("小雨", 6) }
    }
}
