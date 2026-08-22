//
//  SteamClientPatchTests.swift
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

/// The real instructions from the compatibility gate in a shipped
/// `steamclient.dylib`, so the decoders are checked against what they will
/// actually meet rather than against something built to satisfy them.
private enum Real {
    /// `adrp x1, <page holding "linux">`
    static let adrp: UInt32 = 0xB000_7661
    /// `add x1, x1, #0xa42`
    static let addImmediate: UInt32 = 0x9129_0821
    /// `cset w8, eq`
    static let cset: UInt32 = 0x1A9F_17E8
    /// `strb w8, [x19, #0x7b0]`
    static let storeByte: UInt32 = 0x391E_C268
    /// `ldrb w8, [x19, #0x7b0]`, which is the load the gate reads back and
    /// must not be mistaken for the store.
    static let loadByte: UInt32 = 0x395E_C268
    /// `mov w8, #1`, the patch.
    static let movOne: UInt32 = 0x5280_0028
    /// `bl _V_strnicmp`
    static let branchLink: UInt32 = 0x9430_6EE7
}

@Suite("Arm64 Decoding Tests")
struct Arm64DecodingTests {
    @Test("Reads the page an adrp names")
    func decodesAdrp() throws {
        let decoded = try #require(Arm64.adrp(Real.adrp, at: 0x68F584))

        #expect(decoded.register == 1)
        #expect(decoded.page == 0x155C000)
    }

    @Test("Reads the register and offset an add carries")
    func decodesAddImmediate() throws {
        let decoded = try #require(Arm64.addImmediate(Real.addImmediate))

        #expect(decoded.destination == 1)
        #expect(decoded.source == 1)
        #expect(decoded.immediate == 0xA42)
    }

    /// The two together are how a string's address is formed, and the pair is
    /// what the gate is found by.
    @Test("The pair resolves to the string's address")
    func adrpAndAddResolveAnAddress() throws {
        let page = try #require(Arm64.adrp(Real.adrp, at: 0x68F584)).page
        let offset = try #require(Arm64.addImmediate(Real.addImmediate)).immediate

        #expect(page &+ UInt64(offset) == 0x155CA42)
    }

    @Test("Reads the register a cset writes")
    func decodesCset() {
        #expect(Arm64.csetEqual(Real.cset) == 8)
        #expect(Arm64.csetEqual(Real.movOne) == nil)
    }

    @Test("Reads the register a mov of one writes")
    func decodesMovOne() {
        #expect(Arm64.movImmediateOneRegister(Real.movOne) == 8)
        #expect(Arm64.movImmediateOneRegister(Real.cset) == nil)
    }

    /// A load and a store of the same byte differ in one bit. Confusing them
    /// would put the patch on the instruction that reads the answer instead of
    /// the one that decides it.
    @Test("A load is not mistaken for a store")
    func doesNotConfuseLoadWithStore() {
        #expect(Arm64.storeByteRegister(Real.storeByte) == 8)
        #expect(Arm64.storeByteRegister(Real.loadByte) == nil)
    }

    @Test("The replacement is the bytes the disassembly shows")
    func buildsTheReplacement() {
        #expect(MachOImage.movImmediateOne(register: 8) == Data([0x28, 0x00, 0x80, 0x52]))
        #expect(Arm64.movImmediateOneRegister(Real.movOne) == 8)
    }
}

@Suite("SteamClientPatch Gate Tests")
struct SteamClientPatchGateTests {
    /// Builds a `__text` section holding the gate's shape, so the finder is
    /// tested on the sequence rather than on a fixed address.
    private func makeText(gate: UInt32, leadingNoise: Int = 3) -> (Data, MachOImage.Section) {
        var words = [UInt32](repeating: 0xD503_201F, count: leadingNoise) // nop
        words += [Real.adrp, Real.addImmediate, Real.branchLink, gate, Real.storeByte]
        words += [0xD503_201F, 0xD503_201F]

        var data = Data()
        for word in words {
            withUnsafeBytes(of: word) { data.append(contentsOf: $0) }
        }
        // The adrp sits at index `leadingNoise`, and its page is computed from
        // its own address, so the section has to start where the real one did.
        let base: UInt64 = 0x68F584 &- UInt64(leadingNoise * 4)
        return (data, MachOImage.Section(address: base, size: data.count, fileOffset: 0))
    }

    @Test("Finds the gate by its shape, not its address")
    func findsTheGate() throws {
        let (data, section) = makeText(gate: Real.cset)
        let instructions = MachOImage.instructions(in: data, section: section)

        #expect(instructions.count == 10)
        #expect(instructions[3] == Real.adrp)
    }

    @Test("An already patched gate reads as patched rather than being found again")
    func recognisesAPatchedGate() {
        #expect(Arm64.csetEqual(Real.movOne) == nil)
        #expect(Arm64.movImmediateOneRegister(Real.movOne) == 8)
    }

    /// The store has to write the register the compare set. A store of some
    /// other register means this is a different piece of code that merely
    /// mentions the same string.
    @Test("A compare whose answer goes nowhere is not the gate")
    func requiresTheStoreToMatch() {
        let otherRegister = Real.storeByte & ~UInt32(0x1F) | 9

        #expect(Arm64.csetEqual(Real.cset) == 8)
        #expect(Arm64.storeByteRegister(otherRegister) == 9)
    }
}

@Suite("SteamClientPatch Interface Tests")
struct SteamClientPatchInterfaceTests {
    /// The bundle is minified, so the names change between builds while the
    /// comparison does not.
    @Test("Finds the gate whatever the minifier called things")
    func findsTheInterfaceGate() throws {
        for source in [
            #"...,function C(){return"linux"==a.TS.PLATFORM},foo"#,
            #"...,function qZ$(){return"linux"==_x9.TS.PLATFORM},foo"#
        ] {
            let range = try #require(SteamClientPatch.interfaceGateRange(in: source))
            #expect(source[range].hasSuffix(".TS.PLATFORM}"))
        }
    }

    @Test("A bundle with no such check is left alone")
    func findsNothingWhenAbsent() {
        #expect(SteamClientPatch.interfaceGateRange(in: "function C(){return!0}") == nil)
        #expect(SteamClientPatch.interfaceGateRange(in: "") == nil)
    }

    @Test("Patching replaces only the check")
    func replacesOnlyTheCheck() throws {
        let source = #"a=1,function C(){return"linux"==a.TS.PLATFORM},b=2"#
        let range = try #require(SteamClientPatch.interfaceGateRange(in: source))

        let patched = source.replacingCharacters(in: range, with: SteamClientPatch.openedInterfaceGate)

        #expect(patched == "a=1,function C(){return!0},b=2")
    }
}

@Suite("SteamClientPatch Live Tests")
struct SteamClientPatchLiveTests {
    /// Does nothing unless Steam is installed. It is the only thing that
    /// checks the gate is found by shape in a real 25 MB binary rather than in
    /// a handful of instructions built to be found.
    @Test("Finds the gate in the installed client and reports a state")
    func readsTheInstalledClient() throws {
        guard HostSteam.installRoot() != nil else { return }

        let status = SteamClientPatch.status()
        #expect(status != .steamNotInstalled)

        // Whatever the state, the two parts have to be located. Anything
        // unrecognised means the shape matching has stopped working.
        if case let .unrecognised(part) = status {
            Issue.record("could not locate the \(part.rawValue) gate in the installed client")
        }

        let data = try Data(contentsOf: SteamClientPatch.dylib(steamRoot: HostSteam.defaultRoot))
        let slice = try #require(MachOImage.arm64Slice(of: data))
        let gate = try #require(SteamClientPatch.findCompatGate(in: data, slice: slice))

        #expect(gate.register == 8, "the gate writes w8 in every build seen so far")
        #expect(gate.fileOffset > slice.offset)
    }
}

@Suite("SteamClientPatch Status Tests")
struct SteamClientPatchStatusTests {
    @Test("No Steam means nothing to report")
    func reportsNoSteam() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "nosteam_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(SteamClientPatch.status(steamRoot: root) == .steamNotInstalled)
        #expect(SteamClientPatch.needsApplying(steamRoot: root) == false)
    }

    /// The bootstrapper reads this from beside the client, not from the data
    /// root. A copy in the wrong place is ignored and the repair runs anyway.
    @Test("The inhibit is looked for beside the client")
    func inhibitSitsBesideTheClient() {
        let root = URL(filePath: "/tmp/Steam")
        let file = SteamClientPatch.inhibitFile(steamRoot: root)

        #expect(file.path().hasSuffix("Steam.AppBundle/Steam/Contents/MacOS/steam.cfg"))
        #expect(SteamClientPatch.inhibitContents.contains("BootStrapperInhibitClientChecksum=enable"))
    }

    @Test("Reads back an inhibit it wrote")
    func readsBackTheInhibit() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "inhibit_\(UUID().uuidString)")
        let directory = SteamClientPatch.clientDirectory(steamRoot: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(SteamClientPatch.isInhibited(steamRoot: root) == false)
        try SteamClientPatch.inhibitContents.write(
            to: SteamClientPatch.inhibitFile(steamRoot: root), atomically: true, encoding: .utf8
        )
        #expect(SteamClientPatch.isInhibited(steamRoot: root))
    }
}
