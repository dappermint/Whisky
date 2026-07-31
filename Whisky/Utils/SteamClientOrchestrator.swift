//
//  SteamClientOrchestrator.swift
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

import Combine
import Foundation
import WhiskyKit

enum SteamOrchestratorError: LocalizedError {
    /// steam.exe did not appear in the process list within the ready timeout.
    case clientTimeout
    /// The bottle no longer contains a Steam installation.
    case steamNotInstalled

    var errorDescription: String? {
        switch self {
        case .clientTimeout:
            String(localized: "steam.client.timeout")
        case .steamNotInstalled:
            String(localized: "steam.client.missing")
        }
    }
}

/// Runs Steam games through the Windows Steam client without making the user
/// look at it: ensures the client is up (silently), fires `-applaunch`, and
/// watches for the game process to actually appear.
@MainActor
final class SteamClientOrchestrator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case startingClient
        case launching(appId: Int)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var downloadStatus: StallStatus = .noDownloads
    /// App IDs whose executables are currently in the bottle's process list.
    @Published private(set) var runningAppIds: Set<Int> = []
    @Published var launchError: String?

    private let bottle: Bottle
    private let downloadMonitor = SteamDownloadMonitor()
    private var cancellables: Set<AnyCancellable> = []
    private var trackingTask: Task<Void, Never>?
    private var executableNamesByAppId: [Int: Set<String>] = [:]

    private let clientReadyTimeout: TimeInterval = 90
    /// Steam forks the game and the -applaunch invocation returns immediately;
    /// shader precompilation can hold the real game process back for a long
    /// time. Lutris ships 120 seconds for this same wait.
    private let launchGrace: TimeInterval = 120

    init(bottle: Bottle) {
        self.bottle = bottle
        downloadMonitor.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.downloadStatus = status }
            .store(in: &cancellables)
    }

    /// Launches a game via `-applaunch`, bringing the client up first if needed.
    func launch(_ game: SteamGame) async {
        guard phase == .idle else { return }
        phase = .startingClient
        defer { phase = .idle }

        guard let steamRoot = SteamLibrary.detectInstall(bottleURL: bottle.url) else {
            launchError = SteamOrchestratorError.steamNotInstalled.errorDescription
            return
        }
        let steamExe = steamRoot.appending(path: "steam.exe")

        do {
            try await ensureClientRunning(steamExe: steamExe)
        } catch {
            launchError = error.localizedDescription
            return
        }

        phase = .launching(appId: game.appId)
        let plan = LaunchResolver.plan(steamAppId: game.appId)
        let bottle = self.bottle
        let appId = game.appId
        // With the client already up this invocation just forwards and exits,
        // but if the client died in between it becomes the client itself and
        // runs for the whole session -- never await it.
        Task {
            _ = try? await Wine.runProgram(
                at: steamExe, args: ["-applaunch", String(appId)], bottle: bottle,
                programOverrides: plan.overrides,
                gameProfileEnvironment: plan.gameProfileEnvironment
            )
        }

        if await !waitForGameProcess(installURL: game.installURL) {
            launchError = String(localized: "steam.launch.timeout")
        }
    }

    /// Polls the bottle's process list so the library can show which games
    /// are running, including ones started outside Whisky.
    func startTracking(games: [SteamGame]) {
        trackingTask?.cancel()
        for game in games where executableNamesByAppId[game.appId] == nil {
            let installURL = game.installURL
            executableNamesByAppId[game.appId] = Self.executableNames(under: installURL)
        }
        trackingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshRunningState()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Asks the game's processes to close, then refreshes the running state.
    func stop(_ game: SteamGame) async {
        let names = executableNamesByAppId[game.appId]
            ?? Self.executableNames(under: game.installURL)
        guard let output = try? await Wine.runWine(["tasklist.exe", "/FO", "CSV"], bottle: bottle) else {
            return
        }

        for process in Wine.parseTasklistOutput(output)
            where names.contains(process.imageName.lowercased()) {
            await Wine.gracefulKillProcess(winePID: process.winePID, bottle: bottle)
        }
        await refreshRunningState()
    }

    private func refreshRunningState() async {
        let running = await runningImageNames()
        runningAppIds = Set(
            executableNamesByAppId.filter { !$0.value.isDisjoint(with: running) }.keys
        )
    }

    /// Stops download monitoring and process tracking. Call when the owning
    /// view disappears.
    func stop() {
        trackingTask?.cancel()
        trackingTask = nil
        downloadMonitor.stopMonitoring()
    }

    private func ensureClientRunning(steamExe: URL) async throws {
        if await isClientRunning() {
            startDownloadMonitoringIfNeeded()
            return
        }

        // The launcherManaged env recipe (UTF-8 locale, CEF sandbox flags) is
        // what keeps steamwebhelper alive; make sure it applies to this launch.
        if bottle.settings.detectedLauncher == nil {
            bottle.settings.detectedLauncher = .steam
        }
        bottle.settings.launcherCompatibilityMode = true

        let bottle = self.bottle
        // steam.exe -silent runs for the whole session -- never await it.
        Task {
            _ = try? await Wine.runProgram(at: steamExe, args: ["-silent"], bottle: bottle)
        }

        let deadline = Date(timeIntervalSinceNow: clientReadyTimeout)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(2))
            if await isClientRunning() {
                startDownloadMonitoringIfNeeded()
                return
            }
        }
        throw SteamOrchestratorError.clientTimeout
    }

    private func isClientRunning() async -> Bool {
        await runningImageNames().contains("steam.exe")
    }

    /// Waits for any of the game's executables to appear in the process list.
    ///
    /// Returns `true` when the game shows up (or when no candidate exe names
    /// could be determined, in which case there is nothing to watch for).
    private func waitForGameProcess(installURL: URL) async -> Bool {
        let candidates = Self.executableNames(under: installURL)
        guard !candidates.isEmpty else { return true }

        let deadline = Date(timeIntervalSinceNow: launchGrace)
        while Date() < deadline {
            if await !runningImageNames().isDisjoint(with: candidates) {
                return true
            }
            try? await Task.sleep(for: .seconds(3))
        }
        return false
    }

    private func startDownloadMonitoringIfNeeded() {
        guard !downloadMonitor.isMonitoring else { return }
        downloadMonitor.startMonitoring(bottleURL: bottle.url, detectedLauncher: .steam)
    }

    private func runningImageNames() async -> Set<String> {
        guard let output = try? await Wine.runWine(["tasklist.exe", "/FO", "CSV"], bottle: bottle) else {
            return []
        }
        return Set(Wine.parseTasklistOutput(output).map { $0.imageName.lowercased() })
    }

    /// Lowercased executable names at the install root and one directory deep.
    static func executableNames(under installURL: URL) -> Set<String> {
        let fileManager = FileManager.default
        var names: Set<String> = []
        var subdirectories: [URL] = []

        let top = (try? fileManager.contentsOfDirectory(
            at: installURL, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for item in top {
            if item.pathExtension.lowercased() == "exe" {
                names.insert(item.lastPathComponent.lowercased())
            } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                subdirectories.append(item)
            }
        }
        for directory in subdirectories {
            let items = (try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
            for item in items where item.pathExtension.lowercased() == "exe" {
                names.insert(item.lastPathComponent.lowercased())
            }
        }
        return names
    }
}
