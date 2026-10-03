// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// First-launch onboarding: a 2-page swipe carousel explaining what the app
/// does. Shown once (flag in UserDefaults); skippable.
struct OnboardingView: View {
    var onDone: () -> Void
    @State private var page = 0

    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button("Skip", action: onDone)
                    .foregroundStyle(.secondary)
                    .padding()
                    .accessibilityLabel("Skip tutorial")
            }
            TabView(selection: $page) {
                OnboardingPage(
                    art: AnyView(MicArt()),
                    title: "Hear the music.",
                    body: "Point your phone at any music — a piano, a street performer, your own playing. AI Music Radar listens and finds every note. Nothing ever leaves your phone."
                ).tag(0)
                OnboardingPage(
                    art: AnyView(PageArt()),
                    title: "Get the page.",
                    body: "Watch the score write itself in real time. Play it back, study the engraved page, or share it as MIDI, MP3, MusicXML, PDF, or a photo."
                ).tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: page)

            HStack(spacing: 8) {
                ForEach(0..<2) { i in
                    Circle()
                        .fill(i == page ? Ink.teal : Color.secondary.opacity(0.25))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 8)
            .accessibilityHidden(true)

            Button(action: {
                if page == 0 { page = 1 } else { onDone() }
            }) {
                Text(page == 0 ? "Next" : "Get started")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Ink.teal, in: Capsule())
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .accessibilityLabel(page == 0 ? "Next" : "Get started")
        }
        .background(Ink.paper)
    }
}

private struct OnboardingPage: View {
    var art: AnyView
    var title: String
    var body: String

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            art
                .frame(height: 220)
            Text(title)
                .font(.system(size: 40, weight: .regular, design: .serif))
                .foregroundStyle(Ink.ink)
            Text(body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }
}

/// Line-art: microphone with sound waves turning into notes.
private struct MicArt: View {
    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let cy: CGFloat = 150
            // Sound arcs above the mic (top semicircles, sampled manually).
            for r in [34.0, 52.0, 70.0, 88.0] {
                var arc = Path()
                for i in 0...48 {
                    let t = Double(i) / 48.0 * Double.pi
                    let x = cx + r * cos(t)
                    let y = cy - r * sin(t)
                    if i == 0 { arc.move(to: CGPoint(x: x, y: y)) }
                    else { arc.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.stroke(arc, with: .color(Ink.teal.opacity(0.7)), lineWidth: 2)
            }
            // Notes rising.
            let notes = [(0.0, -64.0), (-30.0, -92.0), (28.0, -104.0), (6.0, -128.0)]
            for (dx, dy) in notes {
                let pt = CGPoint(x: cx + dx, y: 150 + dy)
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 6, y: pt.y - 4, width: 12, height: 9)),
                         with: .color(Ink.ink))
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: pt.x + 5.4, y: pt.y))
                    p.addLine(to: CGPoint(x: pt.x + 5.4, y: pt.y - 30))
                }, with: .color(Ink.ink), lineWidth: 1.6)
            }
            // Microphone body.
            let mic = CGRect(x: cx - 22, y: 108, width: 44, height: 84)
            ctx.stroke(Path(roundedRect: mic, cornerRadius: 22), with: .color(Ink.ink), lineWidth: 2.5)
            for i in 0..<3 {
                let y = mic.minY + 16 + CGFloat(i) * 12
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: mic.minX + 8, y: y))
                    p.addLine(to: CGPoint(x: mic.maxX - 8, y: y))
                }, with: .color(Ink.ink.opacity(0.5)), lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Line-art: engraved staff fragment with one teal note.
private struct PageArt: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 15
            let top: CGFloat = 70
            for l in 0..<5 {
                let y = top + CGFloat(l) * s
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: 30, y: y))
                    p.addLine(to: CGPoint(x: size.width - 30, y: y))
                }, with: .color(Ink.ink.opacity(0.85)), lineWidth: 1)
            }
            ctx.draw(Text("𝄞").font(.system(size: s * 4.4)).foregroundStyle(Ink.ink),
                     at: CGPoint(x: 36, y: top - s * 1.1))
            // Beamed pair, middle note teal.
            let xs: [CGFloat] = [120, 175, 230]
            let ys = [top + 3 * s, top + 2.5 * s, top + 2 * s]
            for (i, (x, y)) in zip(xs, ys).enumerated() {
                let c: Color = i == 1 ? Ink.teal : Ink.ink
                ctx.fill(Path(ellipseIn: CGRect(x: x - 8, y: y - 6, width: 16, height: 12)), with: .color(c))
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: x + 7.2, y: y))
                    p.addLine(to: CGPoint(x: x + 7.2, y: y - 3 * s))
                }, with: .color(c), lineWidth: 1.6)
            }
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: xs[0] + 7.2, y: ys[0] - 3 * s))
                p.addLine(to: CGPoint(x: xs[2] + 7.2, y: ys[2] - 3 * s))
                p.addLine(to: CGPoint(x: xs[2] + 7.2, y: ys[2] - 3 * s + 7))
                p.addLine(to: CGPoint(x: xs[0] + 7.2, y: ys[0] - 3 * s + 7))
                p.closeSubpath()
            }, with: .color(Ink.ink), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
