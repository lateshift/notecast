//
//  FolderNameSheet.swift
//  NoteCast
//
//  Create and rename folder sheet.
//

import SwiftUI

/// Modal action for creating or renaming a folder.
enum FolderSheetMode: Identifiable {
    case create
    case rename(folderID: UUID, currentName: String)

    var id: String {
        switch self {
        case .create:
            return "create"
        case .rename(let folderID, _):
            return "rename-\(folderID.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .create:
            return "New Folder"
        case .rename:
            return "Rename Folder"
        }
    }

    var initialName: String {
        switch self {
        case .create:
            return ""
        case .rename(_, let currentName):
            return currentName
        }
    }

    var saveButtonTitle: String {
        switch self {
        case .create:
            return "Create"
        case .rename:
            return "Rename"
        }
    }
}

/// Small sheet used for folder names.
struct FolderNameSheet: View {
    let mode: FolderSheetMode
    let cancel: () -> Void
    let save: (String) -> Void

    @State private var name: String

    init(mode: FolderSheetMode, cancel: @escaping () -> Void, save: @escaping (String) -> Void) {
        self.mode = mode
        self.cancel = cancel
        self.save = save
        self._name = State(initialValue: mode.initialName)
    }

    private var canSave: Bool {
        NoteFolder.cleanName(name) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(mode.title)
                .font(.title2.bold())

            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(submit)

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(mode.saveButtonTitle, action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    private func submit() {
        guard canSave else { return }
        save(name)
    }
}
