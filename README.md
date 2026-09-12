# MediaEditor

A native, dependency-free media editor for iOS — edit **photos** and **videos**
with the same non-destructive engine, usable from both **UIKit** and **SwiftUI**.

> Current release: **1.0.0**. See the [changelog](CHANGELOG.md) for what's included.

## Features

| | Photos | Videos |
|---|:---:|:---:|
| Crop (aspect presets + straighten dial) | ✅ | ✅ |
| Rotation (free + 90°/180°) | ✅ | ✅ |
| Flip horizontal / vertical | ✅ | ✅ |
| Color filters (Mono, Noir, Chrome, Fade…) | ✅ | — |
| Timeline trim | — | ✅ |
| Playback time and duration readout | — | ✅ |
| Remove the audio track | — | ✅ |
| Tap-to-play/pause preview | — | ✅ |
| PencilKit drawing | ✅ | ✅ |
| Overlays: text, emoji, images | ✅ | ✅ |
| Drag a sticker onto the bin to delete it | ✅ | ✅ |
| Undo / redo | ✅ | ✅ |
| Re-editing from a saved recipe | ✅ | ✅ |
| VoiceOver, Switch Control, Dynamic Type, Reduce Motion | ✅ | ✅ |

Built entirely on Apple frameworks — Core Image, Core Graphics, PencilKit, and
AVFoundation. No third-party dependencies.

The table above describes the turnkey editor UI, which is iOS and Mac Catalyst.
Everything it does is driven by `MediaEditorCore`, which is UI-free and builds
natively on macOS as well — see [Requirements](#requirements).

## Requirements

| | Minimum | What you get |
|---|---|---|
| iOS | 17 | Everything — turnkey editor UI + headless core |
| Mac Catalyst | 17 | Everything — the UIKit editor runs as-is |
| macOS (native) | 14 | `MediaEditorCore` only — the headless model and renderers |

**To build:** Xcode 26 / Swift 6.3. The manifest declares
`swift-tools-version: 6.3`, and the default chrome uses iOS 26's Liquid Glass
APIs (behind `#available`, so it still *runs* on iOS 17).

The editor UI is UIKit-based, so on native macOS the UI targets compile to
nothing and `MediaEditorCore` is what you import — the non-destructive
`EditRecipe`, `PhotoRenderer`, and `VideoComposer` all build and run there. Host
a full editor UI on macOS by shipping your app as Mac Catalyst.

## Localization

The editor's UI strings ship with the package in **English** (base), **Italian**,
**French**, **Spanish**, and **Brazilian Portuguese**, resolved from the
package's own bundle — no setup required.

> **Note:** a library's translations only surface if the **host app supports that
> language**. Add the language to your app (an `<lang>.lproj` folder, or an entry
> under the target's localizations); otherwise iOS falls back to English. The
> example app ships all five for this reason.

To reword anything, declare the same key in your app's `Localizable.strings` —
host values win over the package's:

```
"action.done" = "Save";
"tool.crop.title" = "Trim";
```

Keys are listed in `L10n.allKeys`.

## Accessibility

The editor works with VoiceOver and Switch Control from end to end, and every
gesture has an equivalent. The straighten dial, crop frame and trim handles are
adjustable with a swipe up or down, and stickers offer actions to resize, rotate,
move, edit and delete. A two-finger double-tap plays or pauses a video, and the
two-finger scrub backs out of an open tool.

It also respects Reduce Motion, Smart Invert and Dynamic Type; icon buttons show
in the large content viewer at accessibility text sizes.

## Appearance & custom toolbars

The chrome adopts **iOS 26 Liquid Glass** by default: floating bars render with
`UIGlassEffect` and bar actions use the glass / prominent-glass button
configurations, falling back to a dark blur material with plain tinted titles on
iOS 17–25.

The chrome is laid out as three groups: **Cancel** and an **undo/redo** pill at
the top left, **Done** at the top right, and a single centred row of *tools* at
the bottom that hugs its content. Keeping history out of the tool row is what
lets that row stay one uncrowded line — three or four glyphs, not six.

Customization comes in two tiers — restyle what the package draws, or replace
the tool row outright.

### Restyling — `EditorAppearance`

A value type you hand to the editor. Tints, glyphs, corner radii, and a per-button
hook for anything else:

```swift
var appearance = EditorAppearance()
appearance.accent = .systemTeal          // Done / Apply, and "on" toggles
appearance.tint = .white                 // everything else
appearance.symbols[.crop] = "crop"       // swap any action's SF Symbol
appearance.destructive = .systemPink     // the sticker delete bin
appearance.trimColor = .systemGreen      // the video trimmer (nil follows accent)
appearance.prefersLiquidGlass = false    // one look across all OS versions
appearance.styleToolButton = { button, action in
    button.layer.cornerRadius = 8        // applied after the built-in styling
}

MediaEditorView(item: .video(url), appearance: appearance) { _ in }
```

### Replacing the toolbar — `MediaEditorToolbarProviding`

When restyling isn't enough, supply the row yourself. The editor keeps providing
the behaviour; you own the view:

```swift
final class MyToolbar: NSObject, MediaEditorToolbarProviding {
    private var buttons: [EditorAction: UIButton] = [:]

    func makeToolbar(for actions: [EditorAction],
                     editor: MediaEditorViewController) -> UIView? {
        let row = UIStackView()
        for action in actions {                        // already filtered by
            let button = UIButton(type: .system)       // config + media kind
            button.setTitle(action.localizedTitle, for: .normal)
            button.addAction(UIAction { [weak editor] _ in
                editor?.perform(action)                // ← run it
            }, for: .touchUpInside)
            buttons[action] = button
            row.addArrangedSubview(button)
        }
        return row
    }

    func updateToolbar(_ toolbar: UIView, editor: MediaEditorViewController) {
        for (action, button) in buttons {              // ← reflect state
            button.isEnabled = editor.isEnabled(action)
            button.tintColor = editor.isActive(action) ? .systemTeal : .white
        }
    }
}
```

The editor exposes everything a custom row needs:

| | |
|---|---|
| `toolbarActions` | the actions to draw, already filtered by configuration and media kind |
| `EditorAction` | `localizedTitle` and `defaultSymbolName` for each one |
| `perform(_:)` | run an action exactly as the built-in chrome would |
| `isEnabled(_:)` | undo/redo history, whether the source has an audio track… |
| `isActive(_:)` | which tool is open, whether a toggle is engaged |

`updateToolbar(_:editor:)` fires on every state change. Return `nil` from
`makeToolbar` to keep the built-in bar, and implement
`hidesToolbarInToolMode(_:)` to stay visible while crop or drawing is open.

`toolbarActions` deliberately omits `.undo` and `.redo` — they live in the top
bar and stay there even behind a custom row, so you get history for free. A
custom row can still show its own: `perform(.undo)` and `isEnabled(.undo)` work
either way.

The example app's **Branded Editor** screen demonstrates both tiers together —
see `BrandedToolbar.swift`.

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/quantumnoblesix/SwiftMediaEditor.git", from: "1.0.0")
```

then add the product to your target — SwiftPM names the package after the
repository:

```swift
.product(name: "MediaEditor", package: "SwiftMediaEditor")
```

Two products:

- **`MediaEditor`** — turnkey editor (SwiftUI + UIKit) plus the core.
- **`MediaEditorCore`** — headless, UI-free model and renderers only.

## Usage

### SwiftUI

```swift
import MediaEditor

MediaEditorView(item: .photo(image)) { result in
    switch result {
    case let .saved(output, recipe):
        // persist `output`; store `recipe` to re-open later
    case .cancelled:
        break
    }
}
```

### UIKit

```swift
let editor = MediaEditorViewController(item: .video(url)) { result in
    // handle result
}
present(editor, animated: true)
```

### Choosing tools

Photos and videos take separate tool sets, so each can be trimmed down on its
own. By default each gets every tool it supports.

```swift
var configuration = EditorConfiguration()
configuration.photoTools = [.crop, .filters, .drawing, .overlays]
configuration.videoTools = [.trim, .audio, .overlays]      // no crop or drawing on videos

let editor = MediaEditorViewController(item: .video(url), configuration: configuration) { result in
    // handle result
}
```

`MediaEditorView` takes the same `configuration:` argument. A tool that can't
work on a kind of media — filters on a video, trim on a photo — is ignored, and
`configuration.tools = [...]` sets one list for both.

### Headless

Use `EditRecipe` + `PhotoRenderer` / `VideoComposer` directly to apply edits
without any UI — useful for batch processing or re-rendering a stored recipe.

## Performance

The editor is built to stay cheap on older hardware:

- **Previews render at display resolution, not source resolution.** Editing
  re-renders on every change, so a 12 MP photo would otherwise push ~50 MB
  through Core Image each time to fill a ~2 MP view. Full resolution is used
  only for the final render on save, where it matters. Crop and drawing
  geometry are stored normalized, so nothing about the output changes.
- **Overlay edits skip the re-render.** Stickers composite as live views over
  the preview, so dragging one needs no new bitmap
  (`EditRecipe.rendersDifferently(from:)`).
- **The playback tick idles.** The video display link is paused while nothing is
  playing and runs at ~15 Hz otherwise, rather than tracking a ProMotion 120 Hz.
- **Recipes compare by identity.** `ImageRef` is equal by `id`, so undo/redo
  pushes don't `memcmp` multi-megabyte image payloads.
- **Picked images are downscaled and encoded off the main thread.**

For video, the single heaviest operation is the export. Cap it:

```swift
EditorConfiguration(maximumExportDimension: 1920)   // nil keeps source resolution
```

Re-encoding 4K at full resolution is long and thermally expensive; most
destinations never need those pixels. Render dimensions are always rounded to
even numbers, which the H.264 and HEVC encoders require.

## Architecture

Three layers, each its own SwiftPM target:

- **`MediaEditorCore`** — the non-destructive `EditRecipe` model, undo/redo
  history, and the Core Image / AVFoundation renderers. No UIKit.
- **`MediaEditorUIKit`** — the editor view controller, custom tool surfaces, and
  overlay/drawing rasterization.
- **`MediaEditorSwiftUI`** — a thin `UIViewControllerRepresentable` wrapper so
  both UI frameworks share one editor.

Only `MediaEditorCore` is platform-independent. The two UI targets are wrapped in
`#if canImport(UIKit)`, so on native macOS they compile to empty modules and the
package still builds, tests, and ships — you just get the headless half.

The design principle is **non-destructive editing**: user interaction produces a
`Codable` `EditRecipe`, and rendering is `originalMedia + recipe → output`. This
makes undo/redo, persistence, and re-editing trivial and keeps the photo and
video pipelines symmetric. The DocC articles go deeper — see
[Documentation](#documentation).

## Documentation

Each module ships a DocC catalog — `MediaEditorCore`, `MediaEditorUIKit`, and
`MediaEditorSwiftUI` — with articles on getting started, configuring the editor,
customizing its look, and editing without the UI. In Xcode, choose
**Product ▸ Build Documentation**, or from the command line:

```sh
xcodebuild docbuild -scheme MediaEditor-Package -destination 'generic/platform=iOS Simulator'
```

Both modules also ship a privacy manifest (`PrivacyInfo.xcprivacy`): the package
collects no data, does no tracking, and uses none of Apple's required-reason APIs.

## Example app

A runnable SwiftUI demo lives in [`Examples/`](Examples). It generates a sample
image and opens the turnkey editor.

```sh
open Examples/MediaEditorExample.xcodeproj
# select the MediaEditorExample scheme + an iOS Simulator, then Run
```

Or from the command line:

```sh
xcodebuild -project Examples/MediaEditorExample.xcodeproj -scheme MediaEditorExample \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

The demo is structured with **MVVM + a Coordinator** and walks a multi-screen
flow:

1. **Media selection** — pick a source (sample image/video, library, or camera).
2. **Editor choice** — the turnkey **Standard** editor, a **Branded** editor
   showing the appearance and custom-toolbar APIs, or a **Custom** editor
   built entirely on the package's headless API (`PhotoRenderer` + `EditRecipe`
   plus Core Image filters). Choosing Custom first shows a **checklist** to pick
   which tools the editor should offer.
3. **Editing** — the standard editor exercises crop, rotate, flip, overlays
   (text / emoji / photo), and PencilKit drawing on both photos and videos, plus
   filters for photos and trim / audio removal for videos; the custom editor
   offers rotate / flip / filters with its own undo/redo.
4. **Result** — a final preview whose back button returns to the editor, which
   resumes from the saved recipe.

A shared session tracks the modified media across the flow. The UI is localized
in all five supported languages.

## Testing

The full suite runs on an iOS simulator, where the UIKit tool surfaces exist:

```sh
xcodebuild -scheme MediaEditor-Package -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The platform-independent half — the model, both renderers, and localization —
also runs natively on macOS with plain SwiftPM, which is the quicker loop:

```sh
swift test
```

## Roadmap

1. ✅ Foundation — package, `EditRecipe` model, renderers, tests
2. ✅ Photo tools — crop, rotate, flip with live preview + example app
3. ✅ Overlays (text / emoji / image) + PencilKit drawing
4. ✅ Video core — geometry (rotate/flip/crop) + trim export with progress
5. ✅ Trim UI — filmstrip scrubber + live AVPlayer preview
6. ✅ Video crop tool + play/pause transport + audio removal
7. ✅ Overlays and drawing on video, burned in on export by a Core Image
   video compositor
8. ✅ Release 1.0.0 — Apache-2.0 license, macOS support, theming and a
   custom-toolbar API, DocC documentation, privacy manifests

Photos and videos are feature-complete. Video supports the crop tool (aspect
presets, straighten dial, rotate/flip), drawing, text and stickers, timeline
trim, and audio removal, all with export.

### Video preview

The preview applies the recipe's geometry with a `CALayer` transform rather than
an `AVPlayerItem.videoComposition`. That keeps the preview cheap, and it works in
the iOS Simulator — routing preview playback through *any* video composition
renders a black frame there, Apple's own
`AVMutableVideoComposition(propertiesOf:)` included. Export still goes through
`VideoComposer`, and the two share the same geometry math.

Drawing and stickers follow the same split. On screen they're ordinary views
over the player; on export they're rasterized once at the output resolution and
composited over every frame by a small Core Image video compositor. The usual
tool for the job, `AVVideoCompositionCoreAnimationTool`, crashes the iOS
Simulator. Frames that carry drawing or stickers are processed as 8-bit, so an
HDR source exported with them comes out SDR; exports without them are untouched.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before making any change — it holds the
rules and patterns the package is built on.

## License

[Apache License 2.0](LICENSE). Copyright 2026 Emanuele Corona. Every source
file carries an `SPDX-License-Identifier: Apache-2.0` header.
