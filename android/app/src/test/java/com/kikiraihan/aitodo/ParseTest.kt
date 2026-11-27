package com.kikiraihan.aitodo

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ParseTest {
    @Test fun inboxClip() {
        val box = Parse.inbox(JSONObject("""{"last":12,"items":[{"id":12,"kind":"clip","title":"Kiriman dari MacBook","body":"ssh",
            "url":"/kiriman","tag":"clip-3","clipId":3,"text":"ssh root@x\n","createdAt":"2026-11-27T10:00:00Z"}],"rev":5}"""))
        assertEquals(12, box.last)
        val c = box.items.single()
        assertEquals("clip", c.kind)
        assertEquals(3, c.clipId)
        assertEquals("ssh root@x\n", c.text)
        assertFalse(c.textTruncated)
        assertEquals(0, c.todoId)
    }

    @Test fun inboxTruncatedAndReminder() {
        val box = Parse.inbox(JSONObject("""{"last":3,"items":[{"id":3,"kind":"reminder","title":"Telepon","body":"","tag":"reminder-1",
            "reminderId":1,"todoId":9,"textTruncated":true}]}"""))
        val r = box.items.single()
        assertTrue(r.textTruncated)
        assertEquals("", r.text)
        assertEquals(9, r.todoId)
        assertEquals(1, r.reminderId)
    }

    @Test fun reminderNullTodo() {
        val r = Parse.reminder(JSONObject("""{"id":1,"todoId":null,"title":"x","message":"","schedule":{"kind":"daily","time":"08:00"},
            "nextFireAt":"2026-11-28T01:00:00Z","active":true,"scheduleText":"Tiap hari 08.00"}"""))
        assertNull(r.todoId)
        assertEquals("daily", r.scheduleKind)
    }

    @Test fun fcmConfig() {
        assertNull(Parse.fcm(JSONObject("""{"fcm":null,"version":"0.22.0"}""")))
        val c = Parse.fcm(JSONObject("""{"fcm":{"projectId":"p-123","appId":"1:2:android:3","apiKey":"AIza","senderId":"2"}}"""))
        assertEquals("p-123", c?.projectId)
        assertNull(Parse.fcm(JSONObject("""{"fcm":{"projectId":"p","appId":"","apiKey":"a","senderId":"2"}}""")))
    }

    @Test fun chatPage() {
        val p = Parse.chatPage(JSONObject("""{"messages":[{"id":1,"role":"user","content":"hai"},{"id":2,"role":"assistant","content":"ok","batchId":7}],
            "batches":{"7":{"id":7,"status":"pending","items":[{"op":"todo.create","summary":"Tambah todo"}],"undoable":false}}}"""))
        assertEquals(2, p.messages.size)
        assertEquals("pending", p.batches[7]?.status)
    }

    @Test fun copyText() {
        val t = Todo(1, "Bayar listrik", "token PLN", "open", "normal", "", "", "", "manual")
        assertEquals("Bayar listrik\n\ntoken PLN", t.copyText())
        assertEquals("Bayar listrik", t.copyText(titleOnly = true))
    }

    @Test fun serverUrl() {
        assertEquals("https://todo.contoh.id", ServerUrl.normalize(" todo.contoh.id/ "))
        assertEquals("https://todo.contoh.id", ServerUrl.normalize("https://todo.contoh.id/api"))
        assertNull(ServerUrl.normalize("http://todo.contoh.id"))
        assertEquals("http://10.0.2.2:8080", ServerUrl.normalize("http://10.0.2.2:8080"))
        assertNull(ServerUrl.normalize(""))
    }

    @Test fun versions() {
        assertTrue(Versions.newer("v0.22.1", "0.22.0"))
        assertFalse(Versions.newer("v0.22.0", "0.22.0"))
        assertFalse(Versions.newer("0.9.9", "0.22.0"))
        assertTrue(Versions.newer("1.0.0", "0.99.99"))
    }
}
