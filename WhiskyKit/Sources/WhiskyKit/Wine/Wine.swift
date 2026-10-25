// swiftlint:disable file_length
//
//  Wine.swift
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

import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "Wine")

// swiftlint:disable type_body_length

/// The core interface for interacting with Wine on macOS.
///
/// The `Wine` class provides static methods for executing Wine processes, running Windows programs,
/// and managing Wine-related operations within a ``Bottle``. It handles environment configuration,
/// process management, and output streaming.
///
/// ## Overview
///
/// Wine is a compatibility layer that allows Windows applications to run on macOS. This class
/// abstracts the complexity of Wine process management and provides a Swift-friendly API.
///
/// ## Running Programs
///
/// To run a Windows executable:
///
/// ```swift
/// @MainActor
/// func launchGame(at url: URL, in bottle: Bottle) async throws {
///     try await Wine.runProgram(at: url, bottle: bottle)
/// }
/// ```
///
/// ## Wine Commands
///
/// Execute arbitrary Wine commands:
///
/// ```swift
/// @MainActor
/// func getWineVersion() async throws -> String {
///     return try await Wine.wineVersion()
/// }
/// ```
///
/// ## Thread Safety
///
/// Most public methods require `@MainActor` context because they interact with ``Bottle``
/// which is main-actor isolated.
///
/// ## Topics
///
/// ### Running Programs
/// - ``runProgram(at:args:bottle:environment:)``
/// - ``runWine(_:bottle:environment:)``
/// - ``runBatchFile(url:bottle:)``
///
/// ### Wine Processes
/// - ``runWineProcess(name:args:bottle:environment:)``
/// - ``runWineserverProcess(name:args:bottle:environment:)``
///
/// ### Utilities
/// - ``wineVersion()``
/// - ``killBottle(bottle:)``
/// - ``enableDXVK(bottle:)``
/// - ``generateRunCommand(at:bottle:args:environment:)``
/// - ``generateTerminalEnvironmentCommand(bottle:)``
public class Wine {
    /// URL to the installed DXVK folder containing Direct3D-to-Vulkan translation libraries.
    private static let dxvkFolder: URL = WhiskyWineInstaller.libraryFolder.appending(path: "DXVK")
    /// URL to the installed DXMT payload containing Direct3D-11-to-Metal translation libraries.
    /// Absent on runtimes older than Wine Libraries 3.1.0.
    private static let dxmtFolder: URL = WhiskyWineInstaller.libraryFolder.appending(path: "DXMT")

    /// The DXVK payload belonging to `runtime`.
    ///
    /// Translation payloads ship inside a runtime and are built against it, so
    /// a bottle on another runtime must use that runtime's copy or none. A
    /// runtime that ships neither (a GPTK build without Vulkan, say) simply has
    /// those backends unavailable, which is the honest answer.
    static func dxvkFolder(for runtime: String?) -> URL {
        WhiskyWineInstaller.libraryFolder(for: runtime).appending(path: "DXVK")
    }

    /// The DXMT payload belonging to `runtime`.
    static func dxmtFolder(for runtime: String?) -> URL {
        WhiskyWineInstaller.libraryFolder(for: runtime).appending(path: "DXMT")
    }

    /// The URL to the default runtime's `wine64` binary executable.
    ///
    /// This is the main Wine binary used to execute Windows applications.
    /// Anything running in the context of a bottle should use
    /// ``wineBinary(for:)`` instead, since a bottle may select another runtime.
    public static let wineBinary: URL = WhiskyWineInstaller.binFolder.appending(path: "wine64")
    /// URL to the default runtime's `wineserver` binary.
    private static let wineserverBinary: URL = WhiskyWineInstaller.binFolder.appending(path: "wineserver")

    /// The `wine64` binary of the runtime `bottle` is configured to use.
    @MainActor
    public static func wineBinary(for bottle: Bottle) -> URL {
        WhiskyWineInstaller.binFolder(for: bottle.settings.runtime).appending(path: "wine64")
    }

    /// The `wineserver` binary of the runtime `bottle` is configured to use.
    @MainActor
    public static func wineserverBinary(for bottle: Bottle) -> URL {
        WhiskyWineInstaller.binFolder(for: bottle.settings.runtime).appending(path: "wineserver")
    }

    /// A process that has started, and the pid it can be signalled by.
    struct StartedProcess {
        let stream: AsyncStream<ProcessOutput>
        let pid: Int32
    }

    /// Run a process on a executable file given by the `executableURL`, keeping
    /// hold of its pid.
    ///
    /// Only a caller that owns the program's lifetime has any use for the pid;
    /// everything else goes through ``runProcess(name:args:environment:executableURL:directory:fileHandle:)``.
    private static func startProcess(
        name: String? = nil, args: [String], environment: [String: String], executableURL: URL, directory: URL? = nil,
        fileHandle: FileHandle?, emitsOutput: Bool = true
    ) throws -> StartedProcess {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = args
        process.currentDirectoryURL = directory ?? executableURL.deletingLastPathComponent()
        process.environment = environment
        process.qualityOfService = .userInitiated

        let stream = try process.runStream(
            name: name ?? args.joined(separator: " "), fileHandle: fileHandle, emitsOutput: emitsOutput
        )
        return StartedProcess(stream: stream, pid: process.processIdentifier)
    }

    /// Run a process on a executable file given by the `executableURL`
    private static func runProcess(
        name: String? = nil, args: [String], environment: [String: String], executableURL: URL, directory: URL? = nil,
        fileHandle: FileHandle?
    ) throws -> AsyncStream<ProcessOutput> {
        try startProcess(
            name: name, args: args, environment: environment, executableURL: executableURL,
            directory: directory, fileHandle: fileHandle
        ).stream
    }

    /// Run a `wine` process with the given arguments and environment variables returning a stream of output
    private static func runWineProcess(
        name: String? = nil, args: [String], environment: [String: String] = [:],
        runtime: String? = nil, fileHandle: FileHandle?
    ) throws -> AsyncStream<ProcessOutput> {
        try runProcess(
            name: name, args: args, environment: environment,
            executableURL: WhiskyWineInstaller.binFolder(for: runtime).appending(path: "wine64"),
            fileHandle: fileHandle
        )
    }

    /// Run a `wineserver` process with the given arguments and environment variables returning a stream of output
    private static func runWineserverProcess(
        name: String? = nil, args: [String], environment: [String: String] = [:],
        fileHandle: FileHandle?
    ) throws -> AsyncStream<ProcessOutput> {
        try runProcess(
            name: name, args: args, environment: environment, executableURL: wineserverBinary,
            fileHandle: fileHandle
        )
    }

    /// Runs a Wine process with the given arguments and returns a stream of output.
    ///
    /// This method executes the Wine binary with the specified arguments within the context
    /// of a bottle. The bottle's settings are used to configure the Wine environment.
    ///
    /// - Parameters:
    ///   - name: An optional descriptive name for the process, used in logging.
    ///   - args: The command-line arguments to pass to Wine.
    ///   - bottle: The ``Bottle`` context in which to run the process.
    ///   - environment: Additional environment variables to set for this process.
    /// - Returns: An `AsyncStream` of ``ProcessOutput`` containing stdout, stderr, and lifecycle events.
    /// - Throws: An error if the process cannot be started.
    @MainActor
    public static func runWineProcess(
        name: String? = nil, args: [String], bottle: Bottle, environment: [String: String] = [:]
    ) throws -> AsyncStream<ProcessOutput> {
        let fileHandle = try makeFileHandle()
        fileHandle.writeApplicationInfo()
        fileHandle.writeInfo(for: bottle)

        WineUserProfile.reconcile(bottleURL: bottle.url)
        let wineEnvironment = constructWineEnvironment(for: bottle, environment: environment)

        return try runProcess(
            name: name, args: args, environment: wineEnvironment, executableURL: wineBinary(for: bottle),
            fileHandle: fileHandle
        )
    }

    /// Runs a Wine server process with the given arguments and returns a stream of output.
    ///
    /// The Wine server manages shared resources and state for all Wine processes in a bottle.
    /// This method is typically used for administrative operations like killing all processes.
    ///
    /// - Parameters:
    ///   - name: An optional descriptive name for the process, used in logging.
    ///   - args: The command-line arguments to pass to wineserver.
    ///   - bottle: The ``Bottle`` context in which to run the server process.
    ///   - environment: Additional environment variables to set for this process.
    /// - Returns: An `AsyncStream` of ``ProcessOutput`` containing stdout, stderr, and lifecycle events.
    /// - Throws: An error if the process cannot be started.
    @MainActor
    public static func runWineserverProcess(
        name: String? = nil, args: [String], bottle: Bottle, environment: [String: String] = [:]
    ) throws -> AsyncStream<ProcessOutput> {
        let fileHandle = try makeFileHandle()
        fileHandle.writeApplicationInfo()
        fileHandle.writeInfo(for: bottle)

        let wineserverEnvironment = constructWineEnvironment(for: bottle, environment: environment)

        return try runProcess(
            name: name, args: args, environment: wineserverEnvironment,
            executableURL: wineserverBinary(for: bottle),
            fileHandle: fileHandle
        )
    }

    /// Result of a Wine program run, providing the exit code and log file URL
    /// for post-run diagnostics.
    public struct ProgramRunResult: Sendable {
        /// The exit code from the `wine start` process.
        public let exitCode: Int32
        /// URL to the log file created for this run.
        public let logFileURL: URL
        /// The UUID of the run log entry created for this run.
        ///
        /// Use this to correlate the run result with the run log history
        /// entry, e.g., to open the correct log entry in the console UI.
        public let runLogEntryId: UUID
    }

    /// What a program launch runs once its bottle has been prepared for it.
    ///
    /// Returned by `prepareProgramLaunch`, and turned into a shell command by
    /// ``generateRunCommand(for:wineBinary:)``.
    struct PreparedLaunch: Equatable, Sendable {
        /// The environment `wine64` runs with.
        ///
        /// Holds no `WINEDLLOVERRIDES` unless the overrides are meant for a
        /// process this launch spawns: preparation moved the launch's own
        /// overrides into the prefix registry, where no child inherits them.
        let environment: [String: String]
        /// The arguments `wine64` runs with: `start /unix` and the program, or
        /// `explorer /desktop=...` for a program that runs in a virtual desktop.
        let arguments: [String]
    }

    /// Runs a Windows executable within a Wine bottle.
    ///
    /// This is the primary method for launching Windows applications. It prepares the bottle
    /// with `prepareProgramLaunch` and then executes the program using `wine start /unix`.
    ///
    /// - Note: If DXVK is enabled in the bottle's settings (`bottle.settings.dxvk`),
    ///   the DXVK libraries will be automatically installed into the bottle before
    ///   execution. This ensures Direct3D games use Vulkan translation for better
    ///   performance on macOS.
    ///
    /// ## Example
    ///
    /// ```swift
    /// @MainActor
    /// func launchGame() async throws {
    ///     let gameURL = bottle.url
    ///         .appendingPathComponent("drive_c")
    ///         .appendingPathComponent("Games")
    ///         .appendingPathComponent("MyGame.exe")
    ///
    ///     try await Wine.runProgram(at: gameURL, bottle: bottle)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - url: The URL to the Windows executable (.exe) file.
    ///   - args: Optional command-line arguments to pass to the program.
    ///   - bottle: The ``Bottle`` in which to run the program.
    ///   - environment: Additional environment variables for this execution.
    ///   - programOverrides: Optional per-program setting overrides. `nil` fields inherit from bottle.
    ///   - programSettings: The program's settings, which carry its diagnostic `WINEDEBUG` preset.
    ///   - gameProfileEnvironment: Environment variables from the game's GameDB profile.
    ///   - overridesApplyToDescendants: Whether the DLL overrides belong to a process this
    ///     one spawns rather than to `url` itself, as when `steam.exe` launches a game.
    ///   - descendantExecutables: The executable names of what this launch starts, when the
    ///     overrides apply to descendants.
    ///   - descendantLaunchers: Launchers what this launch starts brings up on its own.
    ///   - onOutput: Receives each output event of the `wine64` process as it arrives,
    ///     starting with ``ProcessOutput/started`` once the process is running.
    /// - Returns: The exit code and log file of the run.
    /// - Throws: An error if the program cannot be started or Wine encounters an error.
    @discardableResult
    @MainActor
    public static func runProgram(
        at url: URL, args: [String] = [], bottle: Bottle, environment: [String: String] = [:],
        programOverrides: ProgramOverrides? = nil, programSettings: ProgramSettings? = nil,
        gameProfileEnvironment: [String: String] = [:],
        displayName: String? = nil,
        steamAppId: Int? = nil,
        identityScope: DockIdentity.Scope = .processTree,
        overridesApplyToDescendants: Bool = false,
        descendantExecutables: [String] = [],
        descendantLaunchers: [LauncherType] = [],
        keepAttached: Bool = false,
        workingDirectory: URL? = nil,
        onLogFile: (@MainActor (URL) -> Void)? = nil,
        onStarted: (@MainActor () -> Void)? = nil,
        onOutput: (@MainActor (ProcessOutput) -> Void)? = nil
    ) async throws -> ProgramRunResult {
        let activityToken = beginAppNapActivity(for: bottle)
        defer { activityToken.map(ProcessInfo.processInfo.endActivity) }

        let launch = try await prepareProgramLaunch(
            at: url, args: args, bottle: bottle, environment: environment,
            programOverrides: programOverrides, programSettings: programSettings,
            gameProfileEnvironment: gameProfileEnvironment,
            overridesApplyToDescendants: overridesApplyToDescendants,
            descendantExecutables: descendantExecutables,
            descendantLaunchers: descendantLaunchers
        )

        let (fileHandle, logFileURL) = try makeProgramLogHandle(for: bottle, onLogFile: onLogFile)
        var wineEnvironment = launch.environment
        let programName = url.lastPathComponent

        let appId = steamAppId ?? SteamAppManifest.findAppIdForProgram(at: url)
        let (launchExecutable, dockEnvironment) = await resolvedDockIdentity(
            for: url, bottle: bottle,
            displayName: displayName ?? appId.flatMap { SteamAppManifest.manifest(forAppId: $0)?.name },
            appId: appId, scope: identityScope
        )
        wineEnvironment.merge(dockEnvironment) { current, _ in current }
        let runLogEntry = openRunLog(
            programName: programName, logFileURL: logFileURL, at: url, bottle: bottle,
            activeWineDebugPreset: wineEnvironment.keys.contains("WINEDEBUG")
                ? programSettings?.activeWineDebugPreset?.rawValue : nil
        )

        let runDirectory = workingDirectory ?? url.deletingLastPathComponent()
        let command = SteamHelper.command(
            program: url, args: args, workingDirectory: runDirectory, environment: wineEnvironment
        ) ?? ([url.path(percentEncoded: false)] + args)
        let launchArgs = launchArguments(
            command: command, programName: programName,
            programOverrides: programOverrides, keepAttached: keepAttached
        )

        let started = try startProcess(
            name: programName, args: launchArgs,
            environment: wineEnvironment, executableURL: launchExecutable,
            directory: keepAttached ? runDirectory : nil,
            fileHandle: fileHandle, emitsOutput: onOutput != nil
        )

        let registration = RunRegistration(
            started: started, tracked: keepAttached, bottleURL: bottle.url, programName: programName
        )
        defer { registration.release() }

        let exitCode = await drainProcessStream(started.stream, onStarted: onStarted, onOutput: onOutput)
        completeRunLog(
            id: runLogEntry.id, program: programName, in: bottle.url,
            exitCode: exitCode, hasWineDebug: wineEnvironment.keys.contains("WINEDEBUG")
        )

        return ProgramRunResult(exitCode: exitCode, logFileURL: logFileURL, runLogEntryId: runLogEntry.id)
    }

    @MainActor
    private static func beginAppNapActivity(for bottle: Bottle) -> NSObjectProtocol? {
        guard bottle.settings.disableAppNap else { return nil }
        return ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Wine process running for \(bottle.settings.name)"
        )
    }

    @MainActor
    private static func makeProgramLogHandle(
        for bottle: Bottle, onLogFile: (@MainActor (URL) -> Void)?
    ) throws -> (FileHandle, URL) {
        let (fileHandle, logFileURL) = try makeFileHandleWithURL()
        fileHandle.writeApplicationInfo()
        fileHandle.writeInfo(for: bottle)
        onLogFile?(logFileURL)
        return (fileHandle, logFileURL)
    }

    @MainActor
    private static func drainProcessStream(
        _ stream: AsyncStream<ProcessOutput>,
        onStarted: (@MainActor () -> Void)?,
        onOutput: (@MainActor (ProcessOutput) -> Void)?
    ) async -> Int32 {
        var exitCode: Int32 = 0
        for await output in stream {
            onOutput?(output)
            switch output {
            case .started: onStarted?()
            case let .terminated(code): exitCode = code
            case .message, .error: break
            }
        }
        return exitCode
    }

    @MainActor
    private static func completeRunLog(
        id: UUID, program: String, in bottleURL: URL, exitCode: Int32, hasWineDebug: Bool
    ) {
        var history = RunLogStore.load(for: program, in: bottleURL)
        history.markCompleted(id: id, exitCode: exitCode, hasWineDebug: hasWineDebug)
        RunLogStore.save(history, for: program, in: bottleURL)
    }

    /// Resolves the Dock identity for a launch: the loader binary to exec (an
    /// alias, when the display name needs one) and the environment the loader
    /// or wine64 reads it from.
    @MainActor
    private static func resolvedDockIdentity(
        for url: URL, bottle: Bottle,
        displayName: String?, appId: Int?, scope: DockIdentity.Scope
    ) async -> (executable: URL, environment: [String: String]) {
        guard let dockName = DockIdentity.displayName(for: url, title: displayName) else {
            return (wineBinary(for: bottle), [:])
        }
        let iconFile = await NativeAppIcon.iconFile(for: url, steamAppId: appId)
        let identity = DockIdentity.environment(
            displayName: dockName, exeName: url.lastPathComponent, iconFile: iconFile,
            runtime: bottle.settings.runtime, scope: scope
        )
        let executable = DockIdentity.loaderAlias(displayName: dockName, runtime: bottle.settings.runtime)
            ?? wineBinary(for: bottle)
        return (executable, identity)
    }

    /// Runs a program once `prepare` has prepared the bottle for it.
    @MainActor
    static func runProgram(
        at url: URL, bottle: Bottle, programSettings: ProgramSettings?,
        onOutput: (@MainActor (ProcessOutput) -> Void)?,
        prepare: @MainActor () async throws -> PreparedLaunch
    ) async throws -> ProgramRunResult {
        _ = try await prepare()
        return try await runProgram(
            at: url, bottle: bottle, programSettings: programSettings,
            onOutput: onOutput
        )
    }

    private struct ResolvedLaunchBackend {
        let backend: GraphicsBackend
        let launcher: LauncherType?
        let steeredLauncher: LauncherType?
        let programOverrides: ProgramOverrides?
    }

    /// The effective graphics backend for a launch, and `programOverrides` pinned
    /// to it when `.recommended` resolved somewhere other than the bottle's own
    /// resolution (a steered launcher, or a 32-bit binary) — the bottle's own
    /// override composition does not know what is being launched, so without the
    /// pin a steered launcher would get that backend's files but none of its
    /// WINEDLLOVERRIDES.
    @MainActor
    private static func resolvedLaunchBackend(
        for url: URL, bottle: Bottle, programOverrides: ProgramOverrides?,
        overridesApplyToDescendants: Bool, recommendedBackend: GraphicsBackend
    ) -> ResolvedLaunchBackend {
        // `.recommended` resolves against what is being launched, not just the
        // machine: a launcher is steered to DXVK. Not when the overrides are a
        // descendant's, as with `steam.exe -applaunch`: steam.exe is only the
        // vehicle there and the plan is the game's, so the game resolves the way
        // the bottle's games do. Steered, every game started that way got DXVK's
        // set, `d3d12=` included (#276). The launcher keeps DXVK through its own
        // `AppDefaults` entry, written from the launcher's set.
        let launcher = LauncherType.detect(from: url)
        let steeredLauncher = overridesApplyToDescendants ? nil : launcher
        let architecture = GraphicsBackendResolver.architecture(of: url)
        let chosenBackend = programOverrides?.graphicsBackend ?? bottle.settings.graphicsBackend
        let servable = WhiskyWineInstaller.backendAvailability(
            chosenBackend,
            runtimeInfo: WhiskyWineInstaller.whiskyWineInfo(for: bottle.settings.runtime),
            d3dMetalInstalled: WhiskyWineInstaller.isD3DMetalInstalled(for: bottle.settings.runtime),
            dxmtRuntimeNative: isDXMTRuntimeNative(for: bottle.settings.runtime)
        )
        let effectiveBackendChoice = (chosenBackend != .recommended && servable) ? chosenBackend : .recommended
        let effectiveBackend = if effectiveBackendChoice == .recommended {
            if let steeredLauncher {
                GraphicsBackendResolver.resolve(for: steeredLauncher, architecture: architecture)
            } else if architecture == .x32 {
                GraphicsBackend.dxvk
            } else {
                recommendedBackend
            }
        } else {
            effectiveBackendChoice
        }

        var pinnedOverrides = programOverrides
        if effectiveBackendChoice == .recommended, effectiveBackend != recommendedBackend {
            var pinned = programOverrides ?? ProgramOverrides()
            pinned.graphicsBackend = effectiveBackend
            pinnedOverrides = pinned
        }
        return ResolvedLaunchBackend(
            backend: effectiveBackend,
            launcher: launcher,
            steeredLauncher: steeredLauncher,
            programOverrides: pinnedOverrides
        )
    }

    @MainActor
    private static func preparePrefixDLLs(
        backend: GraphicsBackend, willEnableDXVK: Bool, bottle: Bottle
    ) throws {
        var keep = prefixDLLNames(for: backend, runtime: bottle.settings.runtime)
        if willEnableDXVK {
            keep.formUnion(prefixDLLNames(for: .dxvk, runtime: bottle.settings.runtime))
        }
        clearForeignBackendDLLs(keeping: keep, bottle: bottle)
        try prepareBackendPrefix(backend, bottle: bottle)
    }

    /// Prepares a bottle to launch a program, without launching it.
    ///
    /// This is everything `runProgram` does before it starts the process: it
    /// adds the Noto CJK aliases once Source Han Sans is installed, resolves
    /// the effective graphics backend, deploys that backend's files into the
    /// prefix, builds the environment, and writes the launch's DLL overrides
    /// into the prefix registry. What it writes stays in the prefix, so running
    /// the returned arguments with the returned environment later, from a
    /// terminal, starts the program with the DLLs, fonts and settings a launch
    /// from Whisky gives it. What only happens while `runProgram` runs is not
    /// part of it: the log file and run log entry, the App Nap assertion, and
    /// the Discord bridge and presence.
    ///
    /// - Parameters:
    ///   - url: The URL to the Windows executable (.exe) file.
    ///   - args: Command-line arguments to pass to the program.
    ///   - bottle: The ``Bottle`` in which the program will run.
    ///   - environment: Additional environment variables for this execution.
    ///   - programOverrides: Optional per-program setting overrides. `nil` fields inherit from bottle.
    ///   - programSettings: The program's settings, which carry its diagnostic `WINEDEBUG` preset.
    ///   - gameProfileEnvironment: Environment variables from the game's GameDB profile.
    ///   - overridesApplyToDescendants: Whether the DLL overrides belong to a process this one
    ///     spawns. For a launcher they go to `descendantExecutables` and the environment keeps
    ///     none; otherwise they stay in the environment, since the registry can only scope
    ///     overrides to an executable whose name is known.
    ///   - descendantExecutables: The executable names of what this launch starts, when the
    ///     overrides apply to descendants. The overrides go into their `AppDefaults` entries,
    ///     replacing whatever an earlier launch or version left there.
    ///   - descendantLaunchers: Launchers what this launch starts brings up on its own, such as
    ///     the Rockstar Games Launcher a Rockstar title starts inside the Steam session.
    ///   - recommendedBackend: What `.recommended` resolves to for the bottle's games.
    ///     Defaults to the resolver's answer for the installed runtime; tests pin it.
    ///   - builtinD3D12IsD3DMetal: Whether the runtime's builtin `d3d12` is D3DMetal's.
    ///     Defaults to whether the GPTK payload is deployed; tests pin it.
    ///   - overrideWriter: What writes the DLL overrides into the prefix registry. Tests pass a
    ///     recorder, so they can see what a launch writes without running Wine.
    ///   - importer: What imports the CJK font aliases the prefix is missing. Tests pass a
    ///     recorder here too.
    /// - Returns: The environment and `wine64` arguments the launch runs with.
    /// - Throws: An error if a backend's files cannot be deployed or the DLL override import
    ///   cannot be started. A failed font alias import is only logged.
    @MainActor
    static func prepareProgramLaunch(
        at url: URL, args: [String] = [], bottle: Bottle, environment: [String: String] = [:],
        programOverrides: ProgramOverrides? = nil, programSettings: ProgramSettings? = nil,
        gameProfileEnvironment: [String: String] = [:],
        overridesApplyToDescendants: Bool = false,
        descendantExecutables: [String] = [],
        descendantLaunchers: [LauncherType] = [],
        recommendedBackend: GraphicsBackend = GraphicsBackendResolver.resolve(),
        builtinD3D12IsD3DMetal: Bool = GPTKImporter.isDeployed(),
        overrideWriter: DLLOverrideWriter = { try await syncDLLOverrides(bottle: $0, scopes: $1) },
        importer: RegistryImporter = { try await importRegistry(document: $0, bottle: $1) }
    ) async throws -> PreparedLaunch {
        // Font aliases first, before any setting is read: their import can take
        // a few seconds, and a setting changed during it would leave this launch
        // with one backend's files and another's environment. It must finish
        // before the program starts, since a process reads the aliases once, and
        // like every Wine process it reconciles the user profile before starting.
        await syncCJKFontReplacements(bottle: bottle, importer: importer)

        // The effective backend for this launch: a program-level override wins
        // over the bottle setting, and `.recommended` resolves to its concrete
        // backend. This decides which translation layer's files are deployed;
        // the matching WINEDLLOVERRIDES come from the environment layers.
        let resolved = resolvedLaunchBackend(
            for: url, bottle: bottle, programOverrides: programOverrides,
            overridesApplyToDescendants: overridesApplyToDescendants, recommendedBackend: recommendedBackend
        )
        let effectiveBackend = resolved.backend
        let launcher = resolved.launcher
        let steeredLauncher = resolved.steeredLauncher
        var programOverrides = resolved.programOverrides

        // The profile has to resolve under whichever name this runtime uses
        // before anything in the bottle starts, or the app boots into an empty one.
        WineUserProfile.reconcile(bottleURL: bottle.url)

        let legacyProgramDXVKPre = programOverrides?.graphicsBackend == nil && programOverrides?.dxvk == true
        let willEnableDXVK = effectiveBackend == .dxvk || legacyProgramDXVKPre ||
            (overridesApplyToDescendants && launcher != nil) ||
            (bottle.settings.autoEnableDXVK &&
                bottle.settings.detectedLauncher?.requiresDXVK == true)

        try preparePrefixDLLs(backend: effectiveBackend, willEnableDXVK: willEnableDXVK, bottle: bottle)

        // The MetalFX placeholder serves the bottle's games, and only D3DMetal
        // answers it. A launcher's own launch says nothing about them, so it is
        // keyed on what they resolve to: keyed on the launcher's DXVK, every
        // Steam start took away the placeholder its games need (#276).
        let gamesBackend = bottle.settings.graphicsBackend == .recommended
            ? recommendedBackend : bottle.settings.graphicsBackend
        applyMetalFX(bottle: bottle, backend: steeredLauncher == nil ? effectiveBackend : gamesBackend)

        // Enable DXVK if needed: effective backend, the legacy program-level
        // flag (honored only without a backend override, mirroring
        // applyProgramOverrides), or launcher auto-enable. A launcher that only
        // carries a game's plan still runs, and its helpers keep restarting, on
        // DXVK: its files stay in place, and are copied after a DXMT plan's, so
        // the launcher keeps working when the two share a file.
        let legacyProgramDXVK = programOverrides?.graphicsBackend == nil && programOverrides?.dxvk == true
        let shouldEnableDXVK = effectiveBackend == .dxvk || legacyProgramDXVK ||
            (overridesApplyToDescendants && launcher != nil) ||
            (bottle.settings.autoEnableDXVK &&
                bottle.settings.detectedLauncher?.requiresDXVK == true)

        if shouldEnableDXVK {
            try enableDXVK(bottle: bottle)
        }

        // Build the Wine environment with program overrides flowing through the programUser layer
        var wineEnvironment = constructWineEnvironment(
            for: bottle, environment: environment, programOverrides: programOverrides,
            programSettings: programSettings, gameProfileEnvironment: gameProfileEnvironment,
            recommendedBackend: recommendedBackend, builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal
        )

        try await applyDLLOverrides(
            for: url, bottle: bottle,
            wineEnvironment: &wineEnvironment,
            applyToDescendants: overridesApplyToDescendants,
            descendantExecutables: descendantExecutables,
            descendantLaunchers: descendantLaunchers,
            recommendedBackend: recommendedBackend,
            builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal,
            writer: overrideWriter
        )

        return PreparedLaunch(
            environment: wineEnvironment,
            arguments: launchArguments(for: url, args: args, programOverrides: programOverrides)
        )
    }

    /// The `wine64` arguments for a launch, with an optional per-program virtual desktop.
    private static func launchArguments(
        for url: URL, args: [String], programOverrides: ProgramOverrides?
    ) -> [String] {
        guard let overrides = programOverrides,
              let vdEnabled = overrides.virtualDesktopEnabled, vdEnabled
        else {
            return ["start", "/unix", url.path(percentEncoded: false)] + args
        }
        let resolution = Self.resolveVirtualDesktopResolution(from: overrides)
        let desktopName = url.lastPathComponent.replacingOccurrences(of: " ", with: "_")
        return [
            "explorer", "/desktop=\(desktopName),\(resolution)",
            url.path(percentEncoded: false)
        ] + args
    }

    /// A run's entry in ``ProcessRegistry``, released when the run ends.
    ///
    /// Only an attached run is tracked: a detached run's pid is the
    /// `wine start` stub's, gone within the second and never the game.
    private struct RunRegistration {
        private let pid: Int32?

        init(started: StartedProcess, tracked: Bool, bottleURL: URL, programName: String) {
            guard tracked else {
                pid = nil
                return
            }
            ProcessRegistry.shared.registerLaunched(
                pid: started.pid, bottleURL: bottleURL, programName: programName
            )
            pid = started.pid
        }

        func release() {
            guard let pid else { return }
            ProcessRegistry.shared.unregister(pid: pid)
        }
    }

    /// Opens this run's entry in the run log and stamps the game record.
    ///
    /// Persisted as "running" before the program starts, so a session that never
    /// comes back is still visible afterwards.
    @MainActor
    private static func openRunLog(
        programName: String, logFileURL: URL, at url: URL, bottle: Bottle,
        activeWineDebugPreset: String?
    ) -> RunLogEntry {
        var runLogEntry = RunLogEntry(programName: programName, logFileName: logFileURL.lastPathComponent)
        runLogEntry.activeWineDebugPreset = activeWineDebugPreset

        var runLogHistory = RunLogStore.load(for: programName, in: bottle.url)
        let prunedEntries = runLogHistory.append(runLogEntry)
        RunLogStore.save(runLogHistory, for: programName, in: bottle.url)

        // Stamp the game record too: it is keyed by the exe's bottle-relative
        // path where the run log is keyed by bare filename, so two Launch.exe
        // in one bottle stop sharing a last-played.
        GameRecordStore(bottleURL: bottle.url).recordLaunch(.pin(at: url, bottleURL: bottle.url))
        DiscordIntegration.shared.programLaunching(url, bottle: bottle)

        for pruned in prunedEntries {
            let prunedLogURL = Self.logsFolder.appending(path: pruned.logFileName)
            try? FileManager.default.removeItem(at: prunedLogURL)
        }

        return runLogEntry
    }

    /// The argument vector `wine` is given for this run.
    ///
    /// An attached run names `command` itself, keeping its output and exit code
    /// on the pipe this process holds; `start /unix` gives up both.
    ///
    /// - Parameter command: The program and its arguments, which for a Steam
    ///   session is the helper and the game it will launch.
    static func launchArguments(
        command: [String], programName: String,
        programOverrides: ProgramOverrides?, keepAttached: Bool
    ) -> [String] {
        if let overrides = programOverrides, overrides.virtualDesktopEnabled == true {
            let resolution = Self.resolveVirtualDesktopResolution(from: overrides)
            let desktopName = programName.replacingOccurrences(of: " ", with: "_")
            return ["explorer", "/desktop=\(desktopName),\(resolution)"] + command
        }
        if keepAttached {
            return command
        }
        return ["start", "/unix"] + command
    }

    /// Resolves the virtual desktop resolution string from per-program overrides.
    ///
    /// - Parameter overrides: The program overrides containing display settings.
    /// - Returns: A resolution string like `"1920x1080"`.
    private static func resolveVirtualDesktopResolution(from overrides: ProgramOverrides) -> String {
        let preset = overrides.resolutionPreset ?? .r1920x1080
        if let dims = preset.dimensions {
            return "\(dims.width)x\(dims.height)"
        }
        if preset == .custom {
            let width = overrides.customResolutionWidth ?? 1_920
            let height = overrides.customResolutionHeight ?? 1_080
            return "\(width)x\(height)"
        }
        // matchDisplay fallback
        return "1920x1080"
    }

    /// Generates a shell command string for running a Windows program.
    ///
    /// This method creates a complete shell command that can be copied to a terminal
    /// or used in scripts. It includes all necessary environment variables and properly
    /// escapes arguments to prevent shell injection.
    ///
    /// - Parameters:
    ///   - url: The URL to the Windows executable.
    ///   - bottle: The ``Bottle`` configuration to use.
    ///   - args: Additional arguments as a single string.
    ///   - environment: Custom environment variables.
    ///   - preEscaped: If true, args are already shell-escaped and won't be escaped again.
    ///     Use this when passing an array of arguments that were individually escaped.
    /// - Returns: A shell-safe command string ready for execution.
    @MainActor
    public static func generateRunCommand(
        at url: URL, bottle: Bottle, args: String, environment: [String: String], preEscaped: Bool = false
    ) -> String {
        // Escape args and environment values to prevent shell injection from user-editable settings
        let escapedArgs = preEscaped ? args : args.esc
        WineUserProfile.reconcile(bottleURL: bottle.url)
        let wineEnv = constructWineEnvironment(for: bottle, environment: environment)
        return shellCommand(
            "\(wineBinary(for: bottle).esc) start /unix \(url.esc) \(escapedArgs)", environment: wineEnv
        )
    }

    /// Generates the shell command for a launch that has already been prepared.
    ///
    /// Unlike ``generateRunCommand(at:bottle:args:environment:preEscaped:)``, which
    /// builds the environment from the bottle again, this prints the launch's
    /// environment and arguments exactly as they are, so the command runs the way
    /// the launch would have: without the `WINEDLLOVERRIDES` that preparation moved
    /// into the prefix registry. Leaving the variable out is not enough for that,
    /// since the command only adds to the environment of the shell it runs in, and
    /// that shell may export the bottle's overrides already (`WhiskyCmd shellenv`
    /// and Open in Terminal do). So unless the launch sets the variable itself,
    /// `wine64` runs through `env -u WINEDLLOVERRIDES`.
    ///
    /// - Parameters:
    ///   - launch: A launch from `prepareProgramLaunch`.
    ///   - wineBinary: The `wine64` the command runs. Tests substitute a stub.
    /// - Returns: A shell-safe command string ready for execution.
    static func generateRunCommand(for launch: PreparedLaunch, wineBinary: URL = Wine.wineBinary) -> String {
        var words = [wineBinary.path(percentEncoded: false)] + launch.arguments
        if launch.environment["WINEDLLOVERRIDES"] == nil {
            words = ["env", "-u", "WINEDLLOVERRIDES"] + words
        }
        return shellCommand(words.map(\.esc).joined(separator: " "), environment: launch.environment)
    }

    /// Prefixes `command` with an assignment for each environment variable.
    private static func shellCommand(_ command: String, environment: [String: String]) -> String {
        var wineCmd = command
        for envVar in environment {
            if isValidEnvKey(envVar.key) {
                // Keys are validated to be safe shell identifiers; values are escaped
                // Note: No quotes needed - .esc handles all shell metacharacter escaping
                wineCmd = "\(envVar.key)=\(envVar.value.esc) " + wineCmd
            } else {
                logger.debug("Skipping invalid environment key '\(envVar.key)' in generateRunCommand")
            }
        }

        return wineCmd
    }

    /// Generates shell commands to configure a terminal session for Wine development.
    ///
    /// The generated commands set up the PATH, create convenient aliases for Wine tools,
    /// and export all necessary environment variables for the given bottle. This is the
    /// text `WhiskyCmd shellenv` prints and Open in Terminal evaluates.
    ///
    /// ## Usage
    ///
    /// Evaluate the output in zsh, bash or fish to enable Wine commands:
    ///
    /// ```bash
    /// eval "$(WhiskyCmd shellenv MyBottle)"
    /// # Afterwards you can use:
    /// wine myprogram.exe
    /// winecfg
    /// regedit
    /// ```
    ///
    /// - Parameter bottle: The ``Bottle`` to configure the environment for.
    /// - Returns: A multi-line string of shell export commands and aliases.
    @MainActor
    public static func generateTerminalEnvironmentCommand(bottle: Bottle) -> String {
        generateTerminalEnvironmentCommand(
            binFolder: WhiskyWineInstaller.binFolder(for: bottle.settings.runtime),
            environment: constructWineEnvironment(for: bottle)
        )
    }

    /// Renders the terminal environment for a Wine bin folder and a resolved environment.
    ///
    /// Every value, and the bin folder path, is quoted through ``ShellQuoting``, so nothing
    /// in it expands and `eval` sets each variable to exactly the string given here,
    /// control characters included. Apart from the constant `WINE` and alias lines,
    /// only the existing `$PATH` is left in double quotes, because it has to expand.
    /// Variables are emitted in key order so the output is stable from run to run.
    ///
    /// Split out of ``generateTerminalEnvironmentCommand(bottle:)`` so tests can point the
    /// bin folder at a path the installer never uses.
    static func generateTerminalEnvironmentCommand(binFolder: URL, environment: [String: String]) -> String {
        var cmd = """
        export PATH=\(ShellQuoting.quoted(binFolder.path)):\"$PATH\"
        export WINE=\"wine64\"
        alias wine=\"wine64\"
        alias winecfg=\"wine64 winecfg\"
        alias msiexec=\"wine64 msiexec\"
        alias regedit=\"wine64 regedit\"
        alias regsvr32=\"wine64 regsvr32\"
        alias wineboot=\"wine64 wineboot\"
        alias wineconsole=\"wine64 wineconsole\"
        alias winedbg=\"wine64 winedbg\"
        alias winefile=\"wine64 winefile\"
        alias winepath=\"wine64 winepath\"
        """

        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            if isValidEnvKey(key) {
                // Keys are validated to be safe shell identifiers. Values are single-quoted,
                // not `.esc`-escaped: `.esc` targets bare words, and inside double quotes the
                // shell keeps most of its backslashes, so `d3d11=n,b;dxgi=n,b` came back as
                // `d3d11\=n,b\;dxgi\=n,b`.
                cmd += "\nexport \(ShellQuoting.assignment(key, value))"
            } else {
                logger.debug("Skipping invalid environment key '\(key)' in generateTerminalEnvironmentCommand")
            }
        }

        return cmd
    }

    /// Run a `wineserver` command with the given arguments and return the output result
    @MainActor
    private static func runWineserver(_ args: [String], bottle: Bottle) async throws -> String {
        var result: [ProcessOutput] = []

        for await output in try Self.runWineserverProcess(args: args, bottle: bottle, environment: [:]) {
            result.append(output)
        }

        return result.compactMap { output -> String? in
            switch output {
            case .started, .terminated:
                nil
            case let .message(message), let .error(message):
                message
            }
        }.joined()
    }

    /// Runs a Wine command and returns the collected output as a string.
    ///
    /// This method executes Wine with the given arguments and waits for completion,
    /// collecting all output into a single string. Use this for commands where you
    /// need the complete result, such as queries or configuration commands.
    ///
    /// - Parameters:
    ///   - args: The command-line arguments to pass to Wine.
    ///   - bottle: Optional ``Bottle`` context. If `nil`, runs without a bottle prefix.
    ///   - environment: Additional environment variables.
    /// - Returns: The combined stdout and stderr output from the Wine process.
    /// - Throws: An error if the process cannot be started.
    ///
    /// - Note: This overload maintains backward compatibility with optional Bottle parameter.
    @discardableResult
    @MainActor
    public static func runWine(
        _ args: [String], bottle: Bottle?, environment: [String: String] = [:]
    ) async throws -> String {
        if let bottle {
            try await runWineWithBottle(args, bottle: bottle, environment: environment)
        } else {
            try await runWineWithoutBottle(args, environment: environment)
        }
    }

    /// Run a `wine` command with the given arguments and a bottle context
    ///
    /// - Parameter createsLogFile: `false` for polls whose output is parsed rather
    ///   than read, such as `tasklist.exe`: a log file per poll buries the launch
    ///   logs people are asked to attach.
    @discardableResult
    @MainActor
    static func runWineWithBottle(
        _ args: [String], bottle: Bottle, environment: [String: String] = [:], createsLogFile: Bool = true
    ) async throws -> String {
        var result: [String] = []
        let fileHandle = try createsLogFile ? makeFileHandle() : nil
        fileHandle?.writeApplicationInfo()
        fileHandle?.writeInfo(for: bottle)
        WineUserProfile.reconcile(bottleURL: bottle.url)
        let wineEnvironment = constructWineEnvironment(for: bottle, environment: environment)

        for await output in try runWineProcess(
            args: args, environment: wineEnvironment, runtime: bottle.settings.runtime, fileHandle: fileHandle
        ) {
            switch output {
            case .started, .terminated:
                break
            case let .message(message), let .error(message):
                result.append(message)
            }
        }

        return result.joined()
    }

    /// Run a `wine` command without a bottle context (e.g., for --version queries)
    @discardableResult
    @MainActor
    private static func runWineWithoutBottle(
        _ args: [String], environment: [String: String] = [:]
    ) async throws -> String {
        var result: [String] = []
        let fileHandle = try makeFileHandle()
        fileHandle.writeApplicationInfo()

        for await output in try runWineProcess(args: args, environment: environment, fileHandle: fileHandle) {
            switch output {
            case .started, .terminated:
                break
            case let .message(message), let .error(message):
                result.append(message)
            }
        }

        return result.joined()
    }

    /// Returns the version string of the installed Wine binary.
    ///
    /// This queries Wine for its version and parses the result into a clean version string.
    /// Handles various Wine version formats including CrossOver Wine (WineCX).
    ///
    /// ## Example
    ///
    /// ```swift
    /// @MainActor
    /// func displayVersion() async throws {
    ///     let version = try await Wine.wineVersion()
    ///     print("Wine version: \(version)")  // e.g., "9.0"
    /// }
    /// ```
    ///
    /// - Returns: The Wine version string (e.g., "9.0", "8.0.2").
    /// - Throws: An error if Wine cannot be executed.
    @MainActor
    public static func wineVersion() async throws -> String {
        var output = try await runWineWithoutBottle(["--version"])
        output.replace("wine-", with: "")

        // Deal with WineCX version names
        if let index = output.firstIndex(where: { $0.isWhitespace }) {
            return String(output.prefix(upTo: index))
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Executes a Windows batch file (.bat or .cmd) within a bottle.
    ///
    /// This runs the batch file using `cmd /c` through Wine, allowing execution
    /// of Windows batch scripts for installation or configuration tasks.
    ///
    /// - Parameters:
    ///   - url: The URL to the batch file.
    ///   - bottle: The ``Bottle`` in which to run the script.
    /// - Returns: The output from the batch file execution.
    /// - Throws: An error if execution fails.
    @discardableResult
    @MainActor
    public static func runBatchFile(url: URL, bottle: Bottle) async throws -> String {
        // A script can start a launcher too, so it gets the aliases a program launch gets.
        await syncCJKFontReplacements(bottle: bottle)
        return try await runWine(["cmd", "/c", url.path(percentEncoded: false)], bottle: bottle)
    }

    /// Terminates all Wine processes running in a bottle.
    ///
    /// This sends a kill signal to the bottle's Wine server, which terminates all
    /// associated processes. The operation is fire-and-forget: errors are logged
    /// but not propagated to the caller.
    ///
    /// Use this to forcefully stop all programs in a bottle, for example when
    /// a game becomes unresponsive.
    ///
    /// - Parameter bottle: The ``Bottle`` whose processes should be terminated.
    /// - Note: This is intentionally non-blocking. Errors are logged but not propagated.
    @MainActor
    public static func killBottle(bottle: Bottle) {
        Task {
            do {
                _ = try await runWineserver(["-k"], bottle: bottle)
            } catch {
                Logger.wineKit.error("Failed to kill bottle '\(bottle.settings.name)': \(error.localizedDescription)")
            }
        }
    }

    /// Kills every process in a bottle and does not return until they are gone.
    @MainActor
    public static func killBottleSynchronously(bottle: Bottle, timeout: TimeInterval = 3) {
        for tracked in ProcessRegistry.shared.getProcesses(for: bottle) where tracked.pid > 0 {
            kill(tracked.pid, SIGTERM)
        }

        let process = Process()
        process.executableURL = wineserverBinary(for: bottle)
        process.arguments = ["-k"]
        process.environment = constructWineEnvironment(for: bottle)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Logger.wineKit.error(
                "Failed to kill bottle '\(bottle.settings.name)' on quit: \(error.localizedDescription)"
            )
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }

        if process.isRunning {
            process.terminate()
            Logger.wineKit.warning(
                "wineserver -k for '\(bottle.settings.name)' did not finish within \(timeout, privacy: .public)s"
            )
        }
    }

    /// Kills a bottle's wineserver and blocks until the kill command returns.
    @MainActor
    public static func killBottleAndWait(bottle: Bottle, timeout: TimeInterval = 5) {
        killBottleSynchronously(bottle: bottle, timeout: timeout)
    }

    /// Installs DXVK libraries into a bottle's Windows system directories.
    ///
    /// DXVK translates DirectX 9/10/11 calls to Vulkan, often providing better
    /// performance than Wine's built-in DirectX implementation. This method copies
    /// the DXVK DLL files to the bottle's system32 and syswow64 directories.
    ///
    /// - Parameter bottle: The ``Bottle`` to install DXVK into.
    /// - Throws: An error if the DLL files cannot be copied.
    ///
    /// - Note: This is automatically called by ``runProgram(at:args:bottle:environment:)``
    ///   when DXVK is enabled in the bottle settings.
    @MainActor
    public static func enableDXVK(bottle: Bottle) throws {
        let dxvk = Wine.dxvkFolder(for: bottle.settings.runtime)
        try FileManager.default.replaceDLLs(
            in: bottle.url.appending(path: "drive_c").appending(path: "windows").appending(path: "system32"),
            withContentsIn: dxvk.appending(path: "x64")
        )
        try FileManager.default.replaceDLLs(
            in: bottle.url.appending(path: "drive_c").appending(path: "windows").appending(path: "syswow64"),
            withContentsIn: dxvk.appending(path: "x32")
        )
        let store = GPTKImporter.storeFolder
        let key = GPTKImporter.originalsKey(for: bottle.settings.runtime)
        let origDXGI = GPTKImporter.originalsFolder(inStore: store, key: key).appending(path: "dxgi.dll")
        reconcileDXGIForDXVK(
            prefixRoot: bottle.url,
            gptkOriginalsDXGI: origDXGI,
            gptkPayloadIsDeployed: GPTKImporter.isDeployed(for: bottle.settings.runtime),
            libraryFolder: WhiskyWineInstaller.libraryFolder(for: bottle.settings.runtime)
        )
    }

    /// Reconciles the prefix's `dxgi.dll` with the GPTK payload state, keyed on
    /// whether that payload is deployed.
    ///
    /// DXVK-macOS ships no `dxgi.dll`, so ``enableDXVK(bottle:)`` never
    /// overwrites one and whatever the prefix already holds stays behind the
    /// `n,b` override. Which copy is correct depends entirely on what the
    /// builtin is right now:
    ///
    /// - Payload deployed: the builtin is Apple's D3DMetal forwarder, which
    ///   cannot pair with DXVK's `d3d11`. The prefix needs Wine's own clean
    ///   dxgi from the store, marker-stripped so the loader takes it as a true
    ///   native PE.
    /// - Payload absent: the builtin is Wine's own, which is the pairing DXVK
    ///   is written against, so any native copy in the prefix is residue and
    ///   must go.
    ///
    /// The store outlives an engine install but the deployed payload does not,
    /// so a populated `originals/` alone does not mean the forwarder is in
    /// place. Keying on the payload rather than the store is what makes the
    /// stale-store case (originals from a previous engine, payload gone) take
    /// the removal path instead of deploying a dxgi the current runtime never
    /// shipped.
    ///
    /// The deployed branch still sweeps `syswow64`: GPTK forwards only the
    /// 64-bit builtin, so the 32-bit one is wine's own and DXMT residue there
    /// is just as wrong as without the payload. The sweep is scoped to
    /// `syswow64` on purpose; the stripped system32 copy is native by design,
    /// and a both-arch sweep would delete it on every launch.
    static func reconcileDXGIForDXVK(
        prefixRoot: URL,
        gptkOriginalsDXGI: URL = GPTKImporter.storeFolder
            .appending(path: "originals").appending(path: "dxgi.dll"),
        gptkPayloadIsDeployed: Bool = GPTKImporter.isDeployed(),
        libraryFolder: URL = WhiskyWineInstaller.libraryFolder
    ) {
        guard gptkPayloadIsDeployed else {
            removeStaleNativeDXGI(prefixRoot: prefixRoot, libraryFolder: libraryFolder)
            return
        }
        removeStaleNativeDXGI(prefixRoot: prefixRoot, libraryFolder: libraryFolder, directories: ["syswow64"])
        deployCleanDXGI(prefixRoot: prefixRoot, from: gptkOriginalsDXGI)
    }

    /// Removes a native `dxgi.dll` the prefix must not keep under DXVK.
    ///
    /// DXVK-macOS ships no `dxgi.dll`, so ``enableDXVK(bottle:)`` never
    /// overwrites one. After a bottle has launched under DXMT, its system
    /// directories hold DXMT's *native* dxgi, and a DXVK launch then pairs
    /// DXVK's `d3d11` with DXMT's `dxgi` under the `n,b` override. That mix
    /// cannot create window swapchains: Chromium clients fail with
    /// `DXGI_ERROR_UNSUPPORTED` and run with no window at all. Removing the
    /// leftover lets the `,b` half of the override load the builtin, which is
    /// the pairing DXVK is written against.
    ///
    /// Both arches are swept, because a DXMT launch writes both and a 32-bit
    /// title otherwise keeps the bad pairing. A builtin-marked file is never
    /// touched: that is wine's own fake DLL, exactly what DXVK expects to
    /// defer to, and leaving it in place is what keeps this off the
    /// per-launch prefix-mutation path.
    ///
    /// Whether removal is the right answer at all is decided by
    /// ``reconcileDXGIForDXVK(prefixRoot:gptkOriginalsDXGI:gptkPayloadIsDeployed:libraryFolder:)``,
    /// which owns the payload predicate and picks the `directories` to sweep.
    static func removeStaleNativeDXGI(
        prefixRoot: URL,
        libraryFolder: URL = WhiskyWineInstaller.libraryFolder,
        directories: Set<String> = ["system32", "syswow64"]
    ) {
        let fileManager = FileManager.default
        let builtinDirs = ["system32": "x86_64-windows", "syswow64": "i386-windows"]
        for (dir, arch) in builtinDirs where directories.contains(dir) {
            let dxgi = prefixRoot.appending(path: "drive_c").appending(path: "windows")
                .appending(path: dir).appending(path: "dxgi.dll")
            guard fileManager.fileExists(atPath: dxgi.path(percentEncoded: false)),
                  (try? isNativePE(dxgi)) == true
            else { continue }
            do {
                try fileManager.removeItem(at: dxgi)
                Logger.wineKit.info("Removed stale native dxgi.dll from \(dir, privacy: .public)")
            } catch {
                Logger.wineKit.warning(
                    "Could not remove stale native dxgi.dll: \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            // The removal must not leave the slot empty. Wine's loader only reaches a
            // builtin through its system32 placeholder (ntdll/loader.c
            // find_builtin_without_file refuses every non-16-bit DLL that has no
            // file), so with nothing here `LoadLibrary("dxgi.dll")` fails outright
            // and Chromium's GPU process cannot bring up D3D11. wineboot would
            // reinstall the placeholder on the next prefix update, but a runtime
            // whose wine.inf matches the prefix stamp never runs one. Put back the
            // runtime's own marked copy, which is what wineboot installs.
            let builtin = libraryFolder.appending(path: "Wine").appending(path: "lib")
                .appending(path: "wine").appending(path: arch).appending(path: "dxgi.dll")
            guard fileManager.fileExists(atPath: builtin.path(percentEncoded: false)) else {
                Logger.wineKit.warning("No builtin dxgi.dll to restore into \(dir, privacy: .public)")
                continue
            }
            do {
                try fileManager.copyItem(at: builtin, to: dxgi)
                Logger.wineKit.info("Restored builtin dxgi.dll placeholder into \(dir, privacy: .public)")
            } catch {
                Logger.wineKit.warning(
                    "Could not restore builtin dxgi.dll: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Strips the "Wine builtin DLL" marker at offset 0x40 from a PE file.
    private static func stripBuiltinMarker(at fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return }
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        let dosCode: [UInt8] = [
            0x0E, 0x1F, 0xBA, 0x0E, 0x00, 0xB4, 0x09, 0xCD,
            0x21, 0xB8, 0x01, 0x4C, 0xCD, 0x21, 0x90, 0x90
        ]
        try handle.seek(toOffset: 0x40)
        try handle.write(contentsOf: Data(dosCode))
    }

    /// Deploys Wine's backed-up clean `dxgi.dll` into the prefix, with the
    /// builtin marker stripped so the loader accepts it as a true native PE.
    ///
    /// Only `system32` is written: GPTK deploys forwarders into
    /// `wine/x86_64-windows` only, so the 32-bit builtin is still Wine's own
    /// and the stored 64-bit original has no business in `syswow64`.
    ///
    /// This runs on every DXVK launch, so a prefix that already holds the
    /// stripped original is left untouched rather than copied and patched
    /// again.
    static func deployCleanDXGI(prefixRoot: URL, from gptkOriginalsDXGI: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: gptkOriginalsDXGI.path(percentEncoded: false)) else { return }

        let sys32DXGI = prefixRoot.appending(path: "drive_c").appending(path: "windows")
            .appending(path: "system32").appending(path: "dxgi.dll")
        if isStrippedCopy(sys32DXGI, of: gptkOriginalsDXGI) {
            return
        }
        do {
            try fileManager.installFile(at: sys32DXGI, from: gptkOriginalsDXGI)
            try stripBuiltinMarker(at: sys32DXGI)
        } catch {
            Logger.wineKit.warning(
                "Could not deploy clean dxgi.dll into prefix: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Whether `deployed` is already what ``deployCleanDXGI(prefixRoot:from:)``
    /// would write: a native PE that matches `original` byte for byte outside
    /// the 16-byte marker window at 0x40, the only bytes the strip rewrites.
    private static func isStrippedCopy(_ deployed: URL, of original: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: deployed.path(percentEncoded: false)),
              (try? isNativePE(deployed)) == true,
              let existing = try? Data(contentsOf: deployed),
              let source = try? Data(contentsOf: original),
              existing.count == source.count,
              existing.count >= 0x50
        else { return false }
        let window = 0x40 ..< 0x50
        return existing[..<window.lowerBound] == source[..<window.lowerBound]
            && existing[window.upperBound...] == source[window.upperBound...]
    }

    /// Errors thrown by ``enableDXMT(bottle:)``.
    public enum DXMTError: LocalizedError, Equatable {
        /// The installed runtime has no usable DXMT payload — either absent
        /// (a runtime predating the DXMT payload, or a damaged/truncated
        /// install) or the older builtin-variant payload that cannot be
        /// activated per-bottle.
        case payloadMissing

        public var errorDescription: String? {
            switch self {
            case .payloadMissing:
                String(localized: "wine.dxmt.error.payloadMissing")
            }
        }
    }

    /// DXMT's D3D translation trio — native PEs loaded from the prefix under the
    /// `n,b` override.
    private static let dxmtNativeTrio = ["d3d11.dll", "dxgi.dll", "d3d10core.dll"]

    /// The DXMT files deployed into a bottle: the native D3D trio plus
    /// `winemetal.dll`. `winemetal.dll` is the builtin-marked redirect whose
    /// import resolves to the runtime's `winemetal.dll` builtin in `lib/wine`.
    /// The NVIDIA extras (nvapi64/nvngx) are not deployed into a DXMT prefix:
    /// DXMT's vendor spoofing is out of scope. D3DMetal bottles do get them.
    private static let dxmtPrefixDLLs = dxmtNativeTrio + ["winemetal.dll"]

    /// Whether the installed runtime carries a DXMT payload that can actually be
    /// activated per-bottle: present **and** the *native* variant. A
    /// builtin-marked trio (the older runtime layout) is silently ignored by the
    /// loader in favor of wined3d, so it does not count as available. Used to
    /// gate the DXMT backend in the pickers. The x64 `d3d11.dll` is sampled as
    /// the trio's representative (the runtime assembles all three together); the
    /// per-launch ``enableDXMT(payloadRoot:prefixRoot:)`` guard verifies the whole
    /// trio.
    public static func isDXMTRuntimeNative() -> Bool {
        isDXMTRuntimeNative(payloadRoot: dxmtFolder)
    }

    /// ``isDXMTRuntimeNative()`` against the payload belonging to `runtime`.
    public static func isDXMTRuntimeNative(for runtime: String?) -> Bool {
        isDXMTRuntimeNative(payloadRoot: dxmtFolder(for: runtime))
    }

    /// Capability check against an explicit payload root. Factored out so the
    /// gate can be tested against temporary fixtures (mirrors the
    /// ``enableDXMT(payloadRoot:prefixRoot:)`` seam).
    static func isDXMTRuntimeNative(payloadRoot: URL) -> Bool {
        let d3d11 = payloadRoot.appending(path: "x64").appending(path: "d3d11.dll")
        guard FileManager.default.fileExists(atPath: d3d11.path(percentEncoded: false)) else { return false }
        return (try? isNativePE(d3d11)) ?? false
    }

    /// Returns `true` when the PE at `url` is a markerless *native* DLL — i.e. its
    /// DOS stub does not carry winebuild's "Wine builtin DLL" signature in the 16
    /// bytes at offset 0x40. A builtin-marked copy placed in the prefix is ignored
    /// by the loader, which redirects to the `lib/wine` builtin (wined3d) instead.
    /// A file too short to hold those 16 bytes is treated as **not** native
    /// (fail-closed): a truncated or corrupt payload must not be deployed as if it
    /// were a working native DLL — that would resurrect the silent wined3d
    /// fallback this guard exists to prevent.
    static func isNativePE(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0x40)
        guard let marker = try handle.read(upToCount: 16), marker.count == 16 else {
            return false
        }
        return marker != Data("Wine builtin DLL".utf8)
    }

    /// Places the per-bottle files a backend needs in the prefix before launch.
    ///
    /// DXMT goes first: if launcher auto-DXVK also fires in `runProgram`, DXVK's
    /// file copy deterministically wins, matching the override-layer order where
    /// launcher-managed entries land after bottle-managed ones.
    /// The DLLs a backend leaves in a prefix, so choosing another one can take
    /// them out again. D3DMetal leaves none: it wants the runtime's builtins,
    /// and anything in `system32` shadows those.
    @MainActor
    static func prefixDLLNames(for backend: GraphicsBackend, runtime: String?) -> Set<String> {
        switch backend {
        case .dxvk:
            let folder = dxvkFolder(for: runtime).appending(path: "x64")
            let contents = (try? FileManager.default.contentsOfDirectory(
                atPath: folder.path(percentEncoded: false)
            )) ?? []
            return Set(contents.filter { $0.hasSuffix(".dll") })
        case .dxmt:
            return Set(dxmtPrefixDLLs)
        case .d3dMetal, .wined3d, .recommended:
            return []
        }
    }

    /// Whether the file in the prefix is one a backend payload put there.
    static func isBackendPayload(_ file: URL, named name: String, runtime: String?) -> Bool {
        let store = GPTKImporter.storeFolder
        let key = GPTKImporter.originalsKey(for: runtime)
        let origFolder = GPTKImporter.originalsFolder(inStore: store, key: key)
        let payloads = [
            dxvkFolder(for: runtime).appending(path: "x64"),
            dxvkFolder(for: runtime).appending(path: "x32"),
            dxmtFolder(for: runtime).appending(path: "x64"),
            dxmtFolder(for: runtime).appending(path: "x32"),
            origFolder
        ]
        guard let installed = try? Data(contentsOf: file) else { return false }

        if name == "dxgi.dll", let origData = try? Data(contentsOf: origFolder.appending(path: "dxgi.dll")),
           installed.count == origData.count {
            return true
        }

        return payloads.contains { folder in
            guard let payload = try? Data(contentsOf: folder.appending(path: name)) else {
                return false
            }
            return payload == installed
        }
    }

    /// Takes the previous backend's DLLs back out of the prefix.
    @MainActor
    static func clearForeignBackendDLLs(keeping keep: Set<String>, bottle: Bottle) {
        let runtime = bottle.settings.runtime
        let remove = prefixDLLNames(for: .dxvk, runtime: runtime)
            .union(prefixDLLNames(for: .dxmt, runtime: runtime))
            .subtracting(keep)
        guard !remove.isEmpty else { return }

        let windows = bottle.url.appending(path: "drive_c").appending(path: "windows")
        let builtins = WhiskyWineInstaller.dllFolder(for: runtime)
        let sixtyFour = ["x86_64-windows", "aarch64-windows", "arm64ec-windows"]
            .map { builtins.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        let lanes = [
            (windows.appending(path: "system32"), sixtyFour),
            (windows.appending(path: "syswow64"), builtins.appending(path: "i386-windows"))
        ]

        for (directory, builtinDirectory) in lanes.compactMap({ directory, builtin in
            builtin.map { (directory, $0) }
        }) {
            for name in remove {
                let file = directory.appending(path: name)
                guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)),
                      isBackendPayload(file, named: name, runtime: runtime)
                else { continue }

                let builtin = builtinDirectory.appending(path: name)
                do {
                    if FileManager.default.fileExists(atPath: builtin.path(percentEncoded: false)) {
                        try FileManager.default.installFile(at: file, from: builtin)
                    } else {
                        try FileManager.default.removeItem(at: file)
                    }
                } catch {
                    Logger.wineKit.warning(
                        "Could not restore \(name, privacy: .public) in the prefix"
                    )
                }
            }
        }
    }

    @MainActor
    private static func prepareBackendPrefix(_ backend: GraphicsBackend, bottle: Bottle) throws {
        switch backend {
        case .dxmt:
            try enableDXMT(bottle: bottle)
        case .d3dMetal, .dxvk, .wined3d, .recommended:
            break
        }
    }

    @MainActor
    public static func applyMetalFX(
        bottle: Bottle,
        backend: GraphicsBackend? = nil,
        libraryFolder: URL? = nil
    ) {
        let backend = backend ?? bottle.settings.graphicsBackend
        let libraryFolder = libraryFolder ?? WhiskyWineInstaller.libraryFolder(for: bottle.settings.runtime)
        if backend == .d3dMetal, bottle.settings.metalFX {
            GPTKImporter.seedMetalFXBridgePlaceholder(inBottle: bottle.url, fromLibraryFolder: libraryFolder)
            seedNGXModelConfig(inBottle: bottle.url)
        } else {
            GPTKImporter.clearMetalFXBridgePlaceholder(inBottle: bottle.url)
        }
    }

    /// Where NGX keeps the manifest its updater reads, which a real NVIDIA driver
    /// would have written.
    static let ngxModelConfigPath = ["drive_c", "ProgramData", "NVIDIA", "NGX", "models"]

    /// Writes the NGX manifest a driver install would leave behind.
    ///
    /// Streamline opens this before it does anything else and logs a pair of
    /// errors per launch when it is missing:
    ///
    ///     [streamline][error] File 'C:\ProgramData/NVIDIA/NGX/models/nvngx_config.txt' does not exist
    ///     [streamline][error] readServerManifest: Failed to open manifest file
    ///
    /// Only the over-the-air updater reads what is inside, and that updater
    /// (`nvngx_update.exe`) does not exist here either, so the contents matter
    /// less than the file existing. Left alone once written, so a real one from a
    /// driver install or a user's own edit survives.
    ///
    /// - Parameter bottle: The bottle whose prefix to seed.
    static func seedNGXModelConfig(inBottle bottle: URL) {
        let fileManager = FileManager.default
        let folder = ngxModelConfigPath.reduce(bottle) { $0.appending(path: $1) }
        let config = folder.appending(path: "nvngx_config.txt")
        guard !fileManager.fileExists(atPath: config.path(percentEncoded: false)) else { return }
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? "[global]\nversion = 1\n".write(to: config, atomically: true, encoding: .utf8)
    }

    /// Installs DXMT into a bottle so its Direct3D-11-to-Metal layer is used.
    ///
    /// Copies the native D3D translation trio (`d3d11`, `dxgi`, `d3d10core`) and
    /// `winemetal.dll` from the runtime's DXMT payload into the bottle's system
    /// directories — the same per-bottle, prefix-local model as ``enableDXVK``,
    /// selected by the `n,b` overrides from ``DLLOverrideResolver/dxmtPreset(builtinD3D12IsD3DMetal:)``.
    /// The runtime ships DXMT's `winemetal.dll` builtin (paired with its
    /// `winemetal.so` unixlib) in `lib/wine`, so this method never touches the
    /// shared Wine tree; the prefix `winemetal.dll` is the builtin-marked
    /// redirect that resolves the trio's import to that builtin.
    ///
    /// - Parameter bottle: The ``Bottle`` to install DXMT into.
    /// - Throws: ``DXMTError/payloadMissing`` when the runtime has no usable
    ///   (present and native) DXMT payload, or a `CocoaError` if a copy fails.
    ///
    /// - Note: This is automatically called by `runProgram` when the effective
    ///   graphics backend is `.dxmt`.
    @MainActor
    public static func enableDXMT(bottle: Bottle) throws {
        try enableDXMT(payloadRoot: Wine.dxmtFolder(for: bottle.settings.runtime), prefixRoot: bottle.url)
    }

    /// Performs the DXMT installation against explicit roots. Factored out of
    /// ``enableDXMT(bottle:)`` so the file placement can be tested against
    /// temporary directories (mirrors `enableDXVK`'s prefix-local copy).
    static func enableDXMT(payloadRoot: URL, prefixRoot: URL) throws {
        let fileManager = FileManager.default
        let x64Payload = payloadRoot.appending(path: "x64")
        let x32Payload = payloadRoot.appending(path: "x32")

        let windowsDir = prefixRoot.appending(path: "drive_c").appending(path: "windows")
        let system32 = windowsDir.appending(path: "system32")
        let syswow64 = windowsDir.appending(path: "syswow64")
        // The prefix having a 32-bit tree is not on its own a reason to deploy
        // one: a runtime built without a 32-bit lane, which is every arm64 one,
        // ships no x32 payload at all. Requiring it there fails a bottle whose
        // 64-bit half is complete and correct, and DXMT is 64-bit anyway.
        let deploy32Bit = fileManager.fileExists(atPath: syswow64.path(percentEncoded: false))
            && fileManager.fileExists(atPath: x32Payload.path(percentEncoded: false))

        // Validate every source BEFORE touching the prefix, and require the whole
        // trio to be the native variant. A damaged runtime (a file missing or
        // truncated) or the older builtin-variant payload (which the loader would
        // ignore in favor of wined3d) must fail with the actionable payloadMissing
        // error rather than half-deploy, or launch a bottle that silently isn't
        // using DXMT.
        var sources = dxmtPrefixDLLs.map { x64Payload.appending(path: $0) }
        if deploy32Bit {
            sources += dxmtPrefixDLLs.map { x32Payload.appending(path: $0) }
        }
        let allPresent = sources.allSatisfy { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
        let trioIsNative = dxmtNativeTrio.allSatisfy {
            (try? isNativePE(x64Payload.appending(path: $0))) == true
        }
        guard allPresent, trioIsNative else {
            throw DXMTError.payloadMissing
        }

        for name in dxmtPrefixDLLs {
            try fileManager.installFileIfContentDiffers(
                at: system32.appending(path: name),
                from: x64Payload.appending(path: name)
            )
        }

        // 32-bit half: only when the prefix actually has a syswow64 tree.
        if deploy32Bit {
            for name in dxmtPrefixDLLs {
                try fileManager.installFileIfContentDiffers(
                    at: syswow64.appending(path: name),
                    from: x32Payload.appending(path: name)
                )
            }
        }
    }
}

// MARK: - Environment Key Validation

extension Wine {
    /// Reinitializes a Wine prefix to repair missing user directories.
    ///
    /// This method runs `wineboot --init` to reinitialize the Wine prefix,
    /// which creates any missing user profile directories that may have been
    /// deleted or never properly created during initial bottle setup.
    ///
    /// Use this method when winetricks or other dependency installations fail
    /// due to missing `%AppData%` or user profile directories.
    ///
    /// - Parameter bottle: The ``Bottle`` whose prefix should be repaired.
    /// - Throws: An error if wineboot fails to initialize the prefix.
    ///
    /// - Note: This operation may take several seconds as Wine reinitializes
    ///   the prefix and creates missing directories.
    @discardableResult
    @MainActor
    public static func repairPrefix(bottle: Bottle) async throws -> String {
        logger.info("Repairing Wine prefix for bottle '\(bottle.settings.name)'")
        return try await runWine(["wineboot", "--init"], bottle: bottle)
    }

    /// Refreshes a prefix's `system32` against the runtime it now points at.
    ///
    /// A prefix records which builtin DLLs it was populated with, so a bottle
    /// moved to another runtime keeps the previous one's copies until this runs
    /// — which mixes two Wine trees in one prefix.
    ///
    /// - Parameter bottle: The ``Bottle`` whose prefix should be refreshed.
    /// - Throws: An error if wineboot fails.
    @discardableResult
    @MainActor
    public static func updatePrefix(bottle: Bottle) async throws -> String {
        logger.info("Updating Wine prefix for bottle '\(bottle.settings.name)'")
        return try await runWine(["wineboot", "-u"], bottle: bottle)
    }

    /// Checks if an environment variable key is a valid POSIX shell identifier.
    ///
    /// Valid names must start with an ASCII letter or underscore, followed by
    /// any combination of ASCII letters, digits, or underscores.
    /// This prevents shell injection through malicious environment variable keys.
    ///
    /// - Note: Uses explicit ASCII checks rather than Swift's Unicode-aware
    ///   `isLetter`/`isNumber` methods, since POSIX shells only accept ASCII
    ///   identifiers (`[A-Za-z_][A-Za-z0-9_]*`).
    ///
    /// - Parameter key: The environment variable name to validate.
    /// - Returns: `true` if the key is safe to use in shell commands.
    static func isValidEnvKey(_ key: String) -> Bool {
        guard let first = key.first else { return false }
        guard isAsciiLetter(first) || first == "_" else { return false }
        return key.allSatisfy { isAsciiLetter($0) || isAsciiDigit($0) || $0 == "_" }
    }

    /// Checks if a character is an ASCII letter (A-Z, a-z).
    static func isAsciiLetter(_ char: Character) -> Bool {
        guard let ascii = char.asciiValue else { return false }
        return (ascii >= 65 && ascii <= 90) || (ascii >= 97 && ascii <= 122) // A-Z or a-z
    }

    /// Checks if a character is an ASCII digit (0-9).
    static func isAsciiDigit(_ char: Character) -> Bool {
        guard let ascii = char.asciiValue else { return false }
        return ascii >= 48 && ascii <= 57 // 0-9
    }
}

/// Errors that can occur during Wine interface operations.
public enum WineInterfaceError: Error {
    /// The response from Wine was invalid or could not be parsed.
    case invalidResponse
    /// A build number was asked for that the bottle's Windows version cannot carry.
    case buildVersionMismatch(WinVersion, Int)
}

// MARK: - Logging Support

public extension Wine {
    /// Maximum size of a single Whisky log file written by Wine process logging.
    ///
    /// Policy: cap each individual log at 20 MiB.
    static let maxLogFileBytes: Int64 = 20 * 1_024 * 1_024

    /// Maximum total size allowed for all Whisky log files in `logsFolder`.
    ///
    /// Policy: cap total disk usage of Whisky's log directory at 200 MiB.
    static let maxLogsFolderBytes: Int64 = 200 * 1_024 * 1_024

    /// Marker appended once when file logging begins truncation.
    ///
    /// - Important: This marker is written at most once per log file and counts toward `maxLogFileBytes`.
    static let logTruncationMarker = "\n[Whisky] Log truncated: reached 20 MiB cap; further output discarded.\n"

    /// The URL to the directory where Wine process logs are stored.
    ///
    /// Logs are stored in `~/Library/Logs/{bundle-identifier}/` with ISO 8601
    /// timestamps as filenames.
    static let logsFolder = FileManager.default.urls(
        for: .libraryDirectory, in: .userDomainMask
    )[0].appending(path: "Logs").appending(path: Bundle.whiskyBundleIdentifier)

    /// Enforces log retention policy by deleting the oldest `.log` files until total size is under the limit.
    ///
    /// - Important: This method only operates on the provided folder and only deletes regular files with a `.log`
    ///   extension. It is intentionally best-effort: errors are logged but do not throw.
    static func enforceLogRetention(in folder: URL, maxTotalBytes: Int64) {
        do {
            let keys: [URLResourceKey] = [
                .isRegularFileKey,
                .contentModificationDateKey,
                .creationDateKey,
                .fileSizeKey
            ]
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )

            struct LogFile {
                let url: URL
                let size: Int64
                let date: Date
            }

            var files: [LogFile] = []
            files.reserveCapacity(urls.count)

            for url in urls {
                guard url.pathExtension.lowercased() == "log" else { continue }
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }
                let size = Int64(values.fileSize ?? 0)
                let date = values.contentModificationDate ?? values.creationDate ?? .distantPast
                files.append(LogFile(url: url, size: size, date: date))
            }

            var total: Int64 = files.reduce(0) { $0 + $1.size }
            guard total > maxTotalBytes else { return }

            // Oldest first
            files.sort { $0.date < $1.date }

            for file in files {
                guard total > maxTotalBytes else { break }
                do {
                    try FileManager.default.removeItem(at: file.url)
                    total -= file.size
                } catch {
                    let logPath = file.url.path(percentEncoded: false)
                    let errorDescription = error.localizedDescription
                    Logger.wineKit.error(
                        "Failed to remove log \(logPath, privacy: .public): \(errorDescription, privacy: .public)"
                    )
                }
            }
        } catch {
            let folderPath = folder.path(percentEncoded: false)
            let errorDescription = error.localizedDescription
            Logger.wineKit.error(
                "Failed to enforce retention in \(folderPath, privacy: .public): \(errorDescription, privacy: .public)"
            )
        }
    }

    /// Creates a new file handle for logging Wine process output.
    ///
    /// Each call creates a new log file with the current timestamp.
    /// The log directory is created if it doesn't exist.
    ///
    /// - Returns: A `FileHandle` open for writing to the new log file.
    /// - Throws: An error if the log directory or file cannot be created.
    static func makeFileHandle() throws -> FileHandle {
        let (handle, _) = try makeFileHandleWithURL()
        return handle
    }

    /// Creates a new file handle for logging and returns both the handle and the log file URL.
    ///
    /// This variant is used when the caller needs to track the log file location
    /// (e.g., for post-run crash classification).
    ///
    /// - Returns: A tuple of the open `FileHandle` and its log file `URL`.
    /// - Throws: An error if the log directory or file cannot be created.
    static func makeFileHandleWithURL() throws -> (FileHandle, URL) {
        try makeLogFile(in: logsFolderOverride ?? logsFolder, date: .now)
    }

    /// The folder ``makeFileHandleWithURL()`` creates logs in, instead of ``logsFolder``,
    /// for as long as a task binds it. Tests bind a temporary folder of their own, so the
    /// helper runs they make never write under `~/Library/Logs`, and test processes
    /// running in parallel never share a logs folder.
    @TaskLocal internal static var logsFolderOverride: URL?

    /// Creates a new log file in `folder`, named for `date`, and opens it for writing.
    ///
    /// The name is the ISO 8601 timestamp to the millisecond, with `-2`, `-3` and so on
    /// appended while that name is taken, and the file is only ever created, never
    /// replaced. Names used to stop at the second and the file was written atomically,
    /// so a helper started in the same second as a launch, such as the DLL override
    /// import, replaced the launch's log: the program went on writing to a file that
    /// was no longer on disk, and the log recorded for the run held only the helper's
    /// output.
    ///
    /// - Parameters:
    ///   - folder: The directory to create the log in. It is created if missing.
    ///   - date: The time the log is named for.
    /// - Returns: A tuple of the open `FileHandle` and its log file `URL`.
    /// - Throws: An error if the log directory or file cannot be created.
    internal static func makeLogFile(in folder: URL, date: Date) throws -> (FileHandle, URL) {
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        // Enforce retention before creating a new log file.
        // This is best-effort and only impacts Whisky's own log directory.
        enforceLogRetention(in: folder, maxTotalBytes: maxLogsFolderBytes)

        let timestamp = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        for attempt in 1 ... maxLogNameAttempts {
            let name = attempt == 1 ? timestamp : "\(timestamp)-\(attempt)"
            let fileURL = folder.appending(path: name).appendingPathExtension("log")
            if let handle = try createNewFile(at: fileURL) {
                return (handle, fileURL)
            }
        }
        throw POSIXError(.EEXIST)
    }

    /// How many names ``makeLogFile(in:date:)`` tries for one timestamp.
    private static let maxLogNameAttempts = 100

    /// Creates a file at `url` and opens it for writing, or returns `nil` when
    /// something already exists there. `O_EXCL` makes the check and the creation
    /// one step, so two writers can never end up sharing a path.
    private static func createNewFile(at url: URL) throws -> FileHandle? {
        let (descriptor, error) = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            guard let path else {
                return (-1, EINVAL)
            }
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            return (descriptor, descriptor < 0 ? errno : 0)
        }
        if descriptor >= 0 {
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        guard error == EEXIST else {
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        return nil
    }

    /// Classifies the output from a Wine process run for crash patterns.
    ///
    /// Reads the head and the tail of the log, not the tail alone: missing-DLL
    /// (`import_dll`) and backend-init failures are head-of-log events, and a
    /// long session buries them under hours of output a tail-only window never
    /// sees. Runs on a background task to avoid blocking the UI.
    ///
    /// - Parameters:
    ///   - logFileURL: URL to the Wine log file to analyze.
    ///   - exitCode: The Wine process exit code.
    ///   - classifier: Optional pre-configured classifier. If `nil`, creates one
    ///     with default patterns.
    /// - Returns: A ``CrashDiagnosis`` if the log was readable, or `nil` on failure.
    static func classifyLastRun(
        logFileURL: URL,
        exitCode: Int32,
        classifier: CrashClassifier? = nil
    ) async -> CrashDiagnosis? {
        await Task.detached(priority: .utility) {
            guard let logText = try? classificationWindow(of: logFileURL), !logText.isEmpty else {
                return nil
            }
            let resolvedClassifier = classifier ?? CrashClassifier()
            return resolvedClassifier.classify(log: logText, exitCode: exitCode)
        }.value
    }

    /// The head and tail of a log, joined into the window classification reads.
    private nonisolated static func classificationWindow(of logFileURL: URL) throws -> String? {
        let maxTailBytes = 256 * 1_024
        let maxHeadBytes = 64 * 1_024
        let maxTailLines = 500
        let maxHeadLines = 200

        let handle = try FileHandle(forReadingFrom: logFileURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()

        if end <= UInt64(maxHeadBytes + maxTailBytes) {
            try handle.seek(toOffset: 0)
            let data = try handle.readToEnd() ?? Data()
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count <= maxHeadLines + maxTailLines {
                return text
            }
            return (lines.prefix(maxHeadLines) + lines.suffix(maxTailLines)).joined(separator: "\n")
        }

        try handle.seek(toOffset: 0)
        let headData = try handle.read(upToCount: maxHeadBytes) ?? Data()
        var head = String(data: headData, encoding: .utf8) ?? ""
        // Drop the trailing partial line of the head window.
        if let lastNewline = head.lastIndex(of: "\n") {
            head = String(head[..<lastNewline])
        }
        let headLines = head
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(maxHeadLines)

        try handle.seek(toOffset: end - UInt64(maxTailBytes))
        let tailData = try handle.readToEnd() ?? Data()
        var tail = String(data: tailData, encoding: .utf8) ?? ""
        // Drop the leading partial line of the tail window.
        if let firstNewline = tail.firstIndex(of: "\n") {
            tail = String(tail[tail.index(after: firstNewline)...])
        }
        let tailLines = tail
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maxTailLines)

        return (headLines + tailLines).joined(separator: "\n")
    }
}

// swiftlint:enable type_body_length
