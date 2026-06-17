//
//  LaunchAtLoginController.swift
//  NoteCast
//
//  Small wrapper around macOS' login-item API.
//

import Combine
import Foundation
import ServiceManagement

/// Manages NoteCast's "Start at Login" registration.
///
/// `SMAppService.mainApp` registers the current app bundle as a user-visible
/// login item in System Settings. Keeping this behind a tiny observable object
/// makes the menu bar toggle simple and keeps ServiceManagement details out of
/// the view code.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published private(set) var errorMessage: String?

    var isEnabled: Bool {
        status == .enabled
    }

    var statusMessage: String? {
        if let errorMessage {
            return errorMessage
        }

        switch status {
        case .enabled, .notRegistered:
            return nil
        case .requiresApproval:
            return "Enable NoteCast in System Settings > General > Login Items."
        case .notFound:
            return "Start at Login is unavailable for this build."
        @unknown default:
            return nil
        }
    }

    func refreshStatus() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ shouldEnable: Bool) {
        errorMessage = nil

        do {
            if shouldEnable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Could not update Start at Login: \(error.localizedDescription)"
        }

        refreshStatus()
    }
}
