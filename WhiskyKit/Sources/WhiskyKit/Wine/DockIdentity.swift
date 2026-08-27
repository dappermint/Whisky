//
//  DockIdentity.swift
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

/// Gives a running Windows program the name and icon macOS shows for it.
///
/// LaunchServices names a process with no bundle after the file that was
/// exec'd, which for every Wine launch is the loader, so the Dock reads
/// `wine64` for all of them. Wine's own answer is to exec a hard link to the
/// loader named after the program: same inode, so the code signature and its
/// entitlements come along, but a name a person recognises. That link is made
/// inside `ntdll` for every process Wine spawns, and here for the first one,
/// which Wine never re-execs and so never renames.
///
/// The environment carries the rest: the display name for the processes
/// `ntdll` does rename, an icon file for the patched `winemac.drv`, and the
/// two paths the loader needs once it is running from somewhere that is not
/// its own directory.
public enum DockIdentity {
    /// Characters that would change the meaning of the link path, or that read
    /// badly in a Dock tile.
    private static let unsafe = CharacterSet(charactersIn: "/:\\")
    /// Long enough for any real game title, short enough that the link path
    /// stays well inside `PATH_MAX`.
    private static let maximumLength = 60

    /// Trims a program's name down to something safe to use as a file name.
    ///
    /// - Returns: The trimmed name, or `nil` when nothing usable is left.
    public static func sanitized(_ name: String) -> String? {
        let stripped = name.unicodeScalars
            .map { unsafe.contains($0) || $0.value < 0x20 ? " " : Character($0) }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !stripped.isEmpty, stripped != ".", stripped != ".." else { return nil }
        return String(stripped.prefix(maximumLength))
    }

    /// The name to show for the program at `url`, preferring the GameDB title.
    ///
    /// Falls back to the executable's own name without its extension, which is
    /// what Wine would have used anyway.
    public static func displayName(for url: URL, title: String?) -> String? {
        if let title, let sanitized = sanitized(title) { return sanitized }
        return sanitized(url.deletingPathExtension().lastPathComponent)
    }

    /// Returns a hard link to `runtime`'s loader named `displayName`, creating
    /// it on first use, for a launch to exec in the loader's place.
    ///
    /// The link lives beside a symlink to `ntdll.so`, since the loader finds
    /// that by looking next to itself. Everything else it needs comes from
    /// ``environment(displayName:iconFile:runtime:)``.
    ///
    /// - Returns: The link, or `nil` if it could not be made, in which case the
    ///   caller should launch the loader directly and accept its own name.
    public static func loaderAlias(displayName: String, runtime: String?) -> URL? {
        let fileManager = FileManager.default
        let loader = WhiskyWineInstaller.binFolder(for: runtime)
            .appending(path: "wine64")
            .resolvingSymlinksInPath()
        let loaderPath = loader.path(percentEncoded: false)

        guard let attributes = try? fileManager.attributesOfItem(atPath: loaderPath) else { return nil }
        // Keyed on the loader itself, so a runtime update lands in a fresh
        // directory rather than reusing links to the previous binary.
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "whisky-loader-\(inode)-\(size)")
        let alias = directory.appending(path: displayName)
        let ntdll = directory.appending(path: "ntdll.so")

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: ntdll.path(percentEncoded: false)) {
                try fileManager.createSymbolicLink(
                    at: ntdll, withDestinationURL: loader.deletingLastPathComponent().appending(path: "ntdll.so")
                )
            }
            if !fileManager.fileExists(atPath: alias.path(percentEncoded: false)) {
                try fileManager.linkItem(at: loader, to: alias)
            }
            return alias
        } catch {
            let reason = error.localizedDescription
            Logger.wineKit.warning(
                "Could not name the loader \(displayName, privacy: .public): \(reason, privacy: .public)"
            )
            return nil
        }
    }

    /// The environment a renamed launch needs.
    ///
    /// `WINEDLLPATH` is both what Wine's own rename is gated on and how a
    /// loader running outside its directory finds the unix `.so` builtins;
    /// `WINESERVER` covers the same gap for the server, which the first
    /// process of a cold prefix has to exec itself.
    public static func environment(
        displayName: String, iconFile: URL?, runtime: String?
    ) -> [String: String] {
        var environment = [
            "WINEDLLPATH": WhiskyWineInstaller.dllFolder(for: runtime).path(percentEncoded: false),
            "WINESERVER": WhiskyWineInstaller.binFolder(for: runtime)
                .appending(path: "wineserver").path(percentEncoded: false),
            "WINE_APP_DISPLAY_NAME": displayName
        ]
        if let iconFile {
            environment["WINE_APP_ICON_PATH"] = iconFile.path(percentEncoded: false)
        }
        return environment
    }
}
