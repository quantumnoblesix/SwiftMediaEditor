//
//  PhotoFilter.swift
//  MediaEditorCore
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// A color filter applied to the whole photo, à la the iOS Photos Filters tab.
/// Backed by Core Image built-in effects; `PhotoRenderer` maps each case to a
/// `CIFilter`.
public enum PhotoFilter: String, Codable, Sendable, CaseIterable {
    case none
    case vivid
    case mono
    case noir
    case fade
    case chrome
    case sepia
    case invert
}
