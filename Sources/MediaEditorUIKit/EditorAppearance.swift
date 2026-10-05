//
//  EditorAppearance.swift
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

/// Where the editor's tool row sits.
public enum EditorToolbarPlacement: Hashable, Sendable {
    /// In the top bar, trailing the close button — the layout chat apps use for
    /// their pre-send editor. The Done button, when the editor shows one, moves
    /// to the bottom trailing corner.
    case top
    /// Floating at the bottom, just above the bottom accessory when there is one.
    case bottom
}

/// How the tool row's buttons are drawn.
public enum EditorToolbarStyle: Hashable, Sendable {
    /// Plain glyphs sharing one floating bar.
    case floatingBar
    /// Each glyph on its own circular backing, with an ✕ glyph for Cancel and
    /// undo/redo in circles of their own — the look of a chat app's media
    /// editor.
    case circularButtons
}

/// How the editor's chrome looks.
///
/// Hand one to `MediaEditorViewController` to restyle the built-in bars and
/// buttons without rebuilding them. The defaults adopt iOS 26's Liquid Glass —
/// floating bars use `UIGlassEffect` and bar actions use the glass button
/// configurations — and fall back to a dark blur material with plain tinted
/// titles on iOS 17–25, so one code path reads correctly on every supported OS.
///
/// ```swift
/// var appearance = EditorAppearance()
/// appearance.accent = .systemPink
/// appearance.symbols[.crop] = "crop"
/// appearance.styleToolButton = { button, _ in
///     button.backgroundColor = .darkGray
///     button.layer.cornerRadius = 8
/// }
/// ```
///
/// To replace the tool row wholesale rather than restyle it, implement
/// ``MediaEditorToolbarProviding`` instead.
@MainActor
public struct EditorAppearance {

    /// Tint for ordinary chrome — tool glyphs and the dismissing bar action.
    public var tint: UIColor = .white
    /// Tint for the confirming bar action (Done / Apply) and for toggles that
    /// are currently on, such as a muted audio track.
    public var accent: UIColor = .systemYellow
    /// Colour for destructive affordances — the sticker delete bin fills with it
    /// while a sticker is held over it.
    public var destructive: UIColor = .systemRed
    /// Colour of the video trimmer's frame and edge handles. `nil` follows
    /// `accent`, so a host that recolours its accent gets a matching trimmer.
    public var trimColor: UIColor?
    /// Colour of the chevrons on the trimmer's edge handles. `nil` picks black or
    /// white — whichever stays legible on the trim colour.
    public var trimHandleIconColor: UIColor?
    /// Corner radius of the floating tool row.
    public var toolbarCornerRadius: CGFloat = 28
    /// Point size of the tool-row glyphs.
    public var toolSymbolPointSize: CGFloat = 19
    /// Point size of the undo/redo glyphs, which sit on their own smaller pill
    /// under the top bar rather than in the tool row. Under
    /// ``EditorToolbarStyle/circularButtons`` they get a circle each, sized like
    /// the tool row's, and use ``toolSymbolPointSize`` instead.
    public var historySymbolPointSize: CGFloat = 15
    /// Opt out of Liquid Glass and use the blur material on every OS. Useful
    /// when a host wants one consistent look across iOS versions.
    public var prefersLiquidGlass: Bool = true
    /// Where the tool row sits. A host-supplied row from
    /// ``MediaEditorToolbarProviding`` follows this too.
    public var toolbarPlacement: EditorToolbarPlacement = .bottom
    /// How the built-in tool row draws its buttons.
    public var toolbarStyle: EditorToolbarStyle = .floatingBar
    /// Diameter of each button under ``EditorToolbarStyle/circularButtons``.
    public var circularButtonDiameter: CGFloat = 44

    // MARK: Thumbnail strip

    /// Side of each square cell in a multi-item session's thumbnail strip.
    public var thumbnailSize: CGFloat = 56
    /// Corner radius of the strip's cells.
    public var thumbnailCornerRadius: CGFloat = 8
    /// Gap between the strip's cells.
    public var thumbnailSpacing: CGFloat = 8
    /// Fill behind the strip, edge to edge. `nil` — the default — leaves the
    /// cells on the editor's own black.
    public var thumbnailStripBackground: UIColor?
    /// Fade the strip out while the keyboard is up, so whatever the bottom
    /// accessory grows upward while typing — a list of suggestions, say — has
    /// the room. The space it takes stays reserved, so nothing behind it moves.
    public var hidesThumbnailStripWithKeyboard: Bool = true
    /// Let the user reorder items by long-pressing and dragging a thumbnail.
    public var allowsReordering: Bool = false
    /// Let a horizontal drag on empty canvas page to the next or previous item,
    /// tab-view style: the media follows the finger with its neighbour sliding
    /// in beside it, and settles on whichever page the drag — or a flick —
    /// reaches. A drag that starts on a sticker still moves the sticker.
    public var allowsSwipeBetweenItems: Bool = true
    /// Applied to every strip cell after the built-in styling, with the item
    /// it shows and whether it's selected — to re-skin cells in place.
    public var styleThumbnailCell: ((UIView, MediaEditorItem, _ isSelected: Bool) -> Void)?

    /// Per-action glyph overrides. Anything absent falls back to
    /// ``EditorAction/defaultSymbolName``.
    public var symbols: [EditorAction: String] = [:]

    /// Applied to every tool-row button after the built-in styling, so a host
    /// can adjust or completely re-skin the buttons in place.
    public var styleToolButton: ((UIButton, EditorAction) -> Void)?

    /// Applied to every bar button (Cancel / Done / Apply) after the built-in
    /// styling.
    public var styleBarButton: ((UIButton, EditorBarButtonRole) -> Void)?

    public init() {}

    /// The stock appearance.
    public static var `default`: EditorAppearance { EditorAppearance() }

    /// The layout of a chat app's pre-send editor: an ✕ and a row of circular
    /// tool buttons across the top, leaving the bottom free for a caption bar
    /// passed as the editor's `bottomAccessory`.
    public static var messaging: EditorAppearance {
        var appearance = EditorAppearance()
        appearance.toolbarPlacement = .top
        appearance.toolbarStyle = .circularButtons
        appearance.toolSymbolPointSize = 18
        return appearance
    }

    /// Whether Liquid Glass will actually be used: the OS provides it *and*
    /// the host hasn't opted out.
    public var usesLiquidGlass: Bool {
        guard prefersLiquidGlass else { return false }
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// The glyph to draw for `action`.
    public func symbolName(for action: EditorAction) -> String? {
        symbols[action] ?? action.defaultSymbolName
    }

    // MARK: - Building blocks

    /// A rounded background for a floating bar (tool row, aspect bar, HUD panel).
    public func makeBarBackground(cornerRadius: CGFloat) -> UIVisualEffectView {
        if #available(iOS 26.0, *), prefersLiquidGlass {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true                    // fluid, touch-reactive glass
            let view = UIVisualEffectView(effect: glass)
            // The editor is always dark, and glass has to be told directly: the
            // style it inherits isn't applied when a bar is shown again after a
            // tool, so it comes back light and only darkens a moment later.
            view.overrideUserInterfaceStyle = .dark
            // Let the glass supply its own continuous-rounded shape rather than
            // clipping to a plain corner radius (keeps the fluid edges).
            view.cornerConfiguration = .corners(radius: .fixed(cornerRadius))
            return view
        } else {
            let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
            view.layer.cornerRadius = cornerRadius
            view.layer.cornerCurve = .continuous
            view.clipsToBounds = true
            return view
        }
    }

    /// Styles a bar text button (Cancel / Done / Apply). The confirming role
    /// becomes a tinted prominent glass capsule on iOS 26.
    public func styleBarButton(_ button: UIButton, title: String, role: EditorBarButtonRole) {
        let prominent = role == .confirming
        let colour = prominent ? accent : tint
        if #available(iOS 26.0, *), prefersLiquidGlass {
            var config = prominent
                ? UIButton.Configuration.prominentGlass()
                : UIButton.Configuration.glass()
            config.title = title
            if prominent {
                config.baseBackgroundColor = colour
            } else {
                config.baseForegroundColor = colour
            }
            button.configuration = config
            button.overrideUserInterfaceStyle = .dark   // see `makeBarBackground`
        } else {
            button.setTitle(title, for: .normal)
            button.setTitleColor(colour, for: .normal)
            button.titleLabel?.font = prominent ? .boldSystemFont(ofSize: 16) : .systemFont(ofSize: 15)
        }
        styleBarButton?(button, role)
    }

    /// Styles a symbol tool button. These sit *inside* a glass bar, so they stay
    /// plain on every OS — the glass comes from the bar behind them.
    /// - Parameters:
    ///   - button: the button to style.
    ///   - action: the action it runs, which picks its glyph and accessibility
    ///     label.
    ///   - pointSize: overrides ``toolSymbolPointSize`` for buttons that aren't in
    ///     the tool row, such as the smaller undo/redo pair.
    public func styleToolButton(_ button: UIButton, action: EditorAction, pointSize: CGFloat? = nil) {
        if let symbol = symbolName(for: action) {
            let config = UIImage.SymbolConfiguration(pointSize: pointSize ?? toolSymbolPointSize, weight: .regular)
            button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        }
        button.tintColor = tint
        button.accessibilityLabel = action.localizedTitle
        styleToolButton?(button, action)
    }

    /// Seats `button` on a circular backing — Liquid Glass where available, the
    /// dark blur otherwise — for ``EditorToolbarStyle/circularButtons``.
    ///
    /// Returns the backing, which is what goes into the layout; the button fills
    /// it. Hide the backing, not the button, to take it out of a row.
    public func makeCircularBacking(for button: UIButton) -> UIView {
        let diameter = circularButtonDiameter
        let backing = makeBarBackground(cornerRadius: diameter / 2)
        backing.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        backing.contentView.addSubview(button)
        NSLayoutConstraint.activate([
            backing.widthAnchor.constraint(equalToConstant: diameter),
            backing.heightAnchor.constraint(equalToConstant: diameter),
            button.leadingAnchor.constraint(equalTo: backing.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: backing.contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: backing.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: backing.contentView.bottomAnchor),
        ])
        return backing
    }

    /// Styles a symbol button that isn't tied to an action (the crop tool's
    /// reset control, the transport glyph).
    public func styleSymbolButton(_ button: UIButton, symbol: String, pointSize: CGFloat? = nil) {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize ?? toolSymbolPointSize, weight: .regular)
        button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        button.tintColor = tint
    }
}

#endif
