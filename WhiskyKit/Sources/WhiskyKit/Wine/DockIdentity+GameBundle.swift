//
//  DockIdentity+GameBundle.swift
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

import AppKit
import Foundation
import os.log

public extension DockIdentity {
    /// Where Wine is told to link the loader for the program the identity
    /// belongs to, in place of its own temporary directory.
    static let linkDirectoryKey = "WINE_APP_LINK_DIR"

    /// Where the bundles are kept, one folder per App ID.
    static var gamesFolder: URL {
        WhiskyWineInstaller.applicationFolder.appending(path: "Games")
    }

    /// Writes the bundle a Steam game's process runs from, and returns the
    /// directory inside it that Wine should link the loader into.
    ///
    /// A process with no bundle has a name and an icon only while it runs, and
    /// a tile kept in the Dock points at a loader link that starts nothing.
    /// LaunchServices gives a process started from `Contents/MacOS` the
    /// identity of the bundle around it, whichever file in there was exec'd.
    /// So the game runs from a link beside the bundle's own executable, and
    /// that executable, which is what a kept tile starts, hands the launch
    /// back to the client.
    ///
    /// - Returns: The bundle's `Contents/MacOS`, or `nil` if it could not be
    ///   written, in which case the launch keeps the identity it already had.
    static func gameBundle(
        appId: Int, displayName: String, iconFile: URL?, ntdll: URL, in folder: URL = gamesFolder
    ) -> URL? {
        let fileManager = FileManager.default
        let app = folder.appending(path: String(appId)).appending(path: "\(displayName).app")
        let contents = app.appending(path: "Contents")
        let macos = contents.appending(path: "MacOS")
        let launcher = macos.appending(path: "launch")
        let link = macos.appending(path: "ntdll.so")

        do {
            try fileManager.createDirectory(at: macos, withIntermediateDirectories: true)
            try PropertyListSerialization.data(
                fromPropertyList: infoDictionary(appId: appId, displayName: displayName),
                format: .xml, options: 0
            ).write(to: contents.appending(path: "Info.plist"))
            try Data("#!/bin/sh\nexec /usr/bin/open steam://rungameid/\(appId)\n".utf8).write(to: launcher)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: launcher.path(percentEncoded: false)
            )
            // Recreated rather than reused, for the reason the loader alias
            // gives: the loader looks for this beside wherever it was exec'd.
            try? fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(at: link, withDestinationURL: ntdll)
        } catch {
            let reason = error.localizedDescription
            Logger.wineKit.warning(
                "Could not write a bundle for \(displayName, privacy: .public): \(reason, privacy: .public)"
            )
            return nil
        }

        // ponytail: set once, so art the client downloads later is not picked
        // up until the bundle is deleted. Key it on the icon file if that bites.
        let customIcon = app.appending(path: "Icon\r")
        if !fileManager.fileExists(atPath: customIcon.path(percentEncoded: false)),
           let iconFile, let image = NSImage(contentsOf: iconFile) {
            NSWorkspace.shared.setIcon(image, forFile: app.path(percentEncoded: false), options: [])
        }
        return macos
    }

    static func infoDictionary(appId: Int, displayName: String) -> [String: Any] {
        [
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundleIdentifier": "\(Bundle.whiskyBundleIdentifier).game.\(appId)",
            "CFBundleExecutable": "launch",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "NSPrincipalClass": "NSApplication",
            "NSHighResolutionCapable": true,
            "LSApplicationCategoryType": "public.app-category.games",
            "LSSupportsGameMode": true,
            "GCSupportsGameMode": true,
            // A bundle that asks for one of these without saying why is killed.
            "NSMicrophoneUsageDescription": "This game would like to use the microphone.",
            "NSCameraUsageDescription": "This game would like to use the camera.",
            "NSLocalNetworkUsageDescription": "This game would like to find devices on your local network."
        ]
    }
}
