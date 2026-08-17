//
//  QuickLaunch.swift
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
import os.log
import WhiskyKit

/// Launching from surfaces that live outside the main window: the Dock menu,
/// the menu-bar extra, and `whisky://` URLs.
@MainActor
enum QuickLaunch {
    private static let logger = Logger(
        subsystem: Bundle.whiskyBundleIdentifier, category: "QuickLaunch"
    )

    /// Every pin whose file still exists, across all available bottles.
    ///
    /// Reads `settings.pins` rather than `bottle.pinnedPrograms`: the latter
    /// resolves against `bottle.programs`, which stays empty until a bottle
    /// view scans it. Pins live in settings and are always loaded.
    static func availablePins() -> [(bottle: Bottle, pin: PinnedProgram)] {
        BottleVM.shared.bottles.filter(\.isAvailable).flatMap { bottle in
            bottle.settings.pins.compactMap { pin -> (bottle: Bottle, pin: PinnedProgram)? in
                guard let path = pin.url?.path(percentEncoded: false),
                      FileManager.default.fileExists(atPath: path)
                else { return nil }
                return (bottle, pin)
            }
        }
    }

    /// Launches a pinned program without a prior bottle scan.
    ///
    /// The `Program` is built from the pin so this doesn't depend on a bottle
    /// view having scanned. Failures are reported via an `NSAlert` rather than
    /// a view toast because these surfaces can be the app's only one (the main
    /// window may be closed), so there's no toast presenter to reach.
    static func launch(pin: PinnedProgram, in bottle: Bottle) {
        guard let url = pin.url else { return }
        let program = Program(url: url, bottle: bottle)
        Task {
            let result = await program.launchWithUserMode(useTerminal: false)
            guard case let .launchFailed(_, errorDescription) = result else { return }
            logger.error(
                "Quick launch failed for \(pin.name, privacy: .public): \(errorDescription, privacy: .public)"
            )
            presentLaunchFailure(programName: pin.name, error: errorDescription)
        }
    }

    private static func presentLaunchFailure(programName: String, error: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "menubar.launchFailed \(programName)")
        alert.informativeText = error
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "button.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - whisky:// URLs

    /// Handles a `whisky://` URL. Returns `false` for any other scheme so
    /// file opens keep flowing to `FileOpenView`.
    ///
    /// Forms:
    /// - `whisky://launch?steam=<appid>[&bottle=<name>]`
    /// - `whisky://launch?pin=<name>[&bottle=<name>]`
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == "whisky" else { return false }
        guard url.host() == "launch",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            logger.error("Unrecognized whisky URL: \(url.absoluteString, privacy: .public)")
            return true
        }

        func value(_ name: String) -> String? {
            components.queryItems?.first(where: { $0.name == name })?.value
        }

        if let steam = value("steam"), let appId = Int(steam) {
            launchSteam(appId: appId, bottleName: value("bottle"))
        } else if let pinName = value("pin") {
            launchPin(named: pinName, bottleName: value("bottle"))
        } else {
            logger.error("whisky://launch without steam or pin: \(url.absoluteString, privacy: .public)")
        }
        return true
    }

    private static func launchSteam(appId: Int, bottleName: String?) {
        let bottles = BottleVM.shared.bottles.filter(\.isAvailable)
        do {
            let target: Bottle
            if let bottleName {
                guard let named = bottles.first(where: { $0.settings.name == bottleName }) else {
                    presentLaunchFailure(
                        programName: "Steam \(appId)",
                        error: "No bottle named \(bottleName)."
                    )
                    return
                }
                target = named
            } else {
                target = try SteamLauncher.resolveBottle(appId: appId, in: bottles)
            }
            _ = try SteamLauncher.launch(appId: appId, bottle: target)
        } catch {
            presentLaunchFailure(programName: "Steam \(appId)", error: error.localizedDescription)
        }
    }

    private static func launchPin(named pinName: String, bottleName: String?) {
        let matches = availablePins().filter { entry in
            entry.pin.name.localizedCaseInsensitiveCompare(pinName) == .orderedSame
                && (bottleName == nil || entry.bottle.settings.name == bottleName)
        }
        guard let hit = matches.first else {
            presentLaunchFailure(
                programName: pinName,
                error: "Nothing pinned under that name."
            )
            return
        }
        launch(pin: hit.pin, in: hit.bottle)
    }
}
