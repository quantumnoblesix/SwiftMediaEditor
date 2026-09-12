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
    /// under the top bar rather than in the tool row.
    public var historySymbolPointSize: CGFloat = 15
    /// Opt out of Liquid Glass and use the blur material on every OS. Useful
    /// when a host wants one consistent look across iOS versions.
    public var prefersLiquidGlass: Bool = true

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

    /// The largest a bar title grows with Dynamic Type; the large content viewer
    /// takes over beyond it.
    nonisolated static let barTitleMaximumPointSize: CGFloat = 22

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
            // Glass titles follow Dynamic Type with no ceiling of their own; at the
            // accessibility sizes a two-word bar wrapped and swelled over the
            // preview. Keep the system's font, capped, on one line.
            config.titleLineBreakMode = .byTruncatingTail
            let ceiling = Self.barTitleMaximumPointSize
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                let font = incoming.uiKit.font ?? UIFont.preferredFont(forTextStyle: .body)
                outgoing.uiKit.font = font.withSize(min(font.pointSize, ceiling))
                return outgoing
            }
            if prominent {
                config.baseBackgroundColor = colour
            } else {
                config.baseForegroundColor = colour
            }
            button.configuration = config
        } else {
            button.setTitle(title, for: .normal)
            button.setTitleColor(colour, for: .normal)
            button.titleLabel?.font = EditorAccessibility.scaledFont(
                prominent ? .boldSystemFont(ofSize: 16) : .systemFont(ofSize: 15),
                textStyle: .body, maximumPointSize: Self.barTitleMaximumPointSize)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.lineBreakMode = .byTruncatingTail
        }
        // Past the cap, a long press shows the title at full size.
        button.showsLargeContentViewer = true
        button.largeContentTitle = title
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
        // A glyph can't grow with Dynamic Type; at accessibility text sizes a long
        // press shows the button in the large content viewer instead.
        button.showsLargeContentViewer = true
        button.largeContentTitle = action.localizedTitle
        button.largeContentImage = button.image(for: .normal)
        button.scalesLargeContentImage = true
        styleToolButton?(button, action)
    }

    /// Styles a symbol button that isn't tied to an action (the crop tool's
    /// reset control, the transport glyph). A symbol alone has no name: set the
    /// button's `accessibilityLabel` and `largeContentTitle` too.
    public func styleSymbolButton(_ button: UIButton, symbol: String, pointSize: CGFloat? = nil) {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize ?? toolSymbolPointSize, weight: .regular)
        button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        button.tintColor = tint
        button.showsLargeContentViewer = true
        button.largeContentImage = button.image(for: .normal)
        button.scalesLargeContentImage = true
    }
}

#endif
