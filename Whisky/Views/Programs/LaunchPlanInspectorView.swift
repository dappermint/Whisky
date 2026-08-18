//
//  LaunchPlanInspectorView.swift
//  Whisky
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

import SwiftUI
import WhiskyKit

/// Answers "why is this set" for one program: the launch plan's own notes,
/// then every environment variable the next launch would carry, each labeled
/// with the layer that won it and the reason that layer recorded.
struct LaunchPlanInspectorView: View {
    @ObservedObject var bottle: Bottle
    @ObservedObject var program: Program
    @Environment(\.dismiss) private var dismiss

    @State private var planNotes: [String] = []
    @State private var entries: [EnvironmentProvenance.Entry] = []
    @State private var dllOverrides: String?

    var body: some View {
        NavigationStack {
            List {
                if !planNotes.isEmpty {
                    Section("program.provenance.planSection") {
                        ForEach(planNotes, id: \.self) { note in
                            Text(note)
                                .font(.callout)
                        }
                    }
                }
                Section("program.provenance.envSection") {
                    ForEach(entries, id: \.key) { entry in
                        row(for: entry)
                    }
                    if let dllOverrides {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "WINEDLLOVERRIDES = \(dllOverrides)")
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Text("program.provenance.dllComposed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("program.provenance.title")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 540, minHeight: 480)
        .onAppear(perform: resolve)
    }

    private func row(for entry: EnvironmentProvenance.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(entry.key) = \(entry.value)")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            HStack(spacing: 4) {
                Text(entry.layer.label)
                if let reason = entry.reason {
                    Text(verbatim: "\u{2022} \(reason)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// One resolution per presentation: the same plan and environment the
    /// launch door would assemble, minus the launch log line.
    private func resolve() {
        let plan = LaunchResolver.plan(
            forProgramAt: program.url, userOverrides: program.settings.overrides
        )
        let resolved = Wine.constructWineEnvironmentWithProvenance(
            for: bottle,
            environment: program.generateEnvironment(),
            programOverrides: plan.overrides,
            programSettings: program.settings,
            gameProfileEnvironment: plan.gameProfileEnvironment,
            logSummary: false
        )
        planNotes = plan.provenance
        entries = resolved.provenance.entries.values.sorted { $0.key < $1.key }
        dllOverrides = resolved.environment["WINEDLLOVERRIDES"]
    }
}

// MARK: - Layer Labels

extension EnvironmentLayer {
    /// Where a value came from, in user words.
    var label: String {
        switch self {
        case .base:
            String(localized: "env.layer.base")
        case .platform:
            String(localized: "env.layer.platform")
        case .bottleManaged:
            String(localized: "env.layer.bottleManaged")
        case .launcherManaged:
            String(localized: "env.layer.launcherManaged")
        case .gameProfile:
            String(localized: "env.layer.gameProfile")
        case .bottleUser:
            String(localized: "env.layer.bottleUser")
        case .programUser:
            String(localized: "env.layer.programUser")
        case .featureRuntime:
            String(localized: "env.layer.featureRuntime")
        case .callsiteOverride:
            String(localized: "env.layer.callsiteOverride")
        }
    }
}
