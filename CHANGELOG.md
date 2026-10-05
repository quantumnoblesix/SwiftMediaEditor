# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2026-10-05

### Added

- Pinch to zoom on photos and videos, up to 4×, with stickers, text and
  drawing zooming along. A one-finger drag pans zoomed media, a double tap
  zooms in on the tapped spot or back out, and the media can't be moved past
  its own edges. Photos re-render at the zoomed resolution so they stay sharp.
  With a sticker selected, a pinch still resizes the sticker. Zoom resets on
  switching items and on opening crop, drawing or filters. Passthrough content
  keeps its own gestures. A single tap on the canvas now waits briefly to rule
  out a double tap.

### Changed

- Moving between a session's items now pages tab-view style. Dragging on empty
  canvas carries the media with the finger while the neighbouring item slides
  in beside it, and the drag settles on the page it reaches past halfway, or
  the next one for a flick. Past the first or last item it rubber-bands.
  Tapping a strip thumbnail slides that item in from its side. The next and
  previous items are rendered at screen size ahead of time, so they slide in
  sharp. An incoming video slides in exactly where it will sit, and the
  transport, filmstrip and time readout fade out for the turn and back in with
  the item it lands on. `allowsSwipeBetweenItems` still turns the drag off.

### Fixed

- Passthrough content (a PDF, a GIF) no longer squashes the canvas to a few
  points with the bottom accessory stretched over the freed space. A hosting
  view reports its SwiftUI content's ideal size, and the canvas could lose to
  it. Passthrough content now yields to the layout the way the image preview
  does, and the accessory holds its content height.

## [1.2.0] - 2026-10-05

### Added

#### Multi-item sessions

- `MediaEditorViewController(items:selectedItemID:…)` and
  `MediaEditorView(items:selection:…)` edit several photos and videos as one
  session — the pre-send screen of a chat app. A thumbnail strip above the
  bottom accessory moves between them; each item keeps its own edits and undo
  history. The strip's cells show each item's current edits, and a video's
  trimmed duration.
- `MediaEditorItem` and `MediaSource`: a session's items can be decoded photos,
  photo files (decoded at full size only while selected), videos, or
  passthrough content the editor can't edit — a GIF, a document — shown with
  the host's own view and no tools.
- `select(_:)`, `remove(_:)`, `insert(_:at:)`, and `onSelectionChange`,
  `onItemsChange`, `onRecipeChange` and `onAddItems` on the editor; the SwiftUI
  view keeps its `items` and `selection` bindings in step both ways. Removing
  the last item ends the session with `.cancelled`.
- In the strip, tapping the selected thumbnail arms it and a second tap removes
  the item; an optional "+" cell asks the host for more; long-press-and-drag
  reorders when `EditorAppearance.allowsReordering` is on; VoiceOver gets
  custom actions for all of it. A swipe on empty canvas pages between items
  (`allowsSwipeBetweenItems`).
- `EditorAppearance` strip options: `thumbnailSize`, `thumbnailCornerRadius`,
  `thumbnailSpacing`, `thumbnailStripBackground` (none by default),
  `hidesThumbnailStripWithKeyboard`, `allowsReordering`,
  `allowsSwipeBetweenItems` and `styleThumbnailCell`.
- `EditorConfiguration.finishMode`: `.render` renders every edited item behind
  the progress panel ("Exporting 2 of 5"); `.recipesOnly` hands back the
  recipes at once, for the host to render after closing the screen. A session
  ends with `MediaEditorSessionResult`, one `MediaEditorItemResult` per item.
- `MediaEditorProxy` gains `recipe`, `isToolActive`, `items`,
  `selectedItemID`, `select(_:)` and `remove(_:)`; the editor gains
  `isToolActive` and `tearDown()`.

#### Rendering without the editor

- `EditRenderer` renders `media + recipe` exactly as the editor's own save does
  — the editor now goes through it — for sending in the background, re-rendering
  a stored recipe, or drawing thumbnails: `renderPhoto`, `exportVideo`,
  `render(_:)` and `thumbnail(for:maxPixelSize:)`. Decoding and the Core Image
  pass run off the main actor; thumbnails never touch source resolution. An
  optional image resolver supplies sticker pictures stored by id alone, and
  failures throw `EditRenderer.RenderError`, distinct from cancellation.

### Changed

- While the keyboard is up, the space reserved for the bottom accessory holds
  still: a bar that grows as the user types draws over the media instead of
  shrinking it.

### Fixed

- Cancelling a video export the moment it starts no longer crashes with an
  AVFoundation exception.
- An editor dismissed or swapped out — say, by SwiftUI — pauses its video, and
  `MediaEditorView` tears it down, cancelling any export, instead of leaving
  playback running until it deallocated.
- A large photo can no longer squash a bottom accessory sized by its content.

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

[1.3.0]: https://github.com/quantumnoblesix/SwiftMediaEditor/compare/1.2.0...1.3.0
[1.2.0]: https://github.com/quantumnoblesix/SwiftMediaEditor/compare/1.1.0...1.2.0
[1.1.0]: https://github.com/quantumnoblesix/SwiftMediaEditor/compare/1.0.0...1.1.0
[1.0.0]: https://github.com/quantumnoblesix/SwiftMediaEditor/releases/tag/1.0.0
