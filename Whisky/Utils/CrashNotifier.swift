//
//  CrashNotifier.swift
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

import AppKit
import os.log
import UserNotifications
import WhiskyKit

/// Delivers a crash diagnosis as a user notification when Whisky is in the
/// background.
///
/// A game usually crashes while its own window, not Whisky's, is frontmost,
/// which is exactly when the in-app banner plays to an empty room. Clicking
/// the notification brings Whisky forward and opens the diagnosis.
@MainActor
enum CrashNotifier {
    private static let logger = Logger(
        subsystem: Bundle.whiskyBundleIdentifier, category: "CrashNotifier"
    )

    nonisolated static let programPathKey = "programPath"
    nonisolated static let logFileKey = "logFile"

    /// Posted when the person clicks a crash notification. Carries the same
    /// userInfo keys as the notification content.
    nonisolated static let openDiagnosis = Notification.Name(
        "com.franke.Whisky.openCrashDiagnosisFromNotification"
    )

    /// A lightweight informational notification (audio device changes), on
    /// the same provisional path: quiet delivery, never a permission prompt.
    static func notifyInfo(title: String, body: String, identifier: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = await (try? center.requestAuthorization(options: [.alert, .provisional])) ?? false
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body

            do {
                try await center.add(UNNotificationRequest(
                    identifier: identifier, content: content, trigger: nil
                ))
            } catch {
                logger.error("Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }

    /// Posts a notification for a crash that happened in the background.
    ///
    /// Authorization is provisional: delivered quietly to Notification Center
    /// without ever prompting, which is the right weight for a diagnostic.
    /// Everything the notification says is computed here, before the sendable
    /// hop, so nothing main-actor is touched off it.
    static func notify(
        programName: String,
        category: CrashCategory?,
        programPath: String,
        logFileURL: URL
    ) {
        let title = String(format: String(localized: "notification.crash.title"), programName)
        let body = category?.displayName ?? String(localized: "notification.crash.body")

        Task {
            let center = UNUserNotificationCenter.current()
            let granted = await (try? center.requestAuthorization(options: [.alert, .provisional])) ?? false
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = [
                programPathKey: programPath,
                logFileKey: logFileURL.path(percentEncoded: false)
            ]

            do {
                try await center.add(UNNotificationRequest(
                    identifier: "crash-\(programPath)", content: content, trigger: nil
                ))
            } catch {
                logger.error("Failed to deliver crash notification: \(error.localizedDescription)")
            }
        }
    }
}

/// Routes notification clicks back into the app.
///
/// Stateless, which is what makes the `@unchecked Sendable` true: the delegate
/// is called on an arbitrary queue, extracts value types, and hops to the main
/// actor with only those.
final class CrashNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = CrashNotificationDelegate()

    // `willPresent` is deliberately not implemented: the default withholds the
    // system banner while Whisky is frontmost, where the in-app banner already
    // showed, and Notification Center still keeps the record.

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let programPath = userInfo[CrashNotifier.programPathKey] as? String
        let logFile = userInfo[CrashNotifier.logFileKey] as? String

        // Answered before the hop: the handler only signals that the response
        // was taken, and it is not Sendable enough to carry along.
        completionHandler()

        guard let programPath, let logFile else { return }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(
                name: CrashNotifier.openDiagnosis,
                object: nil,
                userInfo: [
                    CrashNotifier.programPathKey: programPath,
                    CrashNotifier.logFileKey: logFile
                ]
            )
        }
    }
}
