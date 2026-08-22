//
//  SteamCompatToolMappingTests.swift
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

@Suite("SteamCompatTool Mapping Tests")
struct SteamCompatToolMappingTests {
    private func makeConfig(tool: String) -> String {
        """
        "InstallConfigStore"
        {
        \t"Software"
        \t{
        \t\t"CompatToolMapping"
        \t\t{
        \t\t\t"4164420"
        \t\t\t{
        \t\t\t\t"name"\t\t"\(tool)"
        \t\t\t\t"config"\t\t""
        \t\t\t\t"priority"\t\t"250"
        \t\t\t}
        \t\t\t"0"
        \t\t\t{
        \t\t\t\t"name"\t\t"\(tool)"
        \t\t\t\t"config"\t\t""
        \t\t\t\t"priority"\t\t"75"
        \t\t\t}
        \t\t}
        \t\t"Other"
        \t\t{
        \t\t\t"name"\t\t"whisky"
        \t\t}
        \t}
        }
        """
    }

    @Test("Every mapping moves onto the new identifier")
    func migratesEveryMapping() throws {
        let (text, count) = SteamCompatTool.migratingMappings(
            in: makeConfig(tool: "whisky"), from: "whisky", to: "whisky-proton"
        )

        #expect(count == 2)

        let block = try #require(SteamCompatTool.mappingBlockRange(in: text))
        #expect(text[block].components(separatedBy: "\"whisky-proton\"").count == 3)
        #expect(!text[block].contains("\"whisky\""))
    }

    /// The file holds far more of the client's state than the mappings, and a
    /// tool name is a plausible value elsewhere, so the edit has to stay inside
    /// the one block rather than sweeping the file.
    @Test("A matching name outside the mapping block is left alone")
    func leavesTheRestOfTheFileAlone() throws {
        let (text, _) = SteamCompatTool.migratingMappings(
            in: makeConfig(tool: "whisky"), from: "whisky", to: "whisky-proton"
        )

        let other = try #require(text.range(of: "\"Other\""))
        #expect(text[other.upperBound...].contains("\"name\"\t\t\"whisky\""))
    }

    @Test("A file already on the new identifier is not rewritten")
    func skipsAFileAlreadyMigrated() {
        let source = makeConfig(tool: "whisky-proton")

        let (text, count) = SteamCompatTool.migratingMappings(
            in: source, from: "whisky", to: "whisky-proton"
        )

        #expect(count == 0)
        #expect(text == source)
    }

    @Test("A file with no mappings at all is not rewritten")
    func skipsAFileWithNoMappings() {
        let source = "\"InstallConfigStore\"\n{\n}\n"

        let (text, count) = SteamCompatTool.migratingMappings(
            in: source, from: "whisky", to: "whisky-proton"
        )

        #expect(count == 0)
        #expect(text == source)
    }

    /// The block is found by matching braces, so a brace inside a quoted value
    /// must not end it early and strand the mappings that follow.
    @Test("A brace inside a value does not end the block early")
    func survivesABraceInsideAValue() {
        let source = """
        "CompatToolMapping"
        {
        \t"1"
        \t{
        \t\t"config"\t\t"}"
        \t\t"name"\t\t"whisky"
        \t}
        }
        """

        let (text, count) = SteamCompatTool.migratingMappings(
            in: source, from: "whisky", to: "whisky-proton"
        )

        #expect(count == 1)
        #expect(text.contains("\"whisky-proton\""))
    }
}
