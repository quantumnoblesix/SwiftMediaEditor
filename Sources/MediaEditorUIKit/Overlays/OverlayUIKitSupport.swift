//
//  OverlayUIKitSupport.swift
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
import MediaEditorCore

extension RGBAColor {
    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

extension TextAlignment {
    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }
}

extension TextStyle {
    /// The font for this style at a given canvas height (in points or pixels).
    /// Size is a fraction of canvas height so text scales with output resolution.
    func font(canvasHeight: CGFloat) -> UIFont {
        let size = max(1, CGFloat(fontSizeFraction) * canvasHeight)
        if let name = fontName, let font = UIFont(name: name, size: size) {
            return font
        }
        return .systemFont(ofSize: size, weight: .semibold)
    }

    /// Attributed-string attributes for rendering, shared by the interactive
    /// label and the export compositor so preview and output match.
    func attributes(canvasHeight: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment.nsTextAlignment
        return [
            .font: font(canvasHeight: canvasHeight),
            .foregroundColor: color.uiColor,
            .paragraphStyle: paragraph,
        ]
    }

    /// The intrinsic (scale = 1) size of the rendered text for a canvas height.
    func intrinsicSize(canvasHeight: CGFloat) -> CGSize {
        let text = string.isEmpty ? " " : string
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes(canvasHeight: canvasHeight),
            context: nil
        )
        // A little horizontal padding so glyphs aren't clipped.
        return CGSize(width: ceil(bounds.width) + 12, height: ceil(bounds.height) + 6)
    }
}

#endif
