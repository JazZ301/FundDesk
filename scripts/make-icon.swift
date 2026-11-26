import AppKit

let size = 1024
let icon = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let plate = NSBezierPath(roundedRect: NSRect(x: 92, y: 92, width: 840, height: 840), xRadius: 194, yRadius: 194)
    let shade = NSGradient(starting: NSColor(srgbRed: 0.09, green: 0.40, blue: 0.32, alpha: 1),
                           ending: NSColor(srgbRed: 0.12, green: 0.28, blue: 0.24, alpha: 1))!
    shade.draw(in: plate, angle: -45)

    for y in [319, 471, 623] {
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: 266, y: y))
        rule.line(to: NSPoint(x: 758, y: y))
        rule.lineWidth = 7
        NSColor.white.withAlphaComponent(0.23).setStroke()
        rule.stroke()
    }
    let points = [NSPoint(x: 283, y: 362), NSPoint(x: 408, y: 492), NSPoint(x: 531, y: 425),
                  NSPoint(x: 636, y: 550), NSPoint(x: 741, y: 664)]
    let price = NSBezierPath()
    price.move(to: points[0])
    for point in points.dropFirst() { price.line(to: point) }
    price.lineCapStyle = .round
    price.lineJoinStyle = .round
    price.lineWidth = 29
    NSColor(srgbRed: 0.77, green: 0.95, blue: 0.82, alpha: 1).setStroke()
    price.stroke()
    NSColor(srgbRed: 0.94, green: 0.84, blue: 0.53, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 721, y: 644, width: 40, height: 40)).fill()
    return true
}
let png = NSBitmapImageRep(data: icon.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
