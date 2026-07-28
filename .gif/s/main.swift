import AppKit
import ImageIO
import UniformTypeIdentifiers

// Fabrique un GIF de démonstration à partir du vrai moteur de rendu :
// descente sous voile → atterrissage → fourneaux. Aucune capture d'écran.

let W: CGFloat = 460, H: CGFloat = 300
let fps = 20.0, dt = 1 / fps
let groundY: CGFloat = 52          // hauteur du rebord du faux Dock

let scenes: [(String, Double)] = [("chute", 3.0), ("atterri", 0.9), ("cuisine", 4.2)]
let total = scenes.reduce(0) { $0 + $1.1 }

func dockBackdrop(in ctx: CGContext) {
    // Fond façon papier peint
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.09, green: 0.12, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.16, green: 0.20, blue: 0.30, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.13, blue: 0.22, alpha: 1),
    ])!
    grad.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 300)

    // Barre du Dock
    let bar = NSRect(x: 26, y: 8, width: W - 52, height: groundY - 8)
    let path = NSBezierPath(roundedRect: bar, xRadius: 14, yRadius: 14)
    NSColor(white: 1, alpha: 0.14).setFill(); path.fill()
    NSColor(white: 1, alpha: 0.18).setStroke(); path.lineWidth = 1; path.stroke()

    // Quelques icônes génériques
    let tints: [NSColor] = [
        NSColor(srgbRed: 0.35, green: 0.62, blue: 0.94, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1),
        NSColor(srgbRed: 0.42, green: 0.78, blue: 0.55, alpha: 1),
        NSColor(srgbRed: 0.85, green: 0.72, blue: 0.30, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.55, blue: 0.90, alpha: 1),
        NSColor(srgbRed: 0.90, green: 0.44, blue: 0.52, alpha: 1),
    ]
    let size: CGFloat = 30, gap: CGFloat = 8
    let span = CGFloat(tints.count) * size + CGFloat(tints.count - 1) * gap
    var x = (W - span) / 2
    for tint in tints {
        let r = NSRect(x: x, y: 13, width: size, height: size)
        tint.setFill()
        NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
        x += size + gap
    }
}

/// Rend une image du pet à une position donnée, par-dessus le décor.
func frame(at t: Double) -> CGImage {
    let img = NSImage(size: NSSize(width: W, height: H))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    dockBackdrop(in: ctx)

    let v = PetView(frame: NSRect(x: 0, y: 0, width: Cfg.windowW, height: Cfg.windowH))
    v.clock = t
    var px: CGFloat = 0, py: CGFloat = groundY

    var acc = 0.0
    var scene = scenes[0].0, local = t
    for (name, dur) in scenes {
        if t < acc + dur { scene = name; local = t - acc; break }
        acc += dur
    }

    switch scene {
    case "chute":
        v.state = .parachuting
        v.chutePhase = local
        let u = local / 3.0
        py = groundY + (1 - u) * 210                      // descente régulière
        px = -120 + CGFloat(u) * 150                      // dérive en diagonale
        px += CGFloat(sin(local * 2.2)) * 14              // la courbe
        v.facingRight = true
    case "atterri":
        v.state = .happy
        v.jump = CGFloat(max(0, sin(local / 0.9 * .pi))) * 14
        px = 30
    default:
        v.state = .cooking
        v.chefMode = true
        v.cookPhase = local
        px = 30
    }

    v.needsDisplay = true
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    let sprite = NSImage(size: v.bounds.size)
    sprite.addRepresentation(rep)
    sprite.draw(at: NSPoint(x: W / 2 - Cfg.windowW / 2 + px, y: py - Cfg.feetInset),
                from: .zero, operation: .sourceOver, fraction: 1)

    img.unlockFocus()
    var rect = NSRect(x: 0, y: 0, width: W, height: H)
    return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "demo.gif")
// Le nombre d'images déclaré doit coller exactement, sinon finalize échoue
let count = Int((total * fps).rounded())
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString,
                                           count, nil)!
CGImageDestinationSetProperties(dest, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
] as CFDictionary)

// mode planche : quelques instants clés côte à côte
let keys = [0.2, 1.2, 2.4, 3.2, 4.2, 6.5]
let sheet = NSImage(size: NSSize(width: W * CGFloat(keys.count) / 2, height: H * 2))
sheet.lockFocus()
for (i, k) in keys.enumerated() {
    let img = NSImage(cgImage: frame(at: k), size: NSSize(width: W, height: H))
    img.draw(at: NSPoint(x: CGFloat(i % 3) * W, y: CGFloat(1 - i / 3) * H),
             from: .zero, operation: .sourceOver, fraction: 1)
}
sheet.unlockFocus()
let png = NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
let ok = CGImageDestinationFinalize(dest)
print("finalize=\(ok)  existe=\(FileManager.default.fileExists(atPath: out.path))  → \(out.path)")
