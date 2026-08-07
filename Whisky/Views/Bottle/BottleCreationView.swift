//
//  BottleCreationView.swift
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

struct BottleCreationView: View {
    @Binding var newlyCreatedBottleURL: URL?

    @State private var newBottleName: String = ""
    @State private var newBottleVersion: WinVersion = .win10
    @State private var newBottleURL: URL = UserDefaults.standard.url(forKey: "defaultBottleLocation")
        ?? BottleData.defaultBottleDir
    @State private var nameValid: Bool = false
    @State private var accessIssue: ExternalVolumeAccess.Access?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                TextField("create.name", text: $newBottleName)
                    .onChange(of: newBottleName) { _, name in
                        nameValid = !name.isEmpty
                    }
                    .accessibilityIdentifier("create.nameField")

                Picker("create.win", selection: $newBottleVersion) {
                    ForEach(WinVersion.allCases.reversed(), id: \.self) {
                        Text($0.pretty())
                    }
                }

                ActionView(
                    text: "create.path",
                    subtitle: newBottleURL.prettyPath(),
                    actionName: "create.browse"
                ) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = BottleData.containerDir
                    panel.begin { result in
                        if result == .OK, let url = panel.urls.first {
                            newBottleURL = url
                            // Probe here so the consent prompt appears while the user is choosing.
                            accessIssue = ExternalVolumeAccess.requestAccess(to: url).nilIfGranted
                        }
                    }
                }

                if let accessIssue {
                    accessWarning(accessIssue)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("create.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("create.cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("create.cancelButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("create.create") {
                        submit()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!nameValid || accessIssue != nil)
                    .accessibilityIdentifier("create.createButton")
                }
            }
            .onSubmit {
                submit()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: ViewWidth.small)
    }

    @ViewBuilder
    private func accessWarning(_ issue: ExternalVolumeAccess.Access) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.orange)
            Text(explanation(for: issue))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if case let .denied(kind) = issue, kind.requiresConsent,
                   let settings = ExternalVolumeAccess.privacySettingsURL {
                    Button("Open Privacy Settings…") { openURL(settings) }
                }
                Button("Check Again") {
                    accessIssue = ExternalVolumeAccess.requestAccess(to: newBottleURL).nilIfGranted
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        if case .volumeUnavailable = accessIssue { return "That drive isn't connected" }
        return "Whisky can't write to that location"
    }

    private var symbol: String {
        if case .volumeUnavailable = accessIssue { return "externaldrive.badge.xmark" }
        return "lock.fill"
    }

    private func explanation(for issue: ExternalVolumeAccess.Access) -> String {
        switch issue {
        case .granted:
            ""
        case .denied(.removable):
            """
            macOS is withholding access to removable drives. Grant Whisky access under \
            Privacy & Security → Files and Folders, then check again.
            """
        case .denied(.network):
            """
            macOS is withholding access to network volumes. Grant Whisky access under \
            Privacy & Security → Files and Folders, then check again.
            """
        case .denied(.internalDisk):
            "The folder isn't writable. Pick another location, or fix its permissions in Finder."
        case .volumeUnavailable:
            "Reconnect the drive and check again, or pick a location on this Mac."
        case let .failed(reason):
            reason
        }
    }

    func submit() {
        // The default location never passes through the panel, so probe again here.
        let access = ExternalVolumeAccess.requestAccess(to: newBottleURL)
        guard access.isGranted else {
            accessIssue = access
            return
        }
        newlyCreatedBottleURL = BottleVM.shared.createNewBottle(
            bottleName: newBottleName,
            winVersion: newBottleVersion,
            bottleURL: newBottleURL
        )
        dismiss()
    }
}

#Preview {
    BottleCreationView(newlyCreatedBottleURL: .constant(nil))
}
