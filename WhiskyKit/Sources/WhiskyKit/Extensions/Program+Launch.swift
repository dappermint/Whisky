//
//  Program+Launch.swift
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
import Foundation
import os.log

public extension Program {
    /// Launches the program respecting user's modifier key preference and returns the result.
    /// - Parameters:
    ///   - useTerminal: Whether to launch in Terminal mode (e.g., Shift was held).
    ///     **Important:** Capture `NSEvent.modifierFlags.contains(.shift)` synchronously at the call site,
    ///     before entering any async context, to avoid race conditions with key state.
    ///   - debugEnvironment: Variables for this launch only, never written to settings.
    ///     The debug window sends its `WINEDEBUG` here so a channel picked for one
    ///     run does not become the program's permanent configuration.
    ///   - onLogFile: Called with the run's log as soon as it exists, which is
    ///     before the program has finished writing to it.
    ///   - onExit: Called with the real exit code when an attached program ends.
    ///     Never called for the shortcut and installer types, which are handed
    ///     to wineserver and have no exit code to report.
    /// - Returns: LaunchResult once the program is running, not once it is done.
    @MainActor
    func launchWithUserMode(
        useTerminal: Bool,
        debugEnvironment: [String: String] = [:],
        onLogFile: (@MainActor (URL) -> Void)? = nil,
        onExit: (@MainActor (Int32) -> Void)? = nil
    ) async -> LaunchResult {
        // Check for terminal mode (typically shift-click)
        if useTerminal {
            self.runInTerminal()
            return .launchedInTerminal(programName: self.name)
        }

        // This is the one door every direct run goes through, so the full
        // stack is assembled here and no entry point can launch with less:
        // launcher fixes, then the GameDB profile filling whatever the user's
        // own overrides left unset.
        LauncherFixes.detectAndApply(from: url, for: bottle)
        let plan = LaunchResolver.plan(forProgramAt: url, userOverrides: settings.overrides)
        for note in plan.provenance {
            Logger.wineKit.info("\(self.name, privacy: .public) launch plan: \(note, privacy: .public)")
        }

        await Wine.syncAudioRegistry(bottle: bottle)
        await Wine.syncWindowsVersion(bottle: bottle)

        let arguments = settings.arguments.split { $0.isWhitespace }.map(String.init)
        var environment = generateEnvironment()
        environment.merge(debugEnvironment) { _, oneOff in oneOff }

        // A `.exe` runs as our own child: its output lands in this run's log and
        // its exit code is the program's. Everything else goes through
        // `start /unix`, which is what resolves a shortcut or hands an installer
        // to the right handler, at the cost of both of those.
        guard url.pathExtension.lowercased() == "exe" else {
            return await launchDetached(
                arguments: arguments, environment: environment, plan: plan, onLogFile: onLogFile
            )
        }
        return await launchAttached(
            arguments: arguments, environment: environment, plan: plan,
            onLogFile: onLogFile, onExit: onExit
        )
    }

    /// Hands the program to wineserver and returns as soon as the stub does.
    ///
    /// No exit code and no output come back this way, so a crash is only
    /// visible in what the log happens to hold and in the late watcher.
    @MainActor
    private func launchDetached(
        arguments: [String], environment: [String: String], plan: LaunchPlan,
        onLogFile: (@MainActor (URL) -> Void)?
    ) async -> LaunchResult {
        do {
            let result = try await Wine.runProgram(
                at: self.url, args: arguments, bottle: self.bottle, environment: environment,
                programOverrides: plan.overrides, programSettings: settings,
                gameProfileEnvironment: plan.gameProfileEnvironment,
                onLogFile: onLogFile
            )
            settings.lastLogFileURL = result.logFileURL

            if result.exitCode != 0 || logContainsCrashSignatures(result.logFileURL) {
                triggerCrashClassification(logFileURL: result.logFileURL, exitCode: result.exitCode)
            } else {
                watchForLateCrash(logFileURL: result.logFileURL)
            }
            return .launchedSuccessfully(programName: self.name)
        } catch {
            return .launchFailed(programName: self.name, errorDescription: error.localizedDescription)
        }
    }

    /// Runs the program as this process's child, returning once it is running.
    ///
    /// The run itself outlives this call: the exit code arrives on the way out
    /// and is what decides whether the session gets classified as a crash, in
    /// place of the guesswork the detached path is stuck with.
    @MainActor
    private func launchAttached(
        arguments: [String], environment: [String: String], plan: LaunchPlan,
        onLogFile: (@MainActor (URL) -> Void)?,
        onExit: (@MainActor (Int32) -> Void)?
    ) async -> LaunchResult {
        let started = LaunchSignal()

        Task { @MainActor in
            do {
                let result = try await Wine.runProgram(
                    at: self.url, args: arguments, bottle: self.bottle, environment: environment,
                    programOverrides: plan.overrides, programSettings: settings,
                    gameProfileEnvironment: plan.gameProfileEnvironment,
                    keepAttached: true,
                    onLogFile: { [weak self] logURL in
                        self?.settings.lastLogFileURL = logURL
                        onLogFile?(logURL)
                    },
                    onStarted: { started.send(.launchedSuccessfully(programName: self.name)) }
                )
                onExit?(result.exitCode)
                if result.exitCode != 0 || logContainsCrashSignatures(result.logFileURL) {
                    triggerCrashClassification(logFileURL: result.logFileURL, exitCode: result.exitCode)
                }
                // A program that came and went before the started signal was
                // read still launched.
                started.send(.launchedSuccessfully(programName: self.name))
            } catch {
                started.send(
                    .launchFailed(programName: self.name, errorDescription: error.localizedDescription)
                )
            }
        }

        return await started.value
    }

    /// Watches for the session actually ending, then classifies its log.
    ///
    /// The bottle's wineserver going idle is the end-of-session signal, the
    /// same one Discord presence uses, and this run's log keeps growing until
    /// then because Wine's children inherit its file descriptor. Each launch
    /// has its own log file, so concurrent watchers never double-report one
    /// run. The probe is deliberately one interval late; the wineserver may
    /// not be up yet at the moment of launch.
    ///
    /// Bounded, because "wineserver went idle" does not always arrive: a bottle
    /// with a resident Steam client stays busy between games, and every launch
    /// would otherwise leave a poller behind for as long as Whisky runs.
    private func watchForLateCrash(logFileURL: URL) {
        let bottle = self.bottle
        Task {
            let deadline = ContinuousClock.now + Self.watchDuration
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: Self.watchInterval)
                if logContainsCrashSignatures(logFileURL) {
                    triggerCrashClassification(logFileURL: logFileURL, exitCode: 1)
                    return
                }
                // Checked after the scan, so a crash written between the last
                // scan and the wineserver going down still gets one look.
                let running = await Wine.isWineserverRunning(for: bottle)
                if !running { return }
            }
            Logger.wineKit.debug(
                "Late-crash watch for \(self.name, privacy: .public) timed out with the bottle still busy"
            )
        }
    }

    /// How often the late-crash watcher scans the log.
    private static let watchInterval: Duration = .seconds(30)

    /// How long the late-crash watcher keeps scanning before standing down.
    ///
    /// It exists to catch a launch-time crash written after the detached stub
    /// returned; half an hour is far past that.
    private static let watchDuration: Duration = .seconds(30 * 60)

    /// Checks whether the log file contains crash signatures that warrant classification.
    ///
    /// Reads the tail of the log file (bounded to 64 KiB) and searches for known crash
    /// signatures. This is a lightweight heuristic before running the full classifier.
    private func logContainsCrashSignatures(_ logFileURL: URL) -> Bool {
        let maxBytes = 64 * 1_024

        guard let handle = try? FileHandle(forReadingFrom: logFileURL) else { return false }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return false }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)

        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return false }

        return crashSignatures.contains(where: { text.contains($0) })
    }

    /// Triggers background crash classification and posts a notification with the result.
    ///
    /// Classification runs on a background task (`.utility` priority) to avoid
    /// blocking the main thread. On completion, persists a ``DiagnosisHistoryEntry``
    /// and posts ``Notification.Name.crashDiagnosisAvailable``.
    private func triggerCrashClassification(logFileURL: URL, exitCode: Int32) {
        let programPath = self.url.path(percentEncoded: false)
        let programName = self.name
        let bottleName = self.bottle.settings.name
        let bottleURL = self.bottle.url
        let activePreset = self.settings.activeWineDebugPreset

        Task.detached(priority: .utility) {
            guard let diagnosis = await Wine.classifyLastRun(
                logFileURL: logFileURL,
                exitCode: exitCode
            ), !diagnosis.isEmpty
            else {
                return
            }

            // Build and persist a DiagnosisHistoryEntry
            let entry = DiagnosisHistoryEntry(
                timestamp: Date(),
                logFileRef: logFileURL.lastPathComponent,
                primaryCategory: diagnosis.primaryCategory ?? .otherUnknown,
                confidenceTier: diagnosis.primaryConfidence ?? .low,
                topSignatures: Array(diagnosis.matches.prefix(3).map(\.pattern.id)),
                remediationCardIds: diagnosis.applicableRemediationIds,
                wineDebugPreset: activePreset,
                bottleIdentifier: bottleName,
                programPath: programPath
            )

            let historyURL = bottleURL
                .appending(path: "Program Settings")
                .appending(path: programName)
                .appendingPathExtension("diagnosis-history.plist")
            var history = DiagnosisHistory.load(from: historyURL)
            history.append(entry)
            try? history.save(to: historyURL)

            // Update lastDiagnosisDate on the main actor
            await MainActor.run {
                // Post notification for the UI to react
                NotificationCenter.default.post(
                    name: .crashDiagnosisAvailable,
                    object: nil,
                    userInfo: [
                        "diagnosis": diagnosis,
                        "programPath": programPath,
                        "logFileURL": logFileURL
                    ]
                )
            }
        }
    }
}

/// A one-shot handoff from the running task back to the caller that started it.
///
/// The launch result is known when the program starts, the run continues after
/// that, and both ends of it can report: whichever speaks first wins and the
/// rest are dropped rather than resuming a continuation twice.
@MainActor
private final class LaunchSignal {
    private var continuation: CheckedContinuation<LaunchResult, Never>?
    private var result: LaunchResult?

    var value: LaunchResult {
        get async {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    func send(_ result: LaunchResult) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}
