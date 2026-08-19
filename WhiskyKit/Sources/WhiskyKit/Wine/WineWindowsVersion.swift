//
//  WineWindowsVersion.swift
//  WhiskyKit
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

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "WineWindowsVersion")

public extension WinVersion {
    /// The version a prefix reports, worked out from the registry values a
    /// Windows program actually reads.
    ///
    /// `CurrentVersion` stops moving at 6.3 from Windows 8.1 onwards, which is
    /// what Windows itself does, so the build number separates 8.1 from 10 and 11.
    ///
    /// - Parameters:
    ///   - currentVersion: The `CurrentVersion` string, for example `"6.1"`.
    ///   - build: The `CurrentBuild` number, when it is readable.
    init?(currentVersion: String, build: Int?) {
        switch currentVersion {
        case "5.2": self = .winXP
        case "6.1": self = .win7
        case "6.2": self = .win8
        case "6.3", "10.0":
            guard let build else {
                self = currentVersion == "10.0" ? .win10 : .win81
                return
            }
            self = if build >= WinVersion.win11.buildRange.lowerBound {
                .win11
            } else if build >= WinVersion.win10.buildRange.lowerBound {
                .win10
            } else {
                .win81
            }
        default: return nil
        }
    }
}

/// What the last sync wrote, so a launch that changes nothing costs nothing.
struct WindowsVersionState: Codable, Equatable {
    let version: WinVersion

    private static let fileName = ".windows-version-state.plist"

    static func load(from bottleURL: URL) -> WindowsVersionState? {
        guard let data = try? Data(contentsOf: bottleURL.appending(path: fileName)) else { return nil }
        return try? PropertyListDecoder().decode(WindowsVersionState.self, from: data)
    }

    func save(to bottleURL: URL) throws {
        let data = try PropertyListEncoder().encode(self)
        try data.write(to: bottleURL.appending(path: Self.fileName))
    }
}

public extension Wine {
    /// The Windows version this prefix reports to the programs inside it.
    ///
    /// Deliberately not `winecfg -v`: that answers with the name of the closest
    /// version it recognises, so a prefix carrying 6.1 with a Windows 11 build
    /// number came back as "vista" while every program in it read Windows 7.
    ///
    /// - Parameter bottle: The bottle whose prefix to read.
    /// - Returns: The version the prefix reports, or `nil` when the registry
    ///   values do not name one.
    @MainActor
    static func reportedWindowsVersion(bottle: Bottle) async throws -> WinVersion? {
        guard let currentVersion = try await queryRegistryKey(
            bottle: bottle, key: #"HKLM\Software\Microsoft\Windows NT\CurrentVersion"#,
            name: "CurrentVersion", type: .string
        )
        else {
            return nil
        }
        let build = try await buildVersion(bottle: bottle).flatMap(Int.init)
        return WinVersion(currentVersion: currentVersion, build: build)
    }

    /// Brings the prefix in line with the bottle's Windows version setting.
    ///
    /// The setting was applied once, when it was picked, and never checked
    /// again: a write that failed, or a prefix adopted from another Whisky,
    /// left the picker saying Windows 11 over a prefix telling Steam it was
    /// Windows 7. Called from the launch path, where being wrong actually costs
    /// something.
    ///
    /// - Parameter bottle: The bottle to reconcile.
    @MainActor
    static func syncWindowsVersion(bottle: Bottle) async {
        let desired = bottle.settings.windowsVersion
        guard WindowsVersionState.load(from: bottle.url)?.version != desired else { return }

        do {
            let reported = try await reportedWindowsVersion(bottle: bottle)
            if reported != desired {
                logger.info(
                    """
                    Prefix '\(bottle.settings.name, privacy: .public)' reports \
                    \(reported?.pretty() ?? "an unnamed version", privacy: .public), \
                    applying \(desired.pretty(), privacy: .public)
                    """
                )
                try await changeWinVersion(bottle: bottle, win: desired)
            }
            try WindowsVersionState(version: desired).save(to: bottle.url)
        } catch {
            logger.error(
                """
                Windows version sync failed for '\(bottle.settings.name, privacy: .public)': \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }
}
