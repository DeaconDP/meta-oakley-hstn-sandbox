// ClaudeAskTest - the optional online path, on canned replies only
//
// There's no API key on this machine, so the live request is never made. These tests check the
// request body (model, effort, system prompt, only the text and the question) and how replies in
// the Messages API's documented shape become answers: a text block after an (empty) thinking block,
// "The text doesn't say.", a refusal, HTTP errors, a network failure, malformed JSON. The replies are
// hand-written in that shape, not recorded from the live API.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.AskResult
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ClaudeAskTest {

  private fun reply(status: Int, body: String) = ClaudeAsk.Transport { _, _, _ -> ClaudeAsk.Reply(status, body) }

  private fun message(vararg blocks: String, stop: String = "end_turn") =
      """{"id":"msg_01Test","type":"message","role":"assistant","model":"claude-haiku-5-5",""" +
          """"content":[${blocks.joinToString(",")}],"stop_reason":"$stop","stop_details":null,""" +
          """"usage":{"input_tokens":512,"output_tokens":41}}"""

  private val thinking = """{"type":"thinking","thinking":"","signature":"EqQBCkYIBxgCKkA"}"""

  private fun text(t: String) = """{"type":"text","text":${MiniJson.quote(t)}}"""

  @Test
  fun requestCarriesOnlyTheQuestionAndTheText() {
    var url = ""
    var headers = emptyMap<String, String>()
    var body = ""
    val claude = ClaudeAsk("sk-test") { u, h, b ->
      url = u
      headers = h
      body = b
      ClaudeAsk.Reply(200, message(text("He wants to test them.")))
    }
    val r = runBlocking { claude.ask("why did he say \"follow me\"?", "The Time Traveller was expounding.\nA new line.") }
    assertEquals(AskResult.Answer("He wants to test them."), r)
    assertEquals("https://api.anthropic.com/v1/messages", url)
    assertEquals("sk-test", headers["x-api-key"])
    assertEquals("2026-10-21", headers["anthropic-version"])
    val json = MiniJson.parse(body) as Map<*, *>
    assertEquals("claude-haiku-5-5", json["model"])
    assertEquals(mapOf("effort" to "low"), json["output_config"])
    assertTrue((json["system"] as String).contains("The text doesn't say."))
    val messages = json["messages"] as List<*>
    assertEquals(1, messages.size)
    val content = (messages[0] as Map<*, *>)["content"] as String
    assertTrue(content.contains("<text>\nThe Time Traveller was expounding.\nA new line.\n</text>"))
    assertTrue(content.endsWith("Question: why did he say \"follow me\"?"))
    assertEquals(setOf("model", "max_tokens", "output_config", "system", "messages"), json.keys)
  }

  @Test
  fun repliesBecomeAnswers() {
    fun ask(t: ClaudeAsk.Transport) = runBlocking { ClaudeAsk("k", t).ask("q", "text") }
    assertEquals(AskResult.Answer("Filby doubts it. He thinks it's too much to accept."),
        ask(reply(200, message(thinking, text("Filby doubts it.\n He thinks it's too much to accept.")))))
    assertEquals(AskResult.NotInText, ask(reply(200, message(text("The text doesn't say.")))))
    assertEquals(AskResult.NotInText, ask(reply(200, message(text("The text does not say why.")))))
    assertEquals(AskResult.Failed("refusal"), ask(reply(200, message(stop = "refusal"))))
    assertEquals(AskResult.Failed("empty"), ask(reply(200, message(thinking, stop = "max_tokens"))))
    assertEquals(AskResult.Failed("http 401"), ask(reply(401, """{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}""")))
    assertEquals(AskResult.Failed("http 529"), ask(reply(529, """{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}""")))
    assertEquals(AskResult.Failed("bad json"), ask(reply(200, "<html>")))
    assertEquals(AskResult.Failed("network: IOException"), ask { _, _, _ -> throw IOException("no route") })
    assertEquals(AskResult.Unavailable, runBlocking { ClaudeAsk("", reply(200, "")).ask("q", "t") })
  }

  @Test
  fun miniJsonRoundTrips() {
    val s = "quote \" backslash \\ newline \n tab \t unicode é \u0001 end"
    assertEquals(s, MiniJson.parse(MiniJson.quote(s)))
    val v = MiniJson.parse("""{"a":[1,2.5,true,false,null,"xé"],"b":{}}""") as Map<*, *>
    assertEquals(listOf(1L, 2.5, true, false, null, "xé"), v["a"])
    assertEquals(emptyMap<String, Any?>(), v["b"])
  }
}
