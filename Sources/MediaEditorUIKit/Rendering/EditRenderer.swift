//
//  EditRenderer.swift
//  MediaEditorUIKit
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

// The turnkey editor UI is UIKit-based, so it builds for iOS and Mac
// Catalyst. On platforms without UIKit this file compiles to nothing and
// hosts use `MediaEditorCore` directly.
#if canImport(UIKit)

import UIKit
import AVFoundation
import ImageIO
import MediaEditorCore

/// Renders `media + recipe` exactly as the editor's own save does, without the
/// editor — for sending in the background after a session that returned
/// recipes only, re-rendering a stored recipe, or drawing thumbnails.
///
/// It is the editor's save path: `MediaEditorViewController.finish()` calls it,
/// so the output matches pixel for pixel. Photos go through `PhotoRenderer` for
/// geometry and filter, then stickers, strokes and text are composited in
/// `EditRecipe.overlayLayers` order in one full-resolution pass. Videos go
/// through `VideoComposer` with the same artwork.
///
/// **Threading.** Decoding and the Core Image geometry pass run off the main
/// actor; compositing stickers and text needs UIKit drawing and runs on it.
///
/// **Memory.** A full-resolution render holds the source, the geometry pass
/// and the composite at once — hundreds of megabytes for a large photo. Render
/// items one after another, never in parallel.
@MainActor
public struct EditRenderer {

    /// Why a render failed — as opposed to being cancelled, which throws
    /// `CancellationError`.
    public enum RenderError: Error, Sendable {
        /// The source couldn't be read or decoded.
        case unreadableSource
        /// Rendering the edits failed.
        case renderFailed
    }

    /// Export settings for videos.
    public let configuration: EditorConfiguration

    private let imageResolver: ((ImageRef) -> UIImage?)?
    private let renderer = PhotoRenderer()
    private let composer = VideoComposer()
    private let overlayCompositor = OverlayCompositor()
    private let drawingCompositor = DrawingCompositor()
    private let artworkRenderer = VideoArtworkRenderer()

    /// - Parameters:
    ///   - configuration: the video export preset and size cap to use.
    ///   - images: looks up the picture for an image sticker. Needed for
    ///     recipes that reference sticker images by `ImageRef.id` alone; when it
    ///     returns `nil`, or isn't given, the image is decoded from
    ///     `ImageRef.data`.
    public init(configuration: EditorConfiguration = .default,
                images: ((ImageRef) -> UIImage?)? = nil) {
        self.configuration = configuration
        self.imageResolver = images
    }

    // MARK: - Photos

    /// The photo `finish()` would produce for `image` with `recipe`.
    public func renderPhoto(_ image: UIImage, recipe: EditRecipe) async throws -> UIImage {
        try await renderPhoto(source: .photo(image), recipe: recipe, images: stickerImages(for: recipe))
    }

    /// Renders a photo source at full resolution. `images` supplies the sticker
    /// pictures — the editor passes the ones it has already decoded.
    func renderPhoto(source: MediaSource, recipe: EditRecipe, images: [UUID: UIImage]) async throws -> UIImage {
        let upright = try await uprightImage(for: source, maxPixelSize: nil)
        return try await renderPhoto(upright: upright, recipe: recipe, images: images)
    }

    /// Renders an already-upright source — the editor's own decode.
    func renderPhoto(upright: CGImage, recipe: EditRecipe, images: [UUID: UIImage]) async throws -> UIImage {
        let renderer = self.renderer
        let geometry = await Task.detached(priority: .userInitiated) {
            renderer.renderGeometry(cgImage: upright, recipe: recipe)
        }.value
        try Task.checkCancellation()
        guard let geometry else { throw RenderError.renderFailed }
        return composite(base: UIImage(cgImage: geometry), recipe: recipe, images: images)
    }

    /// Stacks the edits onto a rendered base as on screen — the stickers under
    /// the strokes, the strokes, then the stickers over them — in one pass, so a
    /// large photo needs one output bitmap and one for the strokes.
    func composite(base: UIImage, recipe: EditRecipe, images: [UUID: UIImage]) -> UIImage {
        guard !recipe.overlays.isEmpty || recipe.drawing != nil else { return base }
        let canvas = base.size
        let pixels = CGSize(width: canvas.width * base.scale, height: canvas.height * base.scale)
        let strokes = recipe.drawing.flatMap { drawingCompositor.strokeImage(for: $0, outputSize: pixels) }
        let layers = recipe.overlayLayers

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = base.scale
        format.opaque = false
        let bounds = CGRect(origin: .zero, size: canvas)
        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            base.draw(in: bounds)
            overlayCompositor.draw(layers.belowDrawing, in: context.cgContext, canvas: canvas, images: images)
            strokes?.draw(in: bounds)
            overlayCompositor.draw(layers.aboveDrawing, in: context.cgContext, canvas: canvas, images: images)
        }
    }

    // MARK: - Videos

    /// The video `finish()` would produce, written to `outputURL`, which must not
    /// exist yet. Cancelling the calling task throws `CancellationError` and
    /// removes the partial file.
    public func exportVideo(at sourceURL: URL, recipe: EditRecipe, to outputURL: URL,
                            onProgress: ((Float) -> Void)? = nil) async throws {
        try await exportVideo(at: sourceURL, recipe: recipe, to: outputURL,
                              images: stickerImages(for: recipe), onProgress: onProgress)
    }

    func exportVideo(at sourceURL: URL, recipe: EditRecipe, to outputURL: URL,
                     images: [UUID: UIImage], onProgress: ((Float) -> Void)?) async throws {
        let artwork = artworkRenderer
        do {
            try await composer.export(
                asset: AVURLAsset(url: sourceURL), recipe: recipe, to: outputURL,
                preset: configuration.videoExportPreset,
                maximumDimension: configuration.maximumExportDimension,
                onProgress: onProgress,
                overlayImage: { size in
                    // Rendered at the output resolution, so text stays crisp.
                    artwork.render(drawing: recipe.drawing, overlays: recipe.overlays, images: images, size: size)
                })
        } catch {
            // A failed or cancelled export leaves a partial file nobody will read.
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    // MARK: - Session items

    /// Renders one session item: `nil` for passthrough content and for an
    /// identity recipe, which the host sends as the original. A video goes to a
    /// fresh file in the temporary directory, owned by the caller from here on.
    public func render(_ item: MediaEditorItem) async throws -> EditorOutput? {
        guard item.source.isEditable, !item.recipe.isIdentity else { return nil }
        return try await render(source: item.source, recipe: item.recipe,
                                images: stickerImages(for: item.recipe), onProgress: nil)
    }

    /// Renders any editable source, identity recipe included.
    func render(source: MediaSource, recipe: EditRecipe, images: [UUID: UIImage],
                onProgress: ((Float) -> Void)?) async throws -> EditorOutput? {
        switch source {
        case .photo, .photoFile:
            return .photo(try await renderPhoto(source: source, recipe: recipe, images: images))
        case let .video(url):
            let output = Self.temporaryVideoURL()
            try await exportVideo(at: url, recipe: recipe, to: output, images: images, onProgress: onProgress)
            return .video(output)
        case .passthrough:
            return nil
        }
    }

    /// Where a video export goes: a fresh file in the temporary directory.
    static func temporaryVideoURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MediaEditor-\(UUID().uuidString).mp4")
    }

    // MARK: - Thumbnails

    /// A preview of `item` with its recipe applied, at most `maxPixelSize`
    /// pixels on its longest side — for strips and grids.
    ///
    /// Photos are downsampled before any rendering and videos use the frame at
    /// the trim's start, so nothing is decoded or rendered at source resolution.
    /// Passthrough items return their own thumbnail. `nil` if it can't be made.
    public func thumbnail(for item: MediaEditorItem, maxPixelSize: CGFloat) async -> UIImage? {
        await thumbnail(for: item, maxPixelSize: maxPixelSize, images: stickerImages(for: item.recipe))
    }

    func thumbnail(for item: MediaEditorItem, maxPixelSize: CGFloat, images: [UUID: UIImage]) async -> UIImage? {
        guard maxPixelSize >= 1 else { return nil }
        if case let .passthrough(thumbnail, _) = item.source {
            return thumbnail.map { Self.fitted($0, maxPixelSize: maxPixelSize) }
        }
        // A tight crop keeps only part of the frame, so decode a little more
        // than the target — but never the source itself.
        let decodeSize = maxPixelSize * Self.cropZoom(item.recipe)
        let source: CGImage?
        switch item.source {
        case let .video(url):
            source = await Self.frame(of: url, at: item.recipe.trim?.start ?? 0, maxPixelSize: decodeSize)
        default:
            source = try? await uprightImage(for: item.source, maxPixelSize: decodeSize)
        }
        guard let source else { return nil }
        let renderer = self.renderer
        let recipe = item.recipe
        guard let geometry = await Task.detached(priority: .utility, operation: {
            renderer.renderGeometry(cgImage: source, recipe: recipe)
        }).value else { return nil }
        let edited = composite(base: UIImage(cgImage: geometry), recipe: recipe, images: images)
        return Self.fitted(edited, maxPixelSize: maxPixelSize)
    }

    /// How much more of the source a thumbnail needs than its own size: the
    /// crop's zoom, capped so a sliver crop can't force a full decode.
    private static func cropZoom(_ recipe: EditRecipe) -> CGFloat {
        guard let crop = recipe.crop?.rect else { return 1 }
        let kept = max(0.01, min(crop.size.width, crop.size.height))
        return min(4, CGFloat(1 / kept))
    }

    /// `image` scaled down so its longest side is at most `maxPixelSize` pixels.
    private static func fitted(_ image: UIImage, maxPixelSize: CGFloat) -> UIImage {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(pixels.width, pixels.height)
        guard longest > maxPixelSize else { return image }
        let factor = maxPixelSize / longest
        let size = CGSize(width: max(1, (pixels.width * factor).rounded(.down)),
                          height: max(1, (pixels.height * factor).rounded(.down)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Sources

    /// The source as an upright bitmap — at full size, or downsampled so its
    /// longest side is at most `maxPixelSize`. Decoding runs off the main actor.
    func uprightImage(for source: MediaSource, maxPixelSize: CGFloat?) async throws -> CGImage {
        switch source {
        case let .photo(image):
            if maxPixelSize == nil {
                // Full size: the editor's own decode, so a save is pixel for
                // pixel what it was — wide colour included.
                guard let cgImage = image.normalizedUp().cgImage else { throw RenderError.unreadableSource }
                return cgImage
            }
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.upright(image, maxPixelSize: maxPixelSize)
            }.value
            guard let decoded else { throw RenderError.unreadableSource }
            return decoded
        case let .photoFile(url):
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.decodeUpright(url: url, maxPixelSize: maxPixelSize)
            }.value
            guard let decoded else { throw RenderError.unreadableSource }
            return decoded
        case .video, .passthrough:
            throw RenderError.unreadableSource
        }
    }

    /// Redraws `image` upright, optionally scaled down. Safe off the main
    /// thread: the format is built explicitly rather than from the traits.
    nonisolated private static func upright(_ image: UIImage, maxPixelSize: CGFloat?) -> CGImage? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let factor = maxPixelSize.map { min(1, $0 / max(pixels.width, pixels.height)) } ?? 1
        let size = CGSize(width: max(1, (pixels.width * factor).rounded()),
                          height: max(1, (pixels.height * factor).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    /// Decodes an image file upright through ImageIO — downsampled when
    /// `maxPixelSize` is given, which never decodes the full image.
    nonisolated static func decodeUpright(url: URL, maxPixelSize: CGFloat?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        var limit = maxPixelSize
        if limit == nil, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat {
            limit = max(width, height)                  // full size, still upright
        }
        guard let limit else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(limit.rounded(.up)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A video frame at `seconds`, upright and at most `maxPixelSize` across.
    nonisolated private static func frame(of url: URL, at seconds: Double, maxPixelSize: CGFloat) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// The sticker pictures `recipe` needs, from the resolver or the recipe's
    /// own data.
    func stickerImages(for recipe: EditRecipe) -> [UUID: UIImage] {
        var images: [UUID: UIImage] = [:]
        for overlay in recipe.overlays {
            guard case let .image(ref) = overlay.content, images[ref.id] == nil else { continue }
            if let image = imageResolver?(ref) ?? ref.data.flatMap(UIImage.init(data:)) {
                images[ref.id] = image
            }
        }
        return images
    }
}

#endif
