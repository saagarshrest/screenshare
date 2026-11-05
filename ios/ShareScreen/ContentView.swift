import SwiftUI

/// Finds the computer, then shows its screen full-screen.
struct ContentView: View {
    @StateObject private var finder = HostFinder()
    @State private var host: String?
    @State private var showAddress = false
    @State private var typed = UserDefaults.standard.string(forKey: "lastHost") ?? ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let host {
                PlayerView(host: host) { self.host = nil; finder.search() }
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 44)).foregroundStyle(.blue)
                    Text("ShareScreen").font(.title2.weight(.semibold))
                    Text(finder.message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if finder.searching { ProgressView() }
                    HStack(spacing: 12) {
                        Button("Search again") { finder.search() }.disabled(finder.searching)
                        Button("Enter address") { showAddress = true }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(32)
            }
        }
        .onAppear { finder.search() }
        .onChange(of: finder.found) { _, found in if let found { connect(found) } }
        .alert("Computer's address", isPresented: $showAddress) {
            TextField("192.168.1.20", text: $typed).keyboardType(.decimalPad)
            Button("Connect") { finder.check(typed.trimmingCharacters(in: .whitespaces)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown by ShareScreen on your computer.")
        }
    }

    private func connect(_ ip: String) {
        UserDefaults.standard.set(ip, forKey: "lastHost")
        UIApplication.shared.isIdleTimerDisabled = true
        host = ip
    }
}
