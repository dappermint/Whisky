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
    /// Launches this program the way Whisky does.
    @discardableResult
    func launch(
        args: [String], onOutput: (@MainActor (ProcessOutput) -> Void)? = nil
    ) async throws -> Wine.ProgramRunResult {
        try await Wine.runProgram(at: url, bottle: bottle, programSettings: settings, onOutput: onOutput) {
            try await prepareLaunch(args: args)
        }
    }

    /// Prepares the bottle to run this program, then returns the command that runs it.
    func prepareTerminalCommand(args: [String]) async throws -> String {
        try await Wine.generateRunCommand(for: prepareLaunch(args: args))
    }
}

extension Program {
    /// Prepares the bottle for a launch of this program and returns what the launch runs.
    func prepareLaunch(
        args: [String],
        overrideWriter: Wine.DLLOverrideWriter = { try await Wine.syncDLLOverrides(bottle: $0, scopes: $1) },
        importer: Wine.RegistryImporter = { try await Wine.importRegistry(document: $0, bottle: $1) },
        bootstrapper: Wine.PrefixBootstrapper = { try await Wine.bootstrapPrefix(bottle: $0) }
    ) async throws -> Wine.PreparedLaunch {
        try await Wine.prepareBottlePrefix(bottle: bottle, bootstrapper: bootstrapper)
        await Wine.syncAudioRegistry(bottle: bottle)
        return try await Wine.prepareProgramLaunch(
            at: url, args: args, bottle: bottle, environment: generateEnvironment(),
            programOverrides: settings.overrides, programSettings: settings,
            overrideWriter: overrideWriter, importer: importer
        )
    }

    func runInWine() {
        let arguments = settings.arguments.split { $0.isWhitespace }.map(String.init)
        Task {
            do {
                let result = try await self.launch(args: arguments)
                settings.lastLogFileURL = result.logFileURL
                if result.exitCode != 0 || logContainsCrashSignatures(result.logFileURL) {
                    triggerCrashClassification(
                        logFileURL: result.logFileURL,
                        exitCode: result.exitCode
                    )
                }
            } catch {
                self.showRunError(message: error.localizedDescription)
            }
        }
    }

    /// Launches the program respecting user's modifier key preference and returns the result.
    @MainActor
    public func launchWithUserMode(
        useTerminal: Bool,
        debugEnvironment: [String: String] = [:],
        onLogFile: (@MainActor (URL) -> Void)? = nil,
        onExit: (@MainActor (Int32) -> Void)? = nil
    ) async -> LaunchResult {
        if useTerminal {
            do {
                try await openInTerminal()
                return .launchedInTerminal(programName: self.name)
            } catch {
                return .launchFailed(programName: self.name, errorDescription: error.localizedDescription)
            }
        }

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
                displayName: plan.title,
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
                    displayName: plan.title,
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
                started.send(.launchedSuccessfully(programName: self.name))
            } catch {
                started.send(
                    .launchFailed(programName: self.name, errorDescription: error.localizedDescription)
                )
            }
        }

        return await started.value
    }

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
                let running = await Wine.isWineserverRunning(for: bottle)
                if !running { return }
            }
            Logger.wineKit.debug(
                "Late-crash watch for \(self.name, privacy: .public) timed out with the bottle still busy"
            )
        }
    }

    private static let watchInterval: Duration = .seconds(30)
    private static let watchDuration: Duration = .seconds(30 * 60)

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

            await MainActor.run {
                self.settings.lastDiagnosisDate = entry.timestamp
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
