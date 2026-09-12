//
//  EditorConfiguration.swift
//  MediaEditorCore
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// The kind of media an editor session works on.
public enum MediaKind: Sendable, Hashable, CaseIterable {
    case photo
    case video
}

/// Which editing tools are surfaced in the turnkey editor UI. Lets a host trim
/// the editor down to, say, crop + trim only — separately for photos and videos,
/// through `EditorConfiguration.photoTools` and `videoTools`.
public struct EditorTools: OptionSet, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let crop      = EditorTools(rawValue: 1 << 0)
    public static let rotate    = EditorTools(rawValue: 1 << 1)
    public static let flip      = EditorTools(rawValue: 1 << 2)
    public static let drawing   = EditorTools(rawValue: 1 << 3)  // PencilKit
    public static let overlays  = EditorTools(rawValue: 1 << 4)  // text/emoji/image
    public static let trim      = EditorTools(rawValue: 1 << 5)  // videos only
    public static let filters   = EditorTools(rawValue: 1 << 6)  // photos only
    public static let audio     = EditorTools(rawValue: 1 << 7)  // videos only

    /// Every tool available for photos.
    public static let allPhoto: EditorTools = [.crop, .rotate, .flip, .filters, .drawing, .overlays]
    /// Every tool available for videos.
    public static let allVideo: EditorTools = [.crop, .rotate, .flip, .drawing, .overlays, .trim, .audio]
    /// Every tool, regardless of media kind. The UI hides ones that don't apply.
    public static let all: EditorTools = [.crop, .rotate, .flip, .filters, .drawing, .overlays, .trim, .audio]

    /// Every tool that can work on `kind`.
    public static func available(for kind: MediaKind) -> EditorTools {
        switch kind {
        case .photo: return .allPhoto
        case .video: return .allVideo
        }
    }
}

/// Output encoding for an exported video.
public enum VideoExportPreset: Sendable {
    /// HEVC (H.265) — smaller files, modern devices.
    case hevcHighQuality
    /// H.264 — broadest compatibility.
    case h264HighQuality
    /// Pass an explicit `AVAssetExportSession` preset name.
    case custom(String)
}

/// Configuration for a turnkey editor session. UI-framework agnostic so it can
/// live in Core and be shared by both the UIKit and SwiftUI entry points.
public struct EditorConfiguration: Sendable {
    /// Tools offered when the editor opens a photo. Tools that can't work on a
    /// photo — trim, audio — are ignored.
    public var photoTools: EditorTools
    /// Tools offered when the editor opens a video. Tools that can't work on a
    /// video — filters — are ignored.
    public var videoTools: EditorTools

    /// One tool set for photos and videos alike.
    ///
    /// Setting it assigns both `photoTools` and `videoTools`; reading it returns
    /// every tool enabled for either. Set those two directly to choose the tools
    /// for each kind of media independently.
    public var tools: EditorTools {
        get { photoTools.union(videoTools) }
        set {
            photoTools = newValue
            videoTools = newValue
        }
    }

    /// Aspect-ratio presets offered in the crop tool.
    public var aspectPresets: [AspectPreset]
    /// Video export encoding.
    public var videoExportPreset: VideoExportPreset
    /// Caps the longest side of an exported video, in pixels. `nil` keeps the
    /// source resolution.
    ///
    /// Re-encoding a 4K clip at full resolution is a long, thermally expensive
    /// job — the single heaviest thing this package asks of a device — and most
    /// destinations never need those pixels. Capping to 1080p or 720p is the
    /// most effective lever for older hardware.
    public var maximumExportDimension: CGFloat?
    /// Undo/redo history depth.
    public var historyLimit: Int

    public init(
        photoTools: EditorTools = .allPhoto,
        videoTools: EditorTools = .allVideo,
        aspectPresets: [AspectPreset] = [.original, .free, .square, .ratio(width: 4, height: 3),
                                         .ratio(width: 16, height: 9), .ratio(width: 9, height: 16)],
        videoExportPreset: VideoExportPreset = .hevcHighQuality,
        maximumExportDimension: CGFloat? = nil,
        historyLimit: Int = 50
    ) {
        self.photoTools = photoTools
        self.videoTools = videoTools
        self.aspectPresets = aspectPresets
        self.videoExportPreset = videoExportPreset
        self.maximumExportDimension = maximumExportDimension
        self.historyLimit = historyLimit
    }

    /// The tools the editor offers for `kind`: that kind's configured set, less
    /// any tool that can't work on it.
    public func tools(for kind: MediaKind) -> EditorTools {
        switch kind {
        case .photo: return photoTools.intersection(.available(for: .photo))
        case .video: return videoTools.intersection(.available(for: .video))
        }
    }

    public static let `default` = EditorConfiguration()
}
