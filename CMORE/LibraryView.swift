//
//  LibraryView.swift
//  CMORE
//

import SwiftUI
import SwiftData
import PhotosUI
import Vision
import AudioToolbox

struct LibraryView: View {
    @Query(sort: \Session.date, order: .reverse) private var sessions: [Session]

    @State private var showAddOptions = false
    @State private var showPhotoPicker = false
    @State private var navigateToCamera = false
    @State private var selectedVideoURL: URL?
    @State private var navigateToVideo = false
    @State private var showValidationError = false
    @State private var validationErrorMessage = ""
    @State private var shareItems: [URL] = []
    @State private var sessionIDToRename: UUID?
    @State private var renameText = ""
    @State private var showRenameAlert = false
    @AppStorage("soundMuted") private var soundMuted = false

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions Yet",
                        systemImage: "video.slash",
                        description: Text("Tap + to record a new session")
                    )
                } else {
                    List {
                        ForEach(sessions) { session in
                            NavigationLink(destination: SessionReplayView(session: session)) {
                                SessionRow(session: session) 
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    let id = session.id
                                    Task {
                                        try? await SessionStore.shared.delete(id)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                                    let videoURL = documentsDir.appendingPathComponent(session.videoFileName)
                                    let resultsURL = documentsDir.appendingPathComponent(session.resultsFileName)
                                    shareItems = [videoURL, resultsURL]
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)

                                Button() {
                                    rename(session)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        soundMuted.toggle()
                        playSoundToggleFeedback()
                    } label: {
                        Image(systemName: soundMuted ? "bell.slash.fill" : "bell.fill")
                    }
                }
            }
            .overlay(alignment: .bottom) {
                Button {
                    showAddOptions = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.white, .black)
                        .shadow(radius: 4)
                }
                .padding(.bottom, 32)
            }
            .alert("Add Session", isPresented: $showAddOptions) {
                if !ProcessInfo.processInfo.isiOSAppOnMac {
                    Button("Record New") {
                        navigateToCamera = true
                    }
                    Button("Import from Photos") {
                        showPhotoPicker = true
                    }
                } else {
                    Button("Import from Files", role: .confirm) {
                        showPhotoPicker = true
                    }
                }
            }
            .navigationDestination(isPresented: $navigateToCamera) {
                CameraContainerView()
            }
            .navigationDestination(isPresented: $navigateToVideo) {
                if let url = selectedVideoURL {
                    VideoProcessingView(videoURL: url)
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                VideoPicker(completion: { url in
                    handlePickedVideo(url)
                })
            }
            .alert("Invalid Video", isPresented: $showValidationError) {
                Button("OK") {}
            } message: {
                Text(validationErrorMessage)
            }
            .alert("Rename your file", isPresented: $showRenameAlert) {
                TextField("File name", text: $renameText)
                    .autocorrectionDisabled()
                Button("Save") {
                    renameSelectedSession()
                }
                Button("Cancel", role: .cancel) {
                    clearRenameState()
                }
            }
            .sheet(isPresented: Binding(
                get: { !shareItems.isEmpty },
                set: { if !$0 { shareItems = [] } }
            )) {
                if !shareItems.isEmpty {
                    ShareSheet(activityItems: shareItems)
                }
            }
        }
    }

    private func handlePickedVideo(_ url: URL?) {
        guard let url else { return }

        Task {
            let extractor = VideoFrameExtractor(url: url)
            if let error = await extractor.validate() {
                await MainActor.run {
                    validationErrorMessage = error
                    showValidationError = true
                }
            } else {
                await MainActor.run {
                    selectedVideoURL = url
                    navigateToVideo = true
                }
            }
        }
    }

    private func rename(_ session: Session) {
        sessionIDToRename = session.id
        renameText = session.name.isEmpty ? session.date.formatted(date: .abbreviated, time: .omitted) : session.name
        showRenameAlert = true
    }

    private func renameSelectedSession() {
        guard let sessionIDToRename else { return }
        let newName = renameText

        Task {
            do {
                try await SessionStore.shared.rename(sessionIDToRename, to: newName)
            } catch {
                dprint("LibraryView: failed to rename session")
            }
            await MainActor.run {
                clearRenameState()
            }
        }
    }

    private func clearRenameState() {
        sessionIDToRename = nil
        renameText = ""
    }

    private func playSoundToggleFeedback() {
        let soundID: SystemSoundID = soundMuted ? 1104 : 1117
        AudioServicesPlaySystemSound(soundID)
    }
}

// MARK: - Session Row
private struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 60, height: 44)
                .overlay(
                    Image(systemName: "video.fill")
                        .foregroundColor(.secondary)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    (session.name.isEmpty
                        ? Text(session.date, style: .date)
                        : Text(session.name))
                        .font(.headline)
                }

                Text(session.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("\(session.blockCount) blocks")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Camera Container
struct CameraContainerView: View {
    @StateObject private var viewModel = StreamViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StreamView(viewModel: viewModel)
            .task {
                await viewModel.startCamera()
            }
            .navigationBarBackButtonHidden(viewModel.hideNavigationBackButton)
            .onAppear {
                Task { @MainActor in
                    OrientationManager.shared.setOrientation(.landscapeRight)
                }
            }
            .onDisappear {
                Task { @MainActor in
                    OrientationManager.shared.setOrientation(.all)                }
            }
            .onChange(of: viewModel.shouldDismissCamera) { _, shouldDismiss in
                if shouldDismiss {
                    dismiss()
                }
            }
    }
}

// MARK: - Share Sheet
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    LibraryView()
}
