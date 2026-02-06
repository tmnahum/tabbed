import SwiftUI

struct SettingsView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Settings")
                .font(.title2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(width: 400, height: 300)
    }
}
