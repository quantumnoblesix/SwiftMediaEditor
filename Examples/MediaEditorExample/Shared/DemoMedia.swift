//
//  DemoMedia.swift
//  MediaEditorExample
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import UIKit
import AVFoundation

/// Draws a simple, asymmetric test image at runtime — the asymmetry makes
/// rotation and flips obvious.
enum SampleImage {
    static func make(size: CGSize = CGSize(width: 800, height: 1000)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor.systemIndigo.cgColor, UIColor.systemTeal.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors, locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero,
                                  end: CGPoint(x: size.width, y: size.height), options: [])

            let letter = "F" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 520, weight: .heavy),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
            ]
            let textSize = letter.size(withAttributes: attrs)
            letter.draw(at: CGPoint(x: (size.width - textSize.width) / 2,
                                    y: (size.height - textSize.height) / 2),
                        withAttributes: attrs)

            UIColor.systemYellow.setFill()
            cg.fillEllipse(in: CGRect(x: 40, y: 40, width: 90, height: 90))
        }
    }
}

/// Provides the sample video for the editor: a real clip bundled with the app,
/// falling back to a generated one if the resource is missing.
enum SampleVideo {
    static func make(size: CGSize = CGSize(width: 480, height: 270),
                     seconds: Double = 3, fps: Int = 30) async -> URL? {
        // Prefer the bundled clip.
        if let url = Bundle.main.url(forResource: "SampleVideo", withExtension: "mp4") {
            return url
        }
        return await generate(size: size, seconds: seconds, fps: fps)
    }

    /// Renders a short synthetic clip (moving bar) when no bundled video exists.
    private static func generate(size: CGSize, seconds: Double, fps: Int) async -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaEditor-sample-\(UUID().uuidString).mp4")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * Double(fps))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            if let buffer = pixelBuffer(size: size, frame: i, total: frames) {
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? url : nil
    }

    private static func pixelBuffer(size: CGSize, frame: Int, total: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                            kCVPixelFormatType_32ARGB,
                            [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            return nil
        }
        ctx.setFillColor(UIColor.systemIndigo.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        let t = CGFloat(frame) / CGFloat(max(1, total - 1))
        ctx.setFillColor(UIColor.systemYellow.cgColor)
        ctx.fill(CGRect(x: t * (size.width - 60), y: 30, width: 60, height: size.height - 60))
        ctx.setFillColor(UIColor.systemRed.cgColor)
        ctx.fill(CGRect(x: 16, y: size.height - 56, width: 48, height: 40))
        return buffer
    }
}
