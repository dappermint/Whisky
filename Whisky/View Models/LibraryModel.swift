//
//  LibraryModel.swift
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
import Combine
import Foundation
import WhiskyKit

/// How the library grid is ordered.
enum LibrarySort: String, CaseIterable, Identifiable {
    case recent
    case name
    case bottle

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .recent: "library.sort.recent"
        case .name: "library.sort.name"
        case .bottle: "library.sort.bottle"
        }
    }
}

/// A library entry plus what the grid needs to draw it. `bottleName` and
/// `lastPlayed` are presentation, which is why they live here rather than in
/// ``LibraryEntry``; `record` is the entry's persisted state, when it has any.
struct LibraryRow: Identifiable {
    let item: LibraryEntry
    let bottleName: String?
    let lastPlayed: Date?
    let record: GameRecord?

    var id: String { item.id }

    /// A rename wins, then a launcher's proper name (which is how the Steam
    /// client stops reading "steam"), then whatever the source called it.
    var name: String {
        record?.displayName ?? item.launcher?.displayName ?? item.name
    }

    var isFavourite: Bool { record?.favourite == true }
    var isHidden: Bool { record?.hidden == true }
}

/// Builds the library and owns what is currently starting or running.
///
/// A view model rather than view state because the running half comes from a
/// ``SteamClientOrchestrator`` per bottle, and those are long-lived objects with
/// their own pollers: the library previously made one per launch and threw it
/// away, so everything it published (the launch phase, the running App IDs, the
/// launch error) went nowhere.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var rows: [LibraryRow] = []
    @Published var launchError: String?
    @Published var toast: ToastData?

    /// App IDs with a launch in flight, per bottle.
    @Published private var steamLaunching: [URL: Set<Int>] = [:]
    /// App IDs whose own processes are in the bottle's process list.
    @Published private var steamRunning: [URL: Set<Int>] = [:]
    /// Programs whose launch call has not returned yet.
    @Published private var programLaunching: Set<URL> = []

    var sort: LibrarySort = .recent {
        didSet {
            guard sort != oldValue else { return }
            rows = sorted(rows)
        }
    }

    private var orchestrators: [URL: SteamClientOrchestrator] = [:]
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - State

    /// What a card should be showing.
    ///
    /// Running is checked before launching because a Steam launch stays in its
    /// grace period for up to two minutes while shaders precompile, which can
    /// outlast the game actually appearing.
    func state(for entry: LibraryEntry) -> LibraryEntryState {
        switch entry.launch {
        case let .program(url):
            programLaunching.contains(url) ? .launching : .idle
        case let .steam(appID):
            if steamRunning[entry.bottleURL]?.contains(appID) == true {
                .running
            } else if steamLaunching[entry.bottleURL]?.contains(appID) == true {
                .launching
            } else {
                .idle
            }
        }
    }

    // MARK: - Building

    /// Rebuilds every row in one pass.
    ///
    /// Rebuilt whole rather than per card: enumerating Steam walks
    /// `libraryfolders.vdf` and every run log lookup is a plist read, so doing
    /// it inside a card turns scrolling into disk traffic.
    func reload(bottles: [Bottle]) async {
        var built: [LibraryRow] = []
        let showBottleName = bottles.count > 1
        let routed = GameRouting().lastLaunches()

        for bottle in bottles {
            let url = bottle.url
            // Pins come straight from settings, which is a main-actor read.
            // Steam is the part that walks the filesystem, so only that goes
            // off the main actor, and it needs nothing but the bottle URL.
            let pinned = PinnedLibrarySource.items(inBottleAt: url, settings: bottle.settings)
            let steam = await Task.detached { SteamLibrarySource.entries(inBottleAt: url) }.value
            let records = GameRecordStore(bottleURL: url).records()

            for item in LibraryCatalogue.merge([pinned, steam]) {
                built.append(
                    LibraryRow(
                        item: item,
                        bottleName: showBottleName ? bottle.settings.name : nil,
                        lastPlayed: lastPlayed(for: item, records: records, routed: routed),
                        record: records[item.recordID]
                    )
                )
            }

            trackSteam(in: bottle)
        }

        rows = sorted(built)
    }

    /// When an entry was last started in Whisky.
    ///
    /// The game record is the source: it is stamped on every launch and keyed
    /// by identity. The run log and the routing table cover launches from
    /// before records existed, so nobody's history resets on update.
    private func lastPlayed(
        for item: LibraryEntry, records: [GameRecordID: GameRecord], routed: [Int: Date]
    ) -> Date? {
        if let stamped = records[item.recordID]?.lastPlayedInWhisky {
            return stamped
        }
        return switch item.launch {
        case let .program(url):
            RunLogStore.load(for: url.lastPathComponent, in: item.bottleURL)
                .entries.map(\.startTime).max()
        case let .steam(appID):
            routed[appID]
        }
    }

    /// Launchers last whatever the sort is. A storefront client is how you reach
    /// a game, not one of them, and it would otherwise take the top of the grid
    /// on recency because every game launch runs it. Favourites first among the
    /// games, because marking one is the person saying where it should sit.
    private func sorted(_ rows: [LibraryRow]) -> [LibraryRow] {
        rows.sorted { first, second in
            if first.item.isLauncher != second.item.isLauncher {
                return second.item.isLauncher
            }
            if first.isFavourite != second.isFavourite {
                return first.isFavourite
            }
            return switch sort {
            case .recent: byRecency(first, second)
            case .name: byName(first, second)
            case .bottle: byBottle(first, second)
            }
        }
    }

    private func byRecency(_ first: LibraryRow, _ second: LibraryRow) -> Bool {
        switch (first.lastPlayed, second.lastPlayed) {
        case let (lhs?, rhs?): lhs > rhs
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): byName(first, second)
        }
    }

    private func byName(_ first: LibraryRow, _ second: LibraryRow) -> Bool {
        first.name.localizedStandardCompare(second.name) == .orderedAscending
    }

    private func byBottle(_ first: LibraryRow, _ second: LibraryRow) -> Bool {
        let lhs = first.bottleName ?? ""
        let rhs = second.bottleName ?? ""
        guard lhs == rhs else { return lhs.localizedStandardCompare(rhs) == .orderedAscending }
        return byName(first, second)
    }
}

// MARK: - Persisted state

extension LibraryModel {
    func setFavourite(_ row: LibraryRow, _ value: Bool) {
        applyRecordChange(row) { $0.favourite = value }
    }

    func setHidden(_ row: LibraryRow, _ value: Bool) {
        applyRecordChange(row) { $0.hidden = value }
    }

    /// An empty or unchanged-from-source name clears the rename rather than
    /// storing a copy of it, so the card follows the source if it ever renames.
    func rename(_ row: LibraryRow, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceName = row.item.launcher?.displayName ?? row.item.name
        applyRecordChange(row) {
            $0.displayName = trimmed.isEmpty || trimmed == sourceName ? nil : trimmed
        }
    }

    /// Writes one change through the bottle's record store and refreshes just
    /// that row, because a full reload walks Steam's manifests to answer a
    /// question whose answer is already on screen.
    private func applyRecordChange(_ row: LibraryRow, _ mutate: (inout GameRecord) -> Void) {
        let store = GameRecordStore(bottleURL: row.item.bottleURL)
        store.update(row.item.recordID, mutate)
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        rows[index] = LibraryRow(
            item: row.item,
            bottleName: row.bottleName,
            lastPlayed: row.lastPlayed,
            record: store.record(for: row.item.recordID)
        )
        rows = sorted(rows)
    }
}

// MARK: - Launching

extension LibraryModel {
    func launch(_ row: LibraryRow, bottles: [Bottle]) {
        guard let bottle = bottles.first(where: { $0.url == row.item.bottleURL }) else { return }

        switch row.item.launch {
        case let .program(url):
            launchProgram(at: url, in: bottle)
        case let .steam(appID):
            let games = SteamLibrary.enumerate(bottleURL: bottle.url)
            guard let game = games.first(where: { $0.appId == appID }) else {
                launchError = String(localized: "library.launch.steamGameMissing")
                return
            }
            orchestrator(for: bottle).launch(game)
        }
    }

    /// Stops a running Steam game. Programs have no per-entry stop: the launch
    /// path returns long before the program exits, so there is nothing tracked
    /// to stop. The bottle's own stop is what reaches those.
    func stop(_ row: LibraryRow, bottles: [Bottle]) {
        guard case let .steam(appID) = row.item.launch,
              let bottle = bottles.first(where: { $0.url == row.item.bottleURL })
        else { return }

        let games = SteamLibrary.enumerate(bottleURL: bottle.url)
        guard let game = games.first(where: { $0.appId == appID }) else { return }
        Task { await orchestrator(for: bottle).stop(game) }
    }

    private func launchProgram(at url: URL, in bottle: Bottle) {
        // A scanned program where one exists, otherwise materialized from the
        // URL: `bottle.programs` stays empty until a bottle view scans it, and
        // the library is the landing screen, so most launches used to take a
        // bare fallback that carried no overrides at all.
        let program = bottle.programs.first(where: { $0.url == url })
            ?? Program(url: url, bottle: bottle)

        programLaunching.insert(url)
        Telemetry.capture(.firstProgramLaunchAttempted)
        let useTerminal = NSEvent.modifierFlags.contains(.shift)
        Task {
            let result = await program.launchWithUserMode(useTerminal: useTerminal)
            programLaunching.remove(url)
            toast = result.toastData
        }
    }

    /// The orchestrator for a bottle, made once and kept.
    ///
    /// Its `phases` and `runningAppIds` are what the cards read, so it has to
    /// outlive the launch that created it.
    private func orchestrator(for bottle: Bottle) -> SteamClientOrchestrator {
        if let existing = orchestrators[bottle.url] {
            return existing
        }

        let made = SteamClientOrchestrator(bottle: bottle)
        let url = bottle.url
        made.$phases
            .sink { [weak self] phases in
                self?.steamLaunching[url] = Set(phases.keys)
            }
            .store(in: &cancellables)
        made.$runningAppIds
            .sink { [weak self] running in
                self?.steamRunning[url] = running
            }
            .store(in: &cancellables)
        made.$launchError
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.launchError = error
            }
            .store(in: &cancellables)

        orchestrators[bottle.url] = made
        return made
    }

    /// Starts (or restarts) running-state polling for a bottle's Steam games.
    private func trackSteam(in bottle: Bottle) {
        let games = SteamLibrary.enumerate(bottleURL: bottle.url)
        guard !games.isEmpty else { return }
        orchestrator(for: bottle).startTracking(games: games)
    }

    /// Stops every poller. Called when the library leaves the screen.
    func stopTracking() {
        for orchestrator in orchestrators.values {
            orchestrator.stop()
        }
    }
}
