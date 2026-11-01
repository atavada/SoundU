// Renders SoundU's icon artwork. Usage: swift scripts/render-icon.swift <svg-dir> <out-dir>
// Reads AppIcon.svg and MenuBarTemplate.svg from <svg-dir> and writes to <out-dir>:
//   AppIcon.iconset/ (16–512 @1x/@2x PNGs) and AppIcon.icns (via iconutil),
//   MenuBarTemplate.pdf (18 × 18 pt vector), and preview PNGs of the template at 18 and 36 px.
import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("render-icon: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: render-icon.swift <svg-dir> <out-dir>") }
let source = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])

func load(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: source.appendingPathComponent(name)) else {
        fail("cannot load \(name)")
    }
    return image
}

/// Draws `image` scaled to `pixels` × `pixels` and writes it as a PNG.
func writePNG(_ image: NSImage, pixels: Int, to url: URL) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { fail("cannot allocate \(pixels) px bitmap") }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)
    context?.imageInterpolation = .high
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("PNG encode failed") }
    do { try png.write(to: url) } catch { fail("cannot write \(url.path): \(error)") }
}

/// Draws `image` into a single-page vector PDF of `points` × `points`.
func writePDF(_ image: NSImage, points: CGFloat, to url: URL) {
    var box = CGRect(x: 0, y: 0, width: points, height: points)
    guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { fail("cannot create \(url.path)") }
    pdf.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
    image.draw(in: box)
    NSGraphicsContext.restoreGraphicsState()
    pdf.endPDFPage()
    pdf.closePDF()
}

let fm = FileManager.default
let iconset = output.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
do { try fm.createDirectory(at: iconset, withIntermediateDirectories: true) } catch { fail("\(error)") }

let appIcon = load("AppIcon.svg")
for base in [16, 32, 128, 256, 512] {
    writePNG(appIcon, pixels: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(appIcon, pixels: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
do { try iconutil.run() } catch { fail("iconutil: \(error)") }
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil exited \(iconutil.terminationStatus)") }

let template = load("MenuBarTemplate.svg")
writePDF(template, points: 18, to: output.appendingPathComponent("MenuBarTemplate.pdf"))
writePNG(template, pixels: 18, to: output.appendingPathComponent("MenuBarTemplate-18.png"))
writePNG(template, pixels: 36, to: output.appendingPathComponent("MenuBarTemplate-36.png"))

print("rendered \(output.path)")
