/*
 * FlickerDetector - "It's blinking": a light in view going on and off
 *
 * Port of Android's tools/light/FlickerDetector.kt. An appliance LED blinking (a charger, a smoke
 * alarm, a router) or a lamp flashing. The frame is cut into a grid of cells and each cell keeps its
 * brightest pixel (so a small LED still moves its cell a lot) and its mean (to notice movement: a
 * shifting scene changes many cells' means). Over the last few seconds, a cell is blinking if it
 * switches between two clearly different levels, sitting near one or the other, at least
 * `minTransitions` times. Moving the camera changes many cells' means at once (in both directions):
 * that resets the history, so movement isn't mistaken for blinking, and a light switched on once
 * isn't either (only one transition). At the probe's 4 frames a second it sees blinks up to about
 * 1.5 a second; mains flicker (100/120 Hz) is far too fast for any frame rate and isn't detected.
 */

import Foundation

struct FlickerDetector: Sendable {
  static let minFrames = 6
  static let minTransitions = 3
  static let minAmplitude = 60
  static let minOn = 110
  static let motionDelta = 25
  static let motionShare = 0.3

  let cellsX: Int
  let cellsY: Int
  /// Frames of history kept (5 s at 4 fps).
  let window: Int

  private var history: [[Int]] = []
  private var lastMeans: [Int]?

  /// True while something in view is blinking.
  private(set) var blinking = false

  init(cellsX: Int = 12, cellsY: Int = 20, window: Int = 20) {
    self.cellsX = cellsX
    self.cellsY = cellsY
    self.window = window
  }

  /// Adds a frame; returns `blinking`.
  @discardableResult
  mutating func update(_ pixels: [UInt32], width: Int, height: Int) -> Bool {
    let (maxes, means) = cells(pixels, width: width, height: height)
    return updateCells(maxes, means: means)
  }

  /// Adds one frame's cells (row-major, cellsX x cellsY): brightest luma and mean luma per cell.
  @discardableResult
  mutating func updateCells(_ cells: [Int], means: [Int]? = nil) -> Bool {
    let means = means ?? cells
    guard cells.count == cellsX * cellsY, means.count == cells.count else { return blinking }
    if let last = lastMeans {
      let changed = means.indices.filter { abs(means[$0] - last[$0]) > Self.motionDelta }
      let brighter = changed.filter { means[$0] > last[$0] }.count
      // Most cells changing the same way is the room light itself going on or off, not movement.
      let sameWay = Double(max(brighter, changed.count - brighter)) >= Double(changed.count) * 0.9
      if Double(changed.count) > Double(cells.count) * Self.motionShare, !sameWay {
        // The view moved (or the whole scene changed): start again from here.
        history.removeAll()
      }
    }
    lastMeans = means
    history.append(cells)
    if history.count > window { history.removeFirst(history.count - window) }
    blinking = history.count >= Self.minFrames && cells.indices.contains { cellBlinks($0) }
    return blinking
  }

  mutating func reset() {
    history.removeAll()
    lastMeans = nil
    blinking = false
  }

  private func cellBlinks(_ i: Int) -> Bool {
    let series = history.map { $0[i] }
    guard let lo = series.min(), let hi = series.max() else { return false }
    let amp = hi - lo
    if amp < Self.minAmplitude || hi < Self.minOn { return false }
    // Values must sit near the two levels, not drift between them.
    let band = Double(amp) * 0.3
    let near = series.filter { Double($0 - lo) <= band || Double(hi - $0) <= band }.count
    if Double(near) < Double(series.count) * 0.8 { return false }
    // Integer midpoint, as on Android.
    let mid = Double((lo + hi) / 2)
    var transitions = 0
    var state = Double(series[0]) > mid
    for v in series {
      let s = state ? Double(v) > mid - band / 2 : Double(v) > mid + band / 2
      if s != state {
        transitions += 1
        state = s
      }
    }
    return transitions >= Self.minTransitions
  }

  /// Brightest and mean luma in each cell.
  func cells(_ pixels: [UInt32], width: Int, height: Int) -> (maxes: [Int], means: [Int]) {
    var maxes = [Int](repeating: 0, count: cellsX * cellsY)
    var sums = [Int](repeating: 0, count: cellsX * cellsY)
    var counts = [Int](repeating: 0, count: cellsX * cellsY)
    for y in 0..<height {
      let cy = min(y * cellsY / height, cellsY - 1)
      for x in 0..<width {
        let cx = min(x * cellsX / width, cellsX - 1)
        let k = cy * cellsX + cx
        let l = ColourSpace.luma(pixels[y * width + x])
        maxes[k] = max(maxes[k], l)
        sums[k] += l
        counts[k] += 1
      }
    }
    return (maxes, (0..<sums.count).map { sums[$0] / max(1, counts[$0]) })
  }
}
