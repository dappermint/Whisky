//
//  VDFParserTests.swift
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

@Suite("VDFParser Tests")
struct VDFParserTests {
    // MARK: - Real-world shapes

    @Test("Parses an app manifest")
    func parsesAppManifest() throws {
        let acf = """
        "AppState"
        {
            "appid"        "4576510"
            "name"        "Casualties: Unknown Demo"
            "installdir"        "Casualties Unknown Demo"
            "StateFlags"        "4"
            "buildid"        "1785187029"
            "SizeOnDisk"        "541968407"
        }
        """

        let root = try VDFParser.parse(acf)
        let appState = try #require(root["appstate"]?.objectValue)

        #expect(appState["appid"]?.intValue == 4_576_510)
        #expect(appState["name"]?.stringValue == "Casualties: Unknown Demo")
        #expect(appState["installdir"]?.stringValue == "Casualties Unknown Demo")
        #expect(appState["stateflags"]?.intValue == 4)
        #expect(appState["sizeondisk"]?.intValue == 541_968_407)
    }

    @Test("Parses libraryfolders with multiple libraries")
    func parsesLibraryFolders() throws {
        let vdf = """
        "libraryfolders"
        {
            "0"
            {
                "path"        "C:\\\\Program Files (x86)\\\\Steam"
                "apps"
                {
                    "4576510"        "541968407"
                }
            }
            "1"
            {
                "path"        "D:\\\\SteamLibrary"
                "apps"
                {
                    "1245620"        "49061246523"
                }
            }
        }
        """

        let root = try VDFParser.parse(vdf)
        let folders = try #require(root["libraryfolders"]?.objectValue)

        let first = try #require(folders["0"]?.objectValue)
        #expect(first["path"]?.stringValue == "C:\\Program Files (x86)\\Steam")
        #expect(first["apps"]?.objectValue?["4576510"]?.intValue == 541_968_407)

        let second = try #require(folders["1"]?.objectValue)
        #expect(second["path"]?.stringValue == "D:\\SteamLibrary")
        #expect(second["apps"]?.objectValue?.count == 1)
    }

    // MARK: - Grammar details

    @Test("Lowercases keys but preserves value case")
    func lowercasesKeysOnly() throws {
        let root = try VDFParser.parse("\"AppState\"  \"Mixed Case Value\"")

        #expect(root["appstate"]?.stringValue == "Mixed Case Value")
        #expect(root["AppState"] == nil)
    }

    @Test("Handles escaped quotes and backslashes")
    func handlesEscapes() throws {
        let root = try VDFParser.parse(#""name"  "a \"quoted\" path\\here""#)

        #expect(root["name"]?.stringValue == #"a "quoted" path\here"#)
    }

    @Test("Skips line comments")
    func skipsComments() throws {
        let vdf = """
        // header comment
        "key"        "value" // trailing comment
        "other"        "thing"
        """

        let root = try VDFParser.parse(vdf)

        #expect(root["key"]?.stringValue == "value")
        #expect(root["other"]?.stringValue == "thing")
    }

    @Test("Handles CRLF line endings")
    func handlesCRLF() throws {
        let root = try VDFParser.parse("\"a\"\r\n{\r\n\"b\"\t\"c\"\r\n}\r\n")

        #expect(root["a"]?.objectValue?["b"]?.stringValue == "c")
    }

    @Test("Parses an empty object")
    func parsesEmptyObject() throws {
        let root = try VDFParser.parse("\"apps\" {}")

        #expect(root["apps"]?.objectValue?.isEmpty == true)
    }

    @Test("Duplicate keys keep the last occurrence")
    func duplicateKeysLastWins() throws {
        let root = try VDFParser.parse("\"key\" \"first\"\n\"key\" \"second\"")

        #expect(root["key"]?.stringValue == "second")
    }

    @Test("Parses an empty document")
    func parsesEmptyDocument() throws {
        #expect(try VDFParser.parse("").isEmpty)
        #expect(try VDFParser.parse("// only a comment\n").isEmpty)
    }

    // MARK: - Malformed input

    @Test("Throws on unclosed object")
    func throwsOnUnclosedObject() {
        #expect(throws: VDFParseError.unexpectedEnd) {
            try VDFParser.parse("\"root\" { \"key\" \"value\"")
        }
    }

    @Test("Throws on unterminated string with its line")
    func throwsOnUnterminatedString() {
        #expect(throws: VDFParseError.unterminatedString(line: 2)) {
            try VDFParser.parse("\"a\" \"b\"\n\"unclosed")
        }
    }

    @Test("Throws on bare token with its line")
    func throwsOnBareToken() {
        #expect(throws: VDFParseError.unexpectedToken(line: 1)) {
            try VDFParser.parse("bare")
        }
    }

    @Test("Throws on stray closing brace at top level")
    func throwsOnStrayClosingBrace() {
        #expect(throws: VDFParseError.self) {
            try VDFParser.parse("\"a\" \"b\" }")
        }
    }

    @Test("Throws on key without a value")
    func throwsOnKeyWithoutValue() {
        #expect(throws: VDFParseError.unexpectedEnd) {
            try VDFParser.parse("\"lonely\"")
        }
    }
}
