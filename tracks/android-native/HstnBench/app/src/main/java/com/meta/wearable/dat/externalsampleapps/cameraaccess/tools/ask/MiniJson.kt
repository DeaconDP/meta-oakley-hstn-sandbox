// MiniJson - just enough JSON for one Claude request and its reply
//
// The optional Claude path builds one small request body and reads a few fields of the reply.
// android's org.json isn't available to JVM unit tests (it's a stub there), and a JSON library would
// be a new dependency for an off-by-default path, so this writes strings safely and parses the
// reply into plain Maps/Lists. Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.ask

object MiniJson {

  /** [s] as a JSON string literal, quotes included. */
  fun quote(s: String): String {
    val b = StringBuilder(s.length + 16).append('"')
    for (c in s) {
      when (c) {
        '"' -> b.append("\\\"")
        '\\' -> b.append("\\\\")
        '\n' -> b.append("\\n")
        '\r' -> b.append("\\r")
        '\t' -> b.append("\\t")
        '\b' -> b.append("\\b")
        '\u000C' -> b.append("\\f")
        else -> if (c < ' ' || c == ' ' || c == ' ') b.append("\\u%04x".format(c.code)) else b.append(c)
      }
    }
    return b.append('"').toString()
  }

  /** Parses [json] into Map<String, Any?>, List<Any?>, String, Double/Long, Boolean or null. */
  fun parse(json: String): Any? {
    val p = Parser(json)
    val v = p.value()
    p.skipWs()
    require(p.i == json.length) { "trailing data at ${p.i}" }
    return v
  }

  private class Parser(val s: String) {
    var i = 0

    fun skipWs() {
      while (i < s.length && s[i].isWhitespace()) i++
    }

    fun value(): Any? {
      skipWs()
      require(i < s.length) { "unexpected end" }
      return when (s[i]) {
        '{' -> obj()
        '[' -> arr()
        '"' -> str()
        't' -> lit("true", true)
        'f' -> lit("false", false)
        'n' -> lit("null", null)
        else -> num()
      }
    }

    private fun lit(word: String, v: Any?): Any? {
      require(s.startsWith(word, i)) { "bad literal at $i" }
      i += word.length
      return v
    }

    private fun num(): Any {
      val start = i
      while (i < s.length && (s[i].isDigit() || s[i] in "+-.eE")) i++
      val t = s.substring(start, i)
      require(t.isNotEmpty()) { "bad value at $start" }
      return t.toLongOrNull() ?: t.toDouble()
    }

    private fun obj(): Map<String, Any?> {
      i++
      val m = LinkedHashMap<String, Any?>()
      skipWs()
      if (s[i] == '}') {
        i++
        return m
      }
      while (true) {
        skipWs()
        val k = str()
        skipWs()
        require(s[i] == ':') { "expected : at $i" }
        i++
        m[k] = value()
        skipWs()
        when (s[i]) {
          ',' -> i++
          '}' -> {
            i++
            return m
          }
          else -> error("expected , or } at $i")
        }
      }
    }

    private fun arr(): List<Any?> {
      i++
      val l = ArrayList<Any?>()
      skipWs()
      if (s[i] == ']') {
        i++
        return l
      }
      while (true) {
        l += value()
        skipWs()
        when (s[i]) {
          ',' -> i++
          ']' -> {
            i++
            return l
          }
          else -> error("expected , or ] at $i")
        }
      }
    }

    private fun str(): String {
      require(s[i] == '"') { "expected string at $i" }
      i++
      val b = StringBuilder()
      while (true) {
        val c = s[i++]
        when (c) {
          '"' -> return b.toString()
          '\\' -> {
            val e = s[i++]
            when (e) {
              'n' -> b.append('\n')
              't' -> b.append('\t')
              'r' -> b.append('\r')
              'b' -> b.append('\b')
              'f' -> b.append('\u000C')
              'u' -> {
                b.append(s.substring(i, i + 4).toInt(16).toChar())
                i += 4
              }
              else -> b.append(e)
            }
          }
          else -> b.append(c)
        }
      }
    }
  }
}
