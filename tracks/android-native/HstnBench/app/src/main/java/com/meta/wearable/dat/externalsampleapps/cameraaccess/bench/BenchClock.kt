// BenchClock - step-2 benchmark timings
//
// Records monotonic timestamps for each benchmark milestone and logs the elapsed time between a
// start mark and its end mark. Every result line is tagged "HstnBench" with a stable key=value
// layout, so a run can be scraped with `adb logcat -s HstnBench`.

package com.meta.wearable.dat.externalsampleapps.cameraaccess.bench

import android.os.SystemClock
import android.util.Log
import java.util.concurrent.ConcurrentHashMap

object BenchClock {
  private const val TAG = "HstnBench"

  private val marks = ConcurrentHashMap<String, Long>()

  /** Records the start of [metric], replacing any earlier unfinished start. */
  fun start(metric: String) {
    marks[metric] = SystemClock.elapsedRealtime()
  }

  /** Logs the time since [start] for [metric]. Does nothing if [metric] has no pending start. */
  fun end(metric: String, detail: String = "") {
    val startedAt = marks.remove(metric) ?: return
    val elapsedMs = SystemClock.elapsedRealtime() - startedAt
    Log.i(TAG, "metric=$metric ms=$elapsedMs${if (detail.isEmpty()) "" else " $detail"}")
  }

  fun note(message: String) {
    Log.i(TAG, message)
  }
}
