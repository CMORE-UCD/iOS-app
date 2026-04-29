//
//  CMOREApp.swift
//  CMORE
//
//  Created by ZIQIANG ZHU on 8/19/25.
//

import SwiftUI
import SwiftData
import UIKit

// MARK: - Orientation Control

/// Controls which orientations are allowed at any given time.
/// Defaults to all, switches to landscape when entering the camera view.
@MainActor
class OrientationManager {
    static let shared = OrientationManager()
    private(set) var orientationMask: UIInterfaceOrientationMask = .all

    func setOrientation(_ mask: UIInterfaceOrientationMask) {
        orientationMask = mask
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            return
        }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            dprint("Orientation Manager: Orientation update failed: \(error)")
        }

        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

@MainActor
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        return OrientationManager.shared.orientationMask
    }
}

// MARK: - Main App Entry Point
@main
struct CMOREApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
        .modelContainer(SessionStore.shared.container)
    }
}
