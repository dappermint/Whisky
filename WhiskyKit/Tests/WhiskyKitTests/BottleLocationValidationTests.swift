//
//  BottleLocationValidationTests.swift
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

@testable import WhiskyKit
import XCTest

final class BottleLocationValidationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            // Restore writability before removal in case a test made it read-only.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    func testValidForWritableDirectoryWithSpace() {
        XCTAssertEqual(BottleLocationValidation.validate(at: tempDir, minimumFreeBytes: 0), .valid)
    }

    func testValidForNonexistentSubdirectoryOfWritableParent() {
        // Mirrors first-run: the chosen parent (e.g. .../Bottles) doesn't exist
        // yet, so the validator must probe the nearest existing ancestor.
        let subdir = tempDir.appendingPathComponent("Bottles")
        XCTAssertEqual(BottleLocationValidation.validate(at: subdir, minimumFreeBytes: 0), .valid)
    }

    func testNotWritableForReadOnlyDirectory() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tempDir.path)
        let target = tempDir.appendingPathComponent("bottle")

        // The carried path must be the original target the user chose (it is
        // shown to them), not the nearest existing ancestor that was probed.
        guard case let .notWritable(path) = BottleLocationValidation.validate(at: target, minimumFreeBytes: 0) else {
            return XCTFail("Expected .notWritable for a read-only directory")
        }
        XCTAssertEqual(path, target.path(percentEncoded: false))
    }

    func testNotWritableWhenNearestAncestorIsRegularFile() throws {
        // If the walk-up lands on a regular file (a malformed location), the
        // probe write fails and the result is .notWritable rather than a crash.
        let file = tempDir.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: file)
        let target = file.appendingPathComponent("bottle")

        guard case .notWritable = BottleLocationValidation.validate(at: target, minimumFreeBytes: 0) else {
            return XCTFail("Expected .notWritable when the nearest ancestor is a regular file")
        }
    }

    func testInsufficientSpaceWhenFloorExceedsCapacity() {
        let result = BottleLocationValidation.validate(at: tempDir, minimumFreeBytes: .max)

        guard case let .insufficientSpace(available, required) = result else {
            return XCTFail("Expected .insufficientSpace, got \(result)")
        }
        XCTAssertEqual(required, .max)
        XCTAssertGreaterThanOrEqual(available, 0)
    }

    func testNearestExistingDirectoryWalksUpToFirstExistingParent() {
        let deep = tempDir.appendingPathComponent("a/b/c")
        let nearest = BottleLocationValidation.nearestExistingDirectory(for: deep, fileManager: .default)
        XCTAssertEqual(nearest.path, tempDir.resolvingSymlinksInPath().path)
    }

    func testCapableLocationReportsNoMissingCapability() {
        XCTAssertNil(BottleLocationValidation.missingCapability(in: tempDir, fileManager: .default))
    }

    func testCapabilityProbeLeavesNothingBehind() throws {
        XCTAssertNil(BottleLocationValidation.missingCapability(in: tempDir, fileManager: .default))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(leftovers, [], "the capability probe must clean up after itself")
    }

    func testProbeExercisesEveryOperationAPrefixNeeds() throws {
        // Guards the probe itself: if it stops creating a symlink or a colon-named
        // file, it would silently pass locations that cannot host a prefix.
        final class RecordingManager: FileManager, @unchecked Sendable {
            var symlinked = false
            var createdPaths: [String] = []
            var permissionsSet = false

            override func createSymbolicLink(at url: URL, withDestinationURL destURL: URL) throws {
                symlinked = true
                try super.createSymbolicLink(at: url, withDestinationURL: destURL)
            }

            override func createFile(
                atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil
            ) -> Bool {
                createdPaths.append(path)
                return super.createFile(atPath: path, contents: data, attributes: attr)
            }

            override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
                if attributes[.posixPermissions] != nil { permissionsSet = true }
                try super.setAttributes(attributes, ofItemAtPath: path)
            }
        }

        let recorder = RecordingManager()
        XCTAssertNil(BottleLocationValidation.missingCapability(in: tempDir, fileManager: recorder))
        XCTAssertTrue(recorder.symlinked, "must verify symlinks: dosdevices/c: is one")
        XCTAssertTrue(recorder.permissionsSet, "must verify posix permissions")
        XCTAssertTrue(
            recorder.createdPaths.contains { $0.hasSuffix("/c:") },
            "must verify a colon-named file: every dosdevices entry has one"
        )
    }

    func testUnwritableLocationIsReportedBeforeCapabilities() throws {
        // notWritable is the more actionable answer, so it must win over a
        // capability probe that would also fail on the same directory.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tempDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path) }

        guard case .notWritable = BottleLocationValidation.validate(at: tempDir, minimumFreeBytes: 0) else {
            return XCTFail("Expected .notWritable for a read-only directory")
        }
    }

    func testConsentGatedVolumeIsFalseForAnInternalPath() {
        XCTAssertFalse(BottleLocationValidation.isConsentGatedVolume(tempDir))
    }

    func testPrivacySettingsDeepLinkIsValid() throws {
        let url = try XCTUnwrap(BottleLocationValidation.privacySettingsURL)
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
    }
}
