//
//  TroubleshootingChecksTests.swift
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

/// A check stub whose outcome is driven entirely by its params, so registry
/// and engine tests never touch a real diagnostic.
struct StubCheck: TroubleshootingCheck {
    let checkId: String

    func run(params: [String: String], context _: CheckContext) async -> CheckResult {
        CheckResult(
            outcome: CheckOutcome(rawValue: params["outcome"] ?? "pass") ?? .pass,
            evidence: ["stub": "true"],
            summary: "stub result"
        )
    }
}

/// Builds a hermetic check context: all inputs injected, nothing read from
/// the machine running the tests.
func makeCheckContext(
    graphicsBackend: String = "dxmt",
    launcherType: String? = nil,
    programName: String? = nil
) -> CheckContext {
    let bottleURL = URL(filePath: "/tmp/test-bottle-\(UUID().uuidString)")
    let preflight = PreflightData(
        bottleURL: bottleURL,
        bottleName: "Test Bottle",
        programName: programName,
        launcherType: launcherType,
        isWineserverRunning: false,
        processCount: 0,
        graphicsBackend: graphicsBackend
    )
    return CheckContext(
        bottleURL: bottleURL,
        bottleName: "Test Bottle",
        programName: programName,
        preflight: preflight,
        session: TroubleshootingSession(bottleURL: bottleURL)
    )
}

final class TroubleshootingChecksTests: XCTestCase {
    // MARK: - CheckRegistry

    func testUnknownCheckIdReturnsErrorResultInsteadOfCrashing() async {
        let registry = CheckRegistry()

        let result = await registry.run(checkId: "no.such_check", params: [:], context: makeCheckContext())

        XCTAssertEqual(result.outcome, .error)
        XCTAssertTrue(result.summary.contains("no.such_check"))
    }

    func testRegisteredCheckRuns() async {
        let registry = CheckRegistry()
        registry.register(StubCheck(checkId: "stub.custom"))

        let result = await registry.run(
            checkId: "stub.custom",
            params: ["outcome": "fail"],
            context: makeCheckContext()
        )

        XCTAssertEqual(result.outcome, .fail)
        XCTAssertEqual(result.evidence["stub"], "true")
    }

    func testReRegisteringSameIdReplacesSilently() async {
        struct FixedCheck: TroubleshootingCheck {
            let checkId = "stub.replace"
            let outcome: CheckOutcome
            func run(params _: [String: String], context _: CheckContext) async -> CheckResult {
                CheckResult(outcome: outcome, summary: "fixed")
            }
        }
        let registry = CheckRegistry()
        registry.register(FixedCheck(outcome: .pass))
        registry.register(FixedCheck(outcome: .unknown))

        let result = await registry.run(checkId: "stub.replace", params: [:], context: makeCheckContext())

        XCTAssertEqual(result.outcome, .unknown)
    }

    // MARK: - GraphicsBackendCheck

    func testGraphicsBackendCheckMissingParamIsError() async {
        let result = await GraphicsBackendCheck().run(params: [:], context: makeCheckContext())

        XCTAssertEqual(result.outcome, .error)
    }

    func testGraphicsBackendCheckMatchIsAlreadyConfigured() async {
        let result = await GraphicsBackendCheck().run(
            params: ["expected": "dxmt"],
            context: makeCheckContext(graphicsBackend: "dxmt")
        )

        XCTAssertEqual(result.outcome, .alreadyConfigured)
        XCTAssertEqual(result.evidence["current"], "dxmt")
        XCTAssertEqual(result.confidence, .high)
    }

    func testGraphicsBackendCheckMismatchIsFail() async {
        let result = await GraphicsBackendCheck().run(
            params: ["expected": "dxvk"],
            context: makeCheckContext(graphicsBackend: "wined3d")
        )

        XCTAssertEqual(result.outcome, .fail)
        XCTAssertEqual(result.evidence["current"], "wined3d")
        XCTAssertEqual(result.evidence["expected"], "dxvk")
    }

    // MARK: - LauncherTypeCheck

    func testLauncherTypeCheckNoLauncherIsUnknown() async {
        let result = await LauncherTypeCheck().run(params: [:], context: makeCheckContext(launcherType: nil))

        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertEqual(result.confidence, .low)
    }

    func testLauncherTypeCheckDetectedWithoutExpectationIsPass() async {
        let result = await LauncherTypeCheck().run(params: [:], context: makeCheckContext(launcherType: "steam"))

        XCTAssertEqual(result.outcome, .pass)
        XCTAssertEqual(result.evidence["detectedLauncher"], "steam")
    }

    func testLauncherTypeCheckExpectationMatchesCaseInsensitively() async {
        let result = await LauncherTypeCheck().run(
            params: ["expected": "Steam"],
            context: makeCheckContext(launcherType: "steam")
        )

        XCTAssertEqual(result.outcome, .pass)
    }

    func testLauncherTypeCheckExpectationMismatchIsFail() async {
        let result = await LauncherTypeCheck().run(
            params: ["expected": "epic"],
            context: makeCheckContext(launcherType: "steam")
        )

        XCTAssertEqual(result.outcome, .fail)
        XCTAssertEqual(result.evidence["expected"], "epic")
    }

    // MARK: - ProcessRunningCheck

    func testProcessRunningCheckNoProcessesIsFail() async {
        // The context's bottle URL is unique per test, so the shared process
        // registry has no entries for it.
        let result = await ProcessRunningCheck().run(params: [:], context: makeCheckContext())

        XCTAssertEqual(result.outcome, .fail)
        XCTAssertEqual(result.evidence["count"], "0")
    }

    // MARK: - GameConfigAvailableCheck

    func testGameConfigCheckWithoutProgramIsUnknown() async {
        let result = await GameConfigAvailableCheck().run(params: [:], context: makeCheckContext())

        XCTAssertEqual(result.outcome, .unknown)
    }

    func testGameConfigCheckUnknownProgramIsFail() async {
        let result = await GameConfigAvailableCheck().run(
            params: [:],
            context: makeCheckContext(programName: "definitely-not-a-real-game-zzz.exe")
        )

        XCTAssertEqual(result.outcome, .fail)
        XCTAssertEqual(result.evidence["programName"], "definitely-not-a-real-game-zzz.exe")
    }

    // MARK: - WinetricksVerbCheck alternatives

    /// Builds a context whose bottle directory exists, so a verb cache can be
    /// written into it.
    private func makeBottleContext() throws -> CheckContext {
        let bottleURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)
        let preflight = PreflightData(
            bottleURL: bottleURL,
            bottleName: "Test Bottle",
            programName: nil,
            launcherType: nil,
            isWineserverRunning: false,
            processCount: 0,
            graphicsBackend: "dxmt"
        )
        return CheckContext(
            bottleURL: bottleURL,
            bottleName: "Test Bottle",
            preflight: preflight,
            session: TroubleshootingSession(bottleURL: bottleURL)
        )
    }

    func testEitherVisualCPlusPlusRuntimeSatisfiesTheRequirement() async throws {
        let context = try makeBottleContext()
        defer { try? FileManager.default.removeItem(at: context.bottleURL) }
        try WinetricksVerbCache.save(
            WinetricksVerbCache(installedVerbs: ["vcrun2019", "dotnet48"]), to: context.bottleURL
        )

        let result = await WinetricksVerbCheck().run(
            params: ["verbs": "vcrun2022|vcrun2019,dotnet48"], context: context
        )

        XCTAssertEqual(result.outcome, .alreadyConfigured)
        XCTAssertNil(result.evidence["missing"])
    }

    func testMissingRequirementReportsTheVerbToInstall() async throws {
        let context = try makeBottleContext()
        defer { try? FileManager.default.removeItem(at: context.bottleURL) }
        try WinetricksVerbCache.save(WinetricksVerbCache(installedVerbs: ["dotnet48"]), to: context.bottleURL)

        let result = await WinetricksVerbCheck().run(
            params: ["verbs": "vcrun2022|vcrun2019,dotnet48"], context: context
        )

        XCTAssertEqual(result.outcome, .fail)
        // The fix installs what this string names, so it has to be one verb
        // rather than the alternatives that were looked for.
        XCTAssertEqual(result.evidence["missing"], "vcrun2022")
    }

    func testAnEquivalentVerbSatisfiesTheDependencyDefinition() {
        let vcruntime = DependencyDefinition.standardDependencies.first { $0.id == "vcruntime" }

        XCTAssertEqual(vcruntime?.winetricksVerbs, ["vcrun2022"])
        XCTAssertEqual(vcruntime?.equivalentVerbs, ["vcrun2019"])
    }

    func testDependencyDefinitionDecodesWithoutEquivalents() throws {
        let json = """
        {
          "id": "vcruntime", "displayName": "Visual C++ Runtime", "description": "old payload",
          "winetricksVerbs": ["vcrun2019"], "category": "Runtime", "estimatedInstallMinutes": 2
        }
        """
        let decoded = try JSONDecoder().decode(DependencyDefinition.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.winetricksVerbs, ["vcrun2019"])
        XCTAssertTrue(decoded.equivalentVerbs.isEmpty)
    }

    // MARK: - Windows version and build number

    func testEachVersionAcceptsItsOwnDefaultBuild() {
        for version in WinVersion.allCases {
            XCTAssertTrue(
                version.accepts(build: version.defaultBuild),
                "\(version.pretty()) rejects the build Wine writes for it"
            )
        }
    }

    func testABuildFromAnotherVersionIsRefused() {
        // The pair that started this: a prefix on Windows 7 carrying a build
        // number from Windows 11.
        XCTAssertFalse(WinVersion.win7.accepts(build: 22_100))
        XCTAssertFalse(WinVersion.win11.accepts(build: 7_601))
        XCTAssertFalse(WinVersion.win10.accepts(build: 22_000))
    }

    func testNewerBuildsOfTheSameVersionAreAccepted() {
        // Windows 11 24H2 and Windows 10 22H2, which people do set by hand.
        XCTAssertTrue(WinVersion.win11.accepts(build: 26_100))
        XCTAssertTrue(WinVersion.win10.accepts(build: 19_045))
        XCTAssertTrue(WinVersion.win7.accepts(build: 7_600))
    }

    func testPrefixVersionIsReadFromWhatProgramsRead() {
        // The pair that fooled every reader: 6.1 with a Windows 11 build. What
        // programs get told is Windows 7, so that is what Whisky must show.
        XCTAssertEqual(WinVersion(currentVersion: "6.1", build: 22_100), .win7)

        XCTAssertEqual(WinVersion(currentVersion: "5.2", build: 3_790), .winXP)
        XCTAssertEqual(WinVersion(currentVersion: "6.2", build: 9_200), .win8)
        XCTAssertEqual(WinVersion(currentVersion: "6.3", build: 9_600), .win81)
        XCTAssertEqual(WinVersion(currentVersion: "6.3", build: 19_045), .win10)
        XCTAssertEqual(WinVersion(currentVersion: "6.3", build: 22_000), .win11)
        XCTAssertEqual(WinVersion(currentVersion: "10.0", build: 26_100), .win11)
    }

    func testAnUnreadableVersionNamesNothing() {
        XCTAssertNil(WinVersion(currentVersion: "4.0", build: 1_381))
        XCTAssertNil(WinVersion(currentVersion: "", build: nil))
    }

    func testTheSixThreeFamilyFallsBackWithoutABuild() {
        // 8.1, 10 and 11 all report 6.3, so a missing build can only be told
        // apart by which key was there at all.
        XCTAssertEqual(WinVersion(currentVersion: "6.3", build: nil), .win81)
        XCTAssertEqual(WinVersion(currentVersion: "10.0", build: nil), .win10)
    }
}
