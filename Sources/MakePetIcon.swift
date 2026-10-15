import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: MakePetIcon <pet.png> <output.png>\n", stderr)
    exit(64)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let pet = NSImage(contentsOf: sourceURL) else {
    fputs("cannot read current desktop pet\n", stderr)
    exit(66)
}

let canvasSize = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvasSize)
image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else {
    fputs("cannot create icon context\n", stderr)
    exit(70)
}

let canvas = NSRect(origin: .zero, size: canvasSize)
context.clear(canvas)
let rounded = NSBezierPath(roundedRect: canvas.insetBy(dx: 8, dy: 8), xRadius: 220, yRadius: 220)
rounded.addClip()

let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        NSColor(srgbRed: 0.055, green: 0.075, blue: 0.078, alpha: 1).cgColor,
        NSColor(srgbRed: 0.070, green: 0.135, blue: 0.132, alpha: 1).cgColor,
        NSColor(srgbRed: 0.110, green: 0.205, blue: 0.185, alpha: 1).cgColor,
    ] as CFArray,
    locations: [0, 0.58, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 100, y: 960),
    end: CGPoint(x: 930, y: 70),
    options: []
)

let halo = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        NSColor(srgbRed: 0.52, green: 0.95, blue: 0.76, alpha: 0.26).cgColor,
        NSColor(srgbRed: 0.32, green: 0.78, blue: 0.68, alpha: 0).cgColor,
    ] as CFArray,
    locations: [0, 1]
)!
context.drawRadialGradient(
    halo,
    startCenter: CGPoint(x: 512, y: 535),
    startRadius: 10,
    endCenter: CGPoint(x: 512, y: 535),
    endRadius: 420,
    options: []
)

context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -22),
    blur: 34,
    color: NSColor.black.withAlphaComponent(0.52).cgColor
)
NSColor.black.withAlphaComponent(0.24).setFill()
NSBezierPath(ovalIn: NSRect(x: 326, y: 142, width: 372, height: 90)).fill()
context.restoreGState()

let sourceAspect = pet.size.width / pet.size.height
let targetHeight: CGFloat = 730
let targetWidth = targetHeight * sourceAspect
let petRect = NSRect(
    x: (canvasSize.width - targetWidth) / 2,
    y: 174,
    width: targetWidth,
    height: targetHeight
)
pet.draw(
    in: petRect,
    from: NSRect(origin: .zero, size: pet.size),
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: true,
    hints: [.interpolation: NSImageInterpolation.high]
)

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("cannot encode icon\n", stderr)
    exit(70)
}
try png.write(to: outputURL, options: .atomic)
