//
//  VideoFixture.swift
//  MediaEditorUIKitTests
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

// The turnkey editor UI is UIKit-based, so it builds for iOS and Mac
// Catalyst. On platforms without UIKit this file compiles to nothing and
// hosts use `MediaEditorCore` directly.
#if canImport(UIKit)

import AVFoundation
import CoreGraphics

/// Writes small solid-colour clips for tests, with an optional silent audio
/// track — a trimmed copy of the Core suite's fixture, which this target can't
/// reach.
enum VideoFixture {

    private static let audioSampleRate: Double = 44_100
    private static let audioChunkFrames = 1024

    static func make(width: Int, height: Int, seconds: Double, fps: Int = 15,
                     withAudio: Bool = false) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaEditor-fixture-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        var audioInput: AVAssetWriterInput?
        if withAudio {
            let track = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1,
                AVSampleRateKey: audioSampleRate, AVEncoderBitRateKey: 64_000,
            ])
            track.expectsMediaDataInRealTime = false
            writer.add(track)
            audioInput = track
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Interleaved by time: a writer stalls an input that runs far ahead.
        let frames = Int(seconds * Double(fps))
        let samples = audioInput == nil ? 0 : Int(seconds * audioSampleRate)
        var frame = 0, written = 0
        var videoDone = false, audioDone = audioInput == nil
        func appendVideo() -> Bool {
            guard !videoDone, input.isReadyForMoreMediaData else { return false }
            if frame < frames {
                if let buffer = pixelBuffer(width: width, height: height) {
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
                let count = min(audioChunkFrames, samples - written)
                if let sample = silence(frames: count, at: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(audioSampleRate))) {
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
            let videoAhead = Double(frame) / Double(fps) > Double(written) / audioSampleRate
            let progressed = !audioDone && (videoDone || videoAhead)
                ? appendAudio() || appendVideo()
                : appendVideo() || appendAudio()
            if !progressed {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        await writer.finishWriting()
        return url
    }

    private static func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
                            [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private static func silence(frames: Int, at time: CMTime) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: audioSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &format) == noErr, let format else { return nil }
        let byteCount = frames * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: byteCount, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                         dataLength: byteCount) == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(audioSampleRate)),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sizes = [2]
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                   sampleCount: CMItemCount(frames), sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                   sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}

#endif
