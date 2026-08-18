//
//  LibraryView.swift
//  Whisky
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

/// Everything worth launching, across every bottle, most recently played first.
///
/// This is the home screen because it is the thing people open Whisky to do. A
/// bottle is a Wine prefix, which is an implementation detail of running a
/// Windows program on a Mac, and it only earns space on screen once there is
/// more than one of them.
///
/// Entries come from ``LibraryCatalogue``, so Steam games sit beside pinned
/// programs and a future launcher needs no change here.
struct LibraryView: View {
    @EnvironmentObject var bottleVM: BottleVM
    @Binding var selectedBottle: URL?
    /// Toggled by the toolbar's refresh button. Folded into the reload trigger
    /// because the bottle list is unchanged by a refresh, so watching only that
    /// left the button spinning without rebuilding anything.
    @Binding var refresh: Bool
    /// Feeds the window's run-this-file flow, so Add a Game lands in the
    /// same door as a Finder drop.
    @Binding var openedFile: URL?

    @AppStorage("librarySort") private var sort: LibrarySort = .recent
    @AppStorage("libraryShowHidden") private var showHidden = false

    @StateObject private var model = LibraryModel()
    @State private var search: String = ""
    @State private var renameTarget: LibraryRow?
    @State private var renameText: String = ""
    @State private var settingsTarget: LibrarySettingsTarget?

    private var bottles: [Bottle] { bottleVM.bottles.filter(\.isAvailable) }

    private var visible: [LibraryRow] {
        let shown = showHidden ? model.rows : model.rows.filter { !$0.isHidden }
        guard !search.isEmpty else { return shown }
        return shown.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    /// Every input that changes what the grid should contain. Pins live in
    /// bottle settings, so a program pinned in the bottle screen shows up here
    /// without a relaunch.
    private var reloadTrigger: String {
        let pins = bottles.flatMap { $0.settings.pins.map(\.name) }
        return (bottles.map(\.url.path) + pins + ["\(refresh)"]).joined(separator: "\u{1F}")
    }

    var body: some View {
        Group {
            if model.rows.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle("library.title")
        .searchable(text: $search, prompt: Text("library.search"))
        .toolbar { sortMenu }
        .toast($model.toast)
        .task(id: reloadTrigger) {
            await model.reload(bottles: bottles)
        }
        .onChange(of: sort, initial: true) {
            model.sort = sort
        }
        .onDisappear {
            model.stopTracking()
        }
        .alert(
            "library.launch.failed",
            isPresented: Binding(
                get: { model.launchError != nil },
                set: { if !$0 { model.launchError = nil } }
            )
        ) {
            Button("button.ok") { model.launchError = nil }
        } message: {
            Text(model.launchError ?? "")
        }
        .alert(
            "library.rename.title",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            ),
            presenting: renameTarget
        ) { row in
            TextField("library.rename.title", text: $renameText)
            Button("library.rename.title") {
                model.rename(row, to: renameText)
            }
            Button("button.cancel", role: .cancel) {}
        } message: { _ in
            // Clearing the field puts the source's own name back, which is the
            // undo for a rename.
            Text("library.rename.message")
        }
        .sheet(item: $settingsTarget) { target in
            LibraryProgramSettingsSheet(bottle: target.bottle, program: target.program)
        }
    }

    private var sortMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("library.sort", selection: $sort) {
                    ForEach(LibrarySort.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("library.showHidden", isOn: $showHidden)
            } label: {
                Label("library.sort", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityIdentifier("library.sort")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                // 180 rather than 220 so two columns fit at the window's own
                // minimum width, where the sidebar leaves about 330pt: one
                // column of landscape cards is a list with wasted space.
                columns: [GridItem(.adaptive(minimum: 180, maximum: 320), spacing: 14)],
                spacing: 14
            ) {
                ForEach(visible) { row in
                    LibraryCard(
                        item: row.item,
                        title: row.name,
                        bottleName: row.bottleName,
                        lastPlayed: row.lastPlayed,
                        favourite: row.isFavourite,
                        state: model.state(for: row.item),
                        launch: { model.launch(row, bottles: bottles) }
                    )
                    // Dimmed rather than gone under Show Hidden, so hiding is
                    // visibly a state and not a deletion.
                    .opacity(row.isHidden ? 0.55 : 1)
                    .contextMenu { menu(for: row) }
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private func menu(for row: LibraryRow) -> some View {
        Button("button.run") { model.launch(row, bottles: bottles) }
        if model.state(for: row.item) == .running {
            Button("library.card.stop") { model.stop(row, bottles: bottles) }
        }
        Divider()
        Button(row.isFavourite ? "library.card.removeFavorite" : "library.card.addFavorite") {
            model.setFavourite(row, !row.isFavourite)
        }
        Button("library.card.rename") {
            renameText = row.name
            renameTarget = row
        }
        Button(row.isHidden ? "library.card.unhide" : "library.card.hide") {
            model.setHidden(row, !row.isHidden)
        }
        Divider()
        if case let .program(url) = row.item.launch {
            Button("button.showInFinder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("library.card.unpin", role: .destructive) { unpin(url, in: row.item.bottleURL) }
        }
        Button("library.card.settings") {
            openSettings(for: row)
        }
        Button("library.card.configure") {
            selectedBottle = row.item.bottleURL
        }
    }

    private func openSettings(for row: LibraryRow) {
        guard let bottle = bottles.first(where: { $0.url == row.item.bottleURL }) else { return }
        Task {
            // Steam resolution reads bottle.programs, which stays empty until
            // something scans the bottle. A session that went straight to the
            // library has never scanned, so the sheet would silently fall
            // through to the bottle every time.
            if row.item.programURL == nil, bottle.programs.isEmpty {
                await bottle.updateInstalledPrograms()
            }
            if let program = settingsProgram(for: row, in: bottle) {
                settingsTarget = LibrarySettingsTarget(
                    bottle: bottle, program: program, id: program.url
                )
            } else {
                // No single executable speaks for this game; the bottle view
                // has the full list. Say so instead of switching wordlessly.
                model.toast = ToastData(
                    message: String(localized: "library.card.settingsFallback"),
                    style: .info
                )
                selectedBottle = row.item.bottleURL
            }
        }
    }

    /// The program whose settings page speaks for this card. A pin is itself;
    /// a Steam game resolves to an executable under its install folder:
    /// whichever one already carries overrides, else a lone candidate, else
    /// the GameDB's named exe for this App ID.
    private func settingsProgram(for row: LibraryRow, in bottle: Bottle) -> Program? {
        if let url = row.item.programURL {
            return bottle.programs.first { $0.url == url } ?? Program(url: url, bottle: bottle)
        }
        guard let installURL = row.item.installURL else { return nil }
        let candidates = bottle.programs.filter {
            LibraryCatalogue.isPath($0.url, under: installURL)
        }
        if let configured = candidates.first(where: { $0.settings.overrides != nil }) {
            return configured
        }
        if candidates.count == 1 { return candidates.first }
        if case let .steam(appID) = row.item.launch,
           let entry = GameMatcher.bestMatch(
               metadata: ProgramMetadata(exeName: "", steamAppId: appID),
               against: GameDBLoader.loadDefaults()
           )?.entry,
           let exeNames = entry.exeNames {
            let names = Set(exeNames.map { $0.lowercased() })
            return candidates.first { names.contains($0.url.lastPathComponent.lowercased()) }
        }
        return nil
    }

    private func unpin(_ url: URL, in bottleURL: URL) {
        guard let bottle = bottles.first(where: { $0.url == bottleURL }) else { return }
        bottle.settings.pins.removeAll { $0.url == url }
        if let program = bottle.programs.first(where: { $0.url == url }) {
            program.pinned = false
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("library.empty.title", systemImage: "square.grid.2x2")
        } description: {
            Text(bottles.isEmpty ? "library.empty.noBottle" : "library.empty.gameFirst")
        } actions: {
            if let first = bottles.first {
                Button("library.empty.addGame") { openGamePanel() }
                    .buttonStyle(.borderedProminent)
                Button("library.empty.pinHint") { selectedBottle = first.url }
            }
        }
    }

    /// The same run-this-file flow a Finder drop lands in, reached from a
    /// button so an empty library teaches adding a game, not making bottles.
    private func openGamePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["exe", "msi", "bat", "msix", "appx", "url"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.begin { result in
            guard result == .OK, let url = panel.urls.first else { return }
            openedFile = url
        }
    }
}

// MARK: - Per-Game Settings Sheet

/// A card's target for the settings sheet, identified by the executable so
/// reopening for another game replaces the sheet's content. The id is
/// captured at creation because `Identifiable.id` is nonisolated and
/// ``Program`` lives on the main actor.
private struct LibrarySettingsTarget: Identifiable {
    let bottle: Bottle
    let program: Program
    let id: URL
}

/// The card's path to per-game settings: the same form the Programs tab
/// shows, hosted in a sheet because the library cannot push onto a bottle's
/// navigation stack.
private struct LibraryProgramSettingsSheet: View {
    @ObservedObject var bottle: Bottle
    @ObservedObject var program: Program
    @Environment(\.dismiss) private var dismiss
    @State private var overridesExpanded = true

    var body: some View {
        NavigationStack {
            Form {
                ProgramOverrideSettingsView(
                    bottle: bottle, program: program, isExpanded: $overridesExpanded
                )
            }
            .formStyle(.grouped)
            .navigationTitle(program.name)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 620)
    }
}
