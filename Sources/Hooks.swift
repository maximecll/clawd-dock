import Foundation

// ─────────────────────────────────────────────────────────────────────────────
//  Branchement sur Claude Code : ajout/retrait des hooks dans settings.json.
//  Rien n'est écrit sans accord explicite de l'utilisateur (voir l'alerte au
//  premier lancement et les entrées du menu).
// ─────────────────────────────────────────────────────────────────────────────

enum ClaudeHooks {

    /// Chaque hook n'exécute que cette commande — aucun contenu de conversation.
    static let events = [
        ("UserPromptSubmit", "prompt"),
        ("Stop", "done"),
        ("SessionEnd", "session-end"),
    ]
    static let marker = ".clawd-dock/trigger"

    static var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")
    }
    static var backupURL: URL { settingsURL.appendingPathExtension("bak-clawd") }

    static func command(for word: String) -> String {
        "mkdir -p ~/.clawd-dock && echo \(word) > ~/.clawd-dock/trigger"
    }

    /// Le fichier existe-t-il et est-il du JSON qu'on sait relire ?
    private static func readSettings() -> [String: Any]?? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return .some(nil) }
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }          // illisible : on n'y touchera pas
        return .some(obj)
    }

    static func areInstalled() -> Bool {
        guard let outer = readSettings(), let root = outer,
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            for entry in (value as? [[String: Any]] ?? []) {
                for hook in (entry["hooks"] as? [[String: Any]] ?? []) {
                    if (hook["command"] as? String)?.contains(marker) == true { return true }
                }
            }
        }
        return false
    }

    enum Result { case ok, unreadable, writeFailed }

    /// Ajoute (ou retire) nos trois hooks. Sauvegarde le fichier au préalable.
    @discardableResult
    static func set(enabled: Bool) -> Result {
        guard let outer = readSettings() else { return .unreadable }
        var root = outer ?? [:]

        let fm = FileManager.default
        try? fm.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: settingsURL, to: backupURL)
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, word) in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            // on retire toujours nos anciennes entrées avant de réécrire
            entries.removeAll { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.contains(marker) == true
                }
            }
            if enabled {
                entries.append(["hooks": [["type": "command", "command": command(for: word)]]])
            }
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }

        guard let data = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? data.write(to: settingsURL)) != nil
        else { return .writeFailed }
        return .ok
    }
}
