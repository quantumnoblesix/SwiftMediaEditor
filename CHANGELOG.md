# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-10-05

### Added

#### Chat-style layout and a host bottom bar

- `EditorAppearance.toolbarPlacement` puts the tool row at the top or the
  bottom (`EditorToolbarPlacement`), and `toolbarStyle` draws it as one glass
  bar or as a circular button per tool (`EditorToolbarStyle`). With circular
  buttons, Cancel becomes an ✕ and undo/redo get matching circles;
  `circularButtonDiameter` sizes them.
- `EditorAppearance.messaging`: the layout of a chat app's pre-send editor —
  an ✕ and circular tools across the top, leaving the bottom free for a
  caption bar.
- A host-supplied bottom bar — `bottomAccessory:` on `MediaEditorViewController`,
  and a `bottomAccessory` view builder on `MediaEditorView` that receives a
  `MediaEditorProxy` to drive the editor. Typically a caption field and a send
  button. It runs to the bottom edge with its content kept above the home
  indicator, rides up with the keyboard, and hides while a tool is open.
  With one installed, the editor shows no Done button of its own
  (`showsDoneButton`): the bar's send action calls `finish()`.

#### Editing model

- The drawing has a stacking position among the stickers
  (`DrawingData.zIndex`, `Overlay.sitsAboveDrawing(at:)`,
  `EditRecipe.overlayLayers`, `EditRecipe.nextZIndex`). New strokes go over the
  picture stickers already placed, a sticker added afterwards goes over the
  strokes, and text always stays on top. The preview, photo export and video
  export all follow it. Recipes saved with 1.0 load and render as before.
- `MediaGeometry` and `EditRecipe.carryingOverlays(from:sourceSize:)` map edits
  between a recipe's cropped, rotated output and the original media, so they
  can follow the media through a geometry change.
- `NormalizedRect.isClose(to:tolerance:)`.

### Changed

- The editor is always dark, whatever the system appearance — including what
  it presents (text editor, photo and colour pickers, alerts), the PencilKit
  tool palette, and the host's toolbar and bottom bar. Pencil ink keeps its
  true colours on the canvas, in the palette's swatches and in the result,
  instead of PencilKit's dark-mode adaptation.
- Stickers and the drawing stay on the part of the media they were placed on
  when it's cropped, rotated or flipped, instead of moving with the frame. A
  flip mirrors where a sticker sits without mirroring its text. Anything a crop
  cuts away is kept, hidden, and comes back if the crop is widened.
- The crop tool shows the stickers and drawing on the whole media, dimmed where
  the crop leaves them out. They fade out while the crop is being adjusted and
  return once the change is done. Filters stay visible while cropping.
- The pencil draws in place among the stickers — over picture stickers, under
  text — with every other edit still in view.
- Undo and redo appear once there is something to undo, and hide while a tool
  is open.
- `EditRecipe.rendersDifferently(from:)` no longer counts the drawing, which is
  now a live layer over the preview rather than baked into it — so adding
  strokes, or undoing them, no longer re-renders the photo.
- Saving a photo with edits composites everything in one full-resolution pass,
  using less peak memory than before.

### Fixed

- Opening the crop tool and applying without a change no longer records an
  undo step, and four quarter turns no longer leave a 360° rotation.

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

[Unreleased]: https://github.com/quantumnoblesix/SwiftMediaEditor/compare/1.1.0...HEAD
[1.1.0]: https://github.com/quantumnoblesix/SwiftMediaEditor/compare/1.0.0...1.1.0
[1.0.0]: https://github.com/quantumnoblesix/SwiftMediaEditor/releases/tag/1.0.0
