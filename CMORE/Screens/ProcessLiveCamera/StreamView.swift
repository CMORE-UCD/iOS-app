//
//  ContentView.swift
//  CMORE
//
//  Created by ZIQIANG ZHU on 8/19/25.
//
import SwiftUI
import AVFoundation

struct StreamView: View {
    // View model driving camera and recording state
    @ObservedObject var viewModel: StreamViewModel

    // The target stream aspect ratio (e.g., 1920x1080 = 16:9)
    private var streamAspect: CGFloat {
        CameraSettings.resolution.width / CameraSettings.resolution.height
    }

    var body: some View {
        ZStack {
            // Background to match system camera letterboxing
            Color.gray

            // MARK: - Live Preview (fits into available space; no cropping)
            Group {
                ZStack {
                    if let session = viewModel.captureSession {
                        CameraPreviewView(session: session)
                        
                    } else {
                        Image("placeHolder")
                            .resizable()
                            .scaledToFill()
                    }
                    // Overlay constrained to the same space as camera preview
                    GeometryReader { localGeo in
                        if let overlay = viewModel.overlay {
                            OverlayView(overlay, localGeo, viewModel.handedness)
                        }
                        BoxShape()
                            .stroke(
                                viewModel.isAligned ? Color.white.opacity(0.9) : Color.white.opacity(0.6),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                            )
                    }
                }
            }
            .aspectRatio(streamAspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            StreamUI(viewModel)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Preview
#Preview {
    StreamView(viewModel: StreamViewModel())
}

