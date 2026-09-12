//
//  ArtworkVideoCompositor.swift
//  MediaEditorCore
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import AVFoundation
import CoreImage

/// Composites each video frame, placed by the recipe's geometry, under a still
/// piece of artwork — the recipe's drawing and overlays, pre-rendered.
///
/// This is the job `AVVideoCompositionCoreAnimationTool` usually does, but that
/// tool's offline Core Animation renderer crashes the iOS Simulator: it creates
/// an IOSurface for the layer contents from the compositor thread, which the
/// Simulator traps as XPC misuse. Core Image does the same work on devices, the
/// Simulator and macOS alike. It only runs for exports that carry artwork; the
/// rest keep AVFoundation's built-in compositor.
///
/// Frames go through as 8-bit BGRA with color management off, so the video's
/// pixels come out as they went in. The trade-off is HDR: an HDR source exported
/// with artwork comes out as SDR.
final class ArtworkVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    // AVFoundation instantiates the compositor itself and calls it on its own
    // queues. Its only state is the Core Image context, which is thread-safe.

    private let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        // Every frame differs; caching intermediates would only cost memory.
        .cacheIntermediates: false,
    ])

    private static let pixelFormat: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.pixelFormat }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.pixelFormat }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? ArtworkCompositionInstruction,
              let source = request.sourceFrame(byTrackID: instruction.trackID),
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: VideoComposer.ComposeError.exportFailed(underlying: "No frame to composite"))
            return
        }
        let bounds = CGRect(origin: .zero, size: request.renderContext.size)
        let placement = Self.coreImageTransform(instruction.transform,
                                                sourceHeight: CGFloat(CVPixelBufferGetHeight(source)),
                                                renderHeight: bounds.height)
        let frame = CIImage(cvPixelBuffer: source, options: [.colorSpace: NSNull()]).transformed(by: placement)
        let composed = instruction.artwork
            .composited(over: frame)
            .composited(over: CIImage(color: .black))
            .cropped(to: bounds)
        context.render(composed, to: output, bounds: bounds, colorSpace: nil)
        request.finish(withComposedVideoFrame: output)
    }

    /// Restates a y-down transform — the kind a layer instruction takes — for
    /// Core Image's y-up space: flip the source into y-down, apply the transform,
    /// then flip the result back within the render frame.
    static func coreImageTransform(_ transform: CGAffineTransform,
                                   sourceHeight: CGFloat, renderHeight: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceHeight)
            .concatenating(transform)
            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: renderHeight))
    }

    /// `artwork` as Core Image input, stretched over a `renderSize` frame.
    static func prepare(_ artwork: CGImage, for renderSize: CGSize) -> CIImage {
        let image = CIImage(cgImage: artwork, options: [.colorSpace: NSNull()])
        return image.transformed(by: CGAffineTransform(scaleX: renderSize.width / image.extent.width,
                                                       y: renderSize.height / image.extent.height))
    }
}

/// What `ArtworkVideoCompositor` needs for a stretch of the timeline: the source
/// track, where its frames land, and what to lay over them.
final class ArtworkCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    // Immutable after init.
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let trackID: CMPersistentTrackID
    /// Maps source pixels onto the render frame, y-down, as for a layer instruction.
    let transform: CGAffineTransform
    /// Already stretched to the render size.
    let artwork: CIImage

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, transform: CGAffineTransform, artwork: CIImage) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.transform = transform
        self.artwork = artwork
        self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}
