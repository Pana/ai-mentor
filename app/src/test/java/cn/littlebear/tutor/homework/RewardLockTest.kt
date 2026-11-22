package cn.littlebear.tutor.homework

import cn.littlebear.tutor.homework.LockPolicy.Clock
import cn.littlebear.tutor.homework.LockPolicy.Grant
import cn.littlebear.tutor.homework.LockPolicy.Verdict
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RewardLockTest {
    private val own = "cn.littlebear.tutor"
    private val game = "com.example.game"
    private val locked = setOf(game)
    private val t0 = Clock(elapsed = 1_000_000, boot = 7)
    private fun later(ms: Long) = t0.copy(elapsed = t0.elapsed + ms)

    private fun verdict(pkg: String, session: Grant? = null, parent: Grant? = null, now: Clock = t0, apps: Set<String> = locked, mentionsUs: Boolean = false) =
        LockPolicy.verdict(pkg, own, apps, session, parent, now) { mentionsUs }

    @Test fun lockedAppsOpenOnlyDuringASession() {
        assertEquals(Verdict.LOCKED_APP, verdict(game))
        val session = Grant.start(t0, 10 * 60_000L)
        assertEquals(Verdict.ALLOW, verdict(game, session, now = later(9 * 60_000L)))
        assertEquals(Verdict.LOCKED_APP, verdict(game, session, now = later(10 * 60_000L)))
        assertEquals(Verdict.ALLOW, verdict("com.example.reader"))
        assertEquals(Verdict.ALLOW, verdict(own))
    }

    @Test fun nothingIsLockedUntilTheParentPicksApps() {
        assertEquals(Verdict.ALLOW, verdict(game, apps = emptySet()))
        assertEquals(Verdict.ALLOW, verdict("com.android.settings", apps = emptySet(), mentionsUs = true))
    }

    @Test fun aRestartEndsTheSession() {
        val session = Grant.start(t0, 10 * 60_000L)
        // After a reboot the elapsed clock starts again from zero; the old grant must not count.
        val rebooted = Clock(elapsed = 5_000, boot = 8)
        assertEquals(0, session.remaining(rebooted))
        assertEquals(Verdict.LOCKED_APP, verdict(game, session, now = rebooted))
    }

    @Test fun aSecondSessionAddsOnToTheFirst() {
        val first = Grant.start(t0, 10 * 60_000L)
        val now = later(4 * 60_000L)
        assertEquals(11 * 60_000L, Grant.extend(first, now, 5 * 60_000L).remaining(now))
        assertEquals(5 * 60_000L, Grant.extend(null, now, 5 * 60_000L).remaining(now))
        assertEquals(5 * 60_000L, Grant.extend(first, later(20 * 60_000L), 5 * 60_000L).remaining(later(20 * 60_000L)))
    }

    @Test fun settingsThatMentionTheAppAreGuarded() {
        assertEquals(Verdict.GUARDED_SETTINGS, verdict("com.android.settings", mentionsUs = true))
        assertEquals(Verdict.ALLOW, verdict("com.android.settings", mentionsUs = false))
        assertEquals(Verdict.GUARDED_SETTINGS, verdict("com.miui.securitycenter", mentionsUs = true))
        // Ordinary apps that happen to show the name (a chat about it) are not guarded.
        assertEquals(Verdict.ALLOW, verdict("com.tencent.mm", mentionsUs = true))
        // Guarded even during reward time: a session is for cartoons and games, not for turning the lock off.
        assertEquals(Verdict.GUARDED_SETTINGS, verdict("com.android.settings", Grant.start(t0, 60_000), mentionsUs = true))
    }

    @Test fun aVerifiedParentIsNotLocked() {
        val parent = Grant.start(t0, 10 * 60_000L)
        assertEquals(Verdict.ALLOW, verdict(game, parent = parent))
        assertEquals(Verdict.ALLOW, verdict("com.android.settings", parent = parent, mentionsUs = true))
        assertEquals(Verdict.LOCKED_APP, verdict(game, parent = parent, now = later(11 * 60_000L)))
    }

    @Test fun windowTextIsReadOnlyForGuardedScreens() {
        var asked = 0
        LockPolicy.verdict(game, own, locked, null, null, t0) { asked++; true }
        LockPolicy.verdict("com.android.settings", own, locked, null, null, t0) { asked++; false }
        assertEquals(1, asked)
        assertTrue(Grant.start(t0, 1).active(t0))
        assertFalse(Grant.start(t0, 0).active(t0))
    }
}
