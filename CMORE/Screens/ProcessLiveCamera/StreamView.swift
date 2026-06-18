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
                        Color.black
                            .overlay(
                                Text("Camera will appear here")
                                    .foregroundColor(.white)
                                    .font(.title2)
                            )
                    }
                    // Overlay constrained to the same space as camera preview
                    GeometryReader { localGeo in
                        if let overlay = viewModel.overlay {
                            OverlayView(overlay, localGeo, viewModel.handedness)
                        }
                        BoxShape()
                            .stroke(
                                Color.white.opacity(0.9),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                            )
                            .padding(.all, localGeo.size.width * 0.1)
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

