package cn.littlebear.tutor

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test

class TutorServiceTest {
    @Test fun clientSendsCurrentTaskAndDeviceCredential() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("""{"message":"先看看个位","assessment":"UNKNOWN"}"""))
            val settings = ServiceSettings(server.url("/").toString().removeSuffix("/"), "x".repeat(32), true)
            val response = TutorService().request(settings, TutorRequest("help", 2, "MATH", message = "我不会进位"))
            assertEquals("先看看个位", response.message)
            val sent = server.takeRequest()
            assertEquals("/v1/tutor", sent.path)
            assertEquals("Bearer ${settings.token}", sent.getHeader("Authorization"))
            val body = Json.parseToJsonElement(sent.body.readUtf8()).jsonObject
            assertEquals("MATH", body.getValue("subject").jsonPrimitive.content)
            assertEquals("我不会进位", body.getValue("message").jsonPrimitive.content)
        }
    }

    @Test fun credentialsAreNotForwardedToRedirects() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "https://unrelated.invalid/"))
            val settings = ServiceSettings(server.url("/").toString().removeSuffix("/"), "x".repeat(32), true)
            val failure = runCatching { TutorService().request(settings, TutorRequest("help", 2, "MATH")) }.exceptionOrNull()
            assertNotNull(failure)
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun invalidResponsesAreNotDisplayedAsTutorMessages() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("not-json internal details"))
            val settings = ServiceSettings(server.url("/").toString().removeSuffix("/"), "x".repeat(32), true)
            val failure = runCatching { TutorService().request(settings, TutorRequest("help", 2, "MATH")) }.exceptionOrNull()
            assertNotNull(failure)
            assertFalse(failure!!.message!!.contains("internal details"))
        }
    }

    @Test fun disabledConsentPreventsNetworkCalls() = runBlocking {
        MockWebServer().use { server ->
            val settings = ServiceSettings(server.url("/").toString().removeSuffix("/"), "x".repeat(32), false)
            assertTrue(runCatching { TutorService().request(settings, TutorRequest("help", 2, "MATH")) }.isFailure)
            assertEquals(0, server.requestCount)
        }
    }
}
