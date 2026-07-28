import AppKit

// Rend le sprite hors-écran dans une planche PNG, pour vérifier le dessin
// sans avoir besoin de capturer l'écran.

struct Pose {
    var name: String
    var state: PetState
    var walk: CGFloat = 0
    var cook: TimeInterval = 0
    var chute: TimeInterval = 0
    var chef = false
    var right = true
    var jump: CGFloat = 0
}

let sheetRows: [[Pose]] = [
    [
        Pose(name: "idle",    state: .idle),
        Pose(name: "walk-a",  state: .walking, walk: 0.02),
        Pose(name: "walk-b",  state: .walking, walk: 0.19),
        Pose(name: "sit",     state: .sitting),
        Pose(name: "sleep",   state: .sleeping),
        Pose(name: "happy",   state: .happy, jump: 10),
    ],
    [
        Pose(name: "porté",     state: .held),
        Pose(name: "lancé",     state: .thrown),
        Pose(name: "ouverture", state: .parachuting, chute: 0.12),
        Pose(name: "sous voile", state: .parachuting, chute: 0.9),
        Pose(name: "voile+chef", state: .parachuting, chute: 1.6, chef: true),
        Pose(name: "louvoie",   state: .parachuting, chute: 2.5),
    ],
    [
        Pose(name: "agrippé",   state: .hanging),
        Pose(name: "balance",   state: .hanging, right: false),
        Pose(name: "en vol",    state: .leaping),
        Pose(name: "atterri",   state: .cooking, cook: 1.6, chef: true),
        Pose(name: "coucou",    state: .happy, chef: true, jump: 8),
        Pose(name: "dodo-chef", state: .sleeping, chef: true),
    ],
    [
        Pose(name: "chef",       state: .idle,    chef: true),
        Pose(name: "chef-marche", state: .walking, walk: 0.02, chef: true),
        Pose(name: "grésille",   state: .cooking, cook: 1.6, chef: true),
        Pose(name: "saute-1",    state: .cooking, cook: 0.12, chef: true),
        Pose(name: "saute-2",    state: .cooking, cook: 0.45, chef: true),
        Pose(name: "à gauche",   state: .cooking, cook: 0.45, chef: true, right: false),
    ],
]

let cw = Cfg.windowW, ch = Cfg.windowH
let cols = CGFloat(sheetRows[0].count)
let sheet = NSImage(size: NSSize(width: cw * cols, height: ch * CGFloat(sheetRows.count)))

sheet.lockFocus()
NSColor(white: 0.93, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: sheet.size)).fill()

for (rowIndex, row) in sheetRows.enumerated() {
    let y = CGFloat(sheetRows.count - 1 - rowIndex) * ch
    for (i, pose) in row.enumerated() {
        let v = PetView(frame: NSRect(x: 0, y: 0, width: cw, height: ch))
        v.state = pose.state
        v.walkPhase = pose.walk
        v.cookPhase = pose.cook
        v.chutePhase = pose.chute
        v.chefMode = pose.chef
        v.facingRight = pose.right
        v.jump = pose.jump
        v.clock = pose.state == .hanging && !pose.right ? 1.5 : 0.4
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size)
        img.addRepresentation(rep)
        img.draw(at: NSPoint(x: CGFloat(i) * cw, y: y), from: .zero,
                 operation: .sourceOver, fraction: 1)
        NSString(string: pose.name).draw(
            at: NSPoint(x: CGFloat(i) * cw + 6, y: y + 3),
            withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                             .foregroundColor: NSColor.black])
    }
}
sheet.unlockFocus()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "preview.png"
let png = NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("écrit : \(out)")
