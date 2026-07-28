import AppKit

/// Une fenêtre sans bordure refuse d'être « key » par défaut, ce qui casse le
/// suivi du glisser-déposer. On l'autorise.
final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - Contrôleur ----------------------------------------------------------

final class PetController: NSObject {

    private let window: NSWindow
    private let view: PetView
    private var timer: Timer?
    private var statusItem: NSStatusItem?

    private var x: CGFloat = 0                 // position au sol (centre du pet)
    private var y: CGFloat = 0                 // ligne des pieds (écran)
    private var vx: CGFloat = 0                // vitesses pendant la chute
    private var vy: CGFloat = 0
    private var groundY: CGFloat = 0
    private var minX: CGFloat = 0
    private var maxX: CGFloat = 0

    private var direction: CGFloat = 1
    private var stateUntil: TimeInterval = 0
    private var idleSeconds: TimeInterval = 0
    private var nextBlink: TimeInterval = 2
    private var blinkPhase: TimeInterval = -1
    private var jumpVel: CGFloat = 0
    private var lastDockPoll: TimeInterval = -99
    private var clock: TimeInterval = 0
    private var followCursor = UserDefaults.standard.bool(forKey: "followCursor")
    private var dragging = false
    private var chefMode = UserDefaults.standard.bool(forKey: "chefMode")
    private let triggerURL = URL(fileURLWithPath: NSHomeDirectory() + "/.clawd-dock/trigger")
    private var lastTrigger: Date?
    private var triggerCountdown: TimeInterval = 0
    private var claudeOpen = true              // une fenêtre Claude est-elle ouverte ?
    private var claudeBusy = false             // Claude est-il en train de répondre ?
    private var asleepForClaude = false        // endormi parce que Claude est fermé
    private var busySince: TimeInterval = 0    // depuis quand Claude est réputé occupé
    private var chuteDir: CGFloat = 1          // sens de la diagonale sous voile
    private var lastOrigin = NSPoint(x: CGFloat.infinity, y: CGFloat.infinity)
    private var frameCount = 0

    override init() {
        let rect = NSRect(x: 0, y: 0, width: Cfg.windowW, height: Cfg.windowH)
        view = PetView(frame: rect)
        window = PetWindow(contentRect: rect, styleMask: .borderless,
                           backing: .buffered, defer: false)
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                     .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = view
        window.orderFrontRegardless()

        view.onClick   = { [weak self] in self?.cheer() }
        view.onGrab    = { [weak self] p in self?.grab(at: p) }
        view.onMove    = { [weak self] p in self?.moveHeld(to: p) }
        view.onRelease = { [weak self] v in self?.release(velocity: v) }
        view.menuBuilder = { [weak self] in self?.buildMenu() ?? NSMenu() }

        view.chefMode = chefMode
        setupStatusItem()
        try? FileManager.default.createDirectory(at: triggerURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        refreshGround(force: true)
        x = (minX + maxX) / 2
        y = groundY
        setState(.walking, for: 3)

        // On laisse Clawd apparaître avant de proposer quoi que ce soit
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.offerHookSetupIfNeeded()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1 / Cfg.fps, repeats: true) { [weak self] _ in
            self?.tick(1 / Cfg.fps)
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // ── Où est le Dock ? ────────────────────────────────────────────────────
    /// Renvoie le rectangle du Dock en coordonnées Cocoa, si le Dock est en bas.
    private func dockRect() -> NSRect? {
        guard let screen = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        var best: CGRect?
        for w in list {
            guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "Dock",
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 20,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let bx = b["X"], let by = b["Y"], let bw = b["Width"], let bh = b["Height"]
            else { continue }
            // On ne garde qu'un Dock horizontal, en bas
            guard bw > 120, bh > 24, bh < 260, bw > bh else { continue }
            if best == nil || bw > best!.width { best = CGRect(x: bx, y: by, width: bw, height: bh) }
        }
        guard let r = best else { return nil }
        // CGWindow : origine en haut à gauche de l'écran principal → repère Cocoa
        let flippedY = screen.frame.maxY - (r.origin.y + r.height)
        return NSRect(x: r.origin.x, y: flippedY, width: r.width, height: r.height)
    }

    private func refreshGround(force: Bool = false) {
        guard force || clock - lastDockPoll > Cfg.dockPollInterval else { return }
        lastDockPoll = clock
        claudeOpen = claudeIsRunning()

        // Claude fermé, ou réponse jamais close (hook Stop manqué, plantage,
        // machine en veille) : on ne le laisse pas cuisiner indéfiniment.
        if claudeBusy && (!claudeOpen || clock - busySince > Cfg.busyTimeout) {
            claudeBusy = false
            log(!claudeOpen ? "busy annulé (Claude fermé)" : "busy expiré (pas de Stop)")
            if view.state == .cooking { setState(.idle, for: 1) }
        }
        let screen = NSScreen.screens.first ?? NSScreen.main!

        let margin = CGFloat(Art.cols) * Cfg.pixel / 2 + 4
        if let dock = dockRect() {
            groundY = dock.maxY + Cfg.groundNudge   // les pieds sur le rebord du Dock
            minX = dock.minX + margin
            maxX = dock.maxX - margin
        } else {
            // Le Dock n'expose pas ses tuiles : on se cale sur la bande qu'il réserve
            groundY = screen.visibleFrame.minY + Cfg.groundNudge
            minX = screen.visibleFrame.minX + margin
            maxX = screen.visibleFrame.maxX - margin
        }
        if maxX - minX < 60 { minX = screen.frame.minX + 40; maxX = screen.frame.maxX - 40 }
        x = min(max(x, minX), maxX)
    }

    // ── Accrobranche : il s'agrippe à la fenêtre Claude, saute, puis cuisine ─
    /// Claude tourne-t-il ? On regarde l'application, pas ses fenêtres : une
    /// fenêtre réduite ou compacte ne veut pas dire que Claude est fermé.
    private func claudeIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard app.activationPolicy == .regular else { return false }
            if app.bundleIdentifier?.hasPrefix("com.anthropic.claude") == true { return true }
            return app.localizedName == "Claude"
        }
    }

    /// Rectangle de la fenêtre Claude en coordonnées Cocoa.
    private func claudeWindowRect() -> NSRect? {
        guard let screen = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        var best: NSRect?
        for w in list {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  owner.hasPrefix("Claude"),
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let bx = b["X"], let by = b["Y"], let bw = b["Width"], let bh = b["Height"],
                  bw >= 120, bh >= 90 else { continue }
            let r = NSRect(x: bx, y: screen.frame.maxY - (by + bh), width: bw, height: bh)
            if best == nil || r.width * r.height > best!.width * best!.height { best = r }
        }
        return best
    }

    /// Il grimpe s'agripper au rebord haut de la fenêtre Claude.
    func startAdventure() {
        refreshGround(force: true)
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let ledge = claudeWindowRect() ?? screen.visibleFrame
        x = min(max(.random(in: ledge.minX + 80 ... ledge.maxX - 80), minX), maxX)
        y = ledge.maxY - CGFloat(Art.rows + 2) * Cfg.pixel   // les pattes crochètent le rebord
        vx = 0; vy = 0
        chefMode = false                       // la toque n'arrive qu'à l'atterrissage
        view.chefMode = false
        view.facingRight = Bool.random()
        setState(.hanging, for: .random(in: 1.6...2.6))
        placeWindow()
    }

    /// Il lâche prise et pique vers le Dock.
    private func releaseGrip() {
        let target = CGFloat.random(in: minX...maxX)
        vy = 160
        let h = max(40, y - groundY)
        let t = (vy + sqrt(vy * vy + 2 * Cfg.fallGravity * h)) / Cfg.fallGravity
        vx = max(-340, min(340, (target - x) / t))
        view.facingRight = vx >= 0
        setState(.leaping, for: .greatestFiniteMagnitude)   // ne finit qu'au sol
    }

    /// Chute + rebonds ; à l'arrêt il enfile la toque et se met aux fourneaux.
    private func stepFall(_ dt: TimeInterval) {
        vy -= Cfg.fallGravity * CGFloat(dt)
        y += vy * CGFloat(dt)
        x += vx * CGFloat(dt)
        if x < minX { x = minX; vx = abs(vx) * 0.6 }
        if x > maxX { x = maxX; vx = -abs(vx) * 0.6 }
        guard y <= groundY else { return }
        y = groundY
        if -vy > 130 {                          // il rebondit encore
            vy = -vy * Cfg.bounciness
            vx *= 0.55
        } else {
            vy = 0; vx = 0
            // Il n'enfile la toque que si Claude travaille vraiment. Une grimpe
            // lancée à la main depuis le menu se termine par un simple coucou.
            if claudeBusy { startCooking() } else { setState(.happy, for: 1.2) }
        }
    }

    /// Trace horodatée dans ~/.clawd-dock/log — sert à auditer les hooks.
    private func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp)  \(line)\n".data(using: .utf8) else { return }
        let url = triggerURL.deletingLastPathComponent().appendingPathComponent("log")
        if let h = try? FileHandle(forWritingTo: url) {
            if h.seekToEndOfFile() > 64_000 {     // journal borné
                try? h.truncate(atOffset: 0); h.seek(toFileOffset: 0)
            }
            h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Les hooks Claude Code écrivent un mot-clé dans ce fichier.
    private func checkTrigger() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: triggerURL.path),
              let stamp = attrs[.modificationDate] as? Date else { return }
        defer { lastTrigger = stamp }
        guard let last = lastTrigger, stamp > last else { return }
        let event = (try? String(contentsOf: triggerURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        log("événement reçu : \(event.isEmpty ? "(vide)" : event)")
        handle(event: event.isEmpty ? "prompt" : event)
    }

    private func handle(event: String) {
        let airborne: [PetState] = [.held, .thrown, .parachuting, .hanging, .leaping]
        switch event {
        case "done":                     // Claude a fini de répondre : il sert le plat
            claudeBusy = false
            if view.state == .cooking { setState(.happy, for: 1.8); jumpVel = 150 }
        case "session-end":
            claudeBusy = false
        case "climb":                    // grimpe sans prétendre que Claude travaille
            if !airborne.contains(view.state) { startAdventure() }
        case "toss":                     // utile pour tester : echo toss > le fichier
            if !airborne.contains(view.state) { menuToss() }
        default:                         // "prompt" : un message vient de partir
            claudeBusy = true
            busySince = clock
            asleepForClaude = false
            if !airborne.contains(view.state) { startAdventure() }
        }
    }

    // ── Machine à états ─────────────────────────────────────────────────────
    private func setState(_ s: PetState, for duration: TimeInterval) {
        if s != view.state { log("état : \(view.state) → \(s)") }
        view.state = s
        stateUntil = clock + duration
        if s == .walking { idleSeconds = 0 }
    }

    /// Il ne cuisine JAMAIS de son propre chef : la poêle veut dire « Claude
    /// travaille », rien d'autre. Au repos il marche, flâne ou s'assoit.
    private func pickNextAction() {
        if claudeBusy { startCooking(); return }
        if followCursor { setState(.walking, for: 1); return }
        switch Int.random(in: 0..<10) {
        case 0...4:
            direction = Bool.random() ? 1 : -1
            view.facingRight = direction > 0
            setState(.walking, for: .random(in: 2...6))
        case 5...7:
            setState(.idle, for: .random(in: 1.5...4))
        default:
            setState(.sitting, for: .random(in: 3...7))
        }
    }

    private func startCooking() {
        view.chefMode = true
        view.cookPhase = 0
        setState(.cooking, for: .random(in: 8...14))
        statusItem?.menu = buildMenu()
    }

    private func cheer() {
        if view.state == .cooking {          // aux fourneaux : il fait sauter la poêle
            view.cookPhase = 0
            idleSeconds = 0
            return
        }
        if view.state == .sleeping || view.state == .sitting { setState(.idle, for: 0.2) }
        setState(.happy, for: 1.4)
        if view.jump < 1 { jumpVel = 190 }
        idleSeconds = 0
    }

    // ── Attraper, promener, lancer ──────────────────────────────────────────
    private func grab(at p: NSPoint) {
        vx = 0; vy = 0
        setState(.held, for: .greatestFiniteMagnitude)
        moveHeld(to: p)
    }

    /// Il pend au curseur : les pattes qui s'agrippent restent sous le pointeur.
    private func moveHeld(to p: NSPoint) {
        guard view.state == .held else { return }
        x = p.x
        y = p.y - CGFloat(Art.rows + 2) * Cfg.pixel
        idleSeconds = 0
        placeWindow()
        view.needsDisplay = true
    }

    /// Lâché : il part avec la vitesse du geste, puis ouvre son parachute.
    private func release(velocity v: CGVector) {
        let m = Cfg.throwMax
        vx = max(-m, min(m, v.dx))
        vy = max(-m, min(m, v.dy))
        view.facingRight = vx >= 0
        if hypot(vx, vy) < 60 && y - groundY < 30 {   // simple dépôt, pas un lancer
            land()
        } else {
            setState(.thrown, for: .greatestFiniteMagnitude)
        }
    }

    /// Physique du vol libre, jusqu'à l'ouverture de la voile ou le sol.
    private func stepThrow(_ dt: TimeInterval) {
        vy -= Cfg.fallGravity * CGFloat(dt)
        x += vx * CGFloat(dt)
        y += vy * CGFloat(dt)
        bounceOnWalls()
        if y <= groundY { land(); return }
        // Dès qu'il redescend et qu'il a de la marge, la voile s'ouvre
        if vy < 0 && y - groundY > Cfg.chuteMinHeight {
            view.chutePhase = 0
            chuteDir = vx >= 0 ? 1 : -1
            setState(.parachuting, for: .greatestFiniteMagnitude)
        }
    }

    /// Descente lente sous voile, en louvoyant : une belle diagonale courbe.
    private func stepChute(_ dt: TimeInterval) {
        view.chutePhase += dt
        vy += (-Cfg.chuteFall - vy) * min(1, CGFloat(dt) * 3)      // freinage progressif
        // Dérive constante d'un côté, dont la vitesse pulse : une diagonale courbe
        let curve = CGFloat(sin(view.chutePhase * 2 * .pi * Cfg.chuteCurve))
        vx = chuteDir * Cfg.chuteDrift * (0.55 + 0.45 * curve)
        x += vx * CGFloat(dt)
        y += vy * CGFloat(dt)
        view.facingRight = vx >= 0
        bounceOnWalls()
        if y <= groundY { land() }
    }

    private func bounceOnWalls() {
        if x < minX { x = minX; vx = abs(vx); chuteDir = 1 }
        if x > maxX { x = maxX; vx = -abs(vx); chuteDir = -1 }
    }

    /// Atterrissage : en douceur sous voile, avec rebond après un lancer sec.
    private func land() {
        y = groundY
        if view.state == .thrown && -vy > 300 {      // reçu sans parachute : ça rebondit
            vy = -vy * Cfg.bounciness
            vx *= 0.55
            y = groundY + 1
            return
        }
        vx = 0; vy = 0
        if claudeBusy { startCooking() } else { setState(.happy, for: 1.2) }
    }

    // ── Boucle d'animation ──────────────────────────────────────────────────
    private func tick(_ dt: TimeInterval) {
        clock += dt
        frameCount += 1
        view.clock = clock
        refreshGround()

        // Clignement des yeux
        if blinkPhase >= 0 {
            blinkPhase += dt
            let d = 0.14
            view.eyeOpen = blinkPhase < d / 2 ? CGFloat(1 - blinkPhase / (d / 2))
                                              : CGFloat((blinkPhase - d / 2) / (d / 2))
            if blinkPhase > d { blinkPhase = -1; view.eyeOpen = 1; nextBlink = .random(in: 2...6) }
        } else {
            nextBlink -= dt
            if nextBlink <= 0 { blinkPhase = 0 }
        }

        // Saut (gravité)
        if jumpVel != 0 || view.jump > 0 {
            jumpVel -= 620 * CGFloat(dt)
            view.jump += jumpVel * CGFloat(dt)
            if view.jump <= 0 { view.jump = 0; jumpVel = 0 }
        }

        triggerCountdown -= dt
        if triggerCountdown <= 0 { triggerCountdown = 0.3; checkTrigger() }

        // La toque : portée quand il cuisine ou qu'il l'a choisie, jamais en grimpe
        view.chefMode = (chefMode || claudeBusy || view.state == .cooking)
            && view.state != .hanging && view.state != .leaping

        // Tout ce qui se passe en l'air court-circuite la marche normale
        switch view.state {
        case .held:
            view.needsDisplay = true
            return                                    // c'est la souris qui commande
        case .thrown, .parachuting, .leaping, .hanging:
            switch view.state {
            case .thrown:      stepThrow(dt)
            case .parachuting: stepChute(dt)
            case .leaping:     stepFall(dt)
            default:           if clock >= stateUntil { releaseGrip() }
            }
            placeWindow()
            view.needsDisplay = true
            return                                    // le nouvel état prendra la main
        default:
            y = groundY
        }

        // Claude fermé : il pique un somme. Rouvert : il se réveille.
        if !claudeOpen {
            if view.state != .sleeping { setState(.sleeping, for: .greatestFiniteMagnitude) }
            asleepForClaude = true
        } else if asleepForClaude {
            asleepForClaude = false
            setState(.idle, for: 1)
        }

        // Suivi du curseur
        if followCursor && !dragging {
            let target = min(max(NSEvent.mouseLocation.x, minX), maxX)
            let delta = target - x
            if abs(delta) > 6 {
                direction = delta > 0 ? 1 : -1
                view.facingRight = direction > 0
                view.state = .walking
                x += direction * Cfg.walkSpeed * 1.6 * CGFloat(dt)
                view.walkPhase += CGFloat(dt) * 1.6
                idleSeconds = 0
            } else if view.state == .walking {
                view.state = .idle
            }
            placeWindow()
            view.needsDisplay = true
            return
        }

        if view.state == .cooking { view.cookPhase += dt }

        // Déplacement
        if view.state == .walking {
            x += direction * Cfg.walkSpeed * CGFloat(dt)
            view.walkPhase += CGFloat(dt)
            if x <= minX || x >= maxX {
                x = min(max(x, minX), maxX)
                direction *= -1
                view.facingRight = direction > 0
            }
        } else {
            idleSeconds += dt
            // Claude ouvert : il ne pique du nez qu'après un long moment, sinon
            // il marche ou reste assis à attendre.
            if idleSeconds > Cfg.boredomDelay, ![.sleeping, .happy, .cooking].contains(view.state) {
                setState(.sleeping, for: .random(in: 12...25))
            }
        }

        if clock >= stateUntil && view.jump == 0 { pickNextAction() }

        dragging = false
        placeWindow()
        requestRedraw()
    }

    private func placeWindow() {
        let o = NSPoint(x: (x - Cfg.windowW / 2).rounded(),
                        y: (y - Cfg.feetInset).rounded())
        guard o != lastOrigin else { return }
        lastOrigin = o
        window.setFrameOrigin(o)
    }

    /// Les états calmes n'ont pas besoin de 30 images par seconde.
    private func requestRedraw() {
        let calm: [PetState] = [.sitting, .sleeping, .idle]
        if calm.contains(view.state) && frameCount % 2 != 0 { return }
        view.needsDisplay = true
    }

    // ── Branchement sur Claude Code ─────────────────────────────────────────
    /// Proposé une seule fois, jamais fait dans le dos de l'utilisateur.
    private func offerHookSetupIfNeeded() {
        let key = "hookPromptShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard !ClaudeHooks.areInstalled() else { return }

        let alert = NSAlert()
        alert.messageText = "Let Clawd follow your Claude Code sessions?"
        alert.informativeText = """
        Clawd can act out what Claude Code is doing: he climbs your Claude window         when you send a prompt, cooks while Claude is answering, and serves the         dish when it's done. Without this he will just wander your Dock.

        This adds three hooks to ~/.claude/settings.json (UserPromptSubmit, Stop,         SessionEnd). Each one runs only:

            \(ClaudeHooks.command(for: "<word>"))

        No conversation content is read, stored or sent anywhere. Your settings         file is backed up to settings.json.bak-clawd first, and you can undo this         at any time from Clawd's menu.
        """
        alert.addButton(withTitle: "Set it up")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        applyHooks(enabled: true)
    }

    private func applyHooks(enabled: Bool) {
        let outcome = ClaudeHooks.set(enabled: enabled)
        statusItem?.menu = buildMenu()
        log("hooks \(enabled ? "installés" : "retirés") → \(outcome)")

        let alert = NSAlert()
        switch outcome {
        case .ok:
            alert.messageText = enabled ? "Clawd is wired in." : "Clawd is unhooked."
            alert.informativeText = enabled
                ? "Hooks are read when a Claude Code session starts, so restart your session to see him react."
                : "The three hooks were removed from ~/.claude/settings.json."
        case .unreadable:
            alert.alertStyle = .warning
            alert.messageText = "Couldn't read ~/.claude/settings.json"
            alert.informativeText = "The file exists but isn't plain JSON, so nothing was changed. You can add the hooks by hand — see the README."
        case .writeFailed:
            alert.alertStyle = .warning
            alert.messageText = "Couldn't write ~/.claude/settings.json"
            alert.informativeText = "Nothing was changed. A backup of your settings is at settings.json.bak-clawd."
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func toggleHooks() { applyHooks(enabled: !ClaudeHooks.areInstalled()) }

    // ── Menus ───────────────────────────────────────────────────────────────
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let hi = NSMenuItem(title: "Say hi 👋", action: #selector(menuCheer), keyEquivalent: "")
        hi.target = self
        menu.addItem(hi)

        let adv = NSMenuItem(title: "Go climbing! 🧗", action: #selector(menuAdventure),
                             keyEquivalent: "")
        adv.target = self
        menu.addItem(adv)

        let toss = NSMenuItem(title: "Toss him in the air 🪂", action: #selector(menuToss),
                              keyEquivalent: "")
        toss.target = self
        menu.addItem(toss)

        let chef = NSMenuItem(title: "Always wear the chef hat 👨\u{200D}🍳",
                              action: #selector(toggleChef), keyEquivalent: "")
        chef.target = self
        chef.state = chefMode ? .on : .off
        menu.addItem(chef)

        do {
            let cook = NSMenuItem(title: "Start cooking! 🍳",
                                  action: #selector(menuCook), keyEquivalent: "")
            cook.target = self
            menu.addItem(cook)
        }

        menu.addItem(.separator())
        let follow = NSMenuItem(title: "Follow the cursor",
                                action: #selector(toggleFollow), keyEquivalent: "")
        follow.target = self
        follow.state = followCursor ? .on : .off
        menu.addItem(follow)

        let center = NSMenuItem(title: "Recenter on the Dock",
                                action: #selector(recenter), keyEquivalent: "")
        center.target = self
        menu.addItem(center)

        menu.addItem(.separator())
        let wired = ClaudeHooks.areInstalled()
        let hook = NSMenuItem(title: wired ? "Disconnect from Claude Code"
                                           : "Connect to Claude Code…",
                              action: #selector(toggleHooks), keyEquivalent: "")
        hook.target = self
        menu.addItem(hook)

        let quit = NSMenuItem(title: "Quit Clawd", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Clawd")
            btn.image?.isTemplate = true
        }
        item.menu = buildMenu()
        statusItem = item
    }

    @objc private func menuCheer() { cheer() }
    @objc private func menuAdventure() { startAdventure() }
    @objc private func menuToss() {
        release(velocity: CGVector(dx: .random(in: -260 ... 260), dy: .random(in: 700...1000)))
    }
    @objc private func menuCook() {
        view.cookPhase = 0
        setState(.cooking, for: .random(in: 8...14))
        statusItem?.menu = buildMenu()
    }
    @objc private func toggleChef() {
        chefMode.toggle()
        view.chefMode = chefMode
        UserDefaults.standard.set(chefMode, forKey: "chefMode")
        statusItem?.menu = buildMenu()
        setState(.idle, for: 0.5)
    }
    @objc private func toggleFollow() {
        followCursor.toggle()
        UserDefaults.standard.set(followCursor, forKey: "followCursor")
        statusItem?.menu = buildMenu()
        setState(.idle, for: 0.5)
    }
    @objc private func recenter() { refreshGround(force: true); x = (minX + maxX) / 2; placeWindow() }
    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - App -----------------------------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: PetController?
    func applicationDidFinishLaunching(_ note: Notification) {
        controller = PetController()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
