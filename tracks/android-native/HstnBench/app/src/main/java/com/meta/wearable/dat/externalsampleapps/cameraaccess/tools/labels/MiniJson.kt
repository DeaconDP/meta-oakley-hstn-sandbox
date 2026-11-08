// MiniJson - a small JSON reader for the Open Food Facts reply
//
// Android's org.json isn't available in JVM unit tests (it's a stub there), and the label reader
// only needs to read one reply format, so this is a plain recursive-descent parser instead of a new
// dependency. Objects become Map<String, Any?>, arrays List<Any?>, numbers Double, plus String,
// Boolean and null. Throws IllegalArgumentException on malformed input. Pure Kotlin, JVM-tested.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.tools.labels

object MiniJson {

  fun parse(text: String): Any? {
    val p = Parser(text)
    p.skipSpace()
    val value = p.value()
    p.skipSpace()
    require(p.atEnd) { "Trailing characters at ${p.pos}" }
    return value
  }

  private class Parser(val s: String) {
    var pos = 0
    val atEnd: Boolean
      get() = pos >= s.length

    fun skipSpace() {
      while (pos < s.length && s[pos].isWhitespace()) pos++
    }

    fun value(): Any? {
      require(!atEnd) { "Unexpected end" }
      return when (val c = s[pos]) {
        '{' -> obj()
        '[' -> array()
        '"' -> string()
        't' -> literal("true", true)
        'f' -> literal("false", false)
        'n' -> literal("null", null)
        else -> if (c == '-' || c.isDigit()) number() else throw IllegalArgumentException("Bad JSON at $pos")
      }
    }

    private fun literal(word: String, v: Any?): Any? {
      require(s.startsWith(word, pos)) { "Bad literal at $pos" }
      pos += word.length
      return v
    }

    private fun obj(): Map<String, Any?> {
      val map = LinkedHashMap<String, Any?>()
      pos++
      skipSpace()
      if (s.getOrNull(pos) == '}') {
        pos++
        return map
      }
      while (true) {
        skipSpace()
        require(s.getOrNull(pos) == '"') { "Expected key at $pos" }
        val key = string()
        skipSpace()
        require(s.getOrNull(pos) == ':') { "Expected : at $pos" }
        pos++
        skipSpace()
        map[key] = value()
        skipSpace()
        when (s.getOrNull(pos)) {
          ',' -> pos++
          '}' -> {
            pos++
            return map
          }
          else -> throw IllegalArgumentException("Expected , or } at $pos")
        }
      }
    }

    private fun array(): List<Any?> {
      val list = ArrayList<Any?>()
      pos++
      skipSpace()
      if (s.getOrNull(pos) == ']') {
        pos++
        return list
      }
      while (true) {
        skipSpace()
        list += value()
        skipSpace()
        when (s.getOrNull(pos)) {
          ',' -> pos++
          ']' -> {
            pos++
            return list
          }
          else -> throw IllegalArgumentException("Expected , or ] at $pos")
        }
      }
    }

    private fun string(): String {
      pos++
      val sb = StringBuilder()
      while (true) {
        require(pos < s.length) { "Unterminated string" }
        val c = s[pos++]
        when (c) {
          '"' -> return sb.toString()
          '\\' -> {
            require(pos < s.length) { "Unterminated escape" }
            when (val e = s[pos++]) {
              '"', '\\', '/' -> sb.append(e)
              'b' -> sb.append('\b')
              'f' -> sb.append('\u000C')
              'n' -> sb.append('\n')
              'r' -> sb.append('\r')
              't' -> sb.append('\t')
              'u' -> {
                require(pos + 4 <= s.length) { "Bad unicode escape" }
                sb.append(s.substring(pos, pos + 4).toInt(16).toChar())
                pos += 4
              }
              else -> throw IllegalArgumentException("Bad escape \\$e")
            }
          }
          else -> sb.append(c)
        }
      }
    }

    private fun number(): Double {
      val start = pos
      if (s[pos] == '-') pos++
      while (pos < s.length && (s[pos].isDigit() || s[pos] in ".eE+-")) pos++
      return s.substring(start, pos).toDoubleOrNull() ?: throw IllegalArgumentException("Bad number at $start")
    }
  }
}
