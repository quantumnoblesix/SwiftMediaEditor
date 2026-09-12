//
//  EditHistoryTests.swift
//  MediaEditorCoreTests
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import Testing
@testable import MediaEditorCore

@Suite("EditHistory")
struct EditHistoryTests {

    @Test("Starts with no undo/redo available")
    func initialState() {
        let history = EditHistory(initial: 0)
        #expect(history.current == 0)
        #expect(!history.canUndo)
        #expect(!history.canRedo)
    }

    @Test("Push then undo/redo walks the stack")
    func pushUndoRedo() {
        var history = EditHistory(initial: 0)
        history.push(1)
        history.push(2)
        #expect(history.current == 2)
        #expect(history.canUndo)
        #expect(!history.canRedo)

        #expect(history.undo() == 1)
        #expect(history.undo() == 0)
        #expect(history.undo() == nil)   // at oldest
        #expect(history.current == 0)

        #expect(history.redo() == 1)
        #expect(history.canRedo)
    }

    @Test("Pushing equal state is a no-op")
    func pushEqualIsNoop() {
        var history = EditHistory(initial: 7)
        history.push(7)
        #expect(!history.canUndo)
    }

    @Test("Push after undo discards the redo branch")
    func pushDiscardsRedoBranch() {
        var history = EditHistory(initial: 0)
        history.push(1)
        history.push(2)
        _ = history.undo()        // back to 1
        history.push(99)          // branch from 1
        #expect(history.current == 99)
        #expect(!history.canRedo) // old "2" is gone
        #expect(history.undo() == 1)
    }

    @Test("History respects its size limit")
    func respectsLimit() {
        var history = EditHistory(initial: 0, limit: 3)
        for value in 1...10 { history.push(value) }
        #expect(history.current == 10)
        // Only the last 3 states retained: 8, 9, 10.
        #expect(history.undo() == 9)
        #expect(history.undo() == 8)
        #expect(history.undo() == nil)
    }
}
