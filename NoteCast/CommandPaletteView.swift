//
//  CommandPaletteView.swift
//  NoteCast
//
//  Keyboard-first command palette overlay.
//

import SwiftUI

/// Floating command palette shown over the main browser window.
struct CommandPaletteView: View {
    let notes: [Note]
    let folders: [NoteFolder]
    let context: CommandPaletteContext
    let perform: (CommandPaletteItem) -> Void
    let performSecondary: (CommandPaletteItem) -> Void
    let close: () -> Void

    @State private var query = ""
    @State private var selectedItemID: String?
    @FocusState private var isSearchFocused: Bool

    private var sections: [CommandPaletteSection] {
        CommandPaletteSearch.sections(
            notes: notes,
            folders: folders,
            query: query,
            context: context
        )
    }

    private var visibleItems: [CommandPaletteItem] {
        sections.flatMap(\.items)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            VStack(spacing: 0) {
                searchBar
                Divider()
                resultList
            }
            .frame(width: 620, height: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 24, y: 12)

            // SwiftUI TextField handles plain Return through `onSubmit`.
            // This invisible button gives the palette a normal command-key
            // shortcut for the secondary action without custom AppKit key code.
            Button(action: performSecondarySelectedItem) {
                EmptyView()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .opacity(0)
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
        }
        .onAppear {
            selectFirstEnabledItem()
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onChange(of: query) { _, _ in
            selectFirstEnabledItem()
        }
        .onChange(of: notes.map(\.stableID)) { _, _ in
            keepSelectionValid()
        }
        .onExitCommand(perform: close)
        .onMoveCommand(perform: moveSelection)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search notes and commands", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
                .onSubmit(performSelectedItem)
                .accessibilityIdentifier("CommandPalette.searchField")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var resultList: some View {
        if visibleItems.isEmpty {
            ContentUnavailableView("No Results", systemImage: "magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: selectedItemID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.10)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func sectionView(_ section: CommandPaletteSection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(section.title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            ForEach(section.items) { item in
                CommandPaletteRow(
                    item: item,
                    isSelected: item.id == selectedItemID
                ) {
                    perform(item)
                }
                .id(item.id)
            }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        switch direction {
        case .up:
            selectItem(offset: -1)
        case .down:
            selectItem(offset: 1)
        default:
            break
        }
    }

    private func performSelectedItem() {
        guard let selectedItem = visibleItems.first(where: { $0.id == selectedItemID }),
              selectedItem.isEnabled else { return }
        perform(selectedItem)
    }

    private func performSecondarySelectedItem() {
        guard let selectedItem = visibleItems.first(where: { $0.id == selectedItemID }),
              selectedItem.isEnabled else { return }
        performSecondary(selectedItem)
    }

    private func selectFirstEnabledItem() {
        selectedItemID = visibleItems.first(where: \.isEnabled)?.id
    }

    private func keepSelectionValid() {
        guard let selectedItemID,
              visibleItems.contains(where: { $0.id == selectedItemID && $0.isEnabled }) else {
            selectFirstEnabledItem()
            return
        }
    }

    private func selectItem(offset: Int) {
        let enabledItems = visibleItems.filter(\.isEnabled)
        guard !enabledItems.isEmpty else {
            selectedItemID = nil
            return
        }

        let currentIndex = enabledItems.firstIndex { $0.id == selectedItemID } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), enabledItems.count - 1)
        selectedItemID = enabledItems[nextIndex].id
    }
}

private struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isSelected: Bool
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(item.isEnabled ? .secondary : .tertiary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body)
                        .foregroundStyle(item.isEnabled ? .primary : .secondary)
                        .lineLimit(1)

                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if let shortcutHint = item.shortcutHint {
                    Text(shortcutHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .accessibilityIdentifier("CommandPalette.row.\(item.id)")
        .accessibilityLabel(item.title)
    }
}
