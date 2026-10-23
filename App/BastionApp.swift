import SwiftUI
import BastionCore

@main
struct BastionApp: App {
    var body: some Scene {
        WindowGroup { Text("Bastion \(BastionCore.version)").padding() }
    }
}
