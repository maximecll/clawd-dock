import AppKit

// ─────────────────────────────────────────────────────────────────────────────
//  Clawd Dock — le petit Clawd en pixel art qui se balade sur le Dock.
//  La grille du sprite a été relevée directement sur l'original (11 × 8).
// ─────────────────────────────────────────────────────────────────────────────

enum Cfg {
    static let pixel: CGFloat = 5             // taille d'un pixel d'art, en points
    static let windowW: CGFloat = 170         // boîte transparente qui suit le pet
    static let windowH: CGFloat = 190         // (haute : le parachute dépasse)
    static let fps: Double = 30
    static let walkSpeed: CGFloat = 46        // points / seconde
    static let stepsPerSecond: CGFloat = 6    // cadence des pattes
    static let feetInset: CGFloat = 16        // hauteur des pieds dans la fenêtre
    static let groundNudge: CGFloat = -6      // chevauche un peu le rebord du Dock
    static let dockPollInterval: TimeInterval = 2.0
    static let flipCycle: Double = 2.4        // une envolée d'ingrédients toutes les N s
    static let fallGravity: CGFloat = 900     // chute depuis la fenêtre Claude
    static let bounciness: CGFloat = 0.28     // rebonds à l'atterrissage

    // Lancer au curseur + parachute
    static let throwMax: CGFloat = 1500       // vitesse max imprimée par le geste
    static let chuteMinHeight: CGFloat = 80   // en dessous, il retombe sans voile
    static let chuteFall: CGFloat = 62        // vitesse de descente sous voile
    static let chuteDrift: CGFloat = 82       // amplitude du louvoiement horizontal
    static let chuteCurve: Double = 0.42      // fréquence de la courbe, en Hz
    static let chuteOpenTime: Double = 0.35   // durée d'ouverture de la voile
}

enum Palette {
    static let body   = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #D97757
    static let eye    = NSColor(srgbRed: 0.086, green: 0.063, blue: 0.055, alpha: 1)
    static let heart  = NSColor(srgbRed: 0.878, green: 0.325, blue: 0.376, alpha: 1)
    static let toque  = NSColor(srgbRed: 0.973, green: 0.965, blue: 0.949, alpha: 1)
    static let band   = NSColor(srgbRed: 0.855, green: 0.839, blue: 0.808, alpha: 1)
    static let pan    = NSColor(srgbRed: 0.243, green: 0.239, blue: 0.259, alpha: 1)
    static let steam  = NSColor(white: 1, alpha: 1)
    static let cord   = NSColor(srgbRed: 0.42, green: 0.40, blue: 0.38, alpha: 1)
    static let veggies = [
        NSColor(srgbRed: 0.478, green: 0.714, blue: 0.282, alpha: 1),  // poivron
        NSColor(srgbRed: 0.851, green: 0.255, blue: 0.306, alpha: 1),  // tomate
        NSColor(srgbRed: 0.941, green: 0.706, blue: 0.161, alpha: 1),  // maïs
    ]
}

enum PetState {
    case idle, walking, sitting, sleeping, happy, cooking
    case hanging, leaping                 // accrobranche
    case held, thrown, parachuting        // attrapé au curseur, lancé, sous voile
}

enum Art {
    static let cols = 11
    static let rows = 8

    /// Corps (rangées 0…5) — 'O' = corps, '#' = œil, '.' = vide
    static let body: [String] = [
        "..OOOOOOOO.",
        "..O#OOOO#O.",
        "OOOOOOOOOO.",
        "OOOOOOOOOO.",
        "..OOOOOOOOO",
        "..OOOOOOOOO",
    ]
    /// Pattes (rangées 6 et 7)
    static let legCols = [2, 4, 7, 9]
    /// Démarche en diagonale : ces deux pattes avancent ensemble
    static let legGroupA: Set<Int> = [2, 7]
    /// Accrobranche : celles qui crochètent le rebord, celles qui pendouillent
    static let legGrip   = [4, 7]
    static let legDangle = [2, 9]

    /// Toque, posée sur la tête (colonnes 3…8, au-dessus de la rangée 0)
    static let toque = [
        ".OOOO.",
        "OOOOOO",
        ".BBBB.",
    ]
    /// Poêle : manche + rebord, puis le fond. Ancrée colonne 11, rangée 5.
    static let pan = [
        "OOOOOOO",
        "...OOO.",
    ]
    /// Les trois ingrédients sautent au-dessus des colonnes 14, 15 et 16
    static let veggieCols = [14, 15, 16]

    /// Voile du parachute : 18 colonnes, centrée sur le corps (colonnes -3 à 14).
    /// 'W' = toile, 'C' = liseré. La rangée du bas est la dernière du tableau.
    static let canopy = [
        "......WWWWWW......",
        "...WWWWWWWWWWWW...",
        ".WWWWWWWWWWWWWWWW.",
        "CCCCCCCCCCCCCCCCCC",
    ]
    static let canopyCol = -3        // colonne d'ancrage de la voile
    static let canopyRow = -10       // rangée de son sommet
    /// Suspentes : des bords de la voile jusqu'aux épaules, une marche par rangée
    static let cordLeft  = [-3, -2, -1, 0, 1, 2]
    static let cordRight = [14, 13, 12, 11, 10, 9]

    static let heart = ["OO.OO", "OOOOO", ".OOO.", "..O.."]
    static let z     = ["OOOO", "...O", "..O.", ".O..", "OOOO"]
}

// MARK: - Vue du personnage ---------------------------------------------------

final class PetView: NSView {

    var state: PetState = .idle
    var facingRight = true
    var chefMode = false               // toque vissée sur la tête
    var clock: TimeInterval = 0        // horloge globale
    var walkPhase: CGFloat = 0         // n'avance qu'en marchant
    var cookPhase: TimeInterval = 0    // n'avance qu'aux fourneaux
    var chutePhase: TimeInterval = 0   // n'avance que sous voile
    var eyeOpen: CGFloat = 1           // 1 = ouvert, 0 = fermé
    var jump: CGFloat = 0              // offset vertical du saut

    var onClick: (() -> Void)?
    var onGrab: ((NSPoint) -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onRelease: ((CGVector) -> Void)?
    var menuBuilder: (() -> NSMenu)?

    override var isFlipped: Bool { false }

    // ── Dessin ──────────────────────────────────────────────────────────────
    override func draw(_ dirtyRect: NSRect) {
        let p = Cfg.pixel
        let sitting = (state == .sitting || state == .sleeping)
        let walking = (state == .walking)
        let dangling = (state == .hanging || state == .held)

        // Petit rebond de respiration à l'arrêt
        let idleHop: CGFloat = (state == .idle && sin(clock * 2.6) > 0.78) ? p : 0
        let originX = (bounds.midX - CGFloat(Art.cols) * p / 2).rounded()
        let baseY = (Cfg.feetInset + jump + idleHop).rounded()

        /// Rectangle d'une cellule (c, r) ; miroir horizontal si le pet va à gauche
        func cell(_ c: Int, _ r: Int, _ dy: CGFloat = 0) -> NSRect {
            let cc = facingRight ? c : Art.cols - 1 - c
            return NSRect(x: originX + CGFloat(cc) * p,
                          y: baseY + CGFloat(Art.rows - 1 - r) * p + dy,
                          width: p, height: p)
        }
        func fill(_ c: Int, _ r: Int, _ dy: CGFloat = 0, _ dx: CGFloat = 0) {
            var rect = cell(c, r, dy); rect.origin.x += dx; rect.fill()
        }
        func drawGlyph(_ glyph: [String], _ col: Int, _ row: Int, _ dy: CGFloat,
                       _ colors: [Character: NSColor], _ dx: CGFloat = 0) {
            for (r, line) in glyph.enumerated() {
                for (c, ch) in line.enumerated() where ch != "." {
                    (colors[ch] ?? Palette.body).setFill()
                    fill(col + c, row + r, dy, dx)
                }
            }
        }

        // ── Balancements : suspendu au rebord / au curseur, ou pendu sous la voile
        let bodyDY: CGFloat = sitting ? -2 * p : 0
        var bodyDX: CGFloat = 0
        if dangling {
            bodyDX = CGFloat(Int(sin(clock * 2.1) * 1.7)) * p * (facingRight ? 1 : -1)
        } else if state == .parachuting {
            bodyDX = CGFloat(Int(sin(chutePhase * 2.4) * 1.6)) * p
        }

        // ── Corps (assis : il descend de deux pixels, les pattes disparaissent)
        var eyeCells: [NSRect] = []
        Palette.body.setFill()
        for (r, line) in Art.body.enumerated() {
            for (c, ch) in line.enumerated() where ch != "." {
                var rect = cell(c, r, bodyDY)
                rect.origin.x += bodyDX
                rect.fill()                       // l'œil est peint par-dessus
                if ch == "#" { eyeCells.append(rect) }
            }
        }

        // ── Pattes
        Palette.body.setFill()
        switch state {
        case .sitting, .sleeping:
            break                                   // assis : les pattes disparaissent
        case .hanging, .held:
            // Deux pattes s'agrippent au-dessus, les deux autres pendouillent
            for c in Art.legGrip { fill(c, -1) ; fill(c, -2) }
            for c in Art.legDangle { fill(c, 6, 0, bodyDX); fill(c, 7, 0, bodyDX) }
        case .thrown, .leaping:
            for c in Art.legCols { fill(c, 6) }     // pattes repliées en vol
        case .parachuting:
            for c in Art.legCols { fill(c, 6, 0, bodyDX); fill(c, 7, 0, bodyDX) }
        default:
            let step = Int(walkPhase * Cfg.stepsPerSecond) % 2
            for c in Art.legCols {
                fill(c, 6)
                // En marchant, une diagonale sur deux décolle du sol
                let grounded = !walking || (Art.legGroupA.contains(c) == (step == 0))
                if grounded { fill(c, 7) }
            }
        }

        // ── Yeux
        let closed = (state == .sleeping || state == .happy)
        let open = closed ? 0.0 : max(0.3, eyeOpen)
        Palette.eye.setFill()
        for var e in eyeCells {
            let h = max(p * 0.3, p * open)
            e.origin.y += ((p - h) / 2).rounded()
            e.size.height = h.rounded()
            e.fill()
        }

        // ── Toque
        if chefMode {
            drawGlyph(Art.toque, 3, -3, bodyDY, ["O": Palette.toque, "B": Palette.band], bodyDX)
        }

        // ── Parachute
        if state == .parachuting { drawChute(fill: fill, drawGlyph: drawGlyph) }

        // ── Fourneaux
        if state == .cooking {
            drawCooking(p: p, cell: cell,
                        drawGlyph: { g, c, r, dy, colors in drawGlyph(g, c, r, dy, colors) })
        }

        // ── Bulles (calées sur le haut réel du sprite)
        let spriteTop = baseY + CGFloat(Art.rows) * p + bodyDY + (chefMode ? 3 * p : 0)
        if state == .sleeping { drawZzz(topOf: spriteTop) }
        if state == .happy    { drawHeart(topOf: spriteTop) }
    }

    /// Voile + suspentes au-dessus de la tête ; elle se déploie du bas vers le haut.
    private func drawChute(fill: (Int, Int, CGFloat, CGFloat) -> Void,
                           drawGlyph: ([String], Int, Int, CGFloat, [Character: NSColor], CGFloat) -> Void) {
        let openness = min(1, CGFloat(chutePhase / Cfg.chuteOpenTime))
        let sway = CGFloat(Int(sin(chutePhase * 2.4) * 1.6)) * Cfg.pixel * 0.5

        // Les suspentes se tendent en même temps que la voile s'ouvre
        let cords = max(1, Int((openness * CGFloat(Art.cordLeft.count)).rounded()))
        Palette.cord.setFill()
        for i in 0..<cords {
            let row = -1 - (Art.cordLeft.count - 1 - i)      // du haut vers les épaules
            fill(Art.cordLeft[i], row, 0, sway)
            fill(Art.cordRight[i], row, 0, sway)
        }

        // La voile se dévoile du liseré vers le sommet
        let visible = max(1, Int((openness * CGFloat(Art.canopy.count)).rounded()))
        let rows = Array(Art.canopy.suffix(visible))
        drawGlyph(rows, Art.canopyCol, Art.canopyRow + (Art.canopy.count - visible), 0,
                  ["W": Palette.toque, "C": Palette.body], sway)
    }

    /// Poêle tenue devant lui : les ingrédients grésillent, puis s'envolent.
    private func drawCooking(p: CGFloat,
                             cell: (Int, Int, CGFloat) -> NSRect,
                             drawGlyph: ([String], Int, Int, CGFloat, [Character: NSColor]) -> Void) {
        let t = cookPhase.truncatingRemainder(dividingBy: Cfg.flipCycle)
        let tossing = t < 0.9
        let panDY: CGFloat = t < 0.22 ? p : 0          // coup de poignet

        drawGlyph(Art.pan, 11, 5, panDY, ["O": Palette.pan])

        // Ingrédients : grésillement sur place, puis grande envolée
        for (i, col) in Art.veggieCols.enumerated() {
            var dy = panDY
            var dx: CGFloat = 0
            if tossing {
                let u = CGFloat(t / 0.9)
                let arc = sin(u * .pi)
                dy += arc * p * (4.2 + CGFloat(i) * 0.5)
                dx = arc * p * CGFloat(i - 1) * 0.8
            } else {
                dy += abs(sin(CGFloat(cookPhase) * 7 + CGFloat(i) * 1.3)) * p * 0.5
            }
            Palette.veggies[i].setFill()
            var r = cell(col, 4, dy)
            r.origin.x += facingRight ? dx : -dx
            r.fill()
        }

        // Vapeur au-dessus de la poêle
        for i in 0..<3 {
            let phase = (cookPhase * 0.8 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
            Palette.steam.withAlphaComponent(CGFloat(sin(phase * .pi) * 0.5)).setFill()
            var r = cell(14 + i, 3, CGFloat(phase) * p * 3.5)
            r.origin.x += (facingRight ? 1 : -1) * CGFloat(phase) * p
            r.size = NSSize(width: p * 0.8, height: p * 0.8)
            r.fill()
        }
    }

    private func drawFloating(_ glyph: [String], at p0: NSPoint, scale: CGFloat, color: NSColor) {
        color.setFill()
        for (r, line) in glyph.enumerated() {
            for (c, ch) in line.enumerated() where ch != "." {
                NSRect(x: (p0.x + CGFloat(c) * scale).rounded(),
                       y: (p0.y + CGFloat(glyph.count - 1 - r) * scale).rounded(),
                       width: scale, height: scale).fill()
            }
        }
    }

    private func drawZzz(topOf y: CGFloat) {
        let s = (Cfg.pixel * 0.6).rounded()
        for i in 0..<3 {
            let phase = CGFloat((clock * 0.5 + Double(i) * 0.34).truncatingRemainder(dividingBy: 1))
            drawFloating(Art.z,
                         at: NSPoint(x: bounds.midX + 12 + phase * 16, y: y + 4 + phase * 46),
                         scale: s, color: Palette.body.withAlphaComponent(sin(phase * .pi)))
        }
    }

    private func drawHeart(topOf y: CGFloat) {
        let rise = min(1, jump / 12 + 0.3)
        drawFloating(Art.heart,
                     at: NSPoint(x: bounds.midX + 14, y: y + 4 + rise * 8),
                     scale: Cfg.pixel * 0.8,
                     color: Palette.heart.withAlphaComponent(0.55 + rise * 0.45))
    }

    // ── Souris ──────────────────────────────────────────────────────────────
    // Les pixels transparents laissent passer les clics vers le Dock : rien à faire.
    private var trail: [(NSPoint, TimeInterval)] = []
    private var grabbed = false

    override func mouseDown(with event: NSEvent) {
        grabbed = false
        trail = [(NSEvent.mouseLocation, event.timestamp)]
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        if !grabbed {
            guard let start = trail.first?.0,
                  hypot(p.x - start.x, p.y - start.y) > 3 else { return }
            grabbed = true
            onGrab?(p)
        }
        trail.append((p, event.timestamp))
        if trail.count > 8 { trail.removeFirst() }
        onMove?(p)
    }

    override func mouseUp(with event: NSEvent) {
        guard grabbed else { onClick?(); return }
        grabbed = false
        // Vitesse du geste sur les ~80 dernières millisecondes
        let now = event.timestamp
        let recent = trail.filter { now - $0.1 < 0.08 }
        var v = CGVector.zero
        if let first = recent.first, let last = recent.last, recent.count > 1 {
            let dt = max(0.016, now - first.1)
            v = CGVector(dx: (last.0.x - first.0.x) / CGFloat(dt),
                         dy: (last.0.y - first.0.y) / CGFloat(dt))
        }
        onRelease?(v)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuBuilder?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}
