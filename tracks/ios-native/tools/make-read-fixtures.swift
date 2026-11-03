#!/usr/bin/env swift
/*
 * make-read-fixtures - renders the "Read it aloud" test page for the Mock Device Kit
 *
 * Writes two files into the given directory:
 * - read_page.mp4: 8 s of a still printed page, HEVC 540x960 at 24 fps, the same geometry as
 *   plant.mp4, for setCameraFeed (the stream frame the reader uses first).
 * - read_page.png: the same page at 960x1440, the mock's in-stream photo size, for
 *   setCapturedImage (the reader's capturePhoto fallback).
 *
 * The page is a white sheet on a grey table with a short paragraph well inside the frame, so the
 * framing check calls it a good page (no edge touched). Run once, on a Mac, and commit the output:
 *
 *   swift tracks/ios-native/tools/make-read-fixtures.swift \
 *     tracks/ios-native/HstnBench/CameraAccess/A11y/Read/Fixtures
 *
 * Not part of any target. The fixture text is mirrored in ReadAloudUITests.
 */

import AppKit
import AVFoundation
import CoreVideo

let title = "Reading test"
let paragraph =
  "The quick brown fox jumps over the lazy dog. Printed text is read word for word, in order. This is the end of the test page."

func renderPage(width: Int, height: Int) -> CGImage {
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  guard
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
  else { fatalError("No bitmap context") }
  let w = CGFloat(width)
  let h = CGFloat(height)

  // Table.
  context.setFillColor(CGColor(gray: 0.42, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: w, height: h))
  // Sheet, inset so no text can touch a frame edge.
  let sheet = CGRect(x: w * 0.1, y: h * 0.22, width: w * 0.8, height: h * 0.56)
  context.setFillColor(CGColor(gray: 0.97, alpha: 1))
  context.fill(sheet)

  let previous = NSGraphicsContext.current
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
  defer { NSGraphicsContext.current = previous }

  let fontSize = w * 0.056
  let style = NSMutableParagraphStyle()
  style.lineSpacing = fontSize * 0.25
  style.paragraphSpacing = fontSize * 0.6
  let text = NSMutableAttributedString(
    string: title + "\n",
    attributes: [
      .font: NSFont(name: "Helvetica-Bold", size: fontSize * 1.15) ?? NSFont.boldSystemFont(ofSize: fontSize * 1.15),
      .foregroundColor: NSColor.black,
      .paragraphStyle: style,
    ])
  text.append(
    NSAttributedString(
      string: paragraph,
      attributes: [
        .font: NSFont(name: "Georgia", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize),
        .foregroundColor: NSColor.black,
        .paragraphStyle: style,
      ]))
  text.draw(in: sheet.insetBy(dx: sheet.width * 0.08, dy: sheet.height * 0.08))

  guard let image = context.makeImage() else { fatalError("No image") }
  return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
  let rep = NSBitmapImageRep(cgImage: image)
  guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encode failed") }
  try data.write(to: url)
}

func pixelBuffer(from image: CGImage) -> CVPixelBuffer {
  var buffer: CVPixelBuffer?
  let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
  CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
  guard let buffer else { fatalError("No pixel buffer") }
  CVPixelBufferLockBaseAddress(buffer, [])
  defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
  guard
    let context = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
  else { fatalError("No buffer context") }
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  return buffer
}

func writeMovie(_ image: CGImage, to url: URL, seconds: Int, fps: Int32) throws {
  try? FileManager.default.removeItem(at: url)
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: image.width, AVVideoHeightKey: image.height])
  input.expectsMediaDataInRealTime = false
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
  writer.add(input)
  guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
  writer.startSession(atSourceTime: .zero)
  let buffer = pixelBuffer(from: image)
  for frame in 0..<(seconds * Int(fps)) {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
  }
  input.markAsFinished()
  let done = DispatchSemaphore(value: 0)
  writer.finishWriting { done.signal() }
  done.wait()
  if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
  FileHandle.standardError.write("usage: make-read-fixtures.swift <output-directory>\n".data(using: .utf8)!)
  exit(64)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try writePNG(renderPage(width: 960, height: 1440), to: directory.appendingPathComponent("read_page.png"))
try writeMovie(renderPage(width: 540, height: 960), to: directory.appendingPathComponent("read_page.mp4"), seconds: 8, fps: 24)
print("Wrote read_page.png and read_page.mp4 to \(directory.path)")
