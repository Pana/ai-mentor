package cn.littlebear.tutor

import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class FirstVersionTest {
    private val demo = demoFamily()
    private val child = demo.children.first()
    private val other = demo.children.last()
    private val task = Homework(childID = child.id, subject = Subject.MATH, title = "课本作业", draft = "42")
    private val family = demo.addTask(task)

    @Test fun changingTaskSubjectDoesNotRelabelEarlierEvidence() {
        val reviewed = family.submit(child.id, task.id, "42").parentReview(child.id, task.id, false, "需要订正", "计算", false)
        val edited = reviewed.editTask(child.id, task.id, Subject.CHINESE, "语文作业", "阅读")
        assertEquals(Subject.MATH, edited.knowledge(child.id).single().subject)
        assertEquals(Subject.MATH, edited.reviews(child.id).single().subject)
    }

    @Test fun identicalConceptNamesAcrossSubjectsDoNotMergeMastery() {
        val second = task.copy(id = newID(), subject = Subject.CHINESE)
        val next = family.addTask(second)
            .submit(child.id, task.id, "42").parentReview(child.id, task.id, true, "独立解释", "提取信息", true)
            .submit(child.id, second.id, "春天").parentReview(child.id, second.id, true, "独立解释", "提取信息", true)
        assertEquals(2, next.knowledge(child.id).size)
        assertTrue(next.knowledge(child.id).all { it.state == "学习中" })
    }

    @Test fun realHomeworkEvidenceRequiresParentObservationAndAnExplanation() {
        val submitted = family.submit(child.id, task.id, "42")
        assertThrows(IllegalArgumentException::class.java) { submitted.parentReview(child.id, task.id, true, "", "加法", true) }
        val reviewed = submitted.parentReview(child.id, task.id, true, "孩子独立解释了个位进位", "加法", true)
        assertTrue(reviewed.evidence.single().independent)
        assertEquals("parent", reviewed.evidence.single().origin)
        assertEquals("学习中", reviewed.knowledge(child.id).single().state)
        assertEquals(1, reviewed.reviews(child.id).size)
    }

    @Test fun modelGeneratedErrorsCannotDowngradeVerifiedKnowledge() {
        val example = demo.tasksFor(child.id).first { it.subject == Subject.MATH }
        val generated = task.copy(generated = Exercises.all.first().copy(id = "model", verified = false))
        val next = demo.check(child.id, example.id, "42").addTask(generated).check(child.id, generated.id, "wrong")
        assertEquals("学习中", next.knowledge(child.id).single().state)
        assertTrue(next.reviews(child.id).single().dueAt > next.evidence.last().time)
    }

    @Test fun oldLocalDataLoadsWithoutNewFields() {
        val restored = Json.decodeFromString<Family>("""{"schemaVersion":1,"children":[{"id":"old","name":"小明","grade":2}],"tasks":[],"evidence":[]}""")
        assertTrue(restored.sessions.isEmpty())
        assertEquals(20, restored.children.single().studyMinutes)
    }

    @Test fun staleModelReplyCannotOverwriteAnEditedTask() {
        val edited = family.editTask(child.id, task.id, Subject.MATH, "新题", "6+7")
        assertThrows(IllegalArgumentException::class.java) { edited.applyTutor(child.id, task.id, 0, TutorTurn("求助", "旧题提示")) }
        assertTrue(edited.task(child.id, task.id).conversation.isEmpty())
    }

    @Test fun changingAnswerInvalidatesPreviousCheckAndPendingReply() {
        val checked = family.applyTutor(child.id, task.id, 0, TutorTurn("检查", "正确", "check", "CORRECT"))
        val next = checked.saveDraft(child.id, task.id, "43")
        assertEquals("UNKNOWN", next.task(child.id, task.id).aiAssessment)
        assertThrows(IllegalArgumentException::class.java) { next.applyTutor(child.id, task.id, 0, TutorTurn("检查", "正确", "check", "CORRECT")) }
    }

    @Test fun modelFeedbackDoesNotCompleteHomeworkOrInventMastery() {
        val next = family.applyTutor(child.id, task.id, 0, TutorTurn("检查", "看起来正确", "check", "CORRECT"))
        assertEquals(WorkStatus.READY, next.task(child.id, task.id).status)
        assertTrue(next.evidence.isEmpty())
        assertEquals("CORRECT", next.task(child.id, task.id).aiAssessment)
    }

    @Test fun unknownModelAssessmentIsNotAFailedAnswer() {
        val next = family.applyTutor(child.id, task.id, 0, TutorTurn("检查", "需要补图", "check", "UNKNOWN"))
        assertEquals(0, next.task(child.id, task.id).failures)
        assertTrue(next.evidence.isEmpty())
    }

    @Test fun parentReviewRequiresSubmissionAndKeepsFeedback() {
        assertThrows(IllegalArgumentException::class.java) { family.parentReview(child.id, task.id, true, "") }
        val next = family.submit(child.id, task.id, "42").parentReview(child.id, task.id, false, "补写计算步骤")
        assertEquals(WorkStatus.CORRECTION, next.task(child.id, task.id).status)
        assertEquals("补写计算步骤", next.task(child.id, task.id).reviewNote)
        assertEquals(WorkStatus.DONE, next.submit(child.id, task.id, "24+18=42").parentReview(child.id, task.id, true, "已核对").task(child.id, task.id).status)
    }

    @Test fun studyHeartbeatIsIdempotentAndChildScoped() {
        val session = StudySession("session", child.id, task.id, 60, 1000)
        val next = family.recordStudy(session).recordStudy(session).recordStudy(session.copy(seconds = 30))
        assertEquals(60L, next.sessions.single().seconds)
        assertThrows(IllegalStateException::class.java) { next.recordStudy(session.copy(childID = other.id)) }
        assertTrue(next.deleteChild(child.id).sessions.isEmpty())
    }

    @Test fun deletingTaskCleansOnlyItsLearningRecords() {
        val next = family.recordStudy(StudySession("s", child.id, task.id, 10, 1000)).deleteTask(child.id, task.id)
        assertTrue(next.sessions.isEmpty())
        assertEquals(demo.tasksFor(other.id), next.tasksFor(other.id))
        assertThrows(IllegalStateException::class.java) { family.deleteTask(other.id, task.id) }
    }

    @Test fun generatedModelAnswerDoesNotCountAsVerifiedIndependentMastery() {
        val exercise = Exercises.all.first().copy(id = "model-question", verified = false)
        val work = task.copy(generated = exercise, practice = true)
        val next = demo.addTask(work).check(child.id, work.id, "42")
        assertFalse(next.evidence.single().independent)
        assertFalse(next.evidence.single().verifiedExercise)
        assertEquals("待核验", next.knowledge(child.id).single().state)
        assertTrue(next.reviews(child.id).isEmpty())
    }

    @Test fun decimalMistakeIsNotSilentlyAcceptedAsInteger() {
        assertFalse(Exercises.all.first().accepts("4.2"))
        assertTrue(Exercises.all.first().accepts("42。"))
    }

    @Test fun studySettingsAreValidated() {
        assertThrows(IllegalArgumentException::class.java) { demo.editChild(child.copy(studyMinutes = 0)) }
        assertEquals("人教版三年级上册", demo.editChild(child.copy(textbook = "人教版三年级上册")).children.first().textbook)
    }

    @Test fun serviceConfigurationRequiresHttpsExceptDebugLoopback() {
        val settings = ServiceSettings("https://tutor.example", "x".repeat(32), true)
        assertEquals(settings, settings.validated(false))
        assertThrows(IllegalArgumentException::class.java) { settings.copy(url = "http://tutor.example").validated(true) }
        assertThrows(IllegalArgumentException::class.java) { settings.copy(url = "http://127.0.0.1:8787").validated(false) }
        assertEquals("http://127.0.0.1:8787", settings.copy(url = "http://127.0.0.1:8787").validated(true).url)
    }
}
