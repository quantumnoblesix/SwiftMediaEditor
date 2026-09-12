//
//  VideoExportTests.swift
//  MediaEditorCoreTests
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import AVFoundation
import CoreGraphics
import Testing
@testable import MediaEditorCore

@MainActor
// A stalled export or fixture write fails the test instead of hanging the run.
@Suite("VideoComposer export", .timeLimit(.minutes(1)))
struct VideoExportTests {

    private let composer = VideoComposer()

    /// Sample rate of the fixture's silent audio track.
    private static let audioSampleRate: Double = 44_100
    /// Frames of silence written per audio sample buffer.
    private static let audioChunkFrames = 1024

    /// Writes a tiny solid-color H.264 clip to a temp URL for exporting,
    /// optionally carrying a silent AAC track so audio removal is observable.
    private func makeFixture(width: Int, height: Int, seconds: Double, fps: Int,
                             withAudio: Bool = false) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaEditor-fixture-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)

        var audioInput: AVAssetWriterInput?
        if withAudio {
            let track = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: Self.audioSampleRate,
                AVEncoderBitRateKey: 64_000,
            ])
            track.expectsMediaDataInRealTime = false
            writer.add(track)
            audioInput = track
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Feed the inputs interleaved by time. A writer holds back an input that
        // runs about three seconds ahead of the others, so writing all the video
        // before any audio stalls for good on longer clips — the audio that would
        // release it is never reached.
        let frames = Int(seconds * Double(fps))
        let samples = audioInput == nil ? 0 : Int(seconds * Self.audioSampleRate)
        var frame = 0, written = 0
        var videoDone = false, audioDone = audioInput == nil

        func appendVideo() -> Bool {
            guard !videoDone, input.isReadyForMoreMediaData else { return false }
            if frame < frames {
                if let buffer = makePixelBuffer(width: width, height: height, frame: frame) {
                    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
                }
                frame += 1
            } else {
                input.markAsFinished()
                videoDone = true
            }
            return true
        }

        func appendAudio() -> Bool {
            guard !audioDone, let audioInput, audioInput.isReadyForMoreMediaData else { return false }
            if written < samples {
                let count = min(Self.audioChunkFrames, samples - written)
                let at = CMTime(value: CMTimeValue(written), timescale: CMTimeScale(Self.audioSampleRate))
                if let sample = makeSilentAudioBuffer(frames: count, at: at) {
                    audioInput.append(sample)
                }
                written += count
            } else {
                audioInput.markAsFinished()
                audioDone = true
            }
            return true
        }

        while !videoDone || !audioDone {
            // The input that's further behind goes first; if it's busy, the other.
            let videoAhead = Double(frame) / Double(fps) > Double(written) / Self.audioSampleRate
            let progressed = !audioDone && (videoDone || videoAhead)
                ? appendAudio() || appendVideo()
                : appendVideo() || appendAudio()
            if !progressed {
                try Task.checkCancellation()   // lets the suite's time limit end the test
                await Task.yield()
            }
        }

        await writer.finishWriting()
        return url
    }

    /// A buffer of 16-bit mono silence — enough for the writer to lay down a
    /// real audio track without shipping a media file in the test bundle.
    private func makeSilentAudioBuffer(frames: Int, at time: CMTime) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.audioSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                             layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &format) == noErr,
              let format else { return nil }

        let byteCount = frames * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0,
                                                 dataLength: byteCount, flags: 0,
                                                 blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block,
                                         offsetIntoDestination: 0, dataLength: byteCount) == noErr
        else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(Self.audioSampleRate)),
            presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sizes = [2]
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                   sampleCount: CMItemCount(frames), sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                   sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }

    private func trackCount(_ mediaType: AVMediaType, in url: URL) async throws -> Int {
        try await AVURLAsset(url: url).loadTracks(withMediaType: mediaType).count
    }

    private func makePixelBuffer(width: Int, height: Int, frame: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
                            [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func orientedSize(of url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return .zero
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    @Test("Exports a rotated, trimmed clip with swapped dimensions and clipped duration")
    func exportRotateAndTrim() async throws {
        let source = try await makeFixture(width: 160, height: 120, seconds: 2, fps: 15)
        defer { try? FileManager.default.removeItem(at: source) }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaEditor-out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        var progressSeen = false
        let recipe = EditRecipe(
            rotation: RotationState(degrees: 90),
            trim: TrimRange(start: 0.5, duration: 1.0)
        )
        try await composer.export(asset: AVURLAsset(url: source), recipe: recipe,
                                  to: output, preset: .h264HighQuality) { _ in progressSeen = true }

        #expect(FileManager.default.fileExists(atPath: output.path))

        // 160×120 rotated 90° → 120×160 output.
        let size = try await orientedSize(of: output)
        #expect(Int(size.width) == 120)
        #expect(Int(size.height) == 160)

        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 1.0) < 0.2)
        #expect(progressSeen)
    }

    @Test("The audio track survives an export that doesn't ask to drop it")
    func exportKeepsAudioByDefault() async throws {
        let source = try await makeFixture(width: 160, height: 120, seconds: 1, fps: 15, withAudio: true)
        defer { try? FileManager.default.removeItem(at: source) }
        #expect(try await trackCount(.audio, in: source) == 1, "fixture should carry audio")

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaEditor-out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        try await composer.export(asset: AVURLAsset(url: source), recipe: .identity,
                                  to: output, preset: .h264HighQuality)

        #expect(try await trackCount(.audio, in: output) == 1)
        #expect(try await trackCount(.video, in: output) == 1)
    }

    @Test("removeAudio drops the track outright rather than silencing it")
    func exportRemovesAudioTrack() async throws {
        let source = try await makeFixture(width: 160, height: 120, seconds: 2, fps: 15, withAudio: true)
        defer { try? FileManager.default.removeItem(at: source) }
        #expect(try await trackCount(.audio, in: source) == 1, "fixture should carry audio")

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaEditor-out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        // Combined with geometry + trim, so the video-only composition is shown
        // to keep the source timeline the trim seconds are measured against.
        let recipe = EditRecipe(rotation: RotationState(degrees: 90),
                                trim: TrimRange(start: 0.5, duration: 1.0),
                                removeAudio: true)
        try await composer.export(asset: AVURLAsset(url: source), recipe: recipe,
                                  to: output, preset: .h264HighQuality)

        #expect(try await trackCount(.audio, in: output) == 0)
        #expect(try await trackCount(.video, in: output) == 1)

        let size = try await orientedSize(of: output)
        #expect(Int(size.width) == 120)
        #expect(Int(size.height) == 160)

        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 1.0) < 0.2)
    }

    @Test("makeExportAsset hands back the original when audio is kept")
    func exportAssetIsUntouchedWithoutRemoveAudio() async throws {
        let source = try await makeFixture(width: 80, height: 60, seconds: 0.5, fps: 15, withAudio: true)
        defer { try? FileManager.default.removeItem(at: source) }

        let asset = AVURLAsset(url: source)
        let result = try await composer.makeExportAsset(for: asset, recipe: .identity)
        #expect(result === asset)
    }

    @Test("A clip with audio longer than the writer's interleaving window still gets written")
    func longFixtureWithAudioCompletes() async throws {
        // Written video-first, a clip this long stalled the fixture three seconds
        // in, every time; see `makeFixture`.
        let source = try await makeFixture(width: 160, height: 120, seconds: 6, fps: 15, withAudio: true)
        defer { try? FileManager.default.removeItem(at: source) }

        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        #expect(abs(duration - 6) < 0.2)
        #expect(try await trackCount(.audio, in: source) == 1)
        #expect(try await trackCount(.video, in: source) == 1)
    }

    // MARK: - Artwork

    /// A transparent image with an opaque red block in its top-left quadrant —
    /// deliberately asymmetric, so a flipped or mirrored composite can't pass.
    private func makeArtwork(size: CGSize) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        // Core Graphics is y-up, so the image's top half is the upper y range.
        ctx.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height - height / 2))
        return ctx.makeImage()
    }

    private struct RGB { var red, green, blue: Double }

    /// The colours of `url`'s frame at `seconds`, at each point in top-left-origin
    /// pixel coordinates of the oriented frame.
    private func colors(of url: URL, at seconds: Double, points: [CGPoint]) async throws -> [RGB] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        let width = frame.width, height = frame.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            // A bitmap context's first row of memory is the top of what's drawn.
            let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return points.map { point in
            let i = (Int(point.y) * width + Int(point.x)) * 4
            return RGB(red: Double(bytes[i]) / 255, green: Double(bytes[i + 1]) / 255,
                       blue: Double(bytes[i + 2]) / 255)
        }
    }

    @Test("Artwork is composited upright over the output frame, not the source")
    func exportCompositesArtwork() async throws {
        let source = try await makeFixture(width: 160, height: 120, seconds: 1, fps: 15)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaEditor-out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        // Rotated, so artwork applied before the geometry would land sideways.
        var requested: CGSize?
        try await composer.export(asset: AVURLAsset(url: source),
                                  recipe: EditRecipe(rotation: RotationState(degrees: 90)),
                                  to: output, preset: .h264HighQuality,
                                  overlayImage: { size in
                                      requested = size
                                      return makeArtwork(size: size)
                                  })

        #expect(requested == CGSize(width: 120, height: 160), "artwork is drawn for the rotated output frame")
        let samples = try await colors(of: output, at: 0.5, points: [
            CGPoint(x: 30, y: 40),     // top-left, under the red block
            CGPoint(x: 90, y: 40),     // top-right
            CGPoint(x: 30, y: 120),    // bottom-left
        ])
        let topLeft = samples[0], topRight = samples[1], bottomLeft = samples[2]
        #expect(topLeft.red > 0.7 && topLeft.blue < 0.35, "red block expected top-left, got \(topLeft)")
        #expect(topRight.blue > 0.6 && topRight.red < 0.4, "the video should show through elsewhere, got \(topRight)")
        #expect(bottomLeft.blue > 0.6 && bottomLeft.red < 0.4,
                "a vertically flipped composite would put the red here, got \(bottomLeft)")
    }

    @Test("Artwork is requested at the capped size, and costs nothing when absent")
    func artworkToolOnlyWhenNeeded() async throws {
        let source = try await makeFixture(width: 160, height: 120, seconds: 0.5, fps: 15)
        defer { try? FileManager.default.removeItem(at: source) }
        let asset = AVURLAsset(url: source)

        let plain = try await composer.makeVideoComposition(for: asset, recipe: .identity)
        #expect(plain.customVideoCompositorClass == nil)

        var requested: CGSize?
        let empty = try await composer.makeVideoComposition(for: asset, recipe: .identity,
                                                            maximumDimension: 80) { size in
            requested = size
            return nil
        }
        #expect(requested == CGSize(width: 80, height: 60))
        #expect(empty.customVideoCompositorClass == nil, "nothing to draw keeps the built-in compositor")

        let decorated = try await composer.makeVideoComposition(for: asset, recipe: .identity) { size in
            makeArtwork(size: size)
        }
        #expect(decorated.customVideoCompositorClass != nil)
    }
}
