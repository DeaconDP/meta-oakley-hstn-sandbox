// SetupJson - the shared setup file and the short share code
//
// The file (schema 1, same on iOS):
//
//   {"schema":1,
//    "areas":{"speech":{...},"sounds":{...},"ears":{...},"words":{...},"controls":{...},"tips":{...},"descriptions":{...}},
//    "profiles":{"home":{<areas, only what differs from the defaults>},"out and about":{...},"reading":{...}},
//    "activeProfile":"home"}
//
// On the phone it also carries "device" (lock, learned-suggestion counts, migration marker), which
// export leaves out. The share code is "SU1." + base64url(deflate(the file with only what differs
// from the defaults)). Pure Kotlin (java.util.zip, java.util.Base64), JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.settings

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask.MiniJson
import java.io.ByteArrayOutputStream
import java.util.Base64
import java.util.zip.Deflater
import java.util.zip.Inflater

object SetupJson {
  const val SCHEMA = 1
  const val CODE_PREFIX = "SU1."

  /** Compact JSON. Maps keep their order; floats are written without trailing noise. */
  fun encode(v: Any?): String = StringBuilder().also { write(it, v) }.toString()

  private fun write(b: StringBuilder, v: Any?) {
    when (v) {
      null -> b.append("null")
      is String -> b.append(MiniJson.quote(v))
      is Boolean -> b.append(v)
      is Int, is Long -> b.append(v)
      is Float -> writeDouble(b, v.toDouble())
      is Double -> writeDouble(b, v)
      is Map<*, *> -> {
        b.append('{')
        var first = true
        for ((k, value) in v) {
          if (!first) b.append(',')
          first = false
          b.append(MiniJson.quote(k.toString())).append(':')
          write(b, value)
        }
        b.append('}')
      }
      is Iterable<*> -> {
        b.append('[')
        var first = true
        for (item in v) {
          if (!first) b.append(',')
          first = false
          write(b, item)
        }
        b.append(']')
      }
      else -> b.append(MiniJson.quote(v.toString()))
    }
  }

  private fun writeDouble(b: StringBuilder, d: Double) {
    // Floats come from Float fields: print the shortest decimal that reads back the same Float.
    val f = d.toFloat()
    if (f == Math.round(f).toFloat() && kotlin.math.abs(f) < 1e9) b.append(Math.round(f).toLong()).append(".0")
    else b.append(f.toString())
  }

  /** Parses JSON into maps and lists, or null if it isn't JSON. */
  fun parse(text: String): Any? = try { MiniJson.parse(text.trim()) } catch (e: Exception) { null }

  // MARK: short code

  fun toCode(json: String): String {
    val input = json.toByteArray(Charsets.UTF_8)
    val deflater = Deflater(Deflater.BEST_COMPRESSION, true)
    deflater.setInput(input)
    deflater.finish()
    val out = ByteArrayOutputStream()
    val buf = ByteArray(1024)
    while (!deflater.finished()) out.write(buf, 0, deflater.deflate(buf))
    deflater.end()
    return CODE_PREFIX + Base64.getUrlEncoder().withoutPadding().encodeToString(out.toByteArray())
  }

  /** The JSON inside a share code, or null if it isn't one. Spaces and line breaks are ignored. */
  fun fromCode(code: String): String? {
    val c = code.trim().replace(Regex("\\s+"), "")
    if (!c.startsWith(CODE_PREFIX)) return null
    return try {
      val bytes = Base64.getUrlDecoder().decode(c.removePrefix(CODE_PREFIX))
      val inflater = Inflater(true)
      inflater.setInput(bytes)
      val out = ByteArrayOutputStream()
      val buf = ByteArray(1024)
      var guard = 0
      while (!inflater.finished() && guard++ < 1000) {
        val n = inflater.inflate(buf)
        if (n == 0 && (inflater.needsInput() || inflater.needsDictionary())) break
        out.write(buf, 0, n)
        if (out.size() > 256 * 1024) return null
      }
      inflater.end()
      out.toString("UTF-8")
    } catch (e: Exception) {
      null
    }
  }
}
