//
//  NoteBrowserEditorCommandBridge.swift
//  NoteCast
//
//  Small bridge from the editor's local draft state to browser-level commands.
//

import Combine
import Foundation

/// Exposes the active editor's Save/Revert actions to menu and palette code.
///
/// The editor owns draft text, title, and folder state locally, which is the
/// right place for those values. The command palette lives one level higher.
/// This bridge keeps that boundary simple: the editor publishes whether its
/// commands are available and hands over tiny closures for the active note.
@MainActor
final class NoteBrowserEditorCommandBridge: ObservableObject {
    @Published private(set) var canSave = false
    @Published private(set) var canRevert = false

    private var saveHandler: () -> Void = {}
    private var revertHandler: () -> Void = {}

    func update(
        canSave: Bool,
        canRevert: Bool,
        save: @escaping () -> Void,
        revert: @escaping () -> Void
    ) {
        self.canSave = canSave
        self.canRevert = canRevert
        self.saveHandler = save
        self.revertHandler = revert
    }

    func reset() {
        canSave = false
        canRevert = false
        saveHandler = {}
        revertHandler = {}
    }

    func save() {
        guard canSave else { return }
        saveHandler()
    }

    func revert() {
        guard canRevert else { return }
        revertHandler()
    }
}
