import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

/// Globalny skrót klawiszowy przez Carbon — działa bez uprawnień Dostępności.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hk = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hk.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x534E_4F57), id: 1) // 'SNOW'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@main
@MainActor
struct SnowfallApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // bez ikony w Docku, tylko pasek menu
        app.run()
    }
}

/// Okno innej aplikacji, w globalnych współrzędnych CG (0,0 = lewy górny róg ekranu głównego).
struct WindowInfo {
    let id: Int
    let rect: CGRect
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlays: [NSWindow] = []
    private var views: [SnowView] = []
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var intensityItems: [NSMenuItem] = []

    private var intensity: Intensity = .medium
    private var effect: Effect = .snow
    private var effectItems: [NSMenuItem] = []

    // Podmuchy wiatru (wspólne dla wszystkich ekranów)
    private var gust: CGFloat = 0
    private var gustTarget: CGFloat = 0
    private var gustLeft: CGFloat = 0
    private var nextGust: CGFloat = .random(in: 15...40)
    private var running = true
    private var paused = false
    private var sculptMode = false      // tryb lepienia na stałe (z menu)
    private var interactive = false     // czy nakładki teraz przyjmują kliknięcia
    private var sculptItem: NSMenuItem!
    private var sculptHotKey: HotKey?

    private var timer: Timer?
    private var lastTime = CACurrentMediaTime()
    private var frameCount = 0
    private var windowList: [WindowInfo] = []
    private let myPID = Int(ProcessInfo.processInfo.processIdentifier)

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildOverlays()
        buildMenu()
        startLoop()

        // ⌥- (Option + minus) włącza/wyłącza tryb lepienia
        sculptHotKey = HotKey(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(optionKey)) { [weak self] in
            self?.toggleSculpt()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(screensSlept),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(screensWoke),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    // MARK: - Nakładki, po jednej na ekran

    private func buildOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        views = []
        guard let primary = NSScreen.screens.first else { return }

        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = !interactive  // kliknięcia przechodzą na wylot
            w.level = interactive ? .floating : .statusBar  // przy lepieniu pod paskiem menu
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            // brak .fullScreenAuxiliary => nakładka znika w aplikacjach pełnoekranowych

            // Lewy górny róg tego ekranu w globalnych współrzędnych CG
            let originCG = CGPoint(x: screen.frame.minX,
                                   y: primary.frame.maxY - screen.frame.maxY)
            let view = SnowView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                screenOriginCG: originCG)
            view.intensity = intensity
            view.effect = effect
            view.running = running
            view.interactive = interactive
            w.contentView = view
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()

            overlays.append(w)
            views.append(view)
        }
        for v in views {
            v.otherScreens = views.filter { $0 !== v }.map(\.globalRect)
        }
    }

    // MARK: - Pętla

    private func startLoop() {
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastTime, 0.05))
        lastTime = now
        guard !paused else { return }

        let refresh = frameCount % 4 == 0 // lista okien ~15 razy na sekundę
        if refresh { windowList = fetchWindows() }
        frameCount += 1

        updateInteractive()
        updateGust(dt)
        for v in views { v.tick(dt: dt, windows: windowList, refreshed: refresh, gust: gust) }
        handOff()
    }

    /// Przekazuje płatki i liście, które wyleciały za krawędź, na sąsiedni monitor.
    private func handOff() {
        guard views.count > 1 else {
            views.first?.outgoingFlakes.removeAll()
            views.first?.outgoingLeaves.removeAll()
            return
        }
        for v in views {
            for f in v.outgoingFlakes {
                let p = CGPoint(x: f.x, y: f.y)
                views.first(where: { $0 !== v && $0.globalRect.contains(p) })?.accept(flake: f)
            }
            for l in v.outgoingLeaves {
                let p = CGPoint(x: l.x, y: l.y)
                views.first(where: { $0 !== v && $0.globalRect.contains(p) })?.accept(leaf: l)
            }
            v.outgoingFlakes.removeAll()
            v.outgoingLeaves.removeAll()
        }
    }

    /// Co 20–60 s podmuch w losową stronę, trwający 2–4,5 s.
    private func updateGust(_ dt: CGFloat) {
        nextGust -= dt
        if nextGust <= 0 { startGust() }
        if gustLeft > 0 {
            gustLeft -= dt
            if gustLeft <= 0 { gustTarget = 0 }
        }
        gust += (gustTarget - gust) * min(1, dt * 1.2)
    }

    private func startGust() {
        gustTarget = (Bool.random() ? 1 : -1) * CGFloat.random(in: 120...260)
        gustLeft = .random(in: 2...4.5)
        nextGust = .random(in: 20...60)
    }

    /// Lepienie działa tylko po włączeniu trybu w menu.
    private func updateInteractive() {
        var want = sculptMode
        // nie wyłączaj w trakcie przeciągania, żeby kula nie "przykleiła się" do kursora
        if interactive && !want && NSEvent.pressedMouseButtons != 0 { want = true }
        guard want != interactive else { return }
        interactive = want
        overlays.forEach {
            $0.ignoresMouseEvents = !want
            // przy lepieniu nakładka schodzi pod pasek menu, żeby menu było klikalne
            $0.level = want ? .floating : .statusBar
        }
        views.forEach { $0.interactive = want }
    }

    private func fetchWindows() -> [WindowInfo] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        var result: [WindowInfo] = []
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int, pid != myPID,
                  let num = w[kCGWindowNumber as String] as? Int,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  rect.width >= 60, rect.height >= 40 else { continue }
            result.append(WindowInfo(id: num, rect: rect))
        }
        return result // od przedniego do tylnego
    }

    // MARK: - Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "snowflake",
                                           accessibilityDescription: "Efekty")

        let menu = NSMenu()

        toggleItem = NSMenuItem(title: "Włączone", action: #selector(toggleSnow), keyEquivalent: "s")
        toggleItem.target = self
        toggleItem.state = .on
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        for e in Effect.allCases {
            let item = NSMenuItem(title: e.title, action: #selector(setEffect(_:)), keyEquivalent: "\(e.rawValue + 1)")
            item.target = self
            item.tag = e.rawValue
            item.state = e == effect ? .on : .off
            menu.addItem(item)
            effectItems.append(item)
        }
        menu.addItem(.separator())

        let intensityMenu = NSMenu()
        for level in Intensity.allCases {
            let item = NSMenuItem(title: level.title, action: #selector(setIntensity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = level.rawValue
            item.state = level == intensity ? .on : .off
            intensityMenu.addItem(item)
            intensityItems.append(item)
        }
        let intensityRoot = NSMenuItem(title: "Intensywność", action: nil, keyEquivalent: "")
        intensityRoot.submenu = intensityMenu
        menu.addItem(intensityRoot)

        let gustItem = NSMenuItem(title: "Podmuch wiatru", action: #selector(gustNow), keyEquivalent: "w")
        gustItem.target = self
        menu.addItem(gustItem)

        menu.addItem(.separator())

        sculptItem = NSMenuItem(title: "Tryb lepienia   ⌥-", action: #selector(toggleSculpt), keyEquivalent: "")
        sculptItem.target = self
        menu.addItem(sculptItem)

        let clear = NSMenuItem(title: "Usuń bałwany", action: #selector(removeSnowmen), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let wallpaper = NSMenuItem(title: "Ustaw tapetę…", action: #selector(pickWallpaper), keyEquivalent: "t")
        wallpaper.target = self
        menu.addItem(wallpaper)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Zakończ", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func toggleSnow() {
        running.toggle()
        views.forEach { $0.running = running }
        toggleItem.state = running ? .on : .off
    }

    @objc private func setEffect(_ sender: NSMenuItem) {
        guard let e = Effect(rawValue: sender.tag) else { return }
        effect = e
        views.forEach { $0.effect = e }
        effectItems.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
    }

    @objc private func gustNow() { startGust() }

    @objc private func toggleSculpt() {
        sculptMode.toggle()
        sculptItem.state = sculptMode ? .on : .off
    }

    @objc private func removeSnowmen() { views.forEach { $0.removeAllBalls() } }

    @objc private func setIntensity(_ sender: NSMenuItem) {
        guard let level = Intensity(rawValue: sender.tag) else { return }
        intensity = level
        views.forEach { $0.intensity = level }
        intensityItems.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
    }

    @objc private func pickWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.message = "Wybierz tapetę"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
    }

    // MARK: - Zdarzenia systemowe

    @objc private func screensChanged() { buildOverlays() } // podłączenie/odłączenie monitora

    @objc private func screensSlept() { paused = true }

    @objc private func screensWoke() {
        paused = false
        lastTime = CACurrentMediaTime()
    }
}
