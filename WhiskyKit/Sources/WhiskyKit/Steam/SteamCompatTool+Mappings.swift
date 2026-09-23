//
//  SteamCompatTool+Mappings.swift
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

public extension SteamCompatTool {
    /// Where the client keeps the per app tool mappings.
    static let configURL = URL(filePath: NSHomeDirectory())
        .appending(path: "Library")
        .appending(path: "Application Support")
        .appending(path: "Steam")
        .appending(path: "config")
        .appending(path: "config.vdf")

    /// Carries every game mapped to a tool of ours that no longer exists onto
    /// the default tool.
    ///
    /// Tool identifiers are derived from runtime names, so a runtime update or
    /// a change to how the identifier is spelled strands the games mapped to
    /// the old one. The client then runs nothing and says nothing. Pointing
    /// them at the default tool keeps them launching; the picker is still
    /// there to choose another runtime.
    ///
    /// Steam has to be down first. It holds the file open and rewrites it from
    /// memory on exit, so an edit made underneath a running client is undone
    /// the moment it quits.
    ///
    /// - Parameter installed: The identifiers of the tools that exist now.
    /// - Returns: How many mappings moved, which is zero when there is nothing
    ///   to carry and the file is left untouched.
    @discardableResult
    static func migrateMappings(in url: URL = configURL, keeping installed: Set<String>) throws -> Int {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return 0 }

        let (migrated, count) = migratingMappings(in: source, to: name) { tool in
            isOurs(tool) && !installed.contains(tool)
        }
        guard count > 0 else { return 0 }

        try migrated.write(to: url, atomically: true, encoding: .utf8)
        return count
    }

    /// Whether `tool` is an identifier we have ever written.
    static func isOurs(_ tool: String) -> Bool {
        tool == previousName || tool == name || tool.hasPrefix("\(name)-")
    }

    /// Renames the tool inside `CompatToolMapping` and nowhere else in the file.
    static func migratingMappings(
        in source: String, from previous: String, to current: String
    ) -> (text: String, count: Int) {
        migratingMappings(in: source, to: current) { $0 == previous }
    }

    /// Renames every tool `stale` picks inside `CompatToolMapping` and nowhere
    /// else in the file.
    ///
    /// This edits the text rather than parsing and writing the file back,
    /// because the client's writer keeps its own key order and ours would not.
    /// A reordered `config.vdf` is a whole file diff over a one word change,
    /// and the file holds more of the client's state than we know how to keep.
    static func migratingMappings(
        in source: String, to current: String, where stale: (String) -> Bool
    ) -> (text: String, count: Int) {
        guard let block = mappingBlockRange(in: source) else { return (source, 0) }

        var rest = source[block]
        var result = ""
        var count = 0

        while let key = rest.range(of: "\"name\"") {
            result += rest[..<key.upperBound]

            var cursor = key.upperBound
            while cursor < rest.endIndex, rest[cursor].isWhitespace {
                cursor = rest.index(after: cursor)
            }
            result += rest[key.upperBound ..< cursor]

            if cursor < rest.endIndex, rest[cursor] == "\"",
               let close = rest[rest.index(after: cursor)...].firstIndex(of: "\"") {
                let tool = String(rest[rest.index(after: cursor) ..< close])
                if tool != current, stale(tool) {
                    result += "\"\(current)\""
                    cursor = rest.index(after: close)
                    count += 1
                }
            }
            rest = rest[cursor...]
        }
        result += rest

        guard count > 0 else { return (source, 0) }
        return (source[..<block.lowerBound] + result + source[block.upperBound...], count)
    }

    /// The braces of the `CompatToolMapping` block, quotes accounted for.
    static func mappingBlockRange(in source: String) -> Range<String.Index>? {
        guard let key = source.range(of: "\"CompatToolMapping\""),
              let open = source[key.upperBound...].firstIndex(of: "{")
        else { return nil }

        var depth = 0
        var index = open
        var quoted = false
        var escaped = false

        while index < source.endIndex {
            let character = source[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if !quoted, character == "{" {
                depth += 1
            } else if !quoted, character == "}" {
                depth -= 1
                if depth == 0 { return open ..< source.index(after: index) }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
