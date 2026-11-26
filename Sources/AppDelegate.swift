import Foundation
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var overlayWindow: OverlayWindow!
    private var renderTimer: Timer?
    private var windowWatchdogTimer: Timer?
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var lastFullscreenCheckTime: CFTimeInterval = 0
    private var hiddenByFullscreen = false
    private var ticksSinceLastRedraw = 0
    private var lastDemoKeyTime: CFTimeInterval = 0
    private var isPetVisible = true
    private var isHandingOverToNewerCopy = false
    private var dressingRoom: DressingRoomWindowController?
    private var settingsWindow: SettingsWindowController?

    private var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.4.3"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if resolveDuplicateRunningCopies() { return }

        overlayWindow = OverlayWindow()
        overlayWindow.orderFrontRegardless()
        WorkModeExperience.shared.attach(to: overlayWindow)

        let catView = overlayWindow.catView
        catView.onRequestPermission = { [weak self] in
            self?.openInputMonitoringSettings()
        }
        catView.onRightClickMenu = { [weak self] event in
            guard let self else { return }
            let menu = self.buildMenu()
            NSMenu.popUpContextMenu(menu, with: event, for: self.overlayWindow.catView)
        }
        catView.onDropSkinFiles = { [weak self] urls in
            for url in urls { self?.importDroppedFile(from: url) }
        }

        // Wire dual-layer InputEngine -> CatPhysics
        let engine = InputEngine.shared
        engine.onKeyDown = { [weak self] key in
            DispatchQueue.main.async {
                guard !WorkModeExperience.shared.ignoresPhysicalKeyboard else { return }
                self?.overlayWindow.catView.physics.triggerKeyDown(key)
            }
        }
        engine.onMouseClick = { [weak self] button, isDown in
            DispatchQueue.main.async {
                self?.overlayWindow.catView.physics.triggerMouseClick(button: button, isDown: isDown)
            }
        }
        engine.start()

        setupStatusItem()
        if isAutoStartEnabled() {
            // Keep LaunchAgent path updated if user moved KuroCat.app into /Applications
            _ = setAutoStartEnabled(true)
        }
        startRenderLoop()
        startWindowWatchdog()


    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting during launch because a newer copy is running: leave its stats alone.
        if isHandingOverToNewerCopy { return }
        WorkModeExperience.shared.shutdown()
        renderTimer?.invalidate()
        windowWatchdogTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        InputEngine.shared.flushStats()
        InputEngine.shared.stop()
    }

    // MARK: - One KuroCat at a time (newest copy wins)

    /// Users often download a new KuroCat.app while an older copy is still running (or is started
    /// by the login item from another folder). That old process kept running and kept announcing
    /// "new version available" even though they had already updated. Keep only the newest copy:
    /// quit older ones, or hand over to an already-running newer one. Returns true if THIS process quits.
    private func resolveDuplicateRunningCopies() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myURL = Bundle.main.bundleURL.standardizedFileURL
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        if others.isEmpty { return false }

        for other in others {
            guard let otherURL = other.bundleURL?.standardizedFileURL, otherURL != myURL,
                  let otherVersion = Self.shortVersion(ofAppAt: otherURL) else { continue }
            if isVersion(otherVersion, newerThan: currentAppVersion) {
                isHandingOverToNewerCopy = true
                _ = other.activate(options: [])
                NSApp.terminate(nil)
                return true
            }
        }
        for other in others {
            // Same path (replaced in place by an update) or an older/equal copy elsewhere.
            if !other.terminate() { _ = other.forceTerminate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if !other.isTerminated { _ = other.forceTerminate() }
            }
        }
        return false
    }

    /// Reads CFBundleShortVersionString straight from disk (Bundle(url:) may return cached info).
    private static func shortVersion(ofAppAt url: URL) -> String? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any] else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    /// A newer KuroCat.app that is already on disk (e.g. downloaded to ~/Downloads but never
    /// launched because LaunchServices just re-activated this running copy).
    private func newestDownloadedCopy() -> (url: URL, version: String)? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let myURL = Bundle.main.bundleURL.standardizedFileURL
        var best: (url: URL, version: String)?
        let appURLs: [URL]
        if #available(macOS 12.0, *) {
            appURLs = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
        } else {
            appURLs = (LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL]) ?? []
        }
        for url in appURLs {
            let std = url.standardizedFileURL
            guard std != myURL, !std.path.contains("/.Trash/"),
                  let v = Self.shortVersion(ofAppAt: std),
                  isVersion(v, newerThan: best?.version ?? currentAppVersion) else { continue }
            best = (std, v)
        }
        return best
    }

    private func switchToDownloadedCopy(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            DispatchQueue.main.async {
                if error == nil { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: - Adaptive Redraw

    private func startRenderLoop() {
        lastFrameTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.isPetVisible else { return }
            let now = CACurrentMediaTime()
            let dt = CGFloat(now - self.lastFrameTime)
            self.lastFrameTime = now

            // Fullscreen auto-hide check (~2Hz)
            if now - self.lastFullscreenCheckTime > 0.5 {
                self.lastFullscreenCheckTime = now
                let s = CatSettings.shared
                let obsBg = (s.obsCaptureMode > 0 && s.obsHideDesktop)
                if s.autoHideFullscreen && !obsBg {
                    let fs = Self.isOtherAppFullscreen()
                    if fs != self.hiddenByFullscreen {
                        self.hiddenByFullscreen = fs
                        self.overlayWindow.alphaValue = fs ? 0.0 : 1.0
                        if fs { self.overlayWindow.ignoresMouseEvents = true }
                    }
                } else if self.hiddenByFullscreen {
                    self.hiddenByFullscreen = false
                    self.overlayWindow.alphaValue = 1.0
                }
            }

            let view = self.overlayWindow.catView
            let physics = view.physics
            let input = InputEngine.shared
            let windowFrame = self.overlayWindow.frame
            let previousMouseMoveTime = input.lastMouseMoveTime
            let wasBlinking = physics.isBlinking
            let wasYawning = physics.isYawning
            WorkModeExperience.shared.step(dt: dt, window: self.overlayWindow)
            view.alignScruffBackToCursor()
            view.updateHoverAndClickThrough()

            // Track the mouse at 60 Hz. Ordinary movement away from the pet can share the idle redraw cadence.
            let lastDirectInput = max(input.lastKeyActivityTime, input.lastMouseClickTime, self.lastDemoKeyTime)
            let mouseMoving = now - input.lastMouseMoveTime < 0.12
            let mouseStartedMoving = mouseMoving && now - previousMouseMoveTime >= 0.12
            let mouseNearPet = mouseMoving && windowFrame.insetBy(dx: -24, dy: -24).contains(input.lastMouseLocation)
            let isAsleep = physics.sleepiness >= 0.95
            let isActive = CatSettings.shared.isWorkMode || WorkModeExperience.shared.isTransitioning || now - lastDirectInput < 0.8 || !input.activeKeys.isEmpty
                || mouseStartedMoving || mouseNearPet
                || input.leftMouseDown || input.rightMouseDown || input.otherMouseDown || view.isDraggingOrResizing
                || !physics.keyGlow.isEmpty || !physics.floatingKeycaps.isEmpty
                || physics.petHeadIntensity > 0.02 || physics.huntIntensity.value > 0.02
                || physics.scruffDrag.value > 0.02 || physics.lieIntensity.value > 0.02
                || physics.angerIntensity.value > 0.02 || physics.dizzyIntensity.value > 0.02
                || physics.scruffDizzyIntensity.value > 0.02
                || wasYawning || physics.isYawning || (!isAsleep && (wasBlinking || physics.isBlinking))
            let ticksPerRedraw = isActive ? 1 : (isAsleep ? 3 : 2) // 60, 20, or 30 FPS on a 60 Hz tick.
            self.ticksSinceLastRedraw += 1
            // Give small idle movements time to accumulate, but refresh at least every 100 ms.
            if self.ticksSinceLastRedraw >= ticksPerRedraw &&
                (isActive || self.ticksSinceLastRedraw >= 6 || view.poseNeedsDisplay()) {
                self.ticksSinceLastRedraw = 0
                view.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    // MARK: - Menu Bar Icon & Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = makeMenuBarCatIcon()
            button.toolTip = "KuroCatWork 桌宠与 AI 工作助手"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in buildMenu().items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let engine = InputEngine.shared
        let settings = CatSettings.shared
        let physics = overlayWindow.catView.physics
        let en = settings.isEnglish

        func tr(_ zh: String, _ eng: String) -> String { en ? eng : zh }

        // Status header
        let statusPrefix = engine.status.needsAttention ? "⚠️" : "🟢"
        let statusText: String
        if en {
            switch engine.status {
            case .fullHardware: statusText = "Hardware Input Active (HID + EventTap)"
            case .hidOnly: statusText = "Hardware HID Active"
            case .eventTapOnly: statusText = "Global EventTap Active"
            case .needsPermission: statusText = "Input Monitoring Permission Needed"
            case .needsRestart: statusText = "Authorized — Restart to Retry"
            }
        } else {
            statusText = engine.status.rawValue
        }
        let statusItem = NSMenuItem(title: "\(statusPrefix) \(statusText)", action: engine.status.needsAttention ? #selector(openInputMonitoringSettings) : nil, keyEquivalent: "")
        statusItem.target = self
        menu.addItem(statusItem)

        if engine.status == .needsPermission {
            let grantItem = NSMenuItem(title: tr("🔑 前往系统设置开启「输入监控」...", "🔑 Open Input Monitoring Settings..."), action: #selector(openInputMonitoringSettings), keyEquivalent: "")
            grantItem.target = self
            menu.addItem(grantItem)
        }

        // Live stats
        let statsTitle = en
            ? "⌨️ Today \(engine.totalKeystrokesToday)  ·  KPM \(engine.currentKPM)  ·  Pets \(physics.totalPetSessions)"
            : "⌨️ 今日击键 \(engine.totalKeystrokesToday)  ·  KPM \(engine.currentKPM)  ·  摸猫 \(physics.totalPetSessions) 次"
        let statsItem = NSMenuItem(title: statsTitle, action: nil, keyEquivalent: "")
        statsItem.isEnabled = false
        menu.addItem(statsItem)

        menu.addItem(.separator())

        // Essential everyday actions only — everything else lives cleanly in the unified Settings window!
        let visItem = NSMenuItem(title: isPetVisible ? tr("隐藏桌宠", "Hide Pet") : tr("显示桌宠", "Show Pet"), action: #selector(toggleVisibility), keyEquivalent: "")
        visItem.target = self
        menu.addItem(visItem)

        let modeItem = NSMenuItem(title: settings.isWorkMode
            ? tr("✓ 工作模式（双击切换）", "✓ Work Mode (Double-Click)")
            : tr("普通模式（双击切换）", "Companion Mode (Double-Click)"),
            action: #selector(toggleWorkMode), keyEquivalent: "")
        modeItem.target = self
        menu.addItem(modeItem)
        menu.addItem(WorkModeExperience.shared.menuItem())
        let adjustmentMenu = NSMenu()
        let controlsItem = NSMenuItem()
        controlsItem.view = SizeDirectionMenuView(english: en, scale: settings.scale, rotation: settings.rotationDeg,
            onScale: { [weak self] value in
                self?.overlayWindow.applyScale(value)
                self?.overlayWindow.catView.needsDisplay = true
            }, onRotation: { [weak self] value in
                CatSettings.shared.rotationDeg = value
                self?.overlayWindow.catView.needsDisplay = true
            })
        adjustmentMenu.addItem(controlsItem)
        let adjustmentItem = NSMenuItem(title: tr("调整大小与方向", "Size & Direction"), action: nil, keyEquivalent: "")
        adjustmentItem.submenu = adjustmentMenu
        menu.addItem(adjustmentItem)

        // Quick Cat Skin switcher submenu
        let coatMenu = NSMenu()
        let library = SkinLibrary.shared
        let customActive = library.skin(id: settings.customSkin) != nil
        for coat in CatCoatTheme.allCases {
            let coatTitle: String
            if en {
                switch coat {
                case .classicBlack: coatTitle = "Classic Black Cat"
                case .siamese: coatTitle = "Siamese Cat"
                case .shorthair: coatTitle = "Silver Tabby Shorthair"
                case .orangeWhite: coatTitle = "Orange & White Cat"
                }
            } else {
                coatTitle = coat.rawValue
            }
            let item = NSMenuItem(title: coatTitle, action: #selector(selectCoatTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = coat.rawValue
            item.state = !customActive && settings.coatTheme == coat ? .on : .off
            coatMenu.addItem(item)
        }
        if !library.skins.isEmpty {
            coatMenu.addItem(.separator())
            for skin in library.skins {
                let item = NSMenuItem(title: skin.name, action: #selector(selectCustomSkin(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = skin.id
                item.state = settings.customSkin == skin.id ? .on : .off
                if !skin.author.isEmpty { item.toolTip = tr("作者：\(skin.author)", "Author: \(skin.author)") }
                coatMenu.addItem(item)
            }
        }
        coatMenu.addItem(.separator())
        let importItem = NSMenuItem(title: tr("导入皮肤…", "Import Skin…"), action: #selector(showDressingRoom), keyEquivalent: "")
        importItem.target = self
        coatMenu.addItem(importItem)
        let workshopItem = NSMenuItem(title: tr("打开皮肤工坊…", "Open Skin Workshop…"), action: #selector(openSkinWorkshop), keyEquivalent: "")
        workshopItem.target = self
        coatMenu.addItem(workshopItem)
        let openDirItem = NSMenuItem(title: tr("打开皮肤文件夹", "Open Skins Folder"), action: #selector(openSkinsFolder), keyEquivalent: "")
        openDirItem.target = self
        coatMenu.addItem(openDirItem)
        if !library.skins.isEmpty {
            let deleteMenu = NSMenu()
            for skin in library.skins {
                let item = NSMenuItem(title: skin.name, action: #selector(deleteCustomSkin(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = skin.id
                deleteMenu.addItem(item)
            }
            let deleteParent = NSMenuItem(title: tr("删除皮肤", "Delete Skin"), action: nil, keyEquivalent: "")
            deleteParent.submenu = deleteMenu
            coatMenu.addItem(deleteParent)
        }
        let coatParent = NSMenuItem(title: tr("猫咪皮肤 🐱", "Cat Skin 🐱"), action: nil, keyEquivalent: "")
        coatParent.submenu = coatMenu
        menu.addItem(coatParent)

        let settingsItem = NSMenuItem(title: tr("⚙️ 设置…", "⚙️ Settings…"), action: #selector(openSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let relaunchItem = NSMenuItem(title: tr("重启 KuroCatWork (授权后刷新)", "Restart KuroCatWork"), action: #selector(relaunchApp), keyEquivalent: "")
        relaunchItem.target = self
        menu.addItem(relaunchItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: tr("退出 KuroCatWork", "Quit KuroCatWork"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func openSettingsWindow() {
        if settingsWindow == nil {
            let ctrl = SettingsWindowController()
            ctrl.onSettingsChanged = { [weak self] in
                self?.overlayWindow.catView.needsDisplay = true
                self?.dressingRoom?.refresh()
            }
            ctrl.onScaleChanged = { [weak self] newScale in
                self?.overlayWindow.applyScale(newScale)
            }
            ctrl.onResetPoseAndPosition = { [weak self] in
                self?.overlayWindow.applyScale(1.0)
                self?.overlayWindow.resetPosition()
                self?.overlayWindow.catView.needsDisplay = true
            }
            ctrl.onOpenDressingRoom = { [weak self] in
                self?.showDressingRoom()
            }
            ctrl.onImportKeyboardSkin = { [weak self] in
                self?.promptImportKeyboardSkin()
            }
            ctrl.onApplyWindowLevel = { [weak self] in
                self?.overlayWindow.applyWindowLevelAndBehavior()
                self?.syncWindowTopmost()
            }
            ctrl.onApplyOBSMode = { [weak self] in
                self?.overlayWindow.applyOBSMode()
            }
            ctrl.onAutoHideChanged = { [weak self] in
                guard let self else { return }
                if !CatSettings.shared.autoHideFullscreen && self.hiddenByFullscreen {
                    self.hiddenByFullscreen = false
                    self.overlayWindow.alphaValue = 1.0
                }
            }
            ctrl.getAutoStart = { [weak self] in
                self?.isAutoStartEnabled() ?? false
            }
            ctrl.setAutoStart = { [weak self] on in
                _ = self?.setAutoStartEnabled(on)
            }
            ctrl.onLanguageChanged = { [weak self] in
                self?.overlayWindow.catView.needsDisplay = true
            }
            settingsWindow = ctrl
        }
        settingsWindow?.present()
    }

    // MARK: - Actions

    @objc private func openInputMonitoringSettings() {
        if InputEngine.shared.status == .needsRestart {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "已授权，键盘监听启动失败"
            alert.informativeText = "请重启 KuroCatWork，让系统重新建立键盘监听。\n当前程序位置：\(Bundle.main.bundlePath)"
            alert.addButton(withTitle: "重启 KuroCatWork")
            alert.addButton(withTitle: "打开输入监控")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                relaunchApp()
                return
            }
            if response != .alertSecondButtonReturn { return }
        }
        InputEngine.shared.requestPermissionsAndOpenSettings()
    }

    @objc private func toggleVisibility() {
        isPetVisible.toggle()
        if isPetVisible {
            lastFrameTime = CACurrentMediaTime()
            ticksSinceLastRedraw = 0
            overlayWindow.catView.needsDisplay = true
            overlayWindow.orderFrontRegardless()
        } else {
            overlayWindow.orderOut(nil)
            WorkModeExperience.shared.hidePanels()
        }
    }

    @objc private func selectTabletMode(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? Int {
            CatSettings.shared.tabletMode = mode
            overlayWindow.catView.needsDisplay = true
        }
    }

    @objc private func toggleClickThrough() {
        CatSettings.shared.fullClickThrough.toggle()
    }

    @objc private func toggleFullScreenOverlay() {
        CatSettings.shared.fullScreenOverlay.toggle()
        overlayWindow.applyWindowLevelAndBehavior()
        syncWindowTopmost()
    }

    // MARK: - Topmost Watchdog (Space / App Activation)

    private func startWindowWatchdog() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleWorkspaceStateChanged),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleWorkspaceStateChanged),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)

        windowWatchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.syncWindowTopmost()
        }
        RunLoop.main.add(timer, forMode: .common)
        windowWatchdogTimer = timer
    }

    @objc private func handleWorkspaceStateChanged() {
        syncWindowTopmost()
    }

    private func syncWindowTopmost() {
        guard let overlayWindow, isPetVisible, !hiddenByFullscreen else { return }
        let s = CatSettings.shared
        let obsBg = (s.obsCaptureMode > 0 && s.obsHideDesktop)
        if obsBg { return }
        if s.fullScreenOverlay {
            overlayWindow.orderFrontRegardless()
        }
    }

    // MARK: - Launch at Login (macOS LaunchAgent — works reliably for signed & ad-hoc builds)

    private var launchAgentURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return dir.appendingPathComponent("com.chanke.kurocat.plist")
    }

    private func isAutoStartEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    @discardableResult
    private func setAutoStartEnabled(_ enable: Bool) -> Bool {
        let fm = FileManager.default
        let url = launchAgentURL
        if enable {
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let appPath = Bundle.main.bundlePath
                let plist: [String: Any] = [
                    "Label": "com.chanke.kurocat",
                    "ProgramArguments": ["/usr/bin/open", "-a", appPath],
                    "RunAtLoad": true,
                    "KeepAlive": false
                ]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        } else {
            do {
                if fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                }
                return true
            } catch {
                return false
            }
        }
    }

    @objc private func toggleAutoStart() {
        _ = setAutoStartEnabled(!isAutoStartEnabled())
    }

    @objc private func toggleKeyBadges() {
        CatSettings.shared.showKeyBadges.toggle()
    }

    @objc private func toggleMouseBadges() {
        CatSettings.shared.showMouseBadges.toggle()
    }

    @objc private func toggleKeyLegends() {
        CatSettings.shared.showKeyLegends.toggle()
    }

    @objc private func toggleFootEgg() {
        CatSettings.shared.footEasterEgg.toggle()
    }

    @objc private func toggleTailEgg() {
        CatSettings.shared.tailEasterEgg.toggle()
    }

    @objc private func togglePetInteraction() {
        CatSettings.shared.petInteraction.toggle()
    }

    @objc private func selectOBSCaptureMode(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        CatSettings.shared.obsCaptureMode = num.intValue
        if num.intValue == 0 {
            CatSettings.shared.obsHideDesktop = false
        }
        overlayWindow.applyOBSMode()
    }

    @objc private func toggleOBSHideDesktop() {
        CatSettings.shared.obsHideDesktop.toggle()
        overlayWindow.applyOBSMode()
    }

    @objc private func toggleAutoHideFullscreen() {
        CatSettings.shared.autoHideFullscreen.toggle()
        if !CatSettings.shared.autoHideFullscreen && hiddenByFullscreen {
            hiddenByFullscreen = false
            overlayWindow.alphaValue = 1.0
        }
    }

    private static func isOtherAppFullscreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              front.bundleIdentifier != "com.apple.finder" else {
            return false
        }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let pid = front.processIdentifier
        for w in list {
            guard let ownerPID = w[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            for screen in NSScreen.screens {
                if rect.width >= screen.frame.width - 2 && rect.height >= screen.frame.height - 2 {
                    return true
                }
            }
        }
        return false
    }

    @objc private func toggleWorkMode() {
        CatSettings.shared.isEditMode = false
        CatSettings.shared.isWorkMode.toggle()
        overlayWindow.catView.needsDisplay = true
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        CatSettings.shared.language = code
        overlayWindow.catView.needsDisplay = true
    }

    @objc private func selectScale(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        overlayWindow.applyScale(CGFloat(num.doubleValue))
    }

    @objc private func selectCoatTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let coat = CatCoatTheme(rawValue: raw) else { return }
        CatSettings.shared.customSkin = ""
        CatSettings.shared.coatTheme = coat
        // Auto-pair signature eye color (still freely overridable via 瞳色切换!)
        switch coat {
        case .classicBlack:
            CatSettings.shared.eyeTheme = .neonChartreuse
        case .siamese:
            CatSettings.shared.eyeTheme = .siameseBlue
        case .shorthair:
            CatSettings.shared.eyeTheme = .referenceHazel
        case .orangeWhite:
            CatSettings.shared.eyeTheme = .warmAmber
        }
        dressingRoom?.refresh()
        settingsWindow?.refresh()
    }

    // MARK: - Imported skins (换装间)

    private static let skinWorkshopURLString = "https://chanke17.github.io/KuroCat-Workshop/"
    private static let keyboardPlazaURLString = "https://chanke17.github.io/KuroCat-Workshop/#keyboards"

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            importDroppedFile(from: url)
        }
    }

    private func importDroppedFile(from url: URL) {
        if KeyboardSkinSpec.looksLikeKeyboardJSON(url) {
            importKeyboardSkin(from: url)
        } else if url.pathExtension.lowercased() == "kurocat" {
            importSkin(from: url)
        }
    }

    @objc private func openSkinWorkshop() {
        if let url = URL(string: Self.skinWorkshopURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSkinsFolder() {
        let dir = SkinLibrary.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func showDressingRoom() {
        if dressingRoom == nil {
            let controller = DressingRoomWindowController()
            controller.onImport = { [weak self] url in self?.importSkin(from: url) }
            dressingRoom = controller
        }
        dressingRoom?.present()
    }

    /// Validates and stores a `.kurocat`, then wears it. Invalid files get a Chinese explanation.
    private func importSkin(from url: URL) {
        do {
            let id = try SkinLibrary.shared.importFile(url)
            CatSettings.shared.customSkin = id
            let skin = SkinLibrary.shared.skin(id: id)
            var message = "已换上「\(skin?.name ?? "新皮肤")」"
            if let author = skin?.author, !author.isEmpty { message += "（作者：\(author)）" }
            dressingRoom?.setStatus("✓ " + message, kind: 1)
            dressingRoom?.refresh()
            settingsWindow?.refresh()
        } catch {
            let reason = error.localizedDescription
            // With 换装间 open the red status line explains it in place; an alert is only for drops onto the cat.
            if let room = dressingRoom, room.isVisible {
                room.setStatus("没能导入「\(url.lastPathComponent)」：\(reason)", kind: 2)
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "无法导入这个皮肤"
            alert.informativeText = "「\(url.lastPathComponent)」：\(reason)"
            alert.addButton(withTitle: "知道了")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func selectCustomSkin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        CatSettings.shared.customSkin = id
        dressingRoom?.refresh()
        settingsWindow?.refresh()
    }

    @objc private func deleteCustomSkin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let skin = SkinLibrary.shared.skin(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "删除皮肤「\(skin.name)」？"
        alert.informativeText = "会从皮肤文件夹里删除这个文件，删除后需要重新导入。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !SkinLibrary.shared.remove(id: id) {
            let failed = NSAlert()
            failed.messageText = "删除失败"
            failed.informativeText = "无法删除 \(SkinLibrary.directory.appendingPathComponent("\(id).kurocat").path)"
            failed.runModal()
            return
        }
        if CatSettings.shared.customSkin == id { CatSettings.shared.customSkin = "" }
        dressingRoom?.refresh()
        settingsWindow?.refresh()
    }

    @objc private func selectKeyboardTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let theme = KeyboardTheme(rawValue: raw) else { return }
        CatSettings.shared.customKeyboard = ""
        CatSettings.shared.keyboardTheme = theme
    }

    @objc private func selectCustomKeyboard(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        CatSettings.shared.customKeyboard = id
    }

    @objc private func openKeyboardPlaza() {
        if let url = URL(string: Self.keyboardPlazaURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openKeyboardsFolder() {
        let dir = KeyboardSkinLibrary.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func promptImportKeyboardSkin() {
        let en = CatSettings.shared.isEnglish
        let panel = NSOpenPanel()
        panel.title = en ? "Choose Keyboard Skin (.kurokb / .json)" : "选择键盘皮肤文件 (.kurokb / .json)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["kurokb", "json"]
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            importKeyboardSkin(from: url)
        }
    }

    private func importKeyboardSkin(from url: URL) {
        do {
            let id = try KeyboardSkinLibrary.shared.importFile(url)
            CatSettings.shared.customKeyboard = id
            let kb = KeyboardSkinLibrary.shared.skin(id: id)
            var message = "已换上键盘皮肤「\(kb?.name ?? "新键盘")」"
            if let author = kb?.author, !author.isEmpty { message += "（作者：\(author)）" }
            dressingRoom?.setStatus("✓ " + message, kind: 1)
            overlayWindow.catView.needsDisplay = true
            settingsWindow?.refresh()
        } catch {
            let en = CatSettings.shared.isEnglish
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = en ? "Failed to Import Keyboard Skin" : "无法导入这个键盘皮肤"
            alert.informativeText = "「\(url.lastPathComponent)」：\(error.localizedDescription)"
            alert.addButton(withTitle: en ? "OK" : "知道了")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func deleteCustomKeyboard(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let kb = KeyboardSkinLibrary.shared.skin(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "删除键盘皮肤「\(kb.name)」？"
        alert.informativeText = "会从键盘皮肤文件夹里删除这个文件，删除后需要重新导入。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !KeyboardSkinLibrary.shared.remove(id: id) {
            let failed = NSAlert()
            failed.messageText = "删除失败"
            failed.informativeText = "无法删除 \(KeyboardSkinLibrary.directory.appendingPathComponent("\(id).kurokb").path)"
            failed.runModal()
            return
        }
        if CatSettings.shared.customKeyboard == id { CatSettings.shared.customKeyboard = "" }
        settingsWindow?.refresh()
    }

    @objc private func selectEyeTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let theme = EyeColorTheme(rawValue: raw) else { return }
        CatSettings.shared.eyeTheme = theme
    }

    @objc private func resetPosition() {
        overlayWindow.resetPosition()
    }

    @objc private func runDemoBurst() {
        let keys: [PhysicalKey] = [.w, .a, .s, .d, .f, .j, .o, .e, .space, .leftShift]
        for (idx, k) in keys.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(idx) * 0.13) { [weak self] in
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.lastDemoKeyTime = now
                self.overlayWindow.catView.physics.triggerKeyDown(k, at: now)
            }
        }
    }

    @objc private func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        func parse(_ v: String) -> [Int] {
            let trimmed = v.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            return trimmed.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let a = parse(lhs)
        let b = parse(rhs)
        let count = max(a.count, b.count)
        for i in 0..<count {
            let va = i < a.count ? a[i] : 0
            let vb = i < b.count ? b[i] : 0
            if va != vb { return va > vb }
        }
        return false
    }

    private func showInfoAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - Crisp Vector Menu Bar Cat Silhouette Icon

    private func makeMenuBarCatIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)

            // Cute cat head silhouette with ears
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 3.0, y: 8.5))
            path.addLine(to: CGPoint(x: 3.5, y: 2.5))
            path.addLine(to: CGPoint(x: 7.2, y: 6.0))
            path.addQuadCurve(to: CGPoint(x: 10.8, y: 6.0), control: CGPoint(x: 9.0, y: 5.5))
            path.addLine(to: CGPoint(x: 14.5, y: 2.5))
            path.addLine(to: CGPoint(x: 15.0, y: 8.5))
            path.addCurve(to: CGPoint(x: 9.0, y: 15.5), control1: CGPoint(x: 16.0, y: 12.8), control2: CGPoint(x: 13.0, y: 15.5))
            path.addCurve(to: CGPoint(x: 3.0, y: 8.5), control1: CGPoint(x: 5.0, y: 15.5), control2: CGPoint(x: 2.0, y: 12.8))
            path.closeSubpath()

            // Punch out cute cat eyes
            path.addEllipse(in: CGRect(x: 5.4, y: 8.8, width: 2.4, height: 2.2))
            path.addEllipse(in: CGRect(x: 10.2, y: 8.8, width: 2.4, height: 2.2))

            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// Native menu sliders free double-click for companion/work mode switching.
final class SizeDirectionMenuView: NSView {
    private let scaleSlider: NSSlider
    private let rotationSlider: NSSlider
    private let scaleLabel = NSTextField(labelWithString: "")
    private let rotationLabel = NSTextField(labelWithString: "")
    private let onScale: (CGFloat) -> Void
    private let onRotation: (CGFloat) -> Void

    init(english: Bool, scale: CGFloat, rotation: CGFloat,
         onScale: @escaping (CGFloat) -> Void, onRotation: @escaping (CGFloat) -> Void) {
        self.onScale = onScale
        self.onRotation = onRotation
        scaleSlider = NSSlider(value: Double(scale), minValue: 0.45, maxValue: 2.0, target: nil, action: nil)
        rotationSlider = NSSlider(value: Double(rotation), minValue: -180, maxValue: 180, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 292, height: 130))
        let rows: [(String, NSSlider, NSTextField, CGFloat)] = [
            (english ? "Size" : "大小", scaleSlider, scaleLabel, 88),
            (english ? "Direction" : "方向", rotationSlider, rotationLabel, 40)
        ]
        for (title, slider, valueLabel, y) in rows {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 14, y: y + 15, width: 165, height: 20)
            label.font = .menuFont(ofSize: 12)
            addSubview(label)
            valueLabel.frame = NSRect(x: 210, y: y + 15, width: 65, height: 20)
            valueLabel.alignment = .right
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            addSubview(valueLabel)
            slider.frame = NSRect(x: 14, y: y - 5, width: 264, height: 22)
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(sliderChanged(_:))
            slider.setAccessibilityLabel(title)
            addSubview(slider)
        }
        let reset = NSButton(title: english ? "Reset size & direction" : "重置大小与方向", target: self, action: #selector(resetValues))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.frame = NSRect(x: 64, y: 2, width: 164, height: 24)
        addSubview(reset)
        updateLabels()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func updateLabels() {
        scaleLabel.stringValue = "\(Int((scaleSlider.doubleValue * 100).rounded()))%"
        rotationLabel.stringValue = "\(Int(rotationSlider.doubleValue.rounded()))°"
    }
    @objc private func sliderChanged(_ sender: NSSlider) {
        if sender === scaleSlider { onScale(CGFloat(sender.doubleValue)) }
        else { onRotation(CGFloat(sender.doubleValue)) }
        updateLabels()
    }
    @objc private func resetValues() {
        scaleSlider.doubleValue = 1
        rotationSlider.doubleValue = 0
        onScale(1)
        onRotation(0)
        updateLabels()
    }
}
