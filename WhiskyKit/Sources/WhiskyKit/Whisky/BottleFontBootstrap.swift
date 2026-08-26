//
//  BottleFontBootstrap.swift
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

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "BottleFontBootstrap")

/// Copies host fonts into a bottle's `drive_c/windows/Fonts` directory so
/// Windows UIs find the faces they assume are installed.
///
/// This covers the same ground as the "Core Fonts" package CrossOver downloads
/// into every bottle, which is the single most requested prerequisite in its
/// application database. macOS ships all of it in
/// `/System/Library/Fonts/Supplemental`, so the host copy needs no download and
/// avoids redistributing Microsoft's font binaries, which their licence only
/// permits as the original unmodified installers.
///
/// Without these, an application asking for Arial or Tahoma gets whatever the
/// fallback picks, at different metrics, and its text overflows or clips.
public enum BottleFontBootstrap {
    /// Filenames as macOS names them. Looked up in `/Library/Fonts` first, then
    /// `/System/Library/Fonts/Supplemental`; anything a given Mac lacks is
    /// skipped, so this list may name more than one machine has.
    private static let hostFontNames = [
        "Andale Mono.ttf",
        "Arial.ttf", "Arial Bold.ttf", "Arial Italic.ttf", "Arial Bold Italic.ttf",
        "Arial Black.ttf",
        "Arial Narrow.ttf", "Arial Narrow Bold.ttf",
        "Arial Narrow Italic.ttf", "Arial Narrow Bold Italic.ttf",
        "Arial Unicode.ttf",
        "Comic Sans MS.ttf", "Comic Sans MS Bold.ttf",
        "Courier New.ttf", "Courier New Bold.ttf",
        "Courier New Italic.ttf", "Courier New Bold Italic.ttf",
        "Georgia.ttf", "Georgia Bold.ttf", "Georgia Italic.ttf", "Georgia Bold Italic.ttf",
        "Impact.ttf",
        "Tahoma.ttf", "Tahoma Bold.ttf",
        "Times New Roman.ttf", "Times New Roman Bold.ttf",
        "Times New Roman Italic.ttf", "Times New Roman Bold Italic.ttf",
        "Trebuchet MS.ttf", "Trebuchet MS Bold.ttf",
        "Trebuchet MS Italic.ttf", "Trebuchet MS Bold Italic.ttf",
        "Verdana.ttf", "Verdana Bold.ttf", "Verdana Italic.ttf", "Verdana Bold Italic.ttf",
        "Webdings.ttf",
        "Wingdings.ttf", "Wingdings 2.ttf", "Wingdings 3.ttf"
    ]

    /// Host font candidates to copy into a bottle. The first existing path for each
    /// destination filename wins; missing host fonts are skipped silently.
    private static let candidates: [(destination: String, sources: [String])] =
        hostFontNames.map { name in
            (name, ["/Library/Fonts/\(name)", "/System/Library/Fonts/Supplemental/\(name)"])
        }

    /// Copies missing fonts into `<bottlePrefix>/drive_c/windows/Fonts`.
    /// Idempotent: existing destination files are left untouched.
    public static func copySystemFonts(toPrefix prefix: URL) {
        let dest = prefix.appending(path: "drive_c/windows/Fonts")
        let manager = FileManager.default
        try? manager.createDirectory(at: dest, withIntermediateDirectories: true)

        for (filename, sources) in candidates {
            let destURL = dest.appending(path: filename)
            guard !manager.fileExists(atPath: destURL.path(percentEncoded: false)) else { continue }
            guard let source = sources.first(where: { manager.fileExists(atPath: $0) }) else { continue }
            do {
                try manager.copyItem(at: URL(fileURLWithPath: source), to: destURL)
                logger.info("Bootstrapped \(filename, privacy: .public) into bottle fonts")
            } catch {
                logger.warning("Failed to copy \(filename, privacy: .public): \(error.localizedDescription)")
            }
        }
    }
}
