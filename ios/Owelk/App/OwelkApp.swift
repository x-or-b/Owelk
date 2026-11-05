import SwiftUI

@main
struct OwelkApp: App {
    @StateObject private var store = LibraryStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
        }
        .onChange(of: phase) { _, phase in
            switch phase {
            case .active: store.resume()
            case .background: store.pause()
            default: break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var choosingFolder = false
    @State private var folderError: String?

    var body: some View {
        Group {
            if store.hasFolder {
                LibraryView(choosingFolder: $choosingFolder)
            } else {
                Welcome(choosingFolder: $choosingFolder, error: folderError)
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url): folderError = store.choose(url)
            case let .failure(error): folderError = error.localizedDescription
            }
        }
        .alert("Sync Folder", isPresented: Binding(get: { store.hasFolder && folderError != nil },
                                                   set: { if !$0 { folderError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(folderError ?? "")
        }
    }
}

private struct Welcome: View {
    @Binding var choosingFolder: Bool
    let error: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Owelk").font(.largeTitle.weight(.semibold))
            Text("Choose the Owelk folder that Synctrain keeps in step with your computers.\nIt holds owelk-sync.json, devices and Papers.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choose Sync Folder…") { choosingFolder = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .padding(.top, 8)
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
        .padding(40)
    }
}
