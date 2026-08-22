//
//  VDFWriterTests.swift
//  WhiskyKitTests
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
import Testing
@testable import WhiskyKit

@Suite("VDFWriter Tests")
struct VDFWriterTests {
    @Test("A parsed document survives a write and a second parse")
    func roundTrips() throws {
        let source = """
        "libraryfolders"
        {
            "0"
            {
                "path"        "C:\\\\Program Files (x86)\\\\Steam"
                "label"        ""
                "apps"
                {
                    "553850"        "23886986354"
                }
            }
        }
        """
        let parsed = try VDFParser.parse(source)
        let reparsed = try VDFParser.parse(VDFWriter.serialize(parsed))
        #expect(reparsed == parsed)
    }

    @Test("Numeric keys are written in numeric order")
    func ordersNumericKeysNumerically() {
        let document: [String: VDFValue] = ["libraryfolders": .object([
            "10": .string("ten"), "2": .string("two"), "1": .string("one"), "label": .string("last")
        ])]
        let keys = VDFWriter.serialize(document)
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("\""),
                      let closing = trimmed.dropFirst().firstIndex(of: "\"")
                else { return nil }
                return String(trimmed[trimmed.index(after: trimmed.startIndex) ..< closing])
            }
        #expect(keys == ["libraryfolders", "1", "2", "10", "label"])
    }

    @Test("Backslashes and quotes come back out as they went in")
    func escapesWhatTheParserUnescapes() throws {
        let document: [String: VDFValue] = ["root": .object([
            "path": .string("Z:\\Users\\me\\Games"),
            "quoted": .string("a \"quoted\" name")
        ])]
        let reparsed = try VDFParser.parse(VDFWriter.serialize(document))
        #expect(reparsed == document)
    }
}
