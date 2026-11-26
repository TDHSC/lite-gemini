import SwiftUI

/// Pure vector four-point concave star shape used for the splash mark and app emblem.
struct MonochromeSparkShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        let cy = rect.midY
        // Control point offset from center determines the concavity of the star arms
        let k: CGFloat = min(w, h) * 0.08

        var path = Path()
        path.move(to: CGPoint(x: cx, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: cy),
            control: CGPoint(x: cx + k, y: cy - k)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: rect.maxY),
            control: CGPoint(x: cx + k, y: cy + k)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: cy),
            control: CGPoint(x: cx - k, y: cy + k)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: rect.minY),
            control: CGPoint(x: cx - k, y: cy - k)
        )
        path.closeSubpath()
        return path
    }
}
