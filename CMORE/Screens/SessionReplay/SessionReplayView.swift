//
//  SessionReplayView.swift
//  CMORE
//

import SwiftUI
import AVFoundation

// MARK: - AVPlayerLayer wrapper for reliable overlay z-ordering

struct PlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        PlayerUIView(player: player)
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {}
}

class PlayerUIView: UIView {
    private let playerLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

// MARK: - Session Replay View

struct SessionReplayView: View {
    @StateObject private var viewModel: SessionReplayViewModel
    @Environment(\.dismiss) private var dismiss

    init(session: Session) {
        _viewModel = StateObject(wrappedValue: SessionReplayViewModel(session: session))
    }

    var body: some View {
        ZStack {
            Color.black

            // Video + Overlay
            ZStack {
                PlayerView(player: viewModel.player)
                
                GeometryReader { geo in
                    if let frameResult = viewModel.currentFrameResult {
                        OverlayView(frameResult, geo, viewModel.handedness)
                    }
                }
            }
            .aspectRatio(viewModel.videoAspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Controls bar
            VStack(spacing: 3) {
                
                // Block count
                HStack {
                    Image(systemName: "cube.fill")
                        .foregroundColor(.white)
                    Text("\(viewModel.currentBlockCount) blocks")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .padding(.top)

                Spacer()
                
                Group{
                    // Scrubber
                    Slider(
                        value: Binding(
                            get: { viewModel.currentTime },
                            set: { viewModel.seek(to: $0) }
                        ),
                        in: 0...max(viewModel.duration, 0.01)
                    )
                    .tint(.gray.opacity(0.7))
                    
                    // Time labels
                    HStack {
                        Text(formatTime(viewModel.currentTime))
                        Spacer()
                        Text(formatTime(viewModel.duration))
                    }
                    .font(.caption)
                    .foregroundColor(.gray)
                }
                .padding(.horizontal)

                // Playback controls
                HStack(spacing: 40) {
                    Button { viewModel.skipBackward() } label: {
                        Image(systemName: "gobackward.5")
                            .font(.title2)
                            .foregroundColor(.white)
                    }

                    Button { viewModel.togglePlayPause() } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.white)
                    }

                    Button { viewModel.skipForward() } label: {
                        Image(systemName: "goforward.5")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .padding(.all)
        }
        .ignoresSafeArea()
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.white)
                }
            }
        }
        .onAppear {
            Task { @MainActor in
                OrientationManager.shared.setOrientation(.landscapeRight)
            }
        }
        .onDisappear {
            viewModel.player.pause()
            Task { @MainActor in
                OrientationManager.shared.setOrientation(.all)
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
