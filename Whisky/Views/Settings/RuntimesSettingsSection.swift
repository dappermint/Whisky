//
//  RuntimesSettingsSection.swift
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
import UniformTypeIdentifiers
import WhiskyKit

/// Installs and removes Wine runtimes beyond the default one, which bottles can
/// then select individually.
struct RuntimesSettingsSection: View {
    @State private var runtimes: [InstalledRuntime] = []
    @State private var installing = false
    @State private var showImporter = false
    @State private var installError: String?

    var body: some View {
        Section {
            ForEach(runtimes) { runtime in
                LabeledContent {
                    if !runtime.isDefault {
                        Button("settings.runtimes.remove", role: .destructive) {
                            remove(runtime)
                        }
                        .disabled(installing)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(runtime.isDefault
                            ? String(localized: "config.runtime.default")
                            : runtime.displayName)
                        Text(subtitle(for: runtime))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button("settings.runtimes.add") {
                    showImporter = true
                }
                .disabled(installing)

                if installing {
                    ProgressView()
                        .controlSize(.small)
                    Text("settings.runtimes.installing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("settings.runtimes.title")
        } footer: {
            Text("settings.runtimes.info")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { refresh() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.gzip, .archive]) { result in
            guard case let .success(url) = result else { return }
            install(from: url)
        }
        .alert(
            "settings.runtimes.installFailed",
            isPresented: .init(
                get: { installError != nil },
                set: { if !$0 { installError = nil } }
            )
        ) {
            Button("button.ok", role: .cancel) {}
        } message: {
            Text(installError ?? "")
        }
    }

    private func subtitle(for runtime: InstalledRuntime) -> String {
        var parts: [String] = []
        if !runtime.versionDescription.isEmpty {
            parts.append(runtime.versionDescription)
        }
        if runtime.gptkCapable {
            parts.append(String(localized: "settings.runtimes.gptkCapable"))
        }
        return parts.joined(separator: " · ")
    }

    private func refresh() {
        runtimes = WhiskyWineInstaller.installedRuntimes()
    }

    private func install(from url: URL) {
        installing = true
        Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let identifier = try WhiskyWineInstaller.installRuntime(from: url)
                // A GPTK-capable runtime arriving after the payload was imported
                // still needs it, and the store outlives every runtime.
                GPTKImporter.deployStoredPayloadIfCapable(for: identifier)
                await MainActor.run {
                    installing = false
                    refresh()
                }
            } catch {
                await MainActor.run {
                    installing = false
                    installError = error.localizedDescription
                }
            }
        }
    }

    private func remove(_ runtime: InstalledRuntime) {
        guard let identifier = runtime.runtime else { return }
        do {
            // Restore its Wine originals first, or the backups outlive the tree
            // they belong to and the store keeps a set it can never replace.
            try? GPTKImporter.removeDeployedPayload(for: identifier)
            try WhiskyWineInstaller.removeRuntime(identifier)
        } catch {
            installError = error.localizedDescription
        }
        refresh()
    }
}
