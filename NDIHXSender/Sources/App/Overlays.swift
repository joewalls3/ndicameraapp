// FILE: Overlays.swift
import SwiftUI
import CoreGraphics

struct HistogramView: View {
    var lumaSamples: [CGFloat]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width / CGFloat(max(lumaSamples.count, 1))
            Path { path in
                for (index, value) in lumaSamples.enumerated() {
                    let x = CGFloat(index) * width
                    let height = geometry.size.height * min(max(value, 0.0), 1.0)
                    path.addRect(CGRect(x: x, y: geometry.size.height - height, width: width, height: height))
                }
            }
            .fill(Color.white.opacity(0.6))
            .background(Color.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(height: 80)
    }
}

struct ZebrasView: View {
    var mask: CGImage?

    var body: some View {
        MaskedOverlay(mask: mask, tint: Color.white.opacity(0.65))
    }
}

struct FocusPeakingView: View {
    var mask: CGImage?

    var body: some View {
        MaskedOverlay(mask: mask, tint: Color.green.opacity(0.7))
    }
}

struct FocusReticle: View {
    @Binding var isVisible: Bool
    @Binding var position: CGPoint

    var body: some View {
        GeometryReader { geometry in
            if isVisible {
                let size: CGFloat = 100
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.yellow, lineWidth: 2)
                    .frame(width: size, height: size)
                    .position(position)
                    .transition(.scale)
                    .animation(.easeOut(duration: 0.2), value: isVisible)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            isVisible = false
                        }
                    }
            }
        }
        .allowsHitTesting(false)
    }
}

struct HorizonLevelView: View {
    var roll: Double

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let lineLength = size * 0.6
            let lineWidth: CGFloat = 3
            let angle = Angle(radians: roll)

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                Rectangle()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: lineLength, height: lineWidth)
                    .rotationEffect(angle)
                Rectangle()
                    .fill(Color.red.opacity(0.5))
                    .frame(width: lineLength, height: lineWidth / 2)
                    .rotationEffect(.zero)
            }
            .frame(width: size, height: size)
        }
        .frame(width: 120, height: 120)
        .padding()
        .allowsHitTesting(false)
    }
}

private struct MaskedOverlay: View {
    var mask: CGImage?
    var tint: Color

    var body: some View {
        GeometryReader { geometry in
            if let mask = mask {
                tint
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .blendMode(.screen)
                    .mask(
                        Image(decorative: mask, scale: 1.0)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
