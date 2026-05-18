//
//  VideoProcessingView.swift
//  CMORE
//

import SwiftUI
import Vision
import AVFoundation

struct VideoProcessingView: View {
    @StateObject private var viewModel = VideoProcessingViewModel()
    @Environment(\.dismiss) private var dismiss

    let videoURL: URL
    let handedness: HumanHandPoseObservation.Chirality

    @State private var videoAspect: CGFloat = 16.0 / 9.0

    var body: some View {
        ZStack {
            Color.black

            // Video frame + overlay
            ZStack {
                if let frame = viewModel.currentFrame {
                    Image(uiImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.black
                }

                GeometryReader { geo in
                    if let overlay = viewModel.overlay {
                        OverlayView(overlay, geo, viewModel.handedness)
                    }
                }
            }
            .aspectRatio(videoAspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // UI overlay
            VStack {
                HandednessIndicator(handedness: viewModel.handedness)
                    .padding(.top, 5)
                // Block count
                if let blocks = viewModel.overlay?.blockTransfered {
                    Text("Blocks: \(blocks)")
                        .font(.headline)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.black.opacity(0.6))
                        )
                        .foregroundColor(.white)
                }
                Spacer()

                if viewModel.isProcessing {
                    ProgressView("Processing...")
                        .tint(.white)
                        .foregroundColor(.white)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.black.opacity(0.6))
                        )
                        .padding(.bottom, 20)
                }
            }
        }
        .ignoresSafeArea()
        .navigationBarBackButtonHidden(true)
        .onAppear {
            Task { @MainActor in
                OrientationManager.shared.setOrientation(.landscapeRight)
            }
            viewModel.handedness = handedness
            viewModel.loadVideo(url: videoURL)
        }
        .onDisappear {
            Task { @MainActor in
                OrientationManager.shared.setOrientation(.all)
            }
        }
        .task {
            let asset = AVURLAsset(url: videoURL)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), size.width > 0 {
                videoAspect = abs(size.width / size.height)
            }
            await viewModel.startProcessing()
        }
        .onChange(of: viewModel.isDone) { _, isDone in
            if isDone {
                dismiss()
            }
        }
    }
}

