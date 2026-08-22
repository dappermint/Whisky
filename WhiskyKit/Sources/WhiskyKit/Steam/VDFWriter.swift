//
//  VDFWriter.swift
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

/// Writes the text flavor of Valve's KeyValues format, the inverse of
/// ``VDFParser``.
///
/// Output matches the shape Steam itself writes: tab indentation, quoted keys
/// and values, two tabs between a key and its string value, and a brace on the
/// line after an object's key.
///
/// One caveat, and the reason this is scoped rather than general: ``VDFParser``
/// lowercases keys, so a parse-edit-write round trip lowercases the document.
/// That is harmless for `libraryfolders.vdf`, whose keys are already lowercase,
/// and wrong for `config.vdf`, whose keys are not. Only round trip files whose
/// keys you have checked.
public enum VDFWriter {
    /// Serializes a VDF document.
    ///
    /// - Parameter object: The top-level key-value pairs.
    /// - Returns: The document text, newline terminated.
    public static func serialize(_ object: [String: VDFValue]) -> String {
        var output = ""
        writeBody(object, depth: 0, into: &output)
        return output
    }

    private static func writeBody(_ object: [String: VDFValue], depth: Int, into output: inout String) {
        let indent = String(repeating: "\t", count: depth)
        for key in sortedKeys(of: object) {
            guard let value = object[key] else { continue }
            switch value {
            case let .string(string):
                output += "\(indent)\"\(escaped(key))\"\t\t\"\(escaped(string))\"\n"
            case let .object(nested):
                output += "\(indent)\"\(escaped(key))\"\n\(indent){\n"
                writeBody(nested, depth: depth + 1, into: &output)
                output += "\(indent)}\n"
            }
        }
    }

    /// Numeric keys first and in numeric order, everything else after them
    /// alphabetically.
    ///
    /// A dictionary has no order of its own, and the files this writes are
    /// keyed by library index (`"0"`, `"1"`, `"10"`), where lexicographic order
    /// would put `"10"` before `"2"`. Steam does not care, but a human reading
    /// a diff does.
    private static func sortedKeys(of object: [String: VDFValue]) -> [String] {
        let numeric = object.keys.compactMap { key in Int(key).map { (key, $0) } }
        let textual = object.keys.filter { Int($0) == nil }
        return numeric.sorted { $0.1 < $1.1 }.map(\.0) + textual.sorted()
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
