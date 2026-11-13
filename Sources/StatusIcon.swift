import AppKit

/// Draws the Keep Awake status item images in code. No SF Symbol shows a nearly closed laptop.
///
/// Two designs exist. `activeDesign` selects the one that `make(isOn:)` draws. The other design stays
/// in this file as a private function. When Keep Awake is on, light fills the gap between the lid and
/// the base, and short rays leave the open side of the gap.
enum StatusIcon {

    /// The design that `make(isOn:)` draws. Set this to `.frontView` to draw the other design.
    private static let activeDesign: Design = .sideView

    private enum Design {
        /// A side view. The lid is hinged at the left end of the base and open about 16 degrees.
        case sideView
        /// A front three-quarter view. The base is a trapezoid, and the lid leans over it with a gap.
        case frontView
    }

    // MARK: - Geometry, in points. The canvas is 18 by 18 points with its origin at the lower left.

    private static let canvasSide: CGFloat = 18
    private static let lineWidth: CGFloat = 1.5
    /// The clear space between a light band and the solid shapes that border it.
    private static let lightClearance: CGFloat = 0.5

    // Side view.
    private static let sideBaseRectangle = NSRect(x: 1.0, y: 5.0, width: 16.0, height: 2.0)
    private static let sideBaseTop: CGFloat = 7.0
    private static let sideHingeX: CGFloat = 1.0
    private static let sideLidAngleRadians: CGFloat = 16 * .pi / 180
    private static let sideLidLength: CGFloat = 16.0
    private static let sideLidThickness: CGFloat = 2.0
    private static let sideOpeningX: CGFloat = 15.0

    // Front three-quarter view.
    private static let frontBasePoints: [NSPoint] = [
        NSPoint(x: 1.0, y: 3.5),
        NSPoint(x: 17.0, y: 3.5),
        NSPoint(x: 15.5, y: 7.0),
        NSPoint(x: 2.5, y: 7.0),
    ]
    /// The lid outline. Its stroke is `lineWidth`, centered on these points.
    private static let frontLidPoints: [NSPoint] = [
        NSPoint(x: 2.0, y: 10.0),
        NSPoint(x: 16.0, y: 10.0),
        NSPoint(x: 15.0, y: 13.5),
        NSPoint(x: 3.0, y: 13.5),
    ]

    /// The rays of each design. Each ray starts at a point and runs at an angle for a length, in points and degrees.
    private static let sideRays: [(start: NSPoint, angleDegrees: CGFloat, length: CGFloat)] = [
        (NSPoint(x: 15.5, y: 10.0), 25, 1.6),
        (NSPoint(x: 15.5, y: 8.5), -10, 1.5),
    ]
    private static let frontRays: [(start: NSPoint, angleDegrees: CGFloat, length: CGFloat)] = [
        (NSPoint(x: 2.5, y: 8.0), 200, 1.4),
        (NSPoint(x: 15.5, y: 8.0), -20, 1.4),
    ]

    private static let accessibilityDescriptionOff = "Keep Awake is off"
    private static let accessibilityDescriptionOn = "Keep Awake is on"

    // MARK: - Public interface

    /// Returns a template image. The image is black with alpha, so macOS tints it for each menu bar.
    static func make(isOn: Bool) -> NSImage {
        let size = NSSize(width: canvasSide, height: canvasSide)
        let image = NSImage(size: size, flipped: false) { _ in
            drawLaptop(isOn: isOn, design: activeDesign)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = isOn ? accessibilityDescriptionOn : accessibilityDescriptionOff
        return image
    }

    // MARK: - Drawing

    private static func drawLaptop(isOn: Bool, design: Design) {
        NSColor.black.setStroke()
        NSColor.black.setFill()
        switch design {
        case .sideView:
            drawSideView(isOn: isOn)
        case .frontView:
            drawFrontView(isOn: isOn)
        }
    }

    /// Draws the side view. The base is a thin slab. The lid is a thin slab of the same length, hinged at the base corner.
    private static func drawSideView(isOn: Bool) {
        NSBezierPath(roundedRect: sideBaseRectangle, xRadius: 0.5, yRadius: 0.5).fill()
        drawSideLid()
        if isOn {
            drawSideLight()
            strokeRays(sideRays)
        }
    }

    /// Fills the lid in a local frame. The frame starts at the hinge and turns by the lid angle.
    private static func drawSideLid() {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        context.saveGState()
        context.translateBy(x: sideHingeX, y: sideBaseTop)
        context.rotate(by: sideLidAngleRadians)
        let lidRectangle = NSRect(x: 0, y: 0, width: sideLidLength, height: sideLidThickness)
        NSBezierPath(roundedRect: lidRectangle, xRadius: 0.5, yRadius: 0.5).fill()
        context.restoreGState()
    }

    /// Fills the gap between the lid and the base with a solid wedge that keeps clear of both shapes.
    private static func drawSideLight() {
        let baseClearLine = sideBaseTop + lightClearance
        let lidTan = tan(sideLidAngleRadians)
        // The lid lower edge rises by this much per point of distance from the hinge.
        let lidEdgeY = { (x: CGFloat) -> CGFloat in sideBaseTop + (x - sideHingeX) * lidTan }
        let apexX = sideHingeX + 2 * lightClearance / lidTan
        let wedge = NSBezierPath()
        wedge.move(to: NSPoint(x: apexX, y: baseClearLine))
        wedge.line(to: NSPoint(x: sideOpeningX, y: lidEdgeY(sideOpeningX) - lightClearance))
        wedge.line(to: NSPoint(x: sideOpeningX, y: baseClearLine))
        wedge.close()
        wedge.fill()
    }

    /// Draws the front three-quarter view. The base is a trapezoid, and the lid is an outlined screen above it.
    private static func drawFrontView(isOn: Bool) {
        polygon(frontBasePoints).fill()
        let lid = polygon(frontLidPoints)
        lid.lineWidth = lineWidth
        lid.lineJoinStyle = .round
        lid.stroke()
        if isOn {
            // The band fills the gap between the base and the lid, with clear space on both sides.
            NSBezierPath(rect: NSRect(x: 3.0, y: 7.5, width: 12.0, height: 1.0)).fill()
            strokeRays(frontRays)
        }
    }

    private static func polygon(_ points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else {
            return path
        }
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.close()
        return path
    }

    /// Strokes each ray with round ends. The stroke width is `lineWidth`.
    private static func strokeRays(_ rays: [(start: NSPoint, angleDegrees: CGFloat, length: CGFloat)]) {
        for ray in rays {
            let angle = ray.angleDegrees * .pi / 180
            let end = NSPoint(
                x: ray.start.x + ray.length * cos(angle),
                y: ray.start.y + ray.length * sin(angle))
            let path = NSBezierPath()
            path.move(to: ray.start)
            path.line(to: end)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.stroke()
        }
    }
}
