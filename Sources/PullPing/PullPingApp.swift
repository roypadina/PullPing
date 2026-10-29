import SwiftUI

/// Not `@main`: `main.swift` runs smoke mode first.
struct PullPingApp: App {
    var body: some Scene {
        MenuBarExtra("PullPing", systemImage: "arrow.triangle.pull") {
            Text("PullPing")
        }
    }
}
