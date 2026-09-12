//
//  VideoComposer.swift
//  MediaEditorCore
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import AVFoundation
import CoreGraphics

/// Builds AVFoundation compositions that realize an `EditRecipe` for video:
/// crop, rotation, and flip via an `AVMutableVideoComposition`, trim via the
/// export time range, and audio removal by exporting a video-only composition,
/// plus an `export` entry point with progress reporting.
///
/// Drawing and overlays are laid over the frames as a single pre-rendered image
/// by `ArtworkVideoCompositor`, a Core Image compositor. The core can't rasterize
/// text or PencilKit strokes itself, so the UI layer renders that image and
/// hands it in — see `export(asset:recipe:to:preset:maximumDimension:onProgress:overlayImage:)`.
public struct VideoComposer: Sendable {

    public enum ComposeError: Error, Sendable {
        case noVideoTrack
        case exportSessionCreationFailed
        case exportFailed(underlying: String?)
    }

    public init() {}

    /// Builds an `AVMutableVideoComposition` that applies flip → rotation → crop
    /// to the asset's first video track, in the oriented display space (matching
    /// the photo pipeline and what the user sees). The track's `preferredTransform`
    /// is applied first so recorded orientation is respected.
    ///
    /// Trim is intentionally *not* baked into the composition — it is applied as
    /// the export session's `timeRange`, which avoids re-timing the composition.
    /// - Parameters:
    ///   - asset: the video to compose. Its first video track is used.
    ///   - recipe: the edits to apply. Only the geometry — flip, rotation, crop —
    ///     is read here.
    ///   - maximumDimension: caps the longest side of the render frame. `nil`
    ///     keeps the source resolution.
    ///   - overlayImage: artwork to lay over every frame — typically the recipe's
    ///     drawing and overlays, which only a UI layer can rasterize. Called once
    ///     with the final render size (after `maximumDimension`) so it can be drawn
    ///     at exactly the output resolution; it's stretched to the frame either
    ///     way. Return `nil` when there's nothing to draw.
    @MainActor
    public func makeVideoComposition(
        for asset: AVAsset,
        recipe: EditRecipe,
        maximumDimension: CGFloat? = nil,
        overlayImage: (@MainActor (_ renderSize: CGSize) -> CGImage?)? = nil
    ) async throws -> AVMutableVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ComposeError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)

        // Oriented source size after the track's own preferredTransform.
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))

        let geometry = geometryTransform(recipe: recipe,
                                         preferred: preferred,
                                         orientedSize: orientedSize)
        let (transform, renderSize) = scaled(geometry, toFit: maximumDimension)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(transform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        instruction.layerInstructions = [layerInstruction]

        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = renderSize
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let fps = nominalFrameRate > 0 ? nominalFrameRate : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        // Only when there is artwork: the built-in compositor is the cheaper path,
        // and an export with nothing on top shouldn't give it up.
        if let artwork = overlayImage?(renderSize) {
            composition.customVideoCompositorClass = ArtworkVideoCompositor.self
            composition.instructions = [ArtworkCompositionInstruction(
                timeRange: instruction.timeRange, trackID: track.trackID, transform: transform,
                artwork: ArtworkVideoCompositor.prepare(artwork, for: renderSize))]
        }
        return composition
    }

    /// The asset to export for `recipe`: the original, or — when the recipe
    /// removes the audio — a composition holding only the video track.
    ///
    /// Stripping the track outright (rather than silencing it with an audio mix)
    /// keeps the output free of a dead silent track, which is what a host asking
    /// for "remove audio" expects to receive.
    @MainActor
    public func makeExportAsset(for asset: AVAsset, recipe: EditRecipe) async throws -> AVAsset {
        guard recipe.removeAudio else { return asset }
        guard let source = try await asset.loadTracks(withMediaType: .video).first else {
            throw ComposeError.noVideoTrack
        }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ComposeError.exportSessionCreationFailed
        }
        // Insert at the source range's own start so the composition keeps the
        // original timeline — trim seconds stay meaningful against it.
        let assetRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let range = try await source.load(.timeRange).intersection(assetRange)
        try track.insertTimeRange(range, of: source, at: range.start)
        // A composition track starts out with an identity transform; carry the
        // recorded orientation over so the geometry pass sees the same source.
        track.preferredTransform = try await source.load(.preferredTransform)
        return composition
    }

    /// Shrinks a geometry result so its longest side fits `maximum`, scaling the
    /// transform to match so the frame still fills the render size.
    ///
    /// Dimensions are rounded to even numbers: H.264 and HEVC encode in 2×2
    /// chroma blocks, and odd sizes are rejected or padded by some encoders.
    func scaled(_ geometry: (transform: CGAffineTransform, renderSize: CGSize),
                toFit maximum: CGFloat?) -> (transform: CGAffineTransform, renderSize: CGSize) {
        let size = geometry.renderSize
        let longest = max(size.width, size.height)
        guard let maximum, maximum > 0, longest > maximum else {
            return (geometry.transform, CGSize(width: even(size.width), height: even(size.height)))
        }
        let k = maximum / longest
        return (geometry.transform.concatenating(CGAffineTransform(scaleX: k, y: k)),
                CGSize(width: even(size.width * k), height: even(size.height * k)))
    }

    /// Rounds to the nearest even value, never below 2.
    private func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded() * 2)
    }

    /// Computes the layer-instruction transform (mapping source track pixels into
    /// the render frame) and the render size, for the recipe's flip/rotation/crop.
    ///
    /// Works in the oriented, top-left-origin space AVFoundation uses for video
    /// composition. Operations are composed left-to-right (apply-then), starting
    /// from `preferred`.
    func geometryTransform(recipe: EditRecipe,
                           preferred: CGAffineTransform,
                           orientedSize: CGSize) -> (transform: CGAffineTransform, renderSize: CGSize) {
        let w = orientedSize.width, h = orientedSize.height
        let cx = w / 2, cy = h / 2

        var a = CGAffineTransform.identity

        // Flip about the oriented center.
        if recipe.flip.horizontal || recipe.flip.vertical {
            a = a.concatenating(CGAffineTransform(translationX: -cx, y: -cy))
            a = a.concatenating(CGAffineTransform(scaleX: recipe.flip.horizontal ? -1 : 1,
                                                  y: recipe.flip.vertical ? -1 : 1))
            a = a.concatenating(CGAffineTransform(translationX: cx, y: cy))
        }

        // Rotate about the oriented center. The composition space is y-down, so a
        // positive angle is clockwise — matching the recipe's convention.
        if recipe.rotation.degrees != 0 {
            a = a.concatenating(CGAffineTransform(translationX: -cx, y: -cy))
            a = a.concatenating(CGAffineTransform(rotationAngle: recipe.rotation.radians))
            a = a.concatenating(CGAffineTransform(translationX: cx, y: cy))
        }

        // Move the transformed bounding box back to the origin.
        let bounds = CGRect(x: 0, y: 0, width: w, height: h).applying(a)
        a = a.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let rotatedSize = CGSize(width: abs(bounds.width), height: abs(bounds.height))

        // Crop in the rotated/oriented space (top-left-origin normalized rect).
        let crop = recipe.crop?.rect ?? .full
        let cropX = crop.origin.x * rotatedSize.width
        let cropY = crop.origin.y * rotatedSize.height
        a = a.concatenating(CGAffineTransform(translationX: -cropX, y: -cropY))

        let renderSize = CGSize(width: (crop.size.width * rotatedSize.width).rounded(),
                                height: (crop.size.height * rotatedSize.height).rounded())

        return (preferred.concatenating(a), renderSize)
    }

    /// Exports `asset` with `recipe` applied (geometry + trim + audio removal) to
    /// `outputURL`, with `overlayImage`'s artwork composited over every frame,
    /// reporting progress in `0...1`. Throws `CancellationError` if the export is
    /// cancelled, or `ComposeError.exportFailed` on failure.
    ///
    /// The recipe's `drawing` and `overlays` aren't read here — the core has no
    /// way to rasterize text or PencilKit strokes. The turnkey editor renders them
    /// into `overlayImage`; a headless host renders its own, or leaves them out.
    ///
    /// - Parameters:
    ///   - asset: the video to export.
    ///   - recipe: the edits to apply: geometry, trim, and audio removal.
    ///   - outputURL: where to write the MPEG-4 file. Nothing may exist there yet.
    ///   - preset: the encoding to use.
    ///   - maximumDimension: caps the longest side of the output, in pixels.
    ///     `nil` keeps the source resolution.
    ///   - onProgress: called on the main actor with the export's progress, from
    ///     0 to 1.
    ///   - overlayImage: artwork for the output frame; see
    ///     `makeVideoComposition(for:recipe:maximumDimension:overlayImage:)`. It
    ///     comes after `onProgress` so a trailing closure still means progress.
    @MainActor
    public func export(
        asset: AVAsset,
        recipe: EditRecipe,
        to outputURL: URL,
        preset: VideoExportPreset = .hevcHighQuality,
        maximumDimension: CGFloat? = nil,
        onProgress: ((Float) -> Void)? = nil,
        overlayImage: (@MainActor (_ renderSize: CGSize) -> CGImage?)? = nil
    ) async throws {
        // The geometry pass must read the tracks of whatever we hand the export
        // session, so build the (possibly audio-stripped) asset first.
        let exportAsset = try await makeExportAsset(for: asset, recipe: recipe)
        let videoComposition = try await makeVideoComposition(for: exportAsset, recipe: recipe,
                                                              maximumDimension: maximumDimension,
                                                              overlayImage: overlayImage)
        guard let session = AVAssetExportSession(asset: exportAsset, presetName: exportPresetName(for: preset)) else {
            throw ComposeError.exportSessionCreationFailed
        }
        session.videoComposition = videoComposition
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        if let trim = recipe.trim {
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: trim.start, preferredTimescale: 600),
                duration: CMTime(seconds: trim.duration, preferredTimescale: 600)
            )
        }

        let box = UnsafeSendableBox(session)

        // Poll progress on the main actor while the export runs.
        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                onProgress?(box.value.progress)
                let status = box.value.status
                if status != .waiting && status != .exporting { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { progressTask.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                box.value.exportAsynchronously {
                    switch box.value.status {
                    case .completed:
                        cont.resume()
                    case .cancelled:
                        cont.resume(throwing: CancellationError())
                    default:
                        cont.resume(throwing: ComposeError.exportFailed(
                            underlying: box.value.error?.localizedDescription))
                    }
                }
            }
        } onCancel: {
            box.value.cancelExport()
        }
        onProgress?(1)
    }

    /// Resolves a configuration preset to an `AVAssetExportSession` preset name.
    public func exportPresetName(for preset: VideoExportPreset) -> String {
        switch preset {
        case .hevcHighQuality: return AVAssetExportPresetHEVCHighestQuality
        case .h264HighQuality: return AVAssetExportPresetHighestQuality
        case .custom(let name): return name
        }
    }
}

/// Carries a non-`Sendable` reference across a concurrency boundary. Used only
/// for the export session, which is created and configured on the main actor and
/// whose status/progress are safe to read from its completion callback.
private final class UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
