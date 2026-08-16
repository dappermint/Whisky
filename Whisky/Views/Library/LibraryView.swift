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

import SwiftUI
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

    @State private var search: String = ""
    @State private var entries: [Row] = []
    @State private var launchError: String?

    private var bottles: [Bottle] { bottleVM.bottles.filter(\.isAvailable) }

    private var visible: [Row] {
        guard !search.isEmpty else { return entries }
        return entries.filter { $0.item.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle("library.title")
        .searchable(text: $search, prompt: Text("library.search"))
        .task(id: bottles.map(\.url)) {
            await reload()
        }
        .alert("library.launch.failed", isPresented: .constant(launchError != nil)) {
            Button("button.ok") { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)],
                spacing: 14
            ) {
                ForEach(visible) { entry in
                    LibraryCard(
                        item: entry.item,
                        bottleName: entry.bottleName,
                        lastPlayed: entry.lastPlayed,
                        launch: { launch(entry) }
                    )
                    .contextMenu {
                        Button("library.card.configure") {
                            selectedBottle = entry.item.bottleURL
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("library.empty.title", systemImage: "square.grid.2x2")
        } description: {
            Text(bottles.isEmpty ? "library.empty.noBottle" : "library.empty.noPrograms")
        }
    }

    private func launch(_ entry: Row) {
        guard let bottle = bottles.first(where: { $0.url == entry.item.bottleURL }) else { return }

        switch entry.item.launch {
        case let .program(url):
            // Through the bottle's own program list where possible, so the launch
            // picks up that program's overrides rather than only the bottle's.
            if let program = bottle.programs.first(where: { $0.url == url }) {
                program.run()
            } else {
                Task {
                    do {
                        try await Wine.runProgram(at: url, bottle: bottle)
                    } catch {
                        launchError = error.localizedDescription
                    }
                }
            }
        case let .steam(appID):
            let games = SteamLibrary.enumerate(bottleURL: bottle.url)
            guard let game = games.first(where: { $0.appId == appID }) else {
                launchError = String(localized: "library.launch.steamGameMissing")
                return
            }
            SteamClientOrchestrator(bottle: bottle).launch(game)
        }
    }

    /// Rebuilt in one pass rather than per card: enumerating Steam walks
    /// libraryfolders.vdf and every run log lookup is a plist read, so doing it
    /// inside a card turns scrolling into disk traffic.
    private func reload() async {
        var built: [Row] = []
        let showBottleName = bottles.count > 1

        for bottle in bottles {
            let url = bottle.url
            // Pins come straight from settings, which is a main-actor read.
            // Steam is the part that walks the filesystem, so only that goes
            // off the main actor, and it needs nothing but the bottle URL.
            let pinned = PinnedLibrarySource.items(inBottleAt: url, settings: bottle.settings)
            let steam = await Task.detached { SteamLibrarySource.entries(inBottleAt: url) }.value
            let items = LibraryCatalogue.merge([pinned, steam])

            for item in items {
                built.append(
                    Row(
                        item: item,
                        bottleName: showBottleName ? bottle.settings.name : nil,
                        lastPlayed: lastPlayed(for: item, in: bottle.url)
                    )
                )
            }
        }

        entries = built.sorted { first, second in
            switch (first.lastPlayed, second.lastPlayed) {
            case let (lhs?, rhs?):
                lhs > rhs
            case (_?, nil):
                true
            case (nil, _?):
                false
            case (nil, nil):
                first.item.name.localizedStandardCompare(second.item.name) == .orderedAscending
            }
        }
    }

    private func lastPlayed(for item: LibraryEntry, in bottleURL: URL) -> Date? {
        guard case let .program(url) = item.launch else { return nil }
        return RunLogStore.load(for: url.lastPathComponent, in: bottleURL).entries.map(\.startTime).max()
    }
}

/// A library entry plus what this screen needs to draw it. Private because
/// bottleName and lastPlayed are presentation, not part of the catalogue.
private struct Row: Identifiable {
    let item: LibraryEntry
    let bottleName: String?
    let lastPlayed: Date?

    var id: String { item.id }
}
