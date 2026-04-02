//
//  BoundingBoxView.swift
//  CMORE
//
//  Created by ZIQIANG ZHU on 9/30/25.
//

import SwiftUI
import Vision

struct BoundingBoxView: View {
    let geo: GeometryProxy
    let normalizedBox: NormalizedRect
    
    init(_ geo: GeometryProxy, _ bbox: BoundingBoxProviding) {
        self.geo = geo
        self.normalizedBox = bbox.boundingBox
    }

    var body: some View {
        let rect: CGRect = normalizedBox.toImageCoordinates(geo.size)
        
        return Rectangle()
            .stroke(Color.red, lineWidth: 2)
            .frame(
                width: rect.width,
                height: rect.height
            )
            .position(
                x: rect.midX,
                y: rect.midY
            )
    }
}

extension NormalizedRect: @retroactive BoundingBoxProviding {
    public var boundingBox: NormalizedRect { self }
}
