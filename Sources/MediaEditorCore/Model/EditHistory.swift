//
//  EditHistory.swift
//  MediaEditorCore
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// A bounded undo/redo stack over an editable value.
///
/// Because an `EditRecipe` is a small value type, history is just a list of
/// snapshots with a cursor: `undo`/`redo` move the cursor, and `push` records a
/// new state, discarding any redo branch. Generic over `State` so it can be
/// unit-tested with simple values, but typically used as `EditHistory<EditRecipe>`.
public struct EditHistory<State: Equatable & Sendable>: Sendable {
    private var snapshots: [State]
    private var cursor: Int
    /// Maximum number of states retained; older states are dropped past this.
    public let limit: Int

    public init(initial: State, limit: Int = 50) {
        precondition(limit >= 1, "History limit must be at least 1")
        self.snapshots = [initial]
        self.cursor = 0
        self.limit = limit
    }

    /// The state at the current cursor position.
    public var current: State { snapshots[cursor] }

    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < snapshots.count - 1 }

    /// Records a new state. No-op if equal to `current` (avoids redundant
    /// entries from idempotent edits). Discards any redo branch.
    public mutating func push(_ state: State) {
        guard state != current else { return }
        if canRedo {
            snapshots.removeSubrange((cursor + 1)...)
        }
        snapshots.append(state)
        if snapshots.count > limit {
            snapshots.removeFirst(snapshots.count - limit)
        }
        cursor = snapshots.count - 1
    }

    /// Moves back one state and returns it, or `nil` if at the oldest state.
    @discardableResult
    public mutating func undo() -> State? {
        guard canUndo else { return nil }
        cursor -= 1
        return current
    }

    /// Moves forward one state and returns it, or `nil` if at the newest state.
    @discardableResult
    public mutating func redo() -> State? {
        guard canRedo else { return nil }
        cursor += 1
        return current
    }
}
