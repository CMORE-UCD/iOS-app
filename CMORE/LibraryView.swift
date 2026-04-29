//
//  LibraryView.swift
//  CMORE
//

import SwiftUI
import SwiftData
import PhotosUI
import Vision

struct LibraryView: View {
    @Query(sort: \Session.date, order: .reverse) private var sessions: [Session]

    @State private var showAddOptions = false
    @State private var showPhotoPicker = false
    @State private var navigateToCamera = false
    @State private var selectedVideoURL: URL?
    @State private var navigateToVideo = false
    @State private var showHandednessChoice = false
    @State private var selectedHandedness: HumanHandPoseObservation.Chirality = .right
    @State private var showValidationError = false
    @State private var validationErrorMessage = ""
    @State private var shareItems: [URL] = []

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
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
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
                Button("Cancel", role: .cancel) {}
            }
            .navigationDestination(isPresented: $navigateToCamera) {
                CameraContainerView()
            }
            .navigationDestination(isPresented: $navigateToVideo) {
                if let url = selectedVideoURL {
                    VideoProcessingView(videoURL: url, handedness: selectedHandedness)
                }
            }
            .alert("Which hand?", isPresented: $showHandednessChoice) {
                Button("Right Hand") {
                    selectedHandedness = .right
                    navigateToVideo = true
                }
                Button("Left Hand") {
                    selectedHandedness = .left
                    navigateToVideo = true
                }
                Button("Cancel", role: .cancel) {}
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
                    showHandednessChoice = true
                }
            }
        }
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
                Text(session.date, style: .date)
                    .font(.headline)
                Text(session.date, style: .time)
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
            .navigationBarBackButtonHidden(true)
            .onAppear {
                Task { @MainActor in
                    OrientationManager.shared.setOrientation(.landscapeRight)
                }
            }
            .onDisappear {
                Task { @MainActor in
                    OrientationManager.shared.setOrientation(.all)
                }
            }
            .onChange(of: viewModel.showSaveConfirmation) { wasShowing, isShowing in
                if wasShowing && !isShowing {
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
