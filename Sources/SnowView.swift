import AppKit

// MARK: - Stałe i typy

enum Snow {
    static let colW: CGFloat = 3       // szerokość kolumny zaspy (px)
    static let maxPile: CGFloat = 14   // maks. wysokość zaspy (px)
    static let slope: CGFloat = 2.5    // maks. różnica sąsiednich kolumn (kąt usypu)
    static let mouseRadius: CGFloat = 70
    /// Promień zaokrąglenia rogów okien (Tahoe ma większe rogi niż Sonoma/Sequoia).
    static let cornerRadius: CGFloat = {
        if #available(macOS 26, *) { return 16 }
        return 10
    }()
}

enum Effect: Int, CaseIterable {
    case snow, leaves, sakura, rain, fireflies
    var title: String { ["Śnieg", "Liście", "Sakura", "Deszcz", "Świetliki"][rawValue] }
}

enum Intensity: Int, CaseIterable {
    case light, medium, heavy
    var title: String { ["Lekko", "Średnio", "Mocno"][rawValue] }
    var factor: CGFloat { [0.45, 1, 2.3][rawValue] }
    var wind: CGFloat { [8, 15, 45][rawValue] }
}

enum Palette {
    static let leaves: [CGColor] = [
        CGColor(red: 0.85, green: 0.35, blue: 0.10, alpha: 1),
        CGColor(red: 0.92, green: 0.60, blue: 0.12, alpha: 1),
        CGColor(red: 0.70, green: 0.20, blue: 0.10, alpha: 1),
        CGColor(red: 0.60, green: 0.45, blue: 0.15, alpha: 1),
        CGColor(red: 0.95, green: 0.75, blue: 0.20, alpha: 1),
    ]
    static let petals: [CGColor] = [
        CGColor(red: 1.00, green: 0.80, blue: 0.86, alpha: 0.95),
        CGColor(red: 0.98, green: 0.70, blue: 0.80, alpha: 0.95),
        CGColor(red: 1.00, green: 0.89, blue: 0.93, alpha: 0.95),
    ]
}

struct Flake { var x, y, r, vx, vy, phase, alpha: CGFloat }

struct Leaf {
    var x, y, vx, vy, angle, spin, size, phase: CGFloat
    var color: Int
    var sakura: Bool
    var restingOn: Int? = nil   // id okna, -1 = dół ekranu
    var age: CGFloat = 0
    var alpha: CGFloat = 1
}

struct RainStreak { var x, y, vy, len: CGFloat }
struct Splash { var x, y, t: CGFloat }

/// Kropla na „szybie” okna; pozycja względem lewego górnego rogu okna, więc jedzie razem z nim.
struct GlassDrop { let sid: Int; var ox, oy, r, vy, wait, trailTop, phase: CGFloat }

struct Firefly { var x, y, vx, vy, heading, orbit, phase, glowSpeed, glowPhase, alpha: CGFloat }

/// Kula śnieżna. Stos kul = bałwan.
struct Ball {
    enum Support: Equatable { case none, ground, window(Int), ball(Int) }
    let id: Int
    var x, y, r: CGFloat
    var vy: CGFloat = 0
    var held = false
    var support: Support = .none
}

/// Górna krawędź okna (albo dół ekranu) z zaspą śniegu.
struct Surface {
    let id: Int
    var frame: CGRect
    var pile: [CGFloat]
    /// O ile krawędź opada w danej kolumnie przez zaokrąglony róg.
    let base: [CGFloat]

    init(id: Int, frame: CGRect, rounded: Bool = true) {
        self.id = id
        self.frame = frame
        let n = max(1, Int(ceil(frame.width / Snow.colW)))
        pile = Array(repeating: 0, count: n)
        if rounded {
            let r = min(Snow.cornerRadius, frame.width / 2)
            base = (0..<n).map { c in
                let x = (CGFloat(c) + 0.5) * Snow.colW
                let d = max(0, min(x, frame.width - x))
                guard d < r else { return 0 }
                let dx = r - d
                return r - sqrt(max(0, r * r - dx * dx))
            }
        } else {
            base = Array(repeating: 0, count: n)
        }
    }

    var hasSnow: Bool { pile.contains { $0 > 0.3 } }

    func column(at x: CGFloat) -> Int? {
        guard x >= frame.minX, x < frame.maxX else { return nil }
        return min(pile.count - 1, Int((x - frame.minX) / Snow.colW))
    }
    /// Krawędź okna w kolumnie (z rogiem).
    func edge(_ c: Int) -> CGFloat { frame.minY + base[c] }
    /// Wierzch śniegu w kolumnie.
    func top(_ c: Int) -> CGFloat { edge(c) - pile[c] }
}

// MARK: - Widok jednego ekranu

@MainActor
final class SnowView: NSView {
    var intensity: Intensity = .medium
    var effect: Effect = .snow
    var running = true
    /// Tryb lepienia: nakładka przyjmuje kliknięcia.
    var interactive = false {
        didSet { if !interactive { releaseHeld() } }
    }

    /// Lewy górny róg tego ekranu w globalnych współrzędnych CG.
    private let screenOriginCG: CGPoint
    /// Ten ekran w globalnych współrzędnych CG.
    var globalRect: CGRect { CGRect(origin: screenOriginCG, size: bounds.size) }
    /// Pozostałe ekrany (globalne CG) — do przekazywania płatków między monitorami.
    var otherScreens: [CGRect] = [] { didSet { computeOpenings() } }
    /// Kolumny dołu ekranu, pod którymi jest inny monitor (tam śnieg przelatuje dalej).
    private var openBelow: [Bool] = []
    /// Cząstki, które wyleciały na inny ekran (współrzędne globalne); zbiera je AppDelegate.
    var outgoingFlakes: [Flake] = []
    var outgoingLeaves: [Leaf] = []
    private var surfaces: [Surface] = []   // okna na tym ekranie, od przedniego do tylnego
    private var ground: Surface
    private var time: CGFloat = 0
    private var gust: CGFloat = 0

    private var flakes: [Flake] = []
    private var leaves: [Leaf] = []
    private var streaks: [RainStreak] = []
    private var splashes: [Splash] = []
    private var glassDrops: [GlassDrop] = []
    private var fireflies: [Firefly] = []
    private var spawnAcc: [Effect: CGFloat] = [:]
    private var glassAcc: CGFloat = 0

    private var mouse = CGPoint.zero
    private var lastMouse = CGPoint.zero
    private var mouseVel = CGVector.zero
    private var mouseIdle: CGFloat = 0

    private var balls: [Ball] = []
    private var nextBallId = 1
    private var heldId: Int?
    private var grabOffset = CGPoint.zero
    private var lastDrag = CGPoint.zero

    private let glowGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 0.85, green: 1, blue: 0.45, alpha: 0.9),
        CGColor(red: 0.6, green: 0.9, blue: 0.2, alpha: 0),
    ] as CFArray, locations: [0, 1])!

    private let ballGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        CGColor(red: 0.80, green: 0.86, blue: 0.95, alpha: 1),
    ] as CFArray, locations: [0, 1])!

    override var isFlipped: Bool { true } // y rośnie w dół, jak w CGWindowList

    init(frame: NSRect, screenOriginCG: CGPoint) {
        self.screenOriginCG = screenOriginCG
        ground = Surface(id: -1, frame: CGRect(x: 0, y: frame.height, width: frame.width, height: 0), rounded: false)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func tick(dt: CGFloat, windows: [WindowInfo], refreshed: Bool, gust: CGFloat) {
        self.gust = gust
        time += dt
        if refreshed { updateSurfaces(windows) }
        updateMouse(dt)
        stepSnow(dt)
        stepLeaves(dt)
        stepRain(dt)
        stepFireflies(dt)
        updatePiles(dt)
        updateBalls(dt)
        needsDisplay = true
    }

    func accept(flake: Flake) {
        var f = flake
        f.x -= screenOriginCG.x
        f.y -= screenOriginCG.y
        flakes.append(f)
    }

    func accept(leaf: Leaf) {
        var l = leaf
        l.x -= screenOriginCG.x
        l.y -= screenOriginCG.y
        leaves.append(l)
    }

    private func computeOpenings() {
        openBelow = (0..<ground.pile.count).map { c in
            let p = CGPoint(x: screenOriginCG.x + (CGFloat(c) + 0.5) * Snow.colW,
                            y: screenOriginCG.y + bounds.height + 2)
            return otherScreens.contains { $0.contains(p) }
        }
    }

    /// Czy punkt (lokalny) leży na innym monitorze.
    private func onOtherScreen(_ x: CGFloat, _ y: CGFloat) -> Bool {
        let p = CGPoint(x: screenOriginCG.x + x, y: screenOriginCG.y + y)
        return otherScreens.contains { $0.contains(p) }
    }

    /// Nad tym miejscem jest inny monitor — płatki przylecą stamtąd, nie tworzymy nowych.
    private func hasScreenAbove(_ x: CGFloat) -> Bool { onOtherScreen(x, -2) }

    func removeAllBalls() {
        balls.removeAll()
        heldId = nil
    }

    // MARK: - Wspólne

    private var wind: CGFloat { intensity.wind * (0.6 + 0.4 * sin(time * 0.3)) + gust }
    private var widthScale: CGFloat { bounds.width / 1512 }

    private func spawnCount(_ e: Effect, perSecond: CGFloat, dt: CGFloat) -> Int {
        guard running, effect == e else { spawnAcc[e] = 0; return 0 }
        var rate = perSecond
        if ProcessInfo.processInfo.isLowPowerModeEnabled { rate *= 0.5 }
        var acc = (spawnAcc[e] ?? 0) + rate * dt
        let n = Int(acc)
        acc -= CGFloat(n)
        spawnAcc[e] = acc
        return n
    }

    private func spawnXRange(extra: CGFloat) -> ClosedRange<CGFloat> {
        let w = bounds.width
        return (-50 - max(0, extra))...(w + 50 - min(0, extra))
    }

    private func currentMouse() -> CGPoint {
        let p = NSEvent.mouseLocation
        guard let screen = window?.screen ?? NSScreen.screens.first else { return .zero }
        return CGPoint(x: p.x - screen.frame.minX, y: screen.frame.maxY - p.y)
    }

    private func updateMouse(_ dt: CGFloat) {
        let m = currentMouse()
        if dt > 0 { mouseVel = CGVector(dx: (m.x - lastMouse.x) / dt, dy: (m.y - lastMouse.y) / dt) }
        mouseIdle = hypot(mouseVel.dx, mouseVel.dy) < 15 ? mouseIdle + dt : 0
        lastMouse = m
        mouse = m
    }

    private func mousePush(x: CGFloat, y: CGFloat, dt: CGFloat) -> CGVector {
        let dx = x - mouse.x, dy = y - mouse.y
        let d2 = dx * dx + dy * dy
        let R = Snow.mouseRadius
        guard d2 < R * R, d2 > 0.01 else { return .zero }
        let d = sqrt(d2)
        let push = (1 - d / R) * 260 * dt
        return CGVector(dx: dx / d * push, dy: dy / d * push)
    }

    /// Czy punkt jest zasłonięty przez któreś okno leżące przed oknem `idx`.
    private func isCovered(x: CGFloat, y: CGFloat, frontOf idx: Int) -> Bool {
        let p = CGPoint(x: x, y: y)
        for j in 0..<idx where surfaces[j].frame.contains(p) { return true }
        return false
    }

    /// Czy coś spadające z `prevY` do `y` w kolumnie `x` trafiło w okno lub dół ekranu.
    /// `index == nil` oznacza dół ekranu.
    private func landing(x: CGFloat, prevY: CGFloat, y: CGFloat) -> (index: Int?, c: Int, top: CGFloat)? {
        for idx in surfaces.indices {
            guard let c = surfaces[idx].column(at: x) else { continue }
            let top = surfaces[idx].top(c)
            guard prevY < top, y >= top,
                  !isCovered(x: x, y: surfaces[idx].edge(c) - 1, frontOf: idx) else { continue }
            return (idx, c, top)
        }
        if let c = ground.column(at: x), !(c < openBelow.count && openBelow[c]), y >= ground.top(c) {
            return (nil, c, ground.top(c))
        }
        return nil
    }

    // MARK: - Śnieg

    private func stepSnow(_ dt: CGFloat) {
        let W = bounds.width, H = bounds.height
        let wind = self.wind
        let target = 600 * intensity.factor * widthScale
        for _ in 0..<spawnCount(.snow, perSecond: target * 75 / H, dt: dt) where CGFloat(flakes.count) < target * 1.5 {
            let x = CGFloat.random(in: spawnXRange(extra: wind * 3))
            if hasScreenAbove(x) { continue }
            flakes.append(makeFlake(x: x, y: -10))
        }

        var i = 0
        while i < flakes.count {
            var f = flakes[i]
            let prevY = f.y
            let wasInside = bounds.contains(CGPoint(x: f.x, y: f.y))
            f.phase += dt
            let terminal = 30 + f.r * 18
            f.vy += (terminal - f.vy) * min(1, dt * 1.5)
            f.x += (f.vx + wind + sin(f.phase * 1.7) * 12) * dt
            f.y += f.vy * dt
            let p = mousePush(x: f.x, y: f.y, dt: dt)
            f.x += p.dx
            f.y += p.dy

            var gone = f.y > H + 20 || f.x < -150 || f.x > W + 150
            if !gone, let hit = landing(x: f.x, prevY: prevY, y: f.y) {
                if let idx = hit.index { deposit(&surfaces[idx].pile, hit.c, f.r) }
                else { deposit(&ground.pile, hit.c, f.r) }
                gone = true
            } else if wasInside && !bounds.contains(CGPoint(x: f.x, y: f.y)) && onOtherScreen(f.x, f.y) {
                // przelot na sąsiedni monitor
                var g = f
                g.x += screenOriginCG.x
                g.y += screenOriginCG.y
                outgoingFlakes.append(g)
                gone = true
            }
            if gone {
                flakes.swapAt(i, flakes.count - 1)
                flakes.removeLast()
            } else {
                flakes[i] = f
                i += 1
            }
        }
    }

    private func makeFlake(x: CGFloat, y: CGFloat) -> Flake {
        let r = CGFloat.random(in: 1...3.4)
        return Flake(x: x, y: y, r: r,
                     vx: .random(in: -6...6),
                     vy: 30 + r * 18 + .random(in: 0...15),
                     phase: .random(in: 0...6.28),
                     alpha: .random(in: 0.55...0.95))
    }

    private func deposit(_ pile: inout [CGFloat], _ c: Int, _ r: CGFloat) {
        let a = r * 0.5
        pile[c] = min(Snow.maxPile, pile[c] + a)
        if c > 0 { pile[c - 1] = min(Snow.maxPile, pile[c - 1] + a * 0.5) }
        if c < pile.count - 1 { pile[c + 1] = min(Snow.maxPile, pile[c + 1] + a * 0.5) }
    }

    /// Topnienie, osuwanie się i zwiewanie zasp.
    private func updatePiles(_ dt: CGFloat) {
        let melt: CGFloat = (running && effect == .snow) ? 0.12 : 0.8
        let chance = abs(gust) > 60 ? abs(gust) / 250 * dt * 2 : 0
        var blown: [Flake] = []

        func process(_ s: inout Surface) {
            relax(&s.pile, dt: dt, melt: melt)
            guard chance > 0 else { return }
            for c in s.pile.indices where s.pile[c] > 1 && blown.count < 80 && CGFloat.random(in: 0...1) < chance {
                let take = min(s.pile[c], 1.2)
                s.pile[c] -= take
                var f = makeFlake(x: s.frame.minX + (CGFloat(c) + 0.5) * Snow.colW, y: s.top(c) - 1)
                f.r = .random(in: 1...2.2)
                f.vy = .random(in: -70 ... -15)   // podmuch podrywa śnieg w górę
                f.vx = .random(in: -10...10)
                blown.append(f)
            }
        }

        for idx in surfaces.indices { process(&surfaces[idx]) }
        process(&ground)
        flakes.append(contentsOf: blown)
    }

    private func relax(_ pile: inout [CGFloat], dt: CGFloat, melt: CGFloat) {
        let n = pile.count
        for c in 0..<n { pile[c] = max(0, pile[c] - melt * dt) }
        if n > 1 {
            for c in 0..<(n - 1) {
                let diff = pile[c] - pile[c + 1]
                if abs(diff) > Snow.slope {
                    let move = (abs(diff) - Snow.slope) * 0.25 * (diff > 0 ? 1 : -1)
                    pile[c] -= move
                    pile[c + 1] += move
                }
            }
        }
        // śnieg zsuwa się z krawędzi
        if pile[0] > Snow.slope { pile[0] -= (pile[0] - Snow.slope) * 0.25 }
        if pile[n - 1] > Snow.slope { pile[n - 1] -= (pile[n - 1] - Snow.slope) * 0.25 }
    }

    // MARK: - Liście i sakura

    private func stepLeaves(_ dt: CGFloat) {
        let W = bounds.width, H = bounds.height
        let wind = self.wind

        if effect == .leaves || effect == .sakura {
            let sakura = effect == .sakura
            let target = (sakura ? 70 : 35) * intensity.factor * widthScale
            var falling = 0
            for l in leaves where l.restingOn == nil { falling += 1 }
            for _ in 0..<spawnCount(effect, perSecond: target * 55 / H, dt: dt) where CGFloat(falling) < target * 1.5 {
                let x = CGFloat.random(in: spawnXRange(extra: wind * 4))
                if hasScreenAbove(x) { continue }
                leaves.append(makeLeaf(x: x, y: -20, sakura: sakura))
                falling += 1
            }
        }

        let gustLift = abs(gust) > 80 ? abs(gust) / 250 * dt * 1.5 : 0
        let mouseSpeed = hypot(mouseVel.dx, mouseVel.dy)

        var i = 0
        while i < leaves.count {
            var l = leaves[i]
            var gone = false

            if l.restingOn != nil {
                l.age += dt
                let near = hypot(l.x - mouse.x, l.y - mouse.y) < 45
                if (near && mouseSpeed > 150) || CGFloat.random(in: 0...1) < gustLift {
                    // kursor albo podmuch podrywa liść
                    l.restingOn = nil
                    l.vy = -CGFloat.random(in: 80...220)
                    l.vx = near ? mouseVel.dx * 0.4 + .random(in: -40...40) : gust * 0.5
                    l.spin = .random(in: -6...6)
                }
                let life: CGFloat = l.sakura ? 40 : 90
                if l.age > life {
                    l.alpha -= dt * 0.5
                    if l.alpha <= 0 { gone = true }
                }
            } else {
                let prevY = l.y
                let wasInside = bounds.contains(CGPoint(x: l.x, y: l.y))
                l.phase += dt
                let terminal: CGFloat = l.sakura ? 38 : 55
                l.vy += (terminal - l.vy) * min(1, dt * 1.2)
                l.vx *= max(0, 1 - dt * 0.8)
                let sway: CGFloat = l.sakura ? 30 : 45
                l.x += (l.vx + wind * (l.sakura ? 1.6 : 1.3) + sin(l.phase * (l.sakura ? 1.9 : 1.2)) * sway) * dt
                l.y += (l.vy + cos(l.phase * 2.4) * 12) * dt
                l.angle += l.spin * dt
                let p = mousePush(x: l.x, y: l.y, dt: dt)
                l.x += p.dx
                l.y += p.dy

                if let hit = landing(x: l.x, prevY: prevY, y: l.y) {
                    l.restingOn = hit.index.map { surfaces[$0].id } ?? -1
                    l.y = hit.top - l.size * 0.15
                    l.age = 0
                    l.angle = .random(in: -0.35...0.35) + (Bool.random() ? 0 : .pi)
                }
                if l.restingOn == nil && wasInside && !bounds.contains(CGPoint(x: l.x, y: l.y)) && onOtherScreen(l.x, l.y) {
                    var g = l
                    g.x += screenOriginCG.x
                    g.y += screenOriginCG.y
                    outgoingLeaves.append(g)
                    gone = true
                } else if l.y > H + 30 || l.x < -200 || l.x > W + 200 { gone = true }
            }

            if gone {
                leaves.swapAt(i, leaves.count - 1)
                leaves.removeLast()
            } else {
                leaves[i] = l
                i += 1
            }
        }
    }

    private func makeLeaf(x: CGFloat, y: CGFloat, sakura: Bool) -> Leaf {
        Leaf(x: x, y: y,
             vx: .random(in: -10...10),
             vy: sakura ? 35 : 50,
             angle: .random(in: 0...(2 * .pi)),
             spin: .random(in: -2.5...2.5),
             size: sakura ? .random(in: 5...8) : .random(in: 9...15),
             phase: .random(in: 0...6.28),
             color: Int.random(in: 0..<(sakura ? Palette.petals.count : Palette.leaves.count)),
             sakura: sakura)
    }

    // MARK: - Deszcz

    private func stepRain(_ dt: CGFloat) {
        let H = bounds.height
        let vx = wind * 2.5
        let target = 320 * intensity.factor * widthScale
        for _ in 0..<spawnCount(.rain, perSecond: target * 1100 / H, dt: dt) where CGFloat(streaks.count) < target * 1.5 {
            streaks.append(RainStreak(x: .random(in: spawnXRange(extra: vx)), y: -20,
                                      vy: .random(in: 900...1300), len: .random(in: 12...24)))
        }

        var i = 0
        while i < streaks.count {
            var s = streaks[i]
            let prevY = s.y
            s.x += vx * dt
            s.y += s.vy * dt
            var gone = s.y > H + 30
            if !gone, let hit = landing(x: s.x, prevY: prevY, y: s.y) {
                if splashes.count < 200 { splashes.append(Splash(x: s.x, y: hit.top, t: 0)) }
                gone = true
            }
            if gone {
                streaks.swapAt(i, streaks.count - 1)
                streaks.removeLast()
            } else {
                streaks[i] = s
                i += 1
            }
        }

        for k in splashes.indices { splashes[k].t += dt }
        splashes.removeAll { $0.t > 0.3 }

        // Nowe krople na szybach okien
        let raining = running && effect == .rain
        if raining {
            glassAcc += 12 * intensity.factor * widthScale * dt
            while glassAcc >= 1 {
                glassAcc -= 1
                guard glassDrops.count < 200 else { continue }
                let p = CGPoint(x: .random(in: 0...bounds.width), y: .random(in: 0...H))
                // pierwsze okno zawierające punkt = to widoczne na wierzchu
                if let idx = surfaces.firstIndex(where: { $0.frame.contains(p) }) {
                    let fr = surfaces[idx].frame
                    let oy = p.y - fr.minY
                    guard oy > 30 else { continue } // nie na pasku tytułu
                    glassDrops.append(GlassDrop(sid: surfaces[idx].id, ox: p.x - fr.minX, oy: oy,
                                                r: .random(in: 1.5...3.5), vy: 0,
                                                wait: .random(in: 0.5...4), trailTop: oy,
                                                phase: .random(in: 0...6.28)))
                }
            }
        } else {
            glassAcc = 0
        }

        // Spływanie kropel
        var heights: [Int: CGFloat] = [:]
        for s in surfaces { heights[s.id] = s.frame.height }
        var j = 0
        while j < glassDrops.count {
            var d = glassDrops[j]
            guard let h = heights[d.sid] else {
                glassDrops.swapAt(j, glassDrops.count - 1); glassDrops.removeLast(); continue
            }
            if !raining { d.wait = min(d.wait, 0.1) } // po deszczu wszystko spływa
            if d.wait > 0 {
                d.wait -= dt
                d.r = min(4.5, d.r + dt * 0.3)
                d.trailTop = d.oy
            } else {
                d.phase += dt * 6
                d.vy = min(d.vy + 80 * dt, 40 + d.r * 25)
                if raining && CGFloat.random(in: 0...1) < dt * 0.8 {
                    d.vy = 0                                 // kropla przystaje
                    d.wait = .random(in: 0.2...1.2)
                }
                d.oy += d.vy * dt
                d.ox += sin(d.phase) * 0.15
                d.trailTop = max(d.trailTop, d.oy - 140)
            }
            if d.oy > h - 2 {
                glassDrops.swapAt(j, glassDrops.count - 1); glassDrops.removeLast()
            } else {
                glassDrops[j] = d
                j += 1
            }
        }
    }

    // MARK: - Świetliki

    private func stepFireflies(_ dt: CGFloat) {
        let W = bounds.width, H = bounds.height
        let active = running && effect == .fireflies
        let target = 28 * intensity.factor * widthScale
        if active && CGFloat(fireflies.count) < target && CGFloat.random(in: 0...1) < dt * 4 {
            fireflies.append(Firefly(x: .random(in: 0...W), y: .random(in: (H * 0.3)...H),
                                     vx: 0, vy: 0,
                                     heading: .random(in: 0...6.28),
                                     orbit: .random(in: 25...90),
                                     phase: .random(in: 0...6.28),
                                     glowSpeed: .random(in: 1.5...3.2),
                                     glowPhase: .random(in: 0...6.28),
                                     alpha: 0))
        }

        // kursor stoi w miejscu => świetliki się zlatują
        let gathering = mouseIdle > 0.6 && bounds.contains(mouse)
        let mouseSpeed = hypot(mouseVel.dx, mouseVel.dy)

        var i = 0
        while i < fireflies.count {
            var f = fireflies[i]
            f.glowPhase += f.glowSpeed * dt
            f.alpha = active ? min(1, f.alpha + dt * 0.7) : f.alpha - dt * 0.6
            if !active && f.alpha <= 0 {
                fireflies.swapAt(i, fireflies.count - 1); fireflies.removeLast(); continue
            }

            let dx = mouse.x - f.x, dy = mouse.y - f.y
            let dist = hypot(dx, dy)
            var desired: CGVector
            if gathering && dist < 700 {
                f.phase += dt * (0.8 + 40 / f.orbit)
                let tx = mouse.x + cos(f.phase) * f.orbit
                let ty = mouse.y + sin(f.phase) * f.orbit * 0.6
                desired = CGVector(dx: (tx - f.x) * 1.8, dy: (ty - f.y) * 1.8)
            } else if dist < 140 && mouseSpeed > 250 {
                desired = CGVector(dx: -dx / max(dist, 1) * 160, dy: -dy / max(dist, 1) * 160)
            } else {
                f.heading += .random(in: -2.5...2.5) * dt
                if f.x < 40 { f.heading = 0 } else if f.x > W - 40 { f.heading = .pi }
                if f.y < 40 { f.heading = .pi / 2 } else if f.y > H - 40 { f.heading = -.pi / 2 }
                desired = CGVector(dx: cos(f.heading) * 28 + gust * 0.3, dy: sin(f.heading) * 18)
            }
            let sp = hypot(desired.dx, desired.dy)
            if sp > 160 { desired.dx *= 160 / sp; desired.dy *= 160 / sp }
            let k = min(1, dt * 2.5)
            f.vx += (desired.dx - f.vx) * k
            f.vy += (desired.dy - f.vy) * k
            f.x += f.vx * dt
            f.y += f.vy * dt
            fireflies[i] = f
            i += 1
        }
    }

    // MARK: - Okna

    private func updateSurfaces(_ windows: [WindowInfo]) {
        var old: [Int: Surface] = [:]
        for s in surfaces { old[s.id] = s }

        var fresh: [Surface] = []
        var shaken = Set<Int>()
        for w in windows {
            // globalne CG -> współrzędne tego ekranu
            let rect = w.rect.offsetBy(dx: -screenOriginCG.x, dy: -screenOriginCG.y)
            guard rect.intersects(bounds) else { continue }

            if let prev = old.removeValue(forKey: w.id) {
                let moved = abs(prev.frame.minX - rect.minX) > 0.5
                    || abs(prev.frame.minY - rect.minY) > 0.5
                    || abs(prev.frame.width - rect.width) > 0.5
                if moved {
                    release(prev)                 // okno ruszone => śnieg spada
                    shaken.insert(w.id)
                    fresh.append(Surface(id: w.id, frame: rect))
                } else {
                    fresh.append(prev)
                }
            } else {
                fresh.append(Surface(id: w.id, frame: rect))
            }
        }
        shaken.formUnion(old.keys) // okna, które zniknęły
        surfaces = fresh

        if !shaken.isEmpty {
            for k in leaves.indices {
                if let sid = leaves[k].restingOn, shaken.contains(sid) {
                    leaves[k].restingOn = nil
                    leaves[k].vy = 30
                    leaves[k].vx = .random(in: -20...20)
                }
            }
        }
    }

    private func release(_ s: Surface) {
        for (c, h) in s.pile.enumerated() where h > 0.8 {
            let n = min(3, Int(h / 2) + 1)
            for _ in 0..<n {
                var f = makeFlake(x: s.frame.minX + CGFloat(c) * Snow.colW + .random(in: 0...Snow.colW),
                                  y: s.edge(c) - .random(in: 0...h))
                f.vy = .random(in: 90...220)
                f.vx = .random(in: -35...35)
                flakes.append(f)
            }
        }
    }

    // MARK: - Lepienie (mysz)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { grab(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { drag(to: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { releaseHeld() }

    private func grab(at p: CGPoint) {
        guard interactive else { return }
        if let idx = balls.lastIndex(where: { hypot($0.x - p.x, $0.y - p.y) < $0.r }) {
            balls[idx].held = true
            balls[idx].support = .none
            heldId = balls[idx].id
            grabOffset = CGPoint(x: balls[idx].x - p.x, y: balls[idx].y - p.y)
        } else {
            let b = Ball(id: nextBallId, x: p.x, y: p.y, r: 6, held: true)
            nextBallId += 1
            balls.append(b)
            heldId = b.id
            grabOffset = .zero
        }
        lastDrag = p
    }

    private func drag(to p: CGPoint) {
        guard let id = heldId, let idx = balls.firstIndex(where: { $0.id == id }) else { return }
        let moved = hypot(p.x - lastDrag.x, p.y - lastDrag.y)
        lastDrag = p
        var b = balls[idx]
        b.x = min(max(p.x + grabOffset.x, b.r), bounds.width - b.r)
        b.y = p.y + grabOffset.y
        roll(&b, moved: moved)
        balls[idx] = b
    }

    private func releaseHeld() {
        guard let id = heldId else { return }
        heldId = nil
        if let idx = balls.firstIndex(where: { $0.id == id }) {
            balls[idx].held = false
            balls[idx].vy = 0
        }
    }

    /// Toczenie kuli po zaspie zbiera śnieg i powiększa kulę.
    private func roll(_ b: inout Ball, moved: CGFloat) {
        guard moved > 0.1, b.r < 70 else { return }
        let bottom = b.y + b.r
        let reach = b.r * 0.5 + 6
        let left = b.x - b.r * 0.6, right = b.x + b.r * 0.6
        var gained: CGFloat = 0

        func collect(_ s: inout Surface) {
            guard let c0 = s.column(at: max(s.frame.minX, left)),
                  let c1 = s.column(at: min(s.frame.maxX - 0.01, right)), c0 <= c1 else { return }
            for c in c0...c1 where s.pile[c] > 0 && abs(bottom - s.top(c)) < reach {
                let take = min(s.pile[c], moved * 0.15)
                s.pile[c] -= take
                gained += take * Snow.colW
            }
        }

        for idx in surfaces.indices {
            let fr = surfaces[idx].frame
            guard right > fr.minX, left < fr.maxX,
                  !isCovered(x: b.x, y: fr.minY - 1, frontOf: idx) else { continue }
            collect(&surfaces[idx])
        }
        collect(&ground)

        if gained > 0 { b.r = min(70, sqrt(b.r * b.r + gained * 4 / .pi)) }
    }

    // MARK: - Fizyka kul

    private func updateBalls(_ dt: CGFloat) {
        let H = bounds.height
        // od najniżej położonych, żeby podpory były już policzone
        let order = balls.indices.sorted { balls[$0].y + balls[$0].r > balls[$1].y + balls[$1].r }
        for i in order where !balls[i].held {
            var b = balls[i]
            let prevBottom = b.y + b.r
            b.vy = min(b.vy + 1400 * dt, 1500)
            let newBottom = prevBottom + b.vy * dt

            var best: (top: CGFloat, support: Ball.Support)?
            func consider(_ top: CGFloat, _ s: Ball.Support) {
                guard top >= prevBottom - 2, top <= newBottom + 0.01 else { return }
                if best == nil || top < best!.top { best = (top, s) }
            }

            consider(H, .ground)
            for idx in surfaces.indices {
                guard let c = surfaces[idx].column(at: b.x),
                      !isCovered(x: b.x, y: surfaces[idx].edge(c) - 1, frontOf: idx) else { continue }
                consider(surfaces[idx].top(c), .window(surfaces[idx].id))
            }
            for o in balls where o.id != b.id && !o.held && abs(b.x - o.x) < o.r * 0.75 {
                consider(o.y - o.r + min(b.r, o.r) * 0.3, .ball(o.id))
            }

            if let best {
                b.y = best.top - b.r
                b.vy = 0
                b.support = best.support
            } else {
                b.y = newBottom - b.r
                b.support = .none
            }
            balls[i] = b
        }
    }

    // MARK: - Rysowanie

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        var index: [Int: Int] = [:]
        for (i, s) in surfaces.enumerated() { index[s.id] = i }

        drawGlassDrops(ctx, index)
        drawPiles(ctx)
        drawLeaves(ctx, index, resting: true)
        drawBalls(ctx)
        drawRain(ctx)
        drawLeaves(ctx, index, resting: false)
        drawFlakes(ctx)
        drawFireflies(ctx)

        // Wskaźnik trybu lepienia przy kursorze
        if interactive && heldId == nil {
            ctx.setStrokeColor(CGColor(red: 0.6, green: 0.8, blue: 1, alpha: 0.9))
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: mouse.x - 12, y: mouse.y - 12, width: 24, height: 24))
        }
    }

    private func drawPiles(_ ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(CGColor(red: 0.97, green: 0.98, blue: 1, alpha: 0.97))
        for idx in surfaces.indices.reversed() where surfaces[idx].hasSnow {
            let s = surfaces[idx]
            let heights = s.pile.enumerated().map { c, h -> CGFloat in
                let x = s.frame.minX + (CGFloat(c) + 0.5) * Snow.colW
                return isCovered(x: x, y: s.edge(c) - 1, frontOf: idx) ? 0 : h
            }
            ctx.addPath(pilePath(s, heights))
            ctx.fillPath()
        }
        if ground.hasSnow {
            ctx.addPath(pilePath(ground, ground.pile))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    /// Zaspa: wzdłuż (zaokrąglonej) krawędzi okna w górę o wysokość śniegu i z powrotem.
    private func pilePath(_ s: Surface, _ heights: [CGFloat]) -> CGPath {
        let p = CGMutablePath()
        let n = heights.count
        func x(_ c: Int) -> CGFloat { s.frame.minX + (CGFloat(c) + 0.5) * Snow.colW }
        p.move(to: CGPoint(x: x(0), y: s.edge(0) + 0.5))
        for c in 0..<n { p.addLine(to: CGPoint(x: x(c), y: s.edge(c) + 0.5 - heights[c])) }
        for c in stride(from: n - 1, through: 0, by: -1) { p.addLine(to: CGPoint(x: x(c), y: s.edge(c) + 0.5)) }
        p.closeSubpath()
        return p
    }

    private func drawFlakes(_ ctx: CGContext) {
        for f in flakes {
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: f.alpha)
            ctx.fillEllipse(in: CGRect(x: f.x - f.r, y: f.y - f.r, width: f.r * 2, height: f.r * 2))
        }
    }

    private func drawLeaves(_ ctx: CGContext, _ index: [Int: Int], resting: Bool) {
        for l in leaves where (l.restingOn != nil) == resting {
            if let sid = l.restingOn, sid != -1 {
                guard let idx = index[sid],
                      !isCovered(x: l.x, y: surfaces[idx].frame.minY - 1, frontOf: idx) else { continue }
            }
            ctx.saveGState()
            ctx.setAlpha(l.alpha)
            ctx.translateBy(x: l.x, y: l.y)
            ctx.rotate(by: l.angle)
            // w locie liść "obraca się" w 3D, leżący widać z boku
            ctx.scaleBy(x: 1, y: resting ? 0.45 : max(0.25, abs(cos(l.phase * 1.8))))
            let colors = l.sakura ? Palette.petals : Palette.leaves
            ctx.setFillColor(colors[l.color % colors.count])
            ctx.addPath(l.sakura ? petalPath(l.size) : leafPath(l.size))
            ctx.fillPath()
            if !l.sakura {
                ctx.setStrokeColor(CGColor(red: 0.3, green: 0.15, blue: 0.05, alpha: 0.45))
                ctx.setLineWidth(0.8)
                ctx.move(to: CGPoint(x: -l.size * 1.25, y: 0))
                ctx.addLine(to: CGPoint(x: l.size * 0.85, y: 0))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }

    private func leafPath(_ s: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -s, y: 0))
        p.addQuadCurve(to: CGPoint(x: s, y: 0), control: CGPoint(x: 0, y: -s * 0.75))
        p.addQuadCurve(to: CGPoint(x: -s, y: 0), control: CGPoint(x: 0, y: s * 0.75))
        p.closeSubpath()
        return p
    }

    private func petalPath(_ s: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: s * 0.6))
        p.addQuadCurve(to: CGPoint(x: -s * 0.6, y: -s * 0.2), control: CGPoint(x: -s * 0.7, y: s * 0.4))
        p.addQuadCurve(to: CGPoint(x: 0, y: -s * 0.35), control: CGPoint(x: -s * 0.4, y: -s * 0.8))
        p.addQuadCurve(to: CGPoint(x: s * 0.6, y: -s * 0.2), control: CGPoint(x: s * 0.4, y: -s * 0.8))
        p.addQuadCurve(to: CGPoint(x: 0, y: s * 0.6), control: CGPoint(x: s * 0.7, y: s * 0.4))
        p.closeSubpath()
        return p
    }

    private func drawRain(_ ctx: CGContext) {
        guard !streaks.isEmpty || !splashes.isEmpty else { return }
        let vx = wind * 2.5
        ctx.setStrokeColor(CGColor(red: 0.75, green: 0.85, blue: 1, alpha: 0.45))
        ctx.setLineWidth(1.2)
        ctx.setLineCap(.round)
        for s in streaks {
            ctx.move(to: CGPoint(x: s.x - vx / s.vy * s.len, y: s.y - s.len))
            ctx.addLine(to: CGPoint(x: s.x, y: s.y))
        }
        ctx.strokePath()

        for sp in splashes {
            let p = sp.t / 0.3
            ctx.setFillColor(CGColor(red: 0.8, green: 0.9, blue: 1, alpha: 0.7 * (1 - p)))
            for side in [-1, 1] as [CGFloat] {
                let x = sp.x + side * (2 + p * 7)
                let y = sp.y - 8 * p * (1 - p) * 2
                ctx.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
            }
        }
    }

    private func drawGlassDrops(_ ctx: CGContext, _ index: [Int: Int]) {
        for d in glassDrops {
            guard let idx = index[d.sid] else { continue }
            let fr = surfaces[idx].frame
            let x = fr.minX + d.ox, y = fr.minY + d.oy
            guard !isCovered(x: x, y: y, frontOf: idx) else { continue }

            let trailTop = fr.minY + d.trailTop
            if y - trailTop > d.r * 2 {
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
                ctx.setLineWidth(d.r * 0.7)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: x, y: trailTop))
                ctx.addLine(to: CGPoint(x: x, y: y))
                ctx.strokePath()
            }

            let w = d.r * 1.7, h = d.r * (d.vy > 5 ? 2.3 : 1.8)
            let rect = CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
            ctx.setFillColor(CGColor(red: 0.85, green: 0.92, blue: 1, alpha: 0.35))
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.22))
            ctx.setLineWidth(0.8)
            ctx.strokeEllipse(in: rect)
            let hr = max(0.6, d.r * 0.3)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
            ctx.fillEllipse(in: CGRect(x: x - w * 0.25 - hr / 2, y: y - h * 0.25 - hr / 2, width: hr, height: hr))
        }
    }

    private func drawFireflies(_ ctx: CGContext) {
        for f in fireflies {
            let a = f.alpha * (0.35 + 0.65 * max(0, sin(f.glowPhase)))
            guard a > 0.02 else { continue }
            let p = CGPoint(x: f.x, y: f.y)
            ctx.saveGState()
            ctx.setAlpha(a)
            ctx.drawRadialGradient(glowGradient, startCenter: p, startRadius: 0,
                                   endCenter: p, endRadius: 16, options: [])
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0.8, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: f.x - 1.2, y: f.y - 1.2, width: 2.4, height: 2.4))
            ctx.restoreGState()
        }
    }

    private func drawBalls(_ ctx: CGContext) {
        guard !balls.isEmpty else { return }
        var hasBallAbove = Set<Int>()
        for b in balls { if case .ball(let below) = b.support { hasBallAbove.insert(below) } }

        // od najniższych, żeby górne kule nachodziły na dolne
        for b in balls.sorted(by: { $0.y > $1.y }) {
            let rect = CGRect(x: b.x - b.r, y: b.y - b.r, width: b.r * 2, height: b.r * 2)

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 5, color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: rect)
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addEllipse(in: rect)
            ctx.clip()
            ctx.drawRadialGradient(ballGradient,
                                   startCenter: CGPoint(x: b.x - b.r * 0.35, y: b.y - b.r * 0.4), startRadius: 0,
                                   endCenter: CGPoint(x: b.x, y: b.y), endRadius: b.r * 1.05,
                                   options: [])
            ctx.restoreGState()

            let onBall: Bool = { if case .ball = b.support { return true }; return false }()
            let above = hasBallAbove.contains(b.id)
            if onBall && !above { drawFace(ctx, b) }   // góra bałwana
            if onBall && above { drawTorso(ctx, b) }   // środek bałwana
        }
    }

    private func drawFace(_ ctx: CGContext, _ b: Ball) {
        let r = b.r
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        for dx in [-0.3, 0.3] as [CGFloat] {
            let e = r * 0.09
            ctx.fillEllipse(in: CGRect(x: b.x + r * dx - e, y: b.y - r * 0.22 - e, width: e * 2, height: e * 2))
        }
        for k in 0..<5 {
            let a = CGFloat.pi * (0.25 + 0.125 * CGFloat(k))
            let d = r * 0.05
            let px = b.x + cos(a) * r * 0.45, py = b.y + r * 0.05 + sin(a) * r * 0.3
            ctx.fillEllipse(in: CGRect(x: px - d, y: py - d, width: d * 2, height: d * 2))
        }
        ctx.setFillColor(CGColor(red: 0.95, green: 0.5, blue: 0.1, alpha: 1))
        ctx.move(to: CGPoint(x: b.x, y: b.y - r * 0.1))
        ctx.addLine(to: CGPoint(x: b.x + r * 0.75, y: b.y + r * 0.02))
        ctx.addLine(to: CGPoint(x: b.x, y: b.y + r * 0.1))
        ctx.closePath()
        ctx.fillPath()
    }

    private func drawTorso(_ ctx: CGContext, _ b: Ball) {
        let r = b.r
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        for dy in [-0.35, 0, 0.35] as [CGFloat] {
            let d = r * 0.08
            ctx.fillEllipse(in: CGRect(x: b.x - d, y: b.y + r * dy - d, width: d * 2, height: d * 2))
        }
        ctx.setStrokeColor(CGColor(red: 0.4, green: 0.25, blue: 0.12, alpha: 1))
        ctx.setLineWidth(max(2, r * 0.08))
        ctx.setLineCap(.round)
        for s in [-1, 1] as [CGFloat] {
            let start = CGPoint(x: b.x + s * r * 0.85, y: b.y - r * 0.1)
            let end = CGPoint(x: b.x + s * r * 1.7, y: b.y - r * 0.75)
            ctx.move(to: start); ctx.addLine(to: end)
            let mid = CGPoint(x: (start.x + end.x) / 2 + s * r * 0.15, y: (start.y + end.y) / 2)
            ctx.move(to: mid); ctx.addLine(to: CGPoint(x: mid.x + s * r * 0.25, y: mid.y - r * 0.05))
            ctx.strokePath()
        }
    }
}
