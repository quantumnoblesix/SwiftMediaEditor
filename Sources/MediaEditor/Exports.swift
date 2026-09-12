//
//  Exports.swift
//  MediaEditor
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

// Umbrella module for the turnkey editor. A single `import MediaEditor`
// re-exports the SwiftUI entry point, the UIKit editor, and the core model, so
// consumers don't need to know the internal target layout.

@_exported import MediaEditorCore
@_exported import MediaEditorUIKit
@_exported import MediaEditorSwiftUI
