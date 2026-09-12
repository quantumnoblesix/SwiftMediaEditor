# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- VoiceOver can do everything touch can. The straighten dial, crop frame and
  trim handles are adjustable with a swipe up or down. Stickers have actions to
  resize, rotate, move, edit and delete. Filters, text colours and aspect ratios
  are named and announce which one is selected. VoiceOver moves to a tool's title
  when it opens, the two-finger double-tap plays or pauses a video, and the
  escape gesture cancels an open tool.
- Reduce Motion replaces blooming and springing with fades, and Smart Invert
  leaves photos, video, thumbnails and stickers alone.
- Chrome text follows Dynamic Type, capped where a bar has fixed room, and icon
  buttons show in the large content viewer at accessibility sizes.
- The text colour swatches have 44-point touch targets, and the current colour
  gets a solid ring.

### Fixed

- VoiceOver and Switch Control users can pause a playing video: the play button
  no longer fades out of their reach during playback.
- At the largest text sizes, Cancel, Done, Apply and the aspect ratio buttons
  no longer wrap and swell over the preview: their titles stop growing at 22
  points, and a long press shows them in the large content viewer.

## [1.0.0] - 2026-09-12

The first public release.

### Added

#### Editor

- A turnkey photo and video editor for UIKit (`MediaEditorViewController`) and
  SwiftUI (`MediaEditorView`), on iOS 17 and Mac Catalyst 17.
- Undo/redo, and re-opening an edit from a saved recipe.
- Separate tool sets for photos and videos
  (`EditorConfiguration.photoTools` / `videoTools`).

#### Crop, rotation, and filters

- Crop with aspect presets — Original, Free, 1:1, 4:3, 16:9, and 9:16 by
  default, configurable through `EditorConfiguration.aspectPresets` — and a
  reset button.
- Free rotation with a straighten dial and 90° steps, plus horizontal and
  vertical flip, for photos and videos.
- Color filters for photos: Vivid, Mono, Noir, Fade, Chrome, Sepia, and Invert.
- Photos keep their EXIF orientation, and videos the orientation they were
  recorded in.

#### Drawing, text, and stickers

- PencilKit drawing and text, emoji, and image stickers on photos and videos,
  burned into the output.
- Stickers move with a drag, resize with a pinch, and rotate with two fingers —
  or resize and rotate with one finger using the corner handle. Double-tapping a
  text sticker edits it again.
- Text in six preset colors, or any color from the system color picker,
  including opacity.
- Image stickers from the system photo picker, which needs no photo library
  permission. The image is stored in the recipe, so a reopened edit keeps it.
- Drag a sticker onto the bin to delete it, with a haptic tap when it's over the
  bin.

#### Video

- Trimming on a filmstrip, a tap-to-play/pause preview, and an elapsed/total
  time readout.
- Audio track removal, offered only for videos that have audio.
- Export with a progress panel and cancellation, in HEVC, H.264, or any
  `AVAssetExportSession` preset, with an optional cap on output resolution. A
  failed export shows an alert and keeps the editor open.

#### Customization

- Styling through `EditorAppearance`: accent, tint, and delete colors, trimmer
  colors, replacement SF Symbols for any action, and per-button styling hooks.
  The chrome uses Liquid Glass on iOS 26, falls back to a blurred material on
  earlier versions, and can opt out of glass everywhere.
- Fully custom tool rows through `MediaEditorToolbarProviding`.
- Control from code: `perform(_:)`, `apply(_:)`, `isEnabled(_:)`, `isActive(_:)`,
  and the calls that open the crop, drawing, and filter tools.

#### Headless API

- `MediaEditorCore`: the non-destructive `EditRecipe` model, `EditHistory`
  undo/redo, `PhotoRenderer`, and `VideoComposer`. It also builds natively on
  macOS 14.
- Drawing and stickers can be burned into a video export through
  `VideoComposer`'s `overlayImage`, and rendered outside the editor with
  `MediaEditorUIKit`'s `OverlayCompositor` and `DrawingCompositor`.
- Recipes are `Codable`, and fields added later decode with defaults, so recipes
  saved with this version keep loading in future ones.

#### Accessibility and localization

- VoiceOver labels on the tool buttons, a play/pause button and time readout set
  up for VoiceOver, and a VoiceOver action to delete stickers.
- UI localized in English, Italian, French, Spanish, and Brazilian Portuguese.
  Apps can reword any string by defining the same key in their own
  `Localizable.strings`.

#### Distribution

- Privacy manifests for the core and UI modules.
- DocC documentation for each module.
- An example app with standard, branded, and fully custom editors.

### Known limitations

- Video exports that include drawing or stickers are processed in 8-bit, so an
  HDR source comes out SDR.
- On native macOS only `MediaEditorCore` is available; the editor UI runs on the
  Mac through Mac Catalyst.

[Unreleased]: https://github.com/quantumnoblesix/SwiftMediaEditor/compare/1.0.0...HEAD
[1.0.0]: https://github.com/quantumnoblesix/SwiftMediaEditor/releases/tag/1.0.0
