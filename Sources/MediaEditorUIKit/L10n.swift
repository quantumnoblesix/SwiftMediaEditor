//
//  L10n.swift
//  MediaEditorUIKit
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import MediaEditorCore

/// Localized UI strings for the editor chrome, resolved from the package's own
/// bundle so translations ship with the library rather than the host app.
///
/// Shipped languages: English (base), Italian, French, Spanish, and Brazilian
/// Portuguese. A host app can override any of these by declaring the same key in
/// its own `Localizable.strings` — see the README.
enum L10n {

    /// The package's resource bundle holding the shipped translations.
    static let bundle: Bundle = .module

    /// Every key in the string table, used by tests to verify no language is
    /// missing a translation.
    static let allKeys = [
        "action.cancel", "action.done", "action.apply", "action.ok",
        "action.play", "action.pause", "action.undo", "action.redo", "action.delete",
        "tool.rotate", "tool.flip.horizontal", "tool.flip.vertical",
        "video.audio.remove", "video.audio.restore",
        "tool.crop.title", "tool.draw.title", "tool.filters.title",
        "crop.aspect.free", "crop.aspect.original",
        "overlay.add.text", "overlay.add.photo",
        "export.failed.title", "export.progress",
        "filter.original", "filter.vivid", "filter.mono", "filter.noir",
        "filter.fade", "filter.chrome", "filter.sepia", "filter.invert",
        "a11y.straighten", "a11y.crop.area", "a11y.crop.size", "a11y.move.up",
        "a11y.move.down", "a11y.move.left", "a11y.move.right", "a11y.sticker.bigger",
        "a11y.sticker.smaller", "a11y.sticker.rotate.left", "a11y.sticker.rotate.right", "a11y.sticker.edit",
        "a11y.deleted", "a11y.trim.start", "a11y.trim.end", "a11y.playback.position",
        "a11y.playback.time", "a11y.time.of", "a11y.canvas", "crop.reset",
        "text.field", "text.color.more", "color.white", "color.black",
        "color.red", "color.yellow", "color.blue", "color.green",
    ]

    /// Languages shipped with the package.
    static let supportedLanguages = ["en", "it", "fr", "es", "pt-BR"]

    /// Sentinel returned by `Bundle` when a key is absent, so we can tell
    /// "missing" apart from a legitimate empty translation.
    private static let missing = "\u{0}AME.missing"

    private static func string(_ key: String, _ comment: String) -> String {
        // Host apps may override any string by declaring the same key in their
        // own Localizable.strings; fall back to the package's translations.
        let hostValue = Bundle.main.localizedString(forKey: key, value: missing, table: nil)
        if hostValue != missing { return hostValue }
        return NSLocalizedString(key, bundle: bundle, comment: comment)
    }

    // Common actions
    static var cancel: String { string("action.cancel", "Dismisses without saving") }
    static var done: String { string("action.done", "Confirms and saves") }
    static var apply: String { string("action.apply", "Applies the current tool's edit") }
    static var ok: String { string("action.ok", "Acknowledges an alert") }
    static var undo: String { string("action.undo", "Reverts the last edit") }
    static var redo: String { string("action.redo", "Reapplies a reverted edit") }
    static var delete: String { string("action.delete", "Removes a sticker or text overlay") }

    // Video playback + audio
    static var play: String { string("action.play", "Starts video playback") }
    static var pause: String { string("action.pause", "Pauses video playback") }
    static var removeAudio: String { string("video.audio.remove", "Drops the video's audio track") }
    static var restoreAudio: String { string("video.audio.restore", "Brings the video's audio track back") }

    // Tool titles
    static var cropTitle: String { string("tool.crop.title", "Title of the crop tool") }
    static var drawTitle: String { string("tool.draw.title", "Title of the drawing tool") }
    static var filtersTitle: String { string("tool.filters.title", "Title of the filters tool") }
    static var rotate: String { string("tool.rotate", "Rotates 90 degrees clockwise") }
    static var flipHorizontal: String { string("tool.flip.horizontal", "Mirrors left-to-right") }
    static var flipVertical: String { string("tool.flip.vertical", "Mirrors top-to-bottom") }

    /// The display name of a filter, e.g. "Original", "Mono".
    static func filterName(_ filter: PhotoFilter) -> String {
        switch filter {
        case .none:   return string("filter.original", "The unfiltered original")
        case .vivid:  return string("filter.vivid", "Vivid color filter")
        case .mono:   return string("filter.mono", "Monochrome filter")
        case .noir:   return string("filter.noir", "High-contrast black & white filter")
        case .fade:   return string("filter.fade", "Faded filter")
        case .chrome: return string("filter.chrome", "Chrome filter")
        case .sepia:  return string("filter.sepia", "Sepia filter")
        case .invert: return string("filter.invert", "Inverted colors filter")
        }
    }

    // Crop aspect presets ("1:1", "16:9" etc. are numeric and not translated)
    static var aspectFree: String { string("crop.aspect.free", "Unconstrained crop aspect ratio") }
    static var aspectOriginal: String { string("crop.aspect.original", "The source's own aspect ratio") }

    // Add-overlay menu
    static var addText: String { string("overlay.add.text", "Adds a text overlay") }
    static var addPhoto: String { string("overlay.add.photo", "Adds an image overlay") }

    // Video export
    static var exportFailedTitle: String { string("export.failed.title", "Alert title when export fails") }

    /// Export progress, e.g. "Exporting… 42%".
    static func exportProgress(percent: Int) -> String {
        String(format: string("export.progress", "Export progress; %d is the percentage"), percent)
    }

    // Accessibility: names, values and actions VoiceOver speaks
    static var straighten: String { string("a11y.straighten", "VoiceOver name of the straighten dial") }
    static var cropArea: String { string("a11y.crop.area", "VoiceOver name of the crop frame") }

    /// The crop frame's size, e.g. "80% of the width, 60% of the height".
    static func cropSize(widthPercent: Int, heightPercent: Int) -> String {
        String(format: string("a11y.crop.size",
                              "Crop frame size; %1$d and %2$d are percentages of the width and height"),
               widthPercent, heightPercent)
    }

    static var moveUp: String { string("a11y.move.up", "VoiceOver action moving the crop frame or a sticker up") }
    static var moveDown: String { string("a11y.move.down", "VoiceOver action moving the crop frame or a sticker down") }
    static var moveLeft: String { string("a11y.move.left", "VoiceOver action moving the crop frame or a sticker left") }
    static var moveRight: String { string("a11y.move.right", "VoiceOver action moving the crop frame or a sticker right") }
    static var makeBigger: String { string("a11y.sticker.bigger", "VoiceOver action enlarging a sticker") }
    static var makeSmaller: String { string("a11y.sticker.smaller", "VoiceOver action shrinking a sticker") }
    static var rotateLeft: String {
        string("a11y.sticker.rotate.left", "VoiceOver action rotating a sticker counterclockwise")
    }
    static var rotateRight: String { string("a11y.sticker.rotate.right", "VoiceOver action rotating a sticker clockwise") }
    static var editText: String { string("a11y.sticker.edit", "VoiceOver action reopening a text sticker for editing") }
    static var deleted: String { string("a11y.deleted", "Spoken after a sticker is deleted") }
    static var trimStart: String { string("a11y.trim.start", "VoiceOver name of the trimmer's start handle") }
    static var trimEnd: String { string("a11y.trim.end", "VoiceOver name of the trimmer's end handle") }
    static var playbackPosition: String { string("a11y.playback.position", "VoiceOver name of the trimmer's playhead") }
    static var playbackTime: String {
        string("a11y.playback.time", "VoiceOver name of the elapsed / total time readout")
    }

    /// Elapsed against total time, e.g. "2.5 seconds of 10.0 seconds".
    static func timeOf(elapsed: String, total: String) -> String {
        String(format: string("a11y.time.of", "Elapsed against total time; %1$@ is elapsed, %2$@ is total"),
               elapsed, total)
    }

    static var drawingCanvas: String { string("a11y.canvas", "VoiceOver name of the drawing area") }
    static var resetCrop: String { string("crop.reset", "Resets the crop frame and straightening") }

    // Text editor
    static var textField: String { string("text.field", "VoiceOver name of the text being typed") }
    static var moreColors: String { string("text.color.more", "Opens the full color picker") }
    static var colorWhite: String { string("color.white", "Text color swatch") }
    static var colorBlack: String { string("color.black", "Text color swatch") }
    static var colorRed: String { string("color.red", "Text color swatch") }
    static var colorYellow: String { string("color.yellow", "Text color swatch") }
    static var colorBlue: String { string("color.blue", "Text color swatch") }
    static var colorGreen: String { string("color.green", "Text color swatch") }
}
