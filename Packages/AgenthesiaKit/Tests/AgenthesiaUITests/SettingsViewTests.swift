import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgenthesiaUI

@MainActor
@Suite struct SettingsViewTests {
    @Test func listsOnlyInstalledEditorsInTableOrder() {
        let installed = SettingsView.installedEditors {
            ["dev.zed.Zed", "com.microsoft.VSCode"].contains($0) ? URL(filePath: "/A.app") : nil
        }
        #expect(installed.map(\.bundleIdentifier) == ["com.microsoft.VSCode", "dev.zed.Zed"])
        #expect(SettingsView.installedEditors { _ in nil }.isEmpty)
    }

    @Test func hostedSettingsKeepTheStoredChoice() throws {
        let defaults = try #require(UserDefaults(suiteName: "SettingsViewTests-\(UUID())"))
        defaults.set("com.example.Gone", forKey: EditorHandoff.defaultsKey)
        let host = NSHostingView(rootView: SettingsView().defaultAppStorage(defaults))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == 440)
        #expect(host.fittingSize.height > 0)
        // Opening Settings does not rewrite a choice whose editor is gone.
        #expect(defaults.string(forKey: EditorHandoff.defaultsKey) == "com.example.Gone")
    }
}
