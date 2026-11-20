package dev.nicholas.eclipse

import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId

class RemindersTest {
    @Test
    fun aLocalReminderWithAnExplicitNullAccountStillMatchesTheLocalAccount() {
        val json = """[{"key":"r","at":1000,"title":"Train","body":"Soon","account":null}]"""
        assertEquals("", ReminderPlanner.plan(json, 0).single().account)
    }

    @Test
    fun shouldRestoreMatchesBootUpdateTimezoneAndTimeSet() {
        assertTrue(ReminderPlanner.shouldRestore(Intent.ACTION_BOOT_COMPLETED))
        assertTrue(ReminderPlanner.shouldRestore(Intent.ACTION_MY_PACKAGE_REPLACED))
        assertTrue(ReminderPlanner.shouldRestore(Intent.ACTION_TIMEZONE_CHANGED))
        assertTrue(ReminderPlanner.shouldRestore(Intent.ACTION_TIME_CHANGED))
        assertTrue(ReminderPlanner.shouldRestore("android.intent.action.TIME_SET"))

        assertFalse(ReminderPlanner.shouldRestore(Intent.ACTION_VIEW))
        assertFalse(ReminderPlanner.shouldRestore(null))
    }

    @Test
    fun planFiltersPastSortsByTriggerPreservesUidAndStableId() {
        val now = Instant.parse("2026-11-19T00:00:00Z").toEpochMilli()
        val futureEarly = now + 60_000L
        val futureLate = now + 120_000L
        val past = now - 60_000L
        val json = """
            [
              {"key":"k-late","uid":"u-late","at":$futureLate,"title":"Late","body":"Later"},
              {"key":"k-past","uid":"u-past","at":$past,"title":"Past","body":"Gone"},
              {"key":"k-early","uid":"u-early","at":$futureEarly,"title":"Early","body":"Soon"}
            ]
        """.trimIndent()

        val planned = ReminderPlanner.plan(json, now)
        assertEquals(2, planned.size)
        assertEquals("Early", planned[0].title)
        assertEquals("u-early", planned[0].uid)
        assertEquals("k-early".hashCode(), planned[0].id)
        assertEquals(futureEarly, planned[0].triggerAt)
        assertEquals("Late", planned[1].title)
        assertEquals("u-late", planned[1].uid)
        assertEquals("k-late".hashCode(), planned[1].id)
    }

    @Test
    fun planRecalculatesWallClockTriggerAcrossTimeZones() {
        val adelaide = ZoneId.of("Australia/Adelaide")
        val tokyo = ZoneId.of("Asia/Tokyo")
        val originalAt = LocalDateTime.of(2026, 11, 20, 9, 0)
            .atZone(adelaide)
            .toInstant()
            .toEpochMilli()
        val now = Instant.parse("2026-11-19T12:00:00Z").toEpochMilli()
        val json = """
            [
              {
                "key":"k1",
                "uid":"task-1",
                "at":$originalAt,
                "year":2026,
                "month":11,
                "day":20,
                "hour":9,
                "minute":0,
                "title":"Standup",
                "body":"Now, at 9:00 am"
              }
            ]
        """.trimIndent()

        val inTokyo = ReminderPlanner.plan(json, now, tokyo)
        val expectedTokyo = LocalDateTime.of(2026, 11, 20, 9, 0)
            .atZone(tokyo)
            .toInstant()
            .toEpochMilli()
        assertEquals(1, inTokyo.size)
        assertEquals(expectedTokyo, inTokyo.single().triggerAt)
        assertTrue(expectedTokyo > originalAt)
    }

    @Test
    fun planHonorsExactSnoozeAndSecondsAndCapsAtMaxAlarms() {
        val adelaide = ZoneId.of("Australia/Adelaide")
        val tokyo = ZoneId.of("Asia/Tokyo")
        val snoozedAt = LocalDateTime.of(2026, 11, 20, 9, 10, 42)
            .atZone(adelaide)
            .toInstant()
            .toEpochMilli()
        val now = snoozedAt - 60_000L
        val exactJson = """
            [
              {
                "key":"k-exact",
                "uid":"u1",
                "at":$snoozedAt,
                "year":2026,
                "month":11,
                "day":20,
                "hour":9,
                "minute":10,
                "second":42,
                "exact":true,
                "title":"Standup",
                "body":"Snoozed"
              },
              {
                "key":"k-wall",
                "uid":"u2",
                "at":$snoozedAt,
                "year":2026,
                "month":11,
                "day":20,
                "hour":9,
                "minute":10,
                "second":42,
                "exact":false,
                "title":"Wall",
                "body":"Wall clock"
              }
            ]
        """.trimIndent()
        val planned = ReminderPlanner.plan(exactJson, now, tokyo)
        assertEquals(2, planned.size)
        assertEquals("Standup", planned[0].title)
        assertEquals(snoozedAt, planned[0].triggerAt)
        assertEquals("Wall", planned[1].title)
        assertEquals(
            LocalDateTime.of(2026, 11, 20, 9, 10, 42).atZone(tokyo).toInstant().toEpochMilli(),
            planned[1].triggerAt,
        )

        val entries = (1..500).joinToString(",") { i ->
            """{"key":"k-$i","uid":"u-$i","at":${10_000L + (501 - i)},"title":"T$i","body":"B"}"""
        }
        val capped = ReminderPlanner.plan("[$entries]", 0)
        assertEquals(ReminderPlanner.MAX_ALARMS, capped.size)
        assertEquals(10_001L, capped.first().triggerAt)
        assertEquals(10_000L + ReminderPlanner.MAX_ALARMS, capped.last().triggerAt)
    }
}
