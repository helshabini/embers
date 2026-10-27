import SwiftUI

/// The launch screen: the icon's own tree, catching light ember by ember and then burning.
///
/// Drawn rather than shown as an image, because a PNG cannot catch one ember at a time or keep
/// moving once it has. The geometry is lifted from the icon's own SVG — the same flame path, the
/// same eighteen placements, the same two colours — so the drawing and the icon are the same tree
/// rather than two drawings of one.
struct SplashView: View {
    /// Whether the budget is open yet. The splash waits for it, so the animation is never cut short
    /// by a store that is still loading.
    var isReady: Bool = true
    /// Called once the flames have finished catching.
    var onFinished: () -> Void = {}

    @State private var litEmbers = 0
    /// Set once every ember has caught. Handing over needs this *and* `isReady`, and either can
    /// arrive first.
    @State private var flamesHaveCaught = false
    /// Drives the flicker. Fire does not hold still, so neither does this.
    @State private var isBurning = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                ZStack {
                    TrunkShape()
                        .fill(Flame.bark)
                    GroundShape()
                        .fill(Flame.bark)

                    ForEach(Array(Ember.all.enumerated()), id: \.offset) { index, ember in
                        FlameShape()
                            .fill(ember.isInner ? Flame.iconGlow : Flame.iconEmber)
                            .frame(width: Ember.size * ember.scale, height: Ember.size * ember.scale * 1.55)
                            .rotationEffect(.degrees(ember.rotation + flicker(index).lean))
                            .scaleEffect(
                                x: 1 + flicker(index).breadth,
                                y: index < litEmbers ? 1 + flicker(index).height : 0.1,
                                anchor: .bottom
                            )
                            .offset(x: ember.x, y: ember.y + flicker(index).rise)
                            .opacity(index < litEmbers ? 1 : 0)
                            .animation(
                                .spring(response: 0.4, dampingFraction: 0.6),
                                value: litEmbers
                            )
                            .animation(
                                // Each ember moves on its own clock, or they pulse as one body and
                                // read as a throb rather than a fire.
                                .easeInOut(duration: Ember.flickerPeriod + Double(index % 5) * 0.21)
                                    .repeatForever(autoreverses: true),
                                value: isBurning
                            )
                    }
                }
                .frame(width: 300, height: 300)

                VStack(spacing: 6) {
                    Text("Embers")
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                    Text("Your sure way to FIRE")
                        .font(.headline.weight(.medium))
                        .foregroundStyle(Flame.ember)
                }
            }
        }
        .contentShape(Rectangle())
        // Skippable: nobody should have to watch it twice.
        .onTapGesture { onFinished() }
        .task { await catchFire() }
        // `isReady` comes from the change itself rather than from a capture: the closure was made
        // during an earlier render and still holds the old value. This is what the `.task` got
        // wrong — it captured this struct at launch and so never saw the store open.
        .onChange(of: isReady) { _, ready in handOver(caught: flamesHaveCaught, ready: ready) }
        .onChange(of: flamesHaveCaught) { _, caught in handOver(caught: caught, ready: isReady) }
    }

    /// How far this ember is from its resting shape at the moment.
    ///
    /// Fire narrows and stretches as it rises, leans as it goes, and lifts a little. The amounts are
    /// small — this is a flame guttering, not a flag waving.
    private func flicker(_ index: Int) -> (height: CGFloat, breadth: CGFloat, lean: Double, rise: CGFloat) {
        guard isBurning else { return (0, 0, 0, 0) }
        let sign: CGFloat = index.isMultiple(of: 2) ? 1 : -1
        return (
            height: 0.1 * sign,
            breadth: -0.045 * sign,
            lean: Double(sign) * 2.5,
            rise: -3 * sign
        )
    }

    private func catchFire() async {
        try? await Task.sleep(for: .milliseconds(100))

        // Outward from the heart of the tree, one ember at a time, quickening as it takes.
        for index in 1...Ember.all.count {
            litEmbers = index
            try? await Task.sleep(for: .milliseconds(index < 6 ? 52 : 30))
        }
        // Once alight, it stays alight.
        withAnimation { isBurning = true }

        try? await Task.sleep(for: .milliseconds(420))
        flamesHaveCaught = true
    }

    /// Hands over only once the tree has finished catching and the budget is open behind it.
    private func handOver(caught: Bool, ready: Bool) {
        guard caught, ready else { return }
        onFinished()
    }
}

/// One flame, placed exactly where the icon puts it.
///
/// The icon is drawn on a 1024 square; these are those coordinates moved to the centre of a 300
/// square and scaled to fit, so the arrangement is the icon's rather than an impression of it.
private struct Ember {
    var x: CGFloat
    var y: CGFloat
    var rotation: Double
    var scale: CGFloat
    var isInner: Bool

    /// The flame path is 192 units tall in the icon; at the icon's own 0.8 scale on a 1024 square.
    static let size: CGFloat = 124 * canvas
    static let canvas: CGFloat = 300.0 / 1024.0
    static let flickerPeriod = 1.15

    /// Inner embers first, so the tree lights from its heart outwards.
    static let all: [Ember] = (inner + outer)

    private static func at(_ x: CGFloat, _ y: CGFloat, _ rotation: Double, _ scale: CGFloat, inner: Bool) -> Ember {
        Ember(
            x: (x - 512) * canvas,
            // The icon's flames hang from a point; the shape is drawn around its own centre, so the
            // vertical placement lines up with where the icon's tip sits.
            y: (y - 512) * canvas,
            rotation: rotation,
            scale: scale,
            isInner: inner
        )
    }

    private static let inner: [Ember] = [
        at(512, 420, 0, 0.65, inner: true),
        at(449, 344, -25, 0.72, inner: true),
        at(575, 344, 25, 0.72, inner: true),
        at(367, 441, -75, 0.72, inner: true),
        at(657, 441, 75, 0.72, inner: true),
        at(389, 566, -125, 0.68, inner: true),
        at(635, 566, 125, 0.68, inner: true),
    ]

    private static let outer: [Ember] = [
        at(512, 210, 0, 0.8, inner: false),
        at(402, 233, -24, 0.8, inner: false),
        at(622, 233, 24, 0.8, inner: false),
        at(311, 299, -48, 0.8, inner: false),
        at(713, 299, 48, 0.8, inner: false),
        at(255, 397, -72, 0.8, inner: false),
        at(769, 397, 72, 0.8, inner: false),
        at(243, 508, -96, 0.78, inner: false),
        at(781, 508, 96, 0.78, inner: false),
        at(278, 615, -120, 0.74, inner: false),
        at(746, 615, 120, 0.74, inner: false),
    ]
}

/// The icon's flame: a drawn tip, a swelling body, and the lick folded into its left side.
private struct FlameShape: Shape {
    func path(in rect: CGRect) -> Path {
        // The icon's own path, on its own coordinates, then mapped into whatever rect it is given.
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -110))
        path.addCurve(
            to: CGPoint(x: 62, y: 12),
            control1: CGPoint(x: 18, y: -70), control2: CGPoint(x: 62, y: -40)
        )
        path.addCurve(
            to: CGPoint(x: 0, y: 82),
            control1: CGPoint(x: 62, y: 52), control2: CGPoint(x: 34, y: 82)
        )
        path.addCurve(
            to: CGPoint(x: -62, y: 12),
            control1: CGPoint(x: -34, y: 82), control2: CGPoint(x: -62, y: 52)
        )
        path.addCurve(
            to: CGPoint(x: -34, y: -62),
            control1: CGPoint(x: -62, y: -18), control2: CGPoint(x: -44, y: -34)
        )
        path.addCurve(
            to: CGPoint(x: -6, y: -46),
            control1: CGPoint(x: -24, y: -40), control2: CGPoint(x: -12, y: -34)
        )
        path.addCurve(
            to: CGPoint(x: 0, y: -110),
            control1: CGPoint(x: 4, y: -66), control2: CGPoint(x: 2, y: -88)
        )
        path.closeSubpath()

        let source = CGRect(x: -62, y: -110, width: 124, height: 192)
        return path.applying(
            CGAffineTransform(translationX: -source.minX, y: -source.minY)
                .concatenating(
                    CGAffineTransform(
                        scaleX: rect.width / source.width, y: rect.height / source.height
                    )
                )
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        )
    }
}

/// The icon's trunk: three boughs rising out of one base.
private struct TrunkShape: Shape {
    func path(in rect: CGRect) -> Path {
        iconPath(in: rect) { path in
            path.move(to: CGPoint(x: 410, y: 880))
            path.addCurve(to: CGPoint(x: 488, y: 740),
                          control1: CGPoint(x: 470, y: 872), control2: CGPoint(x: 488, y: 820))
            path.addCurve(to: CGPoint(x: 410, y: 480),
                          control1: CGPoint(x: 488, y: 660), control2: CGPoint(x: 420, y: 600))
            path.addCurve(to: CGPoint(x: 500, y: 660),
                          control1: CGPoint(x: 440, y: 560), control2: CGPoint(x: 490, y: 610))
            path.addCurve(to: CGPoint(x: 512, y: 440),
                          control1: CGPoint(x: 500, y: 600), control2: CGPoint(x: 498, y: 540))
            path.addCurve(to: CGPoint(x: 524, y: 660),
                          control1: CGPoint(x: 526, y: 540), control2: CGPoint(x: 524, y: 600))
            path.addCurve(to: CGPoint(x: 614, y: 480),
                          control1: CGPoint(x: 534, y: 610), control2: CGPoint(x: 584, y: 560))
            path.addCurve(to: CGPoint(x: 536, y: 740),
                          control1: CGPoint(x: 604, y: 600), control2: CGPoint(x: 536, y: 660))
            path.addCurve(to: CGPoint(x: 614, y: 880),
                          control1: CGPoint(x: 536, y: 820), control2: CGPoint(x: 554, y: 872))
            path.closeSubpath()
        }
    }
}

/// The spread of roots the trunk stands on.
private struct GroundShape: Shape {
    func path(in rect: CGRect) -> Path {
        iconPath(in: rect) { path in
            path.move(to: CGPoint(x: 330, y: 896))
            path.addQuadCurve(to: CGPoint(x: 694, y: 896), control: CGPoint(x: 512, y: 858))
            path.closeSubpath()
        }
    }
}

/// Draws on the icon's 1024 square and fits the result to `rect`.
private func iconPath(in rect: CGRect, _ build: (inout Path) -> Void) -> Path {
    var path = Path()
    build(&path)
    let scale = min(rect.width, rect.height) / 1024
    return path.applying(
        CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(
                CGAffineTransform(
                    translationX: rect.midX - 512 * scale,
                    y: rect.midY - 512 * scale
                )
            )
    )
}
