# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The first public release, to be tagged `0.1.0`.

### Added

- A turnkey photo and video editor for UIKit (`MediaEditorViewController`) and
  SwiftUI (`MediaEditorView`), on iOS 17 and Mac Catalyst 17.
- `MediaEditorCore`, the headless half: the non-destructive `EditRecipe` model,
  `EditHistory` undo/redo, `PhotoRenderer`, and `VideoComposer`. It also builds
  natively on macOS 14.
- Crop with aspect presets, including the source's own ratio; free rotation with
  a straighten dial and 90° steps; horizontal and vertical flip — for photos and
  videos.
- Color filters for photos.
- PencilKit drawing and text, emoji and image stickers on photos and videos,
  burned into the output. Drag a sticker onto the bin to delete it.
- Video trimming on a filmstrip, a tap-to-play/pause preview, an elapsed/total
  time readout, and audio track removal.
- Video export with progress and cancellation, in HEVC or H.264, with an
  optional cap on output resolution.
- Undo/redo, and re-opening an edit from a saved recipe.
- Separate tool sets for photos and videos
  (`EditorConfiguration.photoTools` / `videoTools`).
- Styling through `EditorAppearance` — Liquid Glass on iOS 26, with a fallback on
  earlier versions — and fully custom tool rows through
  `MediaEditorToolbarProviding`.
- UI localized in English, Italian, French, Spanish, and Brazilian Portuguese.
- A VoiceOver action to delete stickers.
- Privacy manifests for the core and UI modules.
- DocC documentation for each module.

### Known limitations

- Video exports that include drawing or stickers are processed in 8-bit, so an
  HDR source comes out SDR.
- On native macOS only `MediaEditorCore` is available; the editor UI runs on the
  Mac through Mac Catalyst.
