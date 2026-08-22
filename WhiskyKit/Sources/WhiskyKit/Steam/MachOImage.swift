//
//  MachOImage.swift
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

/// Just enough Mach-O to find one instruction in a shipped binary.
///
/// Named for the file rather than the format because `MachO` is a system
/// module, and a type by that name shadows it everywhere the two are in scope.
///
/// Deliberately small: this reads a universal binary's arm64 half, locates a
/// section, and finds a C string. It is not a parser, and anything it does not
/// understand it answers `nil` to rather than guessing.
enum MachOImage {
    /// Where an architecture's image begins inside a universal file.
    struct Slice: Equatable {
        let offset: Int
        let size: Int
    }

    /// A section's addresses, in both the file and the loaded image.
    struct Section: Equatable {
        let address: UInt64
        let size: Int
        let fileOffset: Int
    }

    private static let fatMagics: Set<UInt32> = [0xCAFE_BABE, 0xCAFE_BABF]
    private static let arm64CPU: UInt32 = 0x0100_000C
    private static let segment64: UInt32 = 0x19

    /// The arm64 image inside a universal file.
    ///
    /// A thin arm64 file answers as one slice at offset zero, so callers do not
    /// have to care which they were handed.
    static func arm64Slice(of data: Data) -> Slice? {
        guard data.count > 8 else { return nil }
        let magic = read32(data, at: 0, bigEndian: true)

        guard fatMagics.contains(magic) else {
            // Thin. Only arm64 is of interest, and its magic is little endian.
            let thin = read32(data, at: 0, bigEndian: false)
            guard thin == 0xFEED_FACF else { return nil }
            return Slice(offset: 0, size: data.count)
        }

        let count = Int(read32(data, at: 4, bigEndian: true))
        for index in 0 ..< count {
            let entry = 8 + index * 20
            guard entry + 20 <= data.count else { return nil }
            guard read32(data, at: entry, bigEndian: true) == arm64CPU else { continue }
            return Slice(
                offset: Int(read32(data, at: entry + 8, bigEndian: true)),
                size: Int(read32(data, at: entry + 12, bigEndian: true))
            )
        }
        return nil
    }

    /// A named section of a named segment.
    static func section(named name: String, segment: String, in data: Data, slice: Slice) -> Section? {
        forEachSection(in: data, slice: slice) { sectionName, segmentName, section in
            sectionName == name && segmentName == segment ? section : nil
        }
    }

    /// The load address of a C string in the image, searched across every
    /// section so it does not matter which one the linker chose.
    static func address(of string: String, in data: Data, slice: Slice) -> UInt64? {
        let needle = Data((string + "\0").utf8)
        return forEachSection(in: data, slice: slice) { _, _, section in
            let start = section.fileOffset
            let end = min(start + section.size, data.count)
            guard start < end else { return nil }
            guard let found = data[start ..< end].firstRange(of: needle) else { return nil }
            return section.address &+ UInt64(found.lowerBound - start)
        }
    }

    /// The 32-bit instructions a section holds.
    static func instructions(in data: Data, section: Section) -> [UInt32] {
        let end = min(section.fileOffset + section.size, data.count)
        guard section.fileOffset < end else { return [] }
        return stride(from: section.fileOffset, to: end - 3, by: 4).map {
            read32(data, at: $0, bigEndian: false)
        }
    }

    /// The bytes of `mov w<register>, #1`.
    static func movImmediateOne(register: UInt32) -> Data {
        var insn = UInt32(0x5280_0000) | (1 << 5) | (register & 0x1F)
        return withUnsafeBytes(of: &insn) { Data($0) }
    }

    /// Walks the section table, returning the first non-nil the body produces.
    private static func forEachSection<T>(
        in data: Data, slice: Slice, _ body: (String, String, Section) -> T?
    ) -> T? {
        let base = slice.offset
        guard base + 32 <= data.count else { return nil }
        let commandCount = Int(read32(data, at: base + 16, bigEndian: false))

        var cursor = base + 32
        for _ in 0 ..< commandCount {
            guard cursor + 8 <= data.count else { return nil }
            let command = read32(data, at: cursor, bigEndian: false)
            let commandSize = Int(read32(data, at: cursor + 4, bigEndian: false))
            guard commandSize > 0 else { return nil }

            if command == segment64, cursor + 72 <= data.count {
                let sectionCount = Int(read32(data, at: cursor + 64, bigEndian: false))
                var entry = cursor + 72
                for _ in 0 ..< sectionCount {
                    guard entry + 80 <= data.count else { return nil }
                    let sectionName = name(in: data, at: entry)
                    let segmentName = name(in: data, at: entry + 16)
                    let section = Section(
                        address: read64(data, at: entry + 32),
                        size: Int(read64(data, at: entry + 40)),
                        fileOffset: base + Int(read32(data, at: entry + 48, bigEndian: false))
                    )
                    if let value = body(sectionName, segmentName, section) { return value }
                    entry += 80
                }
            }
            cursor += commandSize
        }
        return nil
    }

    private static func name(in data: Data, at offset: Int) -> String {
        let bytes = data[offset ..< min(offset + 16, data.count)]
        let trimmed = bytes.prefix { $0 != 0 }
        return String(bytes: trimmed, encoding: .utf8) ?? ""
    }

    private static func read32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let value = data[offset ..< offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return bigEndian ? value : value.byteSwapped
    }

    private static func read64(_ data: Data, at offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        return data[offset ..< offset + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }.byteSwapped
    }
}

/// The handful of arm64 instructions this has to recognise.
///
/// Decoding by hand rather than pulling in a disassembler: five encodings are
/// enough to find one compare, and a dependency that can read every instruction
/// is a large price for that.
enum Arm64 {
    /// `adrp Xd, <page>`: the register it writes and the page it names.
    static func adrp(_ insn: UInt32, at address: UInt64) -> (register: UInt32, page: UInt64)? {
        guard insn & 0x9F00_0000 == 0x9000_0000 else { return nil }
        let low = (insn >> 29) & 3
        let high = (insn >> 5) & 0x7FFFF
        var immediate = Int64((high << 2) | low)
        if immediate & (1 << 20) != 0 { immediate -= (1 << 21) }
        let page = UInt64(bitPattern: Int64(address & ~0xFFF) &+ (immediate << 12))
        return (insn & 0x1F, page)
    }

    /// The parts of an `add Xd, Xn, #imm`.
    struct AddImmediate: Equatable {
        let destination: UInt32
        let source: UInt32
        let immediate: UInt32
    }

    /// `add Xd, Xn, #imm`, 64-bit and unshifted, which is the half of an
    /// address that follows an `adrp`.
    static func addImmediate(_ insn: UInt32) -> AddImmediate? {
        guard insn & 0xFF80_0000 == 0x9100_0000 else { return nil }
        return AddImmediate(
            destination: insn & 0x1F, source: (insn >> 5) & 0x1F, immediate: (insn >> 10) & 0xFFF
        )
    }

    /// `cset Wd, eq`, which is `csinc Wd, wzr, wzr, ne`.
    static func csetEqual(_ insn: UInt32) -> UInt32? {
        guard insn & 0xFFFF_FC00 == 0x1A9F_1400 else { return nil }
        return insn & 0x1F
    }

    /// `mov Wd, #1`, the replacement, so an already-patched image is
    /// recognised rather than patched twice.
    static func movImmediateOneRegister(_ insn: UInt32) -> UInt32? {
        guard insn & 0xFFFF_FFE0 == 0x5280_0020 else { return nil }
        return insn & 0x1F
    }

    /// `strb Wt, [Xn, #imm]`: the register it stores.
    static func storeByteRegister(_ insn: UInt32) -> UInt32? {
        guard insn & 0xFFC0_0000 == 0x3900_0000 else { return nil }
        return insn & 0x1F
    }
}
