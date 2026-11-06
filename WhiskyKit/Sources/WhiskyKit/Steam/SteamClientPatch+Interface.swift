//
//  SteamClientPatch+Interface.swift
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

/// The check in the interface bundle that hides the Compatibility settings.
extension SteamClientPatch {
    /// Left inside an opened gate, so it is recognised whatever the minifier
    /// called the function.
    static let openedInterfaceMarker = "/*whisky*/"

    /// What earlier versions wrote. It only kept the bundle working in builds
    /// where the function happened to be called `C`.
    static let legacyOpenedInterfaceGate = "function C(){return!0}"

    /// The gate with its answer fixed. The name has to survive: every caller
    /// refers to it, and the interface stops loading if it goes missing.
    static func openedInterfaceGate(named name: Substring) -> String {
        "function \(name)(){return!0\(openedInterfaceMarker)}"
    }

    static func isInterfaceOpened(_ source: String) -> Bool {
        source.contains(openedInterfaceMarker) || source.contains(legacyOpenedInterfaceGate)
    }

    /// Finds the check that hides the Compatibility pages.
    ///
    /// Matched by shape rather than exact text: the bundle is minified, so the
    /// function and module names change between builds, and so has the order
    /// of the comparison.
    static func interfaceGate(in source: String) -> (range: Range<String.Index>, name: Substring)? {
        let platform = #"[A-Za-z_$][\w$]*\.TS\.PLATFORM"#
        let pattern = #"function ([A-Za-z_$][\w$]*)\(\)\{return ?(?:"linux"=="#
            + platform + "|" + platform + #"=="linux")\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: source, range: NSRange(source.startIndex ..< source.endIndex, in: source)
              ),
              let range = Range(match.range, in: source),
              let name = Range(match.range(at: 1), in: source)
        else { return nil }
        return (range, source[name])
    }
}
