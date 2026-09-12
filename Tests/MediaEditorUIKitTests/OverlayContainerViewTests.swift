//
//  OverlayContainerViewTests.swift
//  MediaEditorUIKitTests
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
import Testing
@testable import MediaEditorUIKit
import MediaEditorCore

/// Records what the container reports to its host.
@MainActor
private final class ContainerSpy: OverlayContainerDelegate {
    private(set) var commits = 0
    private(set) var dragStates: [Bool] = []
    func overlayContainerDidCommit(_ container: OverlayContainerView) { commits += 1 }
    func overlayContainer(_ container: OverlayContainerView, requestsTextEditFor id: UUID) {}
    func overlayContainer(_ container: OverlayContainerView, didTapCanvasWithSelection hadSelection: Bool) {}
    func overlayContainer(_ container: OverlayContainerView, isDraggingSticker dragging: Bool) {
        dragStates.append(dragging)
    }
}

/// Stands in for the container, so a sticker's drag reporting can be checked alone.
@MainActor
private final class StickerSpy: StickerViewDelegate {
    var consumesDrop = false
    private(set) var commits = 0
    private(set) var drags: [CGPoint] = []
    private(set) var endsCancelled: [Bool] = []
    private(set) var deletes = 0
    func stickerViewDidCommit(_ sticker: StickerView) { commits += 1 }
    func stickerViewDidSelect(_ sticker: StickerView) {}
    func stickerViewDidRequestDelete(_ sticker: StickerView) { deletes += 1 }
    func stickerViewDidRequestTextEdit(_ sticker: StickerView) {}
    func stickerView(_ sticker: StickerView, didDragTo location: CGPoint) { drags.append(location) }
    func stickerView(_ sticker: StickerView, didEndDragAt location: CGPoint, cancelled: Bool) -> Bool {
        endsCancelled.append(cancelled)
        return consumesDrop
    }
}

@MainActor
@Suite("OverlayContainerView")
struct OverlayContainerViewTests {

    private func text(_ s: String) -> Overlay {
        Overlay(content: .text(TextStyle(string: s)))
    }

    @Test("reload reflects the overlays it is given")
    func reloadMatchesOverlays() {
        let container = OverlayContainerView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        container.imageFrame = CGRect(x: 0, y: 0, width: 200, height: 200)

        container.reload(overlays: [text("A"), text("B")], images: [:])
        #expect(container.currentOverlays().count == 2)

        // Undo of an "add" restores the earlier overlay set — reload must drop
        // the removed sticker.
        container.reload(overlays: [text("A")], images: [:])
        #expect(container.currentOverlays().count == 1)

        // Undo back to empty removes all stickers.
        container.reload(overlays: [], images: [:])
        #expect(container.currentOverlays().isEmpty)
    }

    // MARK: - Delete bin

    /// A container showing one text sticker, with a host spy attached.
    private func containerWithSticker() throws -> (OverlayContainerView, StickerView, ContainerSpy) {
        let container = OverlayContainerView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        container.imageFrame = container.bounds
        let spy = ContainerSpy()
        container.delegate = spy
        container.reload(overlays: [text("A")], images: [:])
        let sticker = try #require(container.subviews.compactMap { $0 as? StickerView }.first)
        return (container, sticker, spy)
    }

    @Test("Moving a sticker summons the bin; dropping it elsewhere keeps the sticker")
    func dragSummonsBinAndMissKeepsSticker() throws {
        let (container, sticker, spy) = try containerWithSticker()
        #expect(!container.isTrashVisible)

        container.stickerView(sticker, didDragTo: CGPoint(x: 40, y: 40))
        #expect(container.isTrashVisible)
        #expect(!container.isTrashArmed)
        #expect(spy.dragStates == [true])

        let consumed = container.stickerView(sticker, didEndDragAt: CGPoint(x: 40, y: 40), cancelled: false)
        #expect(!consumed)
        #expect(!container.isTrashVisible)
        #expect(container.currentOverlays().count == 1)
        #expect(spy.dragStates == [true, false])
        // A miss is an ordinary move, which the sticker commits itself.
        #expect(spy.commits == 0)
    }

    @Test("Hovering over the bin arms it; leaving disarms it")
    func hoverArmsAndLeavingDisarms() throws {
        let (container, sticker, _) = try containerWithSticker()
        container.stickerView(sticker, didDragTo: CGPoint(x: 40, y: 40))

        container.stickerView(sticker, didDragTo: container.trashCenter)
        #expect(container.isTrashArmed)
        #expect(sticker.alpha < 1, "the sticker should fade while it's about to be deleted")

        container.stickerView(sticker, didDragTo: CGPoint(x: 40, y: 40))
        #expect(!container.isTrashArmed)
        #expect(sticker.alpha == 1)
    }

    @Test("Releasing on the bin deletes the sticker as a single history step")
    func dropOnBinDeletes() throws {
        let (container, sticker, spy) = try containerWithSticker()
        container.stickerView(sticker, didDragTo: container.trashCenter)

        let consumed = container.stickerView(sticker, didEndDragAt: container.trashCenter, cancelled: false)
        #expect(consumed)
        #expect(container.currentOverlays().isEmpty)
        #expect(spy.commits == 1)
        #expect(container.selected == nil)
        #expect(!container.isTrashVisible)
    }

    @Test("An interrupted drag never deletes, even over the bin")
    func cancelledDragNeverDeletes() throws {
        let (container, sticker, spy) = try containerWithSticker()
        container.stickerView(sticker, didDragTo: container.trashCenter)

        let consumed = container.stickerView(sticker, didEndDragAt: container.trashCenter, cancelled: true)
        #expect(!consumed)
        #expect(container.currentOverlays().count == 1)
        #expect(spy.commits == 0)
        #expect(sticker.alpha == 1)
    }

    @Test("Arming needs the finger closer than disarming, so the edge doesn't flicker")
    func armingHasHysteresis() throws {
        let (container, sticker, _) = try containerWithSticker()
        let center = container.trashCenter
        let nearEdge = CGPoint(x: center.x, y: center.y - StickerTrashView.diameter * 0.9)

        container.stickerView(sticker, didDragTo: nearEdge)
        #expect(!container.isTrashArmed, "approaching, 0.9 × diameter is still outside")
        container.stickerView(sticker, didDragTo: center)
        container.stickerView(sticker, didDragTo: nearEdge)
        #expect(container.isTrashArmed, "once armed, the same spot must not disarm it")
    }

    @Test("The bin sits on the displayed media, not in the letterboxing")
    func binAnchorsToMedia() {
        let container = OverlayContainerView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        container.imageFrame = CGRect(x: 0, y: 120, width: 300, height: 160)
        let center = container.trashCenter
        #expect(center.x == 150)
        #expect(center.y > 120 && center.y < 280)
    }

    @Test("A host-chosen bin position wins, even outside the container's bounds")
    func preferredTrashCenterWins() throws {
        let (container, sticker, spy) = try containerWithSticker()
        // Below the 400pt-tall container, as a spot just above a toolbar would be.
        let spot = CGPoint(x: 150, y: 460)
        container.preferredTrashCenter = spot
        #expect(container.trashCenter == spot)

        container.stickerView(sticker, didDragTo: spot)
        #expect(container.isTrashArmed)
        #expect(container.stickerView(sticker, didEndDragAt: spot, cancelled: false))
        #expect(container.currentOverlays().isEmpty)
        #expect(spy.commits == 1)
    }

    @Test("Stickers carry no on-screen delete control — the bin replaces it")
    func stickerHasNoDeleteButton() {
        let sticker = StickerView(overlay: text("A"), image: nil)
        sticker.isSelected = true      // the old control only showed on selection
        sticker.applyLayout(canvasFrame: CGRect(x: 0, y: 0, width: 300, height: 400))
        #expect(!sticker.subviews.contains { $0 is UIButton })
    }

    @Test("VoiceOver, which can't drag to the bin, gets a localized Delete action")
    func voiceOverDeleteAction() throws {
        let sticker = StickerView(overlay: text("Hello"), image: nil)
        let spy = StickerSpy()
        sticker.delegate = spy

        #expect(sticker.isAccessibilityElement)
        #expect(sticker.accessibilityLabel == "Hello", "announced by its content")
        let delete = try #require(sticker.accessibilityCustomActions?.first { $0.name == L10n.delete })
        #expect(delete.actionHandler?(delete) == true)
        #expect(spy.deletes == 1)
    }

    @Test("The VoiceOver Delete action removes the sticker as one history step")
    func voiceOverDeleteRemovesSticker() throws {
        let (container, sticker, spy) = try containerWithSticker()
        let delete = try #require(sticker.accessibilityCustomActions?.first { $0.name == L10n.delete })
        _ = delete.actionHandler?(delete)
        #expect(container.currentOverlays().isEmpty)
        #expect(spy.commits == 1)
    }

    @Test("A drop the container consumes is not also committed as a move")
    func consumedDropSkipsMoveCommit() {
        let sticker = StickerView(overlay: text("A"), image: nil)
        let spy = StickerSpy()
        sticker.delegate = spy

        spy.consumesDrop = true
        sticker.emit(state: .changed, location: CGPoint(x: 10, y: 20))
        sticker.emit(state: .ended, location: CGPoint(x: 10, y: 20))
        #expect(spy.drags == [CGPoint(x: 10, y: 20)])
        #expect(spy.commits == 0, "the deletion is the history step; recording the move too would split it in two")

        spy.consumesDrop = false
        sticker.emit(state: .ended, location: .zero)
        #expect(spy.commits == 1)

        sticker.emit(state: .cancelled, location: .zero)
        #expect(spy.endsCancelled.last == true, "an interrupted gesture has to be reported as one")
    }
}

#endif
