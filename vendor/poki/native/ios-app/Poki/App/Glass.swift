import SwiftUI

// Liquid Glass for Poki's own controls (ESP-340, the owner's "buttons and components support Liquid
// Glass"). On iOS 26 and later these are Apple's own effect, written from the SDK's declarations
// (SwiftUICore: `glassEffect(_:in:)`, `Glass`, `GlassEffectContainer`, `GlassEffectTransition`;
// SwiftUI: `GlassButtonStyle`, `GlassProminentButtonStyle`) and from Apple's "Applying Liquid Glass to
// custom views" and the Human Interface Guidelines' "Materials" (developer.apple.com, read
// 2026-11-11). Before iOS 26 they fall back to the system's materials with a hairline; the app still
// runs on iOS 18. The fallback has only been compiled and, with `-pokiGlass off`, looked at on an
// iOS 27 simulator: no older simulator is on the build machine.
//
// What this file keeps to, and where each rule comes from:
// - Glass is the layer of controls and navigation that floats over content. Human Interface
//   Guidelines: "Don't use Liquid Glass in the content layer." So the round buttons of the top bar,
//   the message field and a card that asks for an answer are glass; bubbles, the task card and the
//   settings cards are not. The suggestion pills are glass too; a drawn look-alike that samples
//   nothing (`PillLook`) waits for the owner's choice.
// - "Use Liquid Glass effects sparingly" (the same page): the few controls that matter most.
// - No glass on glass: the owner's instruction, and WWDC25 session 219 as the research note for
//   ESP-376 quotes it ("always avoid glass on glass"; I have not read the transcript myself). A
//   control inside a glass surface (the buttons in the message field, the status inside a pill) is a
//   plain fill or a tint.
// - Glass shapes near each other share one `GlassEffectContainer` ("Applying Liquid Glass to custom
//   views"): one sampling pass, and they can blend and morph.
// - `glassEffect` goes after the modifiers that change how the view looks (the same article).
// - The regular variant, not clear: clear is for photos and video behind it (Human Interface Guidelines).
// - The system's own bars, sheets and menus already are glass; nothing here touches them.
// - Reduce Transparency and Increase Contrast are the system's to honour: it redraws its glass
//   itself, and the fallback's materials follow them too.

/// What a glass surface becomes before iOS 26.
enum GlassFallback {
    /// A small control over the page (a round button, a pill): the thinnest material, a light edge
    /// and a soft shadow, as the research note for ESP-376 gives it.
    case control
    /// The message field: the bar material with the field's grey edge, as it was before this file.
    case bar
    /// A card that floats over the conversation: the regular material with a separator hairline.
    case card
}

enum GlassSwitch {
    /// `-pokiGlass off` draws the fallback on any iOS, to look at it where no older simulator exists.
    static let forcedOff = UserDefaults.standard.string(forKey: "pokiGlass") == "off"
    /// `-pokiGlass still` draws the glass without its reaction to touch, to tell the two apart.
    static let still = UserDefaults.standard.string(forKey: "pokiGlass") == "still"
}

extension View {
    /// A surface of the control layer in `shape`: Liquid Glass, tinted with `tint` to suggest
    /// prominence and reacting to touch when `interactive`; before iOS 26 the `fallback` material.
    /// On a button, put it on the button and not inside its label: interactive glass inside the label
    /// took the touch for itself and the button never fired (seen in the top bar on iOS 27).
    @ViewBuilder func glassSurface<S: InsettableShape>(in shape: S, tint: Color? = nil, interactive: Bool = false,
                                                       fallback: GlassFallback = .control) -> some View {
        if #available(iOS 26.0, *), !GlassSwitch.forcedOff {
            glassEffect(Glass.regular.tint(tint).interactive(interactive && !GlassSwitch.still), in: shape)
        } else {
            modifier(MaterialSurface(shape: shape, tint: tint, kind: fallback))
        }
    }

    /// Glass shapes that sit near each other, drawn as one group. `spacing` is how near two shapes
    /// must come to merge; keep it smaller than the layout's own spacing so they stay apart at rest.
    @ViewBuilder func glassGroup(spacing: CGFloat? = nil) -> some View {
        if #available(iOS 26.0, *), !GlassSwitch.forcedOff {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// `glassGroup` only when `grouped`.
    @ViewBuilder func glassGroupIf(_ grouped: Bool, spacing: CGFloat? = nil) -> some View {
        if grouped { glassGroup(spacing: spacing) } else { self }
    }

    /// For a glass surface that comes and goes inside a `glassGroup`: the system's own materialize
    /// transition, a fade before iOS 26.
    @ViewBuilder func glassAppearing() -> some View {
        if #available(iOS 26.0, *), !GlassSwitch.forcedOff {
            glassEffectTransition(.materialize)
        } else {
            transition(.opacity)
        }
    }

    /// A text button of the control layer that stands on its own (not inside another glass surface):
    /// the system's glass button, or its prominent, tinted one. Before iOS 26, the bordered styles.
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *), !GlassSwitch.forcedOff {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else if prominent {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}

/// The glass surface's stand-in before iOS 26.
private struct MaterialSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var tint: Color?
    var kind: GlassFallback

    func body(content: Content) -> some View {
        switch kind {
        case .control:
            content
                .background { ZStack { shape.fill(.ultraThinMaterial); if let tint { shape.fill(tint.opacity(0.6)) } } }
                .overlay(shape.strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        case .bar:
            content
                .background(.bar, in: shape)
                .overlay(shape.stroke(ChatColor.fieldEdge, lineWidth: 0.5))
        case .card:
            content
                .background { ZStack { shape.fill(.regularMaterial); if let tint { shape.fill(tint.opacity(0.6)) } } }
                .overlay(shape.strokeBorder(Color(.separator), lineWidth: 0.5))
        }
    }
}
