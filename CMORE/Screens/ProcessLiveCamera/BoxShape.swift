//
//  BoxShape.swift
//  CMORE
//

import SwiftUI

struct BoxShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let w = rect.width
        let h = rect.height
        
        // Helper to map normalized coordinates (0.0 to 1.0) to the shape's frame
        func p(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + nx * w, y: rect.minY + ny * h)
        }
        
        let backLeftX = LiveUIConstants.backLeftX
        let backRightX = LiveUIConstants.backRightX
        let frontTopLeftX = LiveUIConstants.frontTopLeftX
        let frontTopRightX = LiveUIConstants.frontTopRightX
        let frontBottomLeftX = LiveUIConstants.frontBottomLeftX
        let frontBottomRightX = LiveUIConstants.frontBottomRightX
        let centerX = LiveUIConstants.centerX
        let stickTopY = LiveUIConstants.stickTopY
        let backRimY = LiveUIConstants.backRimY
        let frontRimY = LiveUIConstants.frontRimY
        let bottomY = LiveUIConstants.bottomY
        
        // Points
        let btl = p(backLeftX, backRimY)
        let btr = p(backRightX, backRimY)
        
        let ftl = p(frontTopLeftX, frontRimY)
        let ftr = p(frontTopRightX, frontRimY)
        
        let fbl = p(frontBottomLeftX, bottomY)
        let fbr = p(frontBottomRightX, bottomY)
        
        let dTop = p(centerX, stickTopY)
        let dFrontBottom = p(centerX, bottomY)

        // 1. Top Opening (Continuous loop)
        path.move(to: btl)
        path.addLine(to: btr)
        path.addLine(to: ftr)
        path.addLine(to: ftl)
        path.closeSubpath()
        
        // 2. Front Face Drop (U-shape)
        path.move(to: ftl)
        path.addLine(to: fbl)
        path.addLine(to: fbr)
        path.addLine(to: ftr)
        
        // 3. Center Divider & Vertical Stick
        path.move(to: dTop)
        path.addLine(to: dFrontBottom)
        
        return path
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        
        // Now it behaves exactly like a native SwiftUI Shape (like Rectangle or Circle)
        BoxShape()
            .stroke(
                Color.white.opacity(0.9),
                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
            )
            .aspectRatio(16/9, contentMode: .fit)
            .padding(.all, 70)
    }
}
