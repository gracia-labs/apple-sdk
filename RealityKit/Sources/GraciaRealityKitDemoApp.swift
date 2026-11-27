//
//  SwiftUI entry point for the macOS Gracia RealityKit demo.
//

import SwiftUI
import UniformTypeIdentifiers

@main
struct GraciaRealityKitDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1120, height: 740)
    }
}

struct ContentView: View {
    @State private var sceneURL: URL?
    @State private var isPlaying = true
    @State private var showOccluder = true
    @State private var resetToken = 0
    @State private var showImporter = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            RealityKitSplatsViewport(
                sceneURL: sceneURL,
                isPlaying: isPlaying,
                showOccluder: showOccluder,
                resetToken: resetToken)
            .ignoresSafeArea()

            toolbar.padding(16)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                sceneURL = urls.first
                isPlaying = true
                errorMessage = nil
            case .failure(let error):
                errorMessage = "\(error)"
            }
        }
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            HStack(spacing: 12) {
                Button { showImporter = true } label: {
                    Label(sceneURL?.lastPathComponent ?? "Open Scene", systemImage: "folder")
                        .lineLimit(1)
                }

                Button { isPlaying.toggle() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }
                .disabled(sceneURL == nil)

                Toggle("Occluder", isOn: $showOccluder)
                    .toggleStyle(.button)

                Button { resetToken &+= 1 } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }
}
