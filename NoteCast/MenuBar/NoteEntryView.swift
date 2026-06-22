//
//  NoteEntryView.swift
//  NoteCast
//
//  SwiftUI note creation/editing view plus a tiny AppKit text editor wrapper.
//

import AppKit
import SwiftData
import SwiftUI

struct NoteEntryView: View {
    @Environment(\.modelContext) private var modelContext

    private let note: Note?
    private let didSave: () -> Void
    private let didAddNote: (NoteAddedNotificationPayload) -> Void
    private let close: () -> Void

    @State private var title: String
    @State private var text: String
    @State private var errorMessage: String?

    init(
        note: Note?,
        didSave: @escaping () -> Void = {},
        didAddNote: @escaping (NoteAddedNotificationPayload) -> Void = { _ in },
        close: @escaping () -> Void
    ) {
        self.note = note
        self.didSave = didSave
        self.didAddNote = didAddNote
        self.close = close
        self._title = State(initialValue: note?.displayTitle ?? "")
        self._text = State(initialValue: note?.text ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(note == nil ? "New Note" : "Edit Note")
                .font(.headline)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("NoteEntry.titleField")

            CommandReturnTextEditor(text: $text, onCommandReturn: save)
                .frame(minWidth: 620, minHeight: 290)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("NoteEntry.errorText")
            }

            HStack {
                Text("Press ⌘↩ to save")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Cancel") {
                    close()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("NoteEntry.cancelButton")

                Button("Save") {
                    save()
                }
                .accessibilityIdentifier("NoteEntry.saveButton")
            }
        }
        .padding(24)
    }

    private func save() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Write something before saving."
            return
        }

        var addedPayload: NoteAddedNotificationPayload?
        if let note {
            // Editing keeps the original creation metadata and only changes the
            // body, MIME type, and update timestamp.
            note.title = Note.cleanTitle(title) ?? Note.makeAutomaticTitle(createdAt: note.created_at)
            note.text = text
            note.mimetype = NotePersistence.defaultMimetype
            note.updated_at = .now
            note.repairMissingMetadataIfNeeded()
        } else {
            // New notes created from the app are marked as APP; the CLI uses
            // the same model but passes CLI instead.
            let newNote = Note(
                title: title,
                text: text,
                mimetype: NotePersistence.defaultMimetype,
                created_via: NotePersistence.createdViaApp
            )
            modelContext.insert(newNote)
            addedPayload = NoteAddedNotificationPayload(note: newNote)
        }

        do {
            try modelContext.save()
            didSave()
            if let addedPayload {
                didAddNote(addedPayload)
            }
            close()
        } catch {
            // `localizedDescription` can be too vague for SwiftData/Core Data
            // failures, so include Swift's full debug description in the UI.
            // That makes future save problems much easier to diagnose.
            errorMessage = "Could not save note: \(String(describing: error))"
        }
    }
}

/// A SwiftUI wrapper around `NSTextView`.
///
/// SwiftUI's built-in `TextEditor` is intentionally simple and does not expose
/// a direct "Command + Return was pressed" hook on macOS. `NSTextView` is the
/// native AppKit text editor, so wrapping it lets us keep normal multiline
/// editing while also catching ⌘↩ to save.
private struct CommandReturnTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onCommandReturn: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.setAccessibilityIdentifier("NoteEntry.scrollView")

        let textView = CommandReturnTextView()
        textView.string = text
        textView.delegate = context.coordinator
        textView.onCommandReturn = onCommandReturn
        textView.setAccessibilityIdentifier("NoteEntry.textView")

        // Plain text only: no rich text, no font runs. The note body stays a
        // simple String in SwiftData.
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        // Monospace font as requested for the entry text box.
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)

        // Make the text view wrap lines to the scroll view width and grow
        // vertically as the user types more lines.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Put the insertion point in the editor as soon as the window appears.
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        guard let textView = scrollView.documentView as? CommandReturnTextView else {
            return
        }

        textView.onCommandReturn = onCommandReturn

        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandReturnTextEditor
        weak var textView: NSTextView?

        init(parent: CommandReturnTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// NSTextView subclass that treats Command+Return and Command+Enter as Save.
private final class CommandReturnTextView: NSTextView {
    var onCommandReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isCommandReturn = event.modifierFlags.contains(.command)
            && (event.keyCode == 36 || event.keyCode == 76) // Return or keypad Enter

        if isCommandReturn {
            onCommandReturn?()
            return
        }

        super.keyDown(with: event)
    }
}
