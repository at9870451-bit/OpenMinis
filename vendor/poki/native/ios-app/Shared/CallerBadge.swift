import SwiftUI

/// Who is calling Poki: an outside agent's provider logo (Poki/ProviderIcons, in both asset catalogs)
/// on the provider's colour, or its initials on grey. One look for the sessions list, the Activity Log,
/// the connectors and the Live Activity.
enum Caller {
    /// The provider logo for an agent's name ("Claude Code", "Codex", "Gemini CLI").
    /// Each known agent, in match order (more specific names first: "cursor-vscode" is Cursor), with its
    /// logo in the asset catalog (nil: initials) and its colour.
    private static let known: [(match: [String], logo: String?, tint: UInt32, mark: UInt32)] = [
        // Claude is Claude's spark, not Anthropic's mark (that one is for an Anthropic API account).
        (["claude"], "Provider-claude", 0xD97757, 0xFFFFFF),
        (["anthropic"], "Provider-anthropic", 0x191919, 0xF0EEE6),
        // ChatGPT: the black mark on white; OpenAI (Codex, the API): the white mark on black.
        (["chatgpt"], "Provider-openai", 0xFFFFFF, 0x000000),
        (["cursor"], "Provider-cursor", 0x111111, 0xFFFFFF),
        (["windsurf", "codeium"], "Provider-windsurf", 0x0B100F, 0xFFFFFF),
        (["cline", "roo code", "roo-code", "roocode"], "Provider-cline", 0x111111, 0xFFFFFF),
        (["codex", "openai"], "Provider-openai", 0x000000, 0xFFFFFF),
        (["github", "copilot", "visual studio code", "vscode", "vs code"], "Provider-githubcopilot", 0x24292F, 0xFFFFFF),
        (["microsoft"], "Provider-copilot", 0x0078D4, 0xFFFFFF),
        (["gemini", "google"], "Provider-googlegemini", 0x4285F4, 0xFFFFFF),
        (["deepseek"], "Provider-deepseek", 0x4D6BFE, 0xFFFFFF),
        (["openrouter"], "Provider-openrouter", 0x6566F1, 0xFFFFFF),
        (["meta"], "Provider-metaai", 0x0866FF, 0xFFFFFF),
        (["perplexity"], "Provider-perplexity", 0x1FB8CD, 0xFFFFFF),
        (["mistral", "le chat", "le-chat", "lechat"], "Provider-mistral", 0xFA520F, 0xFFFFFF),
        (["grok", "xai"], "Provider-grok", 0x111111, 0xFFFFFF),
        (["raycast"], "Provider-raycast", 0xFF6363, 0xFFFFFF),
        (["goose"], "Provider-goose", 0x111111, 0xFFFFFF),
        (["manus"], "Provider-manus", 0x111111, 0xFFFFFF),
        (["kimi", "moonshot"], "Provider-kimi", 0x111111, 0xFFFFFF),
        (["qwen", "tongyi", "alibaba"], "Provider-qwen", 0x615CED, 0xFFFFFF),
        (["lm studio", "lmstudio"], "Provider-lmstudio", 0x4338CA, 0xFFFFFF),
        (["ollama"], "Provider-ollama", 0x111111, 0xFFFFFF),
        (["hugging", "hf-mcp"], "Provider-huggingface", 0xFFB000, 0xFFFFFF),
        (["n8n"], "Provider-n8n", 0xEA4B71, 0xFFFFFF),
        (["zapier"], "Provider-zapier", 0xFF4F00, 0xFFFFFF),
        (["openclaw"], "Provider-openclaw", 0xE5484D, 0xFFFFFF),
        (["poke"], nil, 0x111111, 0xFFFFFF),
        (["zed"], nil, 0x084CCF, 0xFFFFFF),
    ]

    private static func entry(_ name: String) -> (match: [String], logo: String?, tint: UInt32, mark: UInt32)? {
        let n = name.lowercased()
        return known.first { $0.match.contains { n.contains($0) } }
    }

    static func logo(_ name: String) -> String? { entry(name)?.logo }

    /// The provider's colour, a calm grey otherwise.
    static func tint(_ name: String) -> Color { Color(hex: entry(name)?.tint ?? 0x8E8E93) }

    static func isLight(_ name: String) -> Bool { entry(name)?.tint == 0xFFFFFF }

    /// A tile that disappears on a dark ground (OpenAI's black, Cursor's near-black): under a fifth of white.
    static func isDark(_ name: String) -> Bool {
        let hex = entry(name)?.tint ?? 0x8E8E93
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 < 0.2
    }

    /// The logo's (or initials') colour on that tile.
    static func mark(_ name: String) -> Color { Color(hex: entry(name)?.mark ?? 0xFFFFFF) }

    static func initials(_ name: String) -> String {
        let words = name.split(separator: " ")
        if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        return String(name.prefix(1)).uppercased()
    }
}

/// The caller's round badge.
struct CallerBadge: View {
    var name: String
    var size: CGFloat
    /// On a dark ground: a dark tile turns light with its logo dark (the conversations in dark mode).
    var lifted = false
    var body: some View {
        let invert = lifted && Caller.isDark(name)
        Group {
            if let logo = Caller.logo(name) {
                Image(logo).resizable().renderingMode(.template).scaledToFit()
                    .frame(width: size * 0.54, height: size * 0.54)
            } else {
                Text(verbatim: Caller.initials(name))
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(invert ? Color(hex: 0x111111) : Caller.mark(name))
        .frame(width: size, height: size)
        .background(invert ? Color(hex: 0xF2F2F7) : Caller.tint(name), in: .circle)
        // A white tile (ChatGPT) keeps its edge on a white page.
        .overlay(Circle().strokeBorder(Color(.separator), lineWidth: Caller.isLight(name) ? 0.5 : 0))
        .accessibilityLabel(Text(verbatim: name))
    }
}
