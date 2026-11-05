package cn.littlebear.tutor

import java.util.UUID
import kotlinx.serialization.Serializable

@Serializable enum class Subject(val label: String) { MATH("数学"), CHINESE("语文"), ENGLISH("英语") }
@Serializable enum class WorkStatus(val label: String) {
    READY("待开始"), ACTIVE("进行中"), REVIEW("待检查"), CORRECTION("待订正"), DONE("已完成")
}
@Serializable data class Child(val id: String = newID(), val name: String, val grade: Int,
    val textbook: String = "教材版本待确认", val studyMinutes: Int = 20)
@Serializable data class Homework(
    val id: String = newID(), val childID: String, val subject: Subject, val title: String,
    val instructions: String = "", val status: WorkStatus = WorkStatus.READY,
    val exerciseID: String? = null, val photo: String? = null,
    val hints: Int = 0, val failures: Int = 0, val draft: String = "", val practice: Boolean = false,
    val generated: Exercise? = null, val revision: Int = 0,
    val conversation: List<TutorTurn> = emptyList(), val reviewNote: String = "",
    val aiAssessment: String = "UNKNOWN", val createdAt: Long = System.currentTimeMillis(),
)
@Serializable data class TutorTurn(val question: String, val reply: String, val mode: String = "help",
    val assessment: String = "UNKNOWN", val time: Long = System.currentTimeMillis())
@Serializable data class StudySession(val id: String, val childID: String, val taskID: String,
    val seconds: Long, val startedAt: Long)
@Serializable data class Evidence(
    val id: String = newID(), val childID: String, val taskID: String,
    val exerciseID: String, val concept: String, val answer: String, val correct: Boolean,
    val hints: Int, val priorFailures: Int, val time: Long = System.currentTimeMillis(),
    val verifiedExercise: Boolean = true,
    val independentConfirmed: Boolean = true, val origin: String = "local", val note: String = "",
    val subject: Subject? = null,
) { val independent: Boolean get() = verifiedExercise && independentConfirmed && correct && hints == 0 && priorFailures == 0 }
@Serializable data class Family(
    val schemaVersion: Int = 1, val demo: Boolean = false,
    val children: List<Child> = emptyList(), val tasks: List<Homework> = emptyList(),
    val evidence: List<Evidence> = emptyList(),
    val sessions: List<StudySession> = emptyList(),
) {
    fun tasksFor(childID: String) = tasks.filter { it.childID == childID }
    fun evidenceFor(childID: String) = evidence.filter { it.childID == childID }
    fun addChild(name: String, grade: Int): Family {
        require(name.trim().isNotEmpty() && name.trim().length <= 20) { "请填写 1–20 字的昵称" }
        require(grade in 2..3) { "首版支持二、三年级" }
        return copy(children = children + Child(name = name.trim(), grade = grade))
    }
    fun editChild(child: Child): Family {
        require(children.any { it.id == child.id }) { "孩子档案不存在" }
        require(child.name.trim().length in 1..20 && child.grade in 2..3)
        require(child.textbook.length <= 300 && child.studyMinutes in 5..60)
        return copy(children = children.map { if (it.id == child.id) child.copy(name = child.name.trim(),
            textbook = child.textbook.trim().ifBlank { "教材版本待确认" }) else it })
    }
    fun addTask(task: Homework): Family {
        require(children.any { it.id == task.childID }) { "孩子档案不存在" }
        require(task.title.isNotBlank()) { "请填写作业名称" }
        require(tasks.none { it.id == task.id })
        return copy(tasks = tasks + task)
    }
    fun task(childID: String, taskID: String): Homework = tasks.singleOrNull { it.id == taskID && it.childID == childID }
        ?: error("找不到这个孩子的作业")
    fun update(childID: String, taskID: String, change: (Homework) -> Homework): Family {
        val original = task(childID, taskID)
        val revised = change(original)
        require(revised.id == original.id && revised.childID == original.childID)
        return copy(tasks = tasks.map { if (it.id == taskID) revised else it })
    }
    fun editTask(childID: String, taskID: String, subject: Subject, title: String, instructions: String): Family =
        update(childID, taskID) {
            require(title.trim().length in 1..100 && instructions.length <= 2000)
            require(it.exerciseID == null && it.generated == null) { "练习题不支持修改题意" }
            require(it.status != WorkStatus.DONE) { "已完成作业不能修改题意" }
            it.copy(subject = subject, title = title.trim(), instructions = instructions.trim(), revision = it.revision + 1,
                aiAssessment = "UNKNOWN", status = WorkStatus.READY, reviewNote = "", conversation = emptyList())
        }
    fun deleteTask(childID: String, taskID: String): Family {
        task(childID, taskID)
        return copy(tasks = tasks.filterNot { it.id == taskID }, evidence = evidence.filterNot { it.taskID == taskID },
            sessions = sessions.filterNot { it.taskID == taskID })
    }
    fun submit(childID: String, taskID: String, answer: String) = update(childID, taskID) {
        require(it.status !in listOf(WorkStatus.DONE, WorkStatus.REVIEW))
        it.copy(status = WorkStatus.REVIEW, draft = answer.take(2000), revision = it.revision + 1)
    }
    fun parentReview(childID: String, taskID: String, passed: Boolean, note: String,
        concept: String = "", independent: Boolean = false): Family {
        val work = task(childID, taskID)
        require(work.status == WorkStatus.REVIEW) { "请先让孩子提交检查" }
        require(note.length <= 1000)
        require(concept.length <= 100)
        require(concept.isBlank() || note.isNotBlank()) { "记录知识点时，请填写具体检查依据。" }
        val next = update(childID, taskID) {
            it.copy(status = if (passed) WorkStatus.DONE else WorkStatus.CORRECTION, reviewNote = note.trim(),
                revision = it.revision + 1, failures = it.failures + if (passed) 0 else 1)
        }
        if (concept.isBlank()) return next
        val record = Evidence(childID = childID, taskID = taskID, exerciseID = taskID, concept = concept.trim(),
            answer = work.draft.ifBlank { "纸面作业，由家长检查" }, correct = passed, hints = work.hints,
            priorFailures = work.failures, independentConfirmed = independent, origin = "parent", note = note.trim(), subject = work.subject)
        return next.copy(evidence = next.evidence + record)
    }
    fun saveDraft(childID: String, taskID: String, answer: String) = update(childID, taskID) {
        require(it.status !in listOf(WorkStatus.DONE, WorkStatus.REVIEW))
        if (it.draft == answer) it else it.copy(draft = answer.take(2000), revision = it.revision + 1, aiAssessment = "UNKNOWN")
    }
    fun recordStudy(session: StudySession): Family {
        task(session.childID, session.taskID)
        require(session.seconds in 0..86400)
        val previous = sessions.find { it.id == session.id }
        require(previous == null || (previous.childID == session.childID && previous.taskID == session.taskID))
        if (previous != null && previous.seconds >= session.seconds) return this
        return copy(sessions = sessions.filterNot { it.id == session.id } + session)
    }
    fun applyTutor(childID: String, taskID: String, revision: Int, turn: TutorTurn): Family = update(childID, taskID) {
        require(it.revision == revision) { "作业已改变，保留当前内容，请重新求助。" }
        require(it.status != WorkStatus.DONE)
        require(turn.assessment in listOf("UNKNOWN", "CORRECT", "INCORRECT"))
        // Model feedback is provisional: it never creates mastery evidence or marks homework done.
        it.copy(conversation = (it.conversation + turn).takeLast(60),
            aiAssessment = if (turn.mode == "check") turn.assessment else it.aiAssessment,
            hints = if (turn.mode == "help") it.hints + 1 else it.hints)
    }
    fun hint(childID: String, taskID: String) = update(childID, taskID) {
        require(it.status != WorkStatus.DONE)
        it.copy(hints = (it.hints + 1).coerceAtMost(3), status = WorkStatus.ACTIVE)
    }
    fun check(childID: String, taskID: String, answer: String): Family {
        val task = task(childID, taskID)
        require(task.status != WorkStatus.DONE) { "这项任务已经完成" }
        require(answer.isNotBlank()) { "先写下你的答案吧" }
        val exercise = task.exercise() ?: error("这项作业需要家长检查")
        val correct = exercise.accepts(answer)
        val record = Evidence(childID = childID, taskID = taskID, exerciseID = exercise.id,
            concept = exercise.concept, answer = answer.trim(), correct = correct, hints = task.hints, priorFailures = task.failures,
            verifiedExercise = exercise.verified, subject = task.subject)
        return update(childID, taskID) {
            it.copy(status = if (correct) WorkStatus.DONE else WorkStatus.CORRECTION,
                draft = answer, failures = it.failures + if (correct) 0 else 1)
        }.copy(evidence = evidence + record)
    }
    fun deleteChild(childID: String) = copy(children = children.filterNot { it.id == childID },
        tasks = tasks.filterNot { it.childID == childID }, evidence = evidence.filterNot { it.childID == childID },
        sessions = sessions.filterNot { it.childID == childID })
    fun knowledge(childID: String): List<Knowledge> = evidenceFor(childID).groupBy { record ->
        (record.subject ?: Exercises.byID(record.exerciseID)?.subject ?: tasks.firstOrNull { it.id == record.taskID }?.subject) to record.concept
    }.map { (key, records) ->
        val (subject, concept) = key
        val verified = records.filter { it.verifiedExercise }
        val independentCount = verified.filter { it.independent }.distinctBy { it.exerciseID }.size
        val state = when {
            verified.isEmpty() -> "待核验"
            !verified.last().correct -> "需要再练练"
            independentCount >= 2 -> "初步掌握"
            else -> "学习中"
        }
        Knowledge(concept, state, records, subject)
    }
}
data class Knowledge(val concept: String, val state: String, val evidence: List<Evidence>, val subject: Subject? = null)
@Serializable data class Exercise(val id: String, val subject: Subject, val concept: String, val prompt: String,
    val answer: String, val hints: List<String>, val explanation: String, val verified: Boolean = true) {
    fun accepts(input: String) = input.trim().lowercase().removeSuffix("。").removeSuffix(".") == answer.trim().lowercase()
}
fun Homework.exercise() = generated ?: Exercises.byID(exerciseID)
data class ReviewDue(val concept: String, val subject: Subject, val dueAt: Long, val reason: String)
fun Family.reviews(childID: String): List<ReviewDue> = knowledge(childID).mapNotNull { item ->
    val last = item.evidence.filter { it.verifiedExercise }.maxByOrNull { it.time } ?: return@mapNotNull null
    val work = tasksFor(childID).find { it.id == last.taskID } ?: return@mapNotNull null
    val days = if (!last.correct) 0 else if (item.state == "初步掌握") 3 else 1
    ReviewDue(item.concept, item.subject ?: work.subject, last.time + days * 86_400_000L,
        if (!last.correct) "上次需要订正" else if (last.independent) "隔一段时间再独立试试" else "上次获得过帮助，再试一道不同的题")
}.sortedBy { it.dueAt }
object Exercises {
    val all = listOf(
        Exercise("addition-42", Subject.MATH, "两位数进位加法", "小熊有 24 颗橡果，又找到 18 颗。现在一共有多少颗？", "42",
            listOf("先想想：橡果变多了，还是变少了？应该用什么方法？", "把 18 分成 10 和 8。先算 24 + 10，再加 8。", "24 + 10 = 34，34 + 8 = 42。也可以看看个位满十后怎样进位。"), "24 + 18 = 42。个位 4 + 8 = 12，满十向十位进 1。"),
        Exercise("addition-53", Subject.MATH, "两位数进位加法", "图书角原来有 36 本书，又放入 17 本。现在一共有多少本？", "53",
            listOf("书的总数增加了。你会怎样列式？", "先算 36 + 10，再加 7。", "36 + 10 = 46，46 + 7 = 53。"), "36 + 17 = 53。个位 6 + 7 = 13，需要向十位进 1。"),
        Exercise("reading-spring", Subject.CHINESE, "从短文提取信息", "读一读：春天来了，小草绿了，燕子飞回来了。\n短文描写的是哪个季节？请填写两个字。", "春天",
            listOf("先找一找，哪句话告诉了我们时间？", "看看短文的开头两个字。", "短文开头写着“春天来了”，所以答案是“春天”。"), "可以从短文中找到直接说明季节的词语“春天”。"),
        Exercise("reading-autumn", Subject.CHINESE, "从短文提取信息", "读一读：秋天到了，树叶黄了，果园里的苹果成熟了。\n短文描写的是哪个季节？请填写两个字。", "秋天",
            listOf("哪句话说明了时间？", "先读第一句，再找季节名称。", "“秋天到了”告诉我们答案是“秋天”。"), "答案是秋天，依据是短文第一句。"),
        Exercise("english-apple", Subject.ENGLISH, "常见水果单词", "苹果的英文怎么写？填写一个单词。", "apple",
            listOf("这个单词以字母 a 开头。", "这个单词有五个字母，中间有两个 p。", "苹果是 apple。读一遍，再试着自己拼写。"), "apple 表示苹果。可以这样使用：This is an apple."),
        Exercise("english-pear", Subject.ENGLISH, "常见水果单词", "梨的英文怎么写？填写一个单词。", "pear",
            listOf("它以字母 p 开头。", "这个单词有四个字母，结尾是 ar。", "梨是 pear。读一遍，再试着自己拼写。"), "pear 表示梨。可以这样使用：This is a pear."),
    )
    fun byID(id: String?) = all.find { it.id == id }
    fun initial(subject: Subject) = all.first { it.subject == subject }
    fun next(subject: Subject, completedIDs: Set<String>) = all.firstOrNull { it.subject == subject && it.id !in completedIDs }
    fun practice(subject: Subject, completedIDs: Set<String>): Exercise {
        next(subject, completedIDs)?.let { return it }
        if (subject != Subject.MATH) return all.filter { it.subject == subject }.random()
        val a = kotlin.random.Random.nextInt(11, 50)
        val b = kotlin.random.Random.nextInt(11, 50)
        return Exercise("addition-$a-$b", Subject.MATH, "两位数加法", "算一算：$a + $b = ？请填写一个整数。", "${a + b}",
            listOf("先把第二个数分成整十数与个位数。", "先算 $a + ${b / 10 * 10}，再加 ${b % 10}。", "$a + $b = ${a + b}。检查个位是否需要进位。"),
            "把 $b 分成 ${b / 10 * 10} 和 ${b % 10}，分两步加，结果是 ${a + b}。")
    }
}
fun newID(): String = UUID.randomUUID().toString()
fun demoFamily(): Family {
    val children = listOf(Child(id = "demo-lin", name = "林林", grade = 2), Child(id = "demo-qi", name = "琪琪", grade = 3))
    return Family(demo = true, children = children, tasks = children.flatMap { child ->
        Subject.entries.map { subject ->
            Homework(childID = child.id, subject = subject, title = when(subject) {
                Subject.MATH -> "小熊的橡果问题"
                Subject.CHINESE -> "读一读，找一找"
                Subject.ENGLISH -> "水果单词小练习"
            }, instructions = "示例内容，未对应学校教材", exerciseID = Exercises.initial(subject).id)
        }
    })
}
