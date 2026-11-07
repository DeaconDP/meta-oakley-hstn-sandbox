// ClaudeAsk - the optional online path for open questions ("why did he do that?")
//
// Off by default. It exists only if local.properties has anthropic_api_key (BuildConfig
// ANTHROPIC_API_KEY); without it AskProvider never creates this class and the app makes no network
// request for questions. With it, only questions the phone can't answer itself (AskKind.OPEN) come
// here, only when the user asked one, and OnDeviceAsk says "Asking online." first. What is sent:
// the question and the recent text read out (at most 12 000 characters). Never an image, never the
// whole book.
//
// One Messages API request (POST /v1/messages, anthropic-version 2026-10-21) to Claude Haiku 5.5
// (claude-haiku-5-5), effort low (short answers, quick), adaptive thinking left at its default.
// Raw HTTP rather than the Java SDK: one request on an off-by-default path doesn't justify the SDK's
// size in the APK, and a [Transport] lets tests play recorded replies. The system prompt makes
// Claude answer only from the text and say "The text doesn't say." otherwise, which becomes
// AskResult.NotInText. Pure Kotlin except [HttpTransport] (java.net). Untested live: no key here.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.core.AskResult
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class ClaudeAsk(private val apiKey: String, private val transport: Transport = HttpTransport()) : OnlineAsk {

  data class Reply(val status: Int, val body: String)

  /** Sends one HTTPS POST. Tests replace it with recorded replies. */
  fun interface Transport {
    suspend fun post(url: String, headers: Map<String, String>, body: String): Reply
  }

  override suspend fun ask(question: String, text: String): AskResult {
    if (apiKey.isBlank()) return AskResult.Unavailable
    val reply =
        try {
          transport.post(URL_MESSAGES, headers(), requestBody(question, text))
        } catch (e: kotlinx.coroutines.CancellationException) {
          throw e
        } catch (e: Exception) {
          return AskResult.Failed("network: ${e.javaClass.simpleName}")
        }
    return parseReply(reply)
  }

  fun headers(): Map<String, String> =
      mapOf(
          "x-api-key" to apiKey,
          "anthropic-version" to API_VERSION,
          "content-type" to "application/json",
      )

  companion object {
    const val URL_MESSAGES = "https://api.anthropic.com/v1/messages"
    const val API_VERSION = "2026-10-21"
    const val MODEL = "claude-haiku-5-5"
    const val NOT_IN_TEXT = "The text doesn't say."

    val SYSTEM =
        "You answer a blind listener's spoken question about a text that was just read aloud to " +
            "them by a reading app. Use only the text given. If the text does not answer the " +
            "question, reply exactly: $NOT_IN_TEXT Do not guess or use outside knowledge about the " +
            "book. Reply in one to three short sentences of plain spoken English: no lists, no " +
            "markdown, no quotation marks around the whole answer."

    fun requestBody(question: String, text: String): String =
        """{"model":${MiniJson.quote(MODEL)},"max_tokens":1024,""" +
            """"output_config":{"effort":"low"},""" +
            """"system":${MiniJson.quote(SYSTEM)},""" +
            """"messages":[{"role":"user","content":${MiniJson.quote("<text>\n$text\n</text>\n\nQuestion: $question")}}]}"""

    /** The spoken answer in [reply], or why there isn't one. */
    fun parseReply(reply: Reply): AskResult {
      if (reply.status !in 200..299) return AskResult.Failed("http ${reply.status}")
      val json = try {
        MiniJson.parse(reply.body) as? Map<*, *>
      } catch (e: Exception) {
        null
      } ?: return AskResult.Failed("bad json")
      if (json["stop_reason"] == "refusal") return AskResult.Failed("refusal")
      val content = json["content"] as? List<*> ?: return AskResult.Failed("no content")
      val text = content.filterIsInstance<Map<*, *>>()
          .filter { it["type"] == "text" }
          .mapNotNull { it["text"] as? String }
          .joinToString(" ")
          .replace(Regex("\\s+"), " ")
          .trim()
      if (text.isEmpty()) return AskResult.Failed("empty")
      if (text.trimEnd('.').equals(NOT_IN_TEXT.trimEnd('.'), ignoreCase = true) ||
          text.startsWith("The text doesn't say", ignoreCase = true) ||
          text.startsWith("The text does not say", ignoreCase = true)) {
        return AskResult.NotInText
      }
      return AskResult.Answer(text)
    }
  }
}

/** The real transport: HttpURLConnection on the IO dispatcher, 10 s to connect, 20 s to answer. */
class HttpTransport : ClaudeAsk.Transport {
  override suspend fun post(url: String, headers: Map<String, String>, body: String): ClaudeAsk.Reply =
      withContext(Dispatchers.IO) {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
          c.requestMethod = "POST"
          c.connectTimeout = 10_000
          c.readTimeout = 20_000
          c.doOutput = true
          for ((k, v) in headers) c.setRequestProperty(k, v)
          c.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
          val status = c.responseCode
          val stream = if (status in 200..299) c.inputStream else c.errorStream
          ClaudeAsk.Reply(status, stream?.bufferedReader()?.use { it.readText() }.orEmpty())
        } finally {
          c.disconnect()
        }
      }
}
