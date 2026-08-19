// swiftlint:disable file_length
//
//  WhiskyApp.swift
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

import os.log
import SwiftUI
import WhiskyKit

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.dappermint.WhiskyPreview", category: "WhiskyApp"
)

@main
// swiftlint:disable:next type_body_length
struct WhiskyApp: App {
    /// True when launched by the UI test harness (the `-WhiskyUITestMode` launch
    /// argument set in `WhiskyUITests`). UI tests run without a Wine runtime
    /// installed, which would otherwise auto-present the first-launch setup sheet
    /// over the main window and race every toolbar interaction; this lets that
    /// auto-presentation (and the update check) be skipped in tests.
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("-WhiskyUITestMode")

    /// Scene id for the main window, used to reopen it from the menu-bar extra.
    static let mainWindowID = "main"

    /// Scene id for the Debug window.
    static let debugWindowID = "debug"

    /// Opt-in: show a menu-bar extra and keep Whisky running after the main
    /// window closes (see `AppDelegate.applicationShouldTerminateAfterLastWindowClosed`).
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = false
    @State var showSetup: Bool = false
    @State private var showMigrate: Bool = false
    @State private var showDiagnosticsSheet: Bool = false
    @State private var showTroubleshootingPicker: Bool = false
    @State private var showTroubleshootingWizard: Bool = false
    @State private var troubleshootingBottle: Bottle?
    @State private var troubleshootingProgram: Program?
    @State private var troubleshootingEntryContext: EntryContext?
    @State private var crashDiagnosisBanner: CrashDiagnosisBannerState?
    @State private var crashDiagnosisSheet: CrashDiagnosisBannerState?
    @State private var crashDiagnosisLogText: String = ""
    @State private var audioDeviceToast: ToastData?
    @State private var audioMonitor = AudioDeviceMonitor()
    @State private var audioAlertTracker = AudioAlertTracker()
    @AppStorage("audioDeviceAlerts") private var audioDeviceAlerts = true
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openURL) var openURL
    @Environment(\.openWindow) var openWindow

    init() {
        Telemetry.startIfConsented()
    }

    /// Installs the D3D12 video processor and the MetalFX bridge into runtimes
    /// that already hold the GPTK payload.
    ///
    /// Deploying does both too, but an install that was set up before they
    /// existed never deploys again, so without this it would keep rendering
    /// video through the engine's broken fallback, and keep MetalFX
    /// unreachable, until it happened to reimport. Idempotent, and a no-op on
    /// runtimes and payloads that carry neither.
    private func installGPTKExtrasIfNeeded() {
        var data = BottleData()
        let bottles = data.loadBottles().map(\.url)
        Task.detached(priority: .background) {
            GPTKImporter.ensureVideoProcessorEverywhere(bottles: bottles)
            GPTKImporter.ensureMetalFXBridgeEverywhere()
        }
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView(showSetup: $showSetup)
                // Wide enough for two columns of library cards next to the
                // sidebar. At 600 the grid could only ever draw one.
                .frame(minWidth: ViewWidth.window, minHeight: 316)
                .environmentObject(BottleVM.shared)
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                    Task.detached {
                        await WhiskyApp.deleteOldLogs()
                    }
                    installGPTKExtrasIfNeeded()
                    startAudioDeviceListening()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .crashDiagnosisAvailable)
                ) { notification in
                    handleCrashDiagnosisNotification(notification)
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: CrashNotifier.openDiagnosis)
                ) { notification in
                    openDiagnosisFromUserNotification(notification)
                }
                .sheet(isPresented: $showDiagnosticsSheet) {
                    DiagnosticsPickerSheet()
                        .environmentObject(BottleVM.shared)
                }
                .sheet(isPresented: $showTroubleshootingPicker) {
                    TroubleshootingTargetPicker(
                        bottles: BottleVM.shared.bottles
                    ) { bottle, program in
                        troubleshootingBottle = bottle
                        troubleshootingProgram = program
                        troubleshootingEntryContext = .helpMenu(
                            bottleURL: bottle.url,
                            programURL: program?.url
                        )
                        showTroubleshootingWizard = true
                    }
                }
                .sheet(isPresented: $showTroubleshootingWizard) {
                    if let bottle = troubleshootingBottle,
                       let context = troubleshootingEntryContext {
                        TroubleshootingWizardView(
                            bottle: bottle,
                            program: troubleshootingProgram,
                            entryContext: context
                        )
                    }
                }
                .sheet(isPresented: $showMigrate) {
                    MigrateBottlesSheet()
                        .environmentObject(BottleVM.shared)
                }
                .sheet(item: $crashDiagnosisSheet) { banner in
                    DiagnosticsView(
                        diagnosis: banner.diagnosis,
                        logText: crashDiagnosisLogText,
                        programName: banner.programName,
                        bottleName: bottle(forProgramPath: banner.programPath)?.settings.name ?? "",
                        timestamp: Date(),
                        applyBottle: bottle(forProgramPath: banner.programPath)
                    )
                    .frame(minWidth: 600, minHeight: 400)
                }
                .overlay(alignment: .top) {
                    if let banner = crashDiagnosisBanner {
                        crashDiagnosisBannerView(banner)
                    }
                }
                .toast($audioDeviceToast)
        }
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(before: .systemServices) {
                Divider()
                Button("open.setup") {
                    showSetup = true
                }
                Button("install.cli") {
                    Task {
                        await WhiskyCmd.install()
                    }
                }
            }
            CommandGroup(replacing: .newItem) {
                // Cmd-N was deleted with the stock New menu; a launcher's
                // most natural new thing is a bottle.
                Button("button.createBottle") {
                    NotificationCenter.default.post(name: .whiskyCreateBottle, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .newItem) {
                Button("open.bottle") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = false
                    panel.begin { result in
                        if result == .OK {
                            if let url = panel.urls.first {
                                // Task inherits main actor context from SwiftUI commands builder
                                Task {
                                    BottleVM.shared.bottlesList.paths.append(url)
                                    BottleVM.shared.loadBottles()
                                }
                            }
                        }
                    }
                }
                .keyboardShortcut("I", modifiers: [.command])
                Button("Import Bottles from Another Whisky…") {
                    showMigrate = true
                }
            }
            CommandGroup(after: .importExport) {
                Button("debug.window.open") {
                    openWindow(id: Self.debugWindowID)
                }
                .keyboardShortcut("B", modifiers: [.command, .shift])
                Button("open.logs") {
                    WhiskyApp.openLogsFolder()
                }
                .keyboardShortcut("L", modifiers: [.command])
                Button("kill.bottles") {
                    WhiskyApp.killBottles()
                }
                .keyboardShortcut("K", modifiers: [.command, .shift])
                Button("wine.clearShaderCaches") {
                    WhiskyApp.killBottles() // Better not make things more complicated for ourselves
                    WhiskyApp.wipeShaderCaches()
                }
            }
            CommandGroup(replacing: .help) {
                Button("help.github") {
                    if let url = URL(string: "https://github.com/dappermint/Whisky") {
                        openURL(url)
                    }
                }
                // Issues are disabled on the preview repo, so reports go to
                // upstream's tracker, where anything preview-only is out of
                // scope. docs/SUPPORT.md tells people which is which.
                Button("help.issues") {
                    if let url = URL(string: "https://github.com/frankea/Whisky/issues") {
                        openURL(url)
                    }
                }
                Divider()
                Button("Run Diagnostics\u{2026}") {
                    showDiagnosticsSheet = true
                }
                .keyboardShortcut("D", modifiers: [.command, .shift])
                Button(String(localized: "troubleshooting.entry.helpMenu")) {
                    showTroubleshootingPicker = true
                }
                .keyboardShortcut("T", modifiers: [.command, .shift])
            }
        }
        Window("debug.window.title", id: Self.debugWindowID) {
            DebugWindowView()
                .environmentObject(BottleVM.shared)
        }
        .defaultSize(width: 900, height: 620)

        Settings {
            SettingsView()
        }
        MenuBarExtra("Whisky Preview", systemImage: "wineglass", isInserted: $showMenuBarExtra) {
            WhiskyMenuBarView()
                .environmentObject(BottleVM.shared)
        }
    }

    // MARK: - Crash Diagnosis Notification

    private func handleCrashDiagnosisNotification(_ notification: Notification) {
        guard let diagnosis = notification.userInfo?["diagnosis"] as? CrashDiagnosis,
              let programPath = notification.userInfo?["programPath"] as? String,
              let logFileURL = notification.userInfo?["logFileURL"] as? URL
        else { return }

        let programName = URL(fileURLWithPath: programPath).deletingPathExtension().lastPathComponent
        crashDiagnosisBanner = CrashDiagnosisBannerState(
            diagnosis: diagnosis,
            programName: programName,
            programPath: programPath,
            logFileURL: logFileURL
        )

        // A game usually crashes while its own window is frontmost, so the
        // banner above plays to an empty room; Notification Center is what
        // actually reaches the person.
        if !NSApp.isActive {
            CrashNotifier.notify(
                programName: programName,
                category: diagnosis.primaryCategory,
                programPath: programPath,
                logFileURL: logFileURL
            )
        }

        // Auto-dismiss after 8 seconds
        Task {
            try? await Task.sleep(for: .seconds(8))
            withAnimation {
                crashDiagnosisBanner = nil
            }
        }
    }

    /// A click on the crash notification: the diagnosis is re-derived from
    /// the log it named, the same way the launcher section reopens one.
    private func openDiagnosisFromUserNotification(_ notification: Notification) {
        guard let programPath = notification.userInfo?[CrashNotifier.programPathKey] as? String,
              let logFile = notification.userInfo?[CrashNotifier.logFileKey] as? String
        else { return }

        let logFileURL = URL(fileURLWithPath: logFile)
        let programName = URL(fileURLWithPath: programPath).deletingPathExtension().lastPathComponent
        Task {
            guard let diagnosis = await Wine.classifyLastRun(logFileURL: logFileURL, exitCode: 1) else { return }
            openDiagnosisFromCrash(CrashDiagnosisBannerState(
                diagnosis: diagnosis,
                programName: programName,
                programPath: programPath,
                logFileURL: logFileURL
            ))
        }
    }

    private func crashDiagnosisBannerView(_ banner: CrashDiagnosisBannerState) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(String(format: String(localized: "crash.banner.title"), banner.programName))
                .fontWeight(.medium)
            Spacer()
            Button("crash.banner.viewDiagnosis") {
                openDiagnosisFromCrash(banner)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(String(localized: "troubleshooting.entry.troubleshoot")) {
                openTroubleshootingFromCrash(banner)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                withAnimation {
                    crashDiagnosisBanner = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.controlBackgroundColor))
                .shadow(radius: 4)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Troubleshooting from Crash Banner

    /// The bottle whose prefix contains `programPath`, if any.
    private func bottle(forProgramPath programPath: String) -> Bottle? {
        BottleVM.shared.bottles.first { bottle in
            programPath.hasPrefix(bottle.url.path(percentEncoded: false))
        }
    }

    private func openDiagnosisFromCrash(_ banner: CrashDiagnosisBannerState) {
        withAnimation {
            crashDiagnosisBanner = nil
        }
        Task {
            crashDiagnosisLogText = (try? String(contentsOf: banner.logFileURL, encoding: .utf8)) ?? ""
            crashDiagnosisSheet = banner
        }
    }

    private func openTroubleshootingFromCrash(_ banner: CrashDiagnosisBannerState) {
        withAnimation {
            crashDiagnosisBanner = nil
        }

        guard let bottle = bottle(forProgramPath: banner.programPath) else {
            // Fallback: open picker if we could not match the program
            showTroubleshootingPicker = true
            return
        }

        let program = bottle.programs.first { program in
            program.url.path(percentEncoded: false) == banner.programPath
        }
        let evidence: [String: String] = [
            "crashCategory": banner.diagnosis.primaryCategory?.rawValue ?? "unknown",
            "logFileURL": banner.logFileURL.absoluteString
        ]
        troubleshootingBottle = bottle
        troubleshootingProgram = program
        troubleshootingEntryContext = .launchFailure(
            programURL: program?.url ?? URL(fileURLWithPath: banner.programPath),
            bottleURL: bottle.url,
            evidence: evidence
        )
        showTroubleshootingWizard = true
    }

    // MARK: - Audio Device Alerts

    private func startAudioDeviceListening() {
        audioMonitor.startListening { event in
            Task { @MainActor in
                guard audioDeviceAlerts,
                      audioAlertTracker.shouldAlert(deviceName: event.deviceName)
                else { return }

                let title: String
                let style: ToastStyle
                switch event.eventType {
                case .defaultOutputChanged, .disconnected:
                    title = String(localized: "audio.alert.disconnected")
                    style = .info
                case .reconnected:
                    title = String(localized: "audio.alert.reconnected")
                    style = .success
                case .sampleRateChanged:
                    // Only worth a word when the rate is HFP-low (Bluetooth
                    // headset fell back to its telephony profile).
                    guard let device = audioMonitor.defaultOutputDevice(),
                          device.sampleRate < 22_050, device.sampleRate > 0
                    else { return }
                    title = String(localized: "audio.alert.lowSampleRate")
                    style = .info
                }

                // A toast in Whisky's window is invisible exactly when it
                // matters, mid-game with the headset gone, so background
                // alerts go to Notification Center instead.
                if NSApp.isActive {
                    audioDeviceToast = ToastData(
                        message: title + ": \(event.deviceName)", style: style
                    )
                } else {
                    CrashNotifier.notifyInfo(
                        title: title,
                        body: event.deviceName,
                        identifier: "audio-\(event.deviceName)"
                    )
                }
            }
        }
    }
}

// MARK: - WhiskyApp Utility Methods

extension WhiskyApp {
    @MainActor
    static func killBottles() {
        for bottle in BottleVM.shared.bottles {
            // killBottle is fire-and-forget; errors are logged internally
            Wine.killBottle(bottle: bottle)
        }
    }

    static func openLogsFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Wine.logsFolder.path)
    }

    static func deleteOldLogs() {
        let pastDate = Date().addingTimeInterval(-7 * 24 * 60 * 60)

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: Wine.logsFolder,
            includingPropertiesForKeys: [.creationDateKey]
        )
        else {
            return
        }

        let logs = urls.filter { url in
            url.pathExtension == "log"
        }

        let oldLogs = logs.filter { url in
            do {
                let resourceValues = try url.resourceValues(forKeys: [.creationDateKey])

                return resourceValues.creationDate ?? Date() < pastDate
            } catch {
                return false
            }
        }

        for log in oldLogs {
            do {
                try FileManager.default.removeItem(at: log)
            } catch {
                logger.warning("Failed to delete log: \(error.localizedDescription)")
            }
        }
    }

    static func wipeShaderCaches() {
        let getconf = Process()
        getconf.executableURL = URL(fileURLWithPath: "/usr/bin/getconf")
        getconf.arguments = ["DARWIN_USER_CACHE_DIR"]
        let pipe = Pipe()
        getconf.standardOutput = pipe
        do {
            try getconf.run()
        } catch {
            logger.error("Failed to run getconf: \(error.localizedDescription)")
            return
        }
        getconf.waitUntilExit()

        let getconfOutput: Data
        do {
            getconfOutput = try pipe.fileHandleForReading.readToEnd() ?? Data()
        } catch {
            logger.error("Failed to read getconf output: \(error.localizedDescription)")
            return
        }

        guard let getconfOutputString = String(data: getconfOutput, encoding: .utf8) else {
            logger.error("Failed to decode getconf output as UTF-8")
            return
        }
        let d3dmPath = URL(fileURLWithPath: getconfOutputString.trimmingCharacters(in: .whitespacesAndNewlines))
            .appending(path: "d3dm").path
        do {
            try FileManager.default.removeItem(atPath: d3dmPath)
            logger.info("Successfully cleared shader caches")
        } catch {
            logger.warning("Failed to remove shader cache at \(d3dmPath): \(error.localizedDescription)")
        }
    }
}
