import AppKit

@MainActor enum AppIcon {
    static func image(size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let scale = size / 512
        let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 456, height: 456), xRadius: 102, yRadius: 102)
        NSGradient(starting: NSColor(calibratedRed: 0.75, green: 0.82, blue: 0.87, alpha: 1), ending: NSColor(calibratedRed: 0.96, green: 0.98, blue: 1, alpha: 1))?.draw(in: background, angle: 70)
        NSColor.white.withAlphaComponent(0.75).setStroke(); background.lineWidth = 2; background.stroke()
        NSGraphicsContext.saveGraphicsState()
        let tilt = NSAffineTransform(); tilt.translateX(by: 241, yBy: 256); tilt.rotate(byDegrees: 14); tilt.translateX(by: -241, yBy: -256); tilt.concat()
        let rear = NSBezierPath(roundedRect: NSRect(x: 115, y: 117, width: 206, height: 278), xRadius: 24, yRadius: 24)
        let rearShadow = NSShadow(); rearShadow.shadowColor = NSColor.black.withAlphaComponent(0.15); rearShadow.shadowBlurRadius = 14; rearShadow.shadowOffset = NSSize(width: 0, height: -8); rearShadow.set()
        NSColor(calibratedWhite: 1, alpha: 0.65).setFill(); rear.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        let front = NSBezierPath()
        front.move(to: NSPoint(x: 188, y: 103)); front.line(to: NSPoint(x: 336, y: 103))
        front.curve(to: NSPoint(x: 360, y: 127), controlPoint1: NSPoint(x: 351, y: 103), controlPoint2: NSPoint(x: 360, y: 112))
        front.line(to: NSPoint(x: 360, y: 345)); front.line(to: NSPoint(x: 309, y: 401)); front.line(to: NSPoint(x: 188, y: 401))
        front.curve(to: NSPoint(x: 164, y: 377), controlPoint1: NSPoint(x: 173, y: 401), controlPoint2: NSPoint(x: 164, y: 392))
        front.line(to: NSPoint(x: 164, y: 127)); front.curve(to: NSPoint(x: 188, y: 103), controlPoint1: NSPoint(x: 164, y: 112), controlPoint2: NSPoint(x: 173, y: 103)); front.close()
        let shadow = NSShadow(); shadow.shadowColor = NSColor(calibratedWhite: 0.08, alpha: 0.25); shadow.shadowBlurRadius = 22; shadow.shadowOffset = NSSize(width: 4, height: -12); shadow.set()
        NSColor(calibratedRed: 0.11, green: 0.16, blue: 0.22, alpha: 1).setFill(); front.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.19, alpha: 1), ending: NSColor(calibratedRed: 0.26, green: 0.33, blue: 0.39, alpha: 1))?.draw(in: front, angle: 90)
        NSColor.white.withAlphaComponent(0.35).setStroke(); front.lineWidth = 1.5; front.stroke()
        for index in 0..<5 {
            let contact = NSBezierPath(roundedRect: NSRect(x: 189 + index * 26, y: 333, width: 15, height: 34), xRadius: 4, yRadius: 4)
            NSGradient(starting: NSColor(calibratedRed: 0.65, green: 0.64, blue: 0.52, alpha: 1), ending: NSColor(calibratedRed: 0.94, green: 0.91, blue: 0.74, alpha: 1))?.draw(in: contact, angle: 90)
        }
        let arrows = NSBezierPath(); arrows.lineWidth = 12; arrows.lineCapStyle = .round; arrows.lineJoinStyle = .round
        arrows.move(to: NSPoint(x: 211, y: 266)); arrows.line(to: NSPoint(x: 312, y: 266))
        arrows.move(to: NSPoint(x: 290, y: 286)); arrows.line(to: NSPoint(x: 312, y: 266)); arrows.line(to: NSPoint(x: 290, y: 246))
        arrows.move(to: NSPoint(x: 312, y: 213)); arrows.line(to: NSPoint(x: 211, y: 213))
        arrows.move(to: NSPoint(x: 233, y: 233)); arrows.line(to: NSPoint(x: 211, y: 213)); arrows.line(to: NSPoint(x: 233, y: 193))
        NSColor(calibratedRed: 0.55, green: 0.93, blue: 0.87, alpha: 1).setStroke(); arrows.stroke()
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: NSRect(x: 198, y: 142, width: 128, height: 4), xRadius: 2, yRadius: 2).fill()
        image.unlockFocus(); return image
    }
}

@MainActor final class CopyDockView: NSView {
    var fraction: Double = 0
    private let artwork = AppIcon.image()
    override func draw(_ dirtyRect: NSRect) {
        artwork.draw(in: bounds)
        let track = NSRect(x: bounds.width * 0.13, y: bounds.height * 0.05, width: bounds.width * 0.74, height: bounds.height * 0.065)
        NSColor.black.withAlphaComponent(0.45).setFill(); NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        var fill = track; fill.size.width *= min(1, max(0, fraction))
        NSColor.white.setFill(); NSBezierPath(roundedRect: fill, xRadius: 4, yRadius: 4).fill()
    }
}
