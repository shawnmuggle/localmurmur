import AppKit
import SwiftUI
import AVFoundation
import MurmurCore

// NSWindow that closes itself when ESC is pressed
private class EscapableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

// Wrapper that holds config as @State so SwiftUI re-renders immediately on
// every picker/toggle change, without waiting for an explicit Save press.
@MainActor
private struct SettingsRoot: View {
    @State var config: AppConfig
    let onSave: () -> Void
    let onConfigChange: (AppConfig) -> Void

    var body: some View {
        SettingsView(
            config: Binding(get: { config }, set: { config = $0; onConfigChange($0) }),
            onSave: onSave
        )
    }
}

private enum MicrophoneFailure: Error {
    case permissionDenied
    case permissionRestricted
    case noInputDevice
    case selectedDeviceUnavailable
    case startFailed(String)

    var title: String {
        switch self {
        case .permissionDenied, .permissionRestricted:
            return L("alert.microphone.permission.title")
        case .noInputDevice:
            return L("alert.microphone.no_device.title")
        case .selectedDeviceUnavailable:
            return L("alert.microphone.selected_unavailable.title")
        case .startFailed:
            return L("alert.microphone.start_failed.title")
        }
    }

    var message: String {
        switch self {
        case .permissionDenied:
            return L("alert.microphone.permission.message")
        case .permissionRestricted:
            return L("alert.microphone.restricted.message")
        case .noInputDevice:
            return L("alert.microphone.no_device.message")
        case .selectedDeviceUnavailable:
            return L("alert.microphone.selected_unavailable.message")
        case .startFailed(let detail):
            return String(format: L("alert.microphone.start_failed.message"), detail)
        }
    }

    var canOpenSettings: Bool {
        switch self {
        case .permissionDenied, .permissionRestricted:
            return true
        case .noInputDevice, .selectedDeviceUnavailable, .startFailed:
            return false
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var floatingWindow: FloatingWindow!
    private var settingsWindow: NSWindow?
    private var historyWindow:  NSWindow?
    private var hotwordsWindow: NSWindow?
    private var statsWindow:    NSWindow?
    private var statusItem: NSStatusItem!
    private var ptt: PushToTalk!
    private var keyboard: KeyboardMonitor!
    private var audio: AudioCapture!
    private var accessibilityRetryTimer: Timer?
    private var micSleepTimer: Timer?  // releases the warm mic engine after idle
    private var microphoneAlertVisible = false
    private var pttStartInProgress = false
    private let configStore   = ConfigStore()
    private let historyStore  = HistoryStore()
    private let hotwordStore  = HotwordStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // no Dock icon

        floatingWindow = FloatingWindow()

        ptt = PushToTalk(config: configStore.config)
        setupPTTCallbacks()
        setupAudio()
        setupTray()

        // Request microphone permission first, then keyboard (accessibility).
        // Accessibility prompt opens System Settings which steals focus and
        // prevents the microphone dialog from appearing, so mic must go first.
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            if !granted {
                fputs("[murmur] microphone permission denied\n", stderr)
                DispatchQueue.main.async {
                    self?.showMicrophoneFailureAlert(.permissionDenied)
                }
            }
            // The capture engine is started lazily on first PTT press and kept warm
            // only between presses (idle auto-sleep), so the mic isn't held open the
            // whole time the app runs. See onPTTStart / onPTTStop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.setupKeyboard()
            }
        }
    }

    // MARK: - PTT callbacks

    private func setupPTTCallbacks() {
        ptt.onStatusChange = { [weak self] status in
            guard let self = self else { return }
            self.floatingWindow.update(
                status: status,
                text: self.ptt.currentText,
                levels: self.ptt.audioLevels
            )
            // Record completed transcription to history
            if status == .done {
                let text = self.ptt.currentText
                self.historyStore.add(text: text)
            }
        }
        ptt.onTextChange = { [weak self] text in
            guard let self = self else { return }
            self.floatingWindow.update(
                status: self.ptt.status,
                text: text,
                levels: self.ptt.audioLevels
            )
        }
        ptt.onAudioLevels = { [weak self] levels in
            guard let self = self else { return }
            self.floatingWindow.update(
                status: self.ptt.status,
                text: self.ptt.currentText,
                levels: levels
            )
        }
    }

    // MARK: - Keyboard

    private func setupKeyboard() {
        let cfg = configStore.config
        keyboard = KeyboardMonitor(hotkey: cfg.hotkey, mouseEnterBtn: cfg.mouse_enter_btn)

        keyboard.onPTTStart = { [weak self] in
            fputs("[AppDelegate] onPTTStart fired\n", stderr)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.pttStartInProgress else { return }
                self.pttStartInProgress = true
                defer { self.pttStartInProgress = false }

                // Cancel any pending mic-sleep — we're using it again.
                self.micSleepTimer?.invalidate()
                self.micSleepTimer = nil

                do {
                    try await self.prepareAudioForCapture()
                } catch let error as MicrophoneFailure {
                    self.showMicrophoneFailureAlert(error)
                    return
                } catch {
                    self.showMicrophoneFailureAlert(.startFailed(error.localizedDescription))
                    return
                }

                // handleStart resets the recognizer buffer; beginCapture then flushes
                // warm pre-roll into that fresh session.
                self.ptt.handleStart()
                guard self.ptt.isSessionActive else { return }

                self.audio.beginCapture()
            }
        }
        keyboard.onPTTStop = { [weak self] in
            fputs("[AppDelegate] onPTTStop fired\n", stderr)
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Keep capturing briefly after release so the tail of the last word
                // isn't clipped, then stop forwarding (engine stays warm for now).
                try? await Task.sleep(nanoseconds: 180_000_000)  // 0.18s
                self.audio.endCapture()
                self.ptt.handleStop()

                // Keep the engine warm for a short while so back-to-back dictation is
                // instant, then release the mic (orange indicator turns off) for privacy.
                self.micSleepTimer?.invalidate()
                self.micSleepTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    fputs("[AppDelegate] mic idle — releasing engine\n", stderr)
                    self.audio.stopEngine()
                }
            }
        }
        keyboard.onCursorPosition = { [weak self] point in
            Task { @MainActor [weak self] in
                self?.floatingWindow.positionNearCursor(point)
            }
        }
        keyboard.onMouseEnter = {
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false)?.post(tap: .cghidEventTap)
        }
        keyboard.start()
        if !AXIsProcessTrusted() {
            accessibilityRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self.accessibilityRetryTimer = nil
                    self.keyboard.start()
                }
            }
        }
    }

    // MARK: - Audio

    private func setupAudio() {
        audio = AudioCapture()
        audio.onChunk = { [weak self] data in
            Task { @MainActor [weak self] in self?.ptt.handleAudioChunk(data) }
        }
        // Audio is started on PTT press and stopped on PTT release
    }

    private func prepareAudioForCapture() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await requestMicrophoneAccess()
            guard granted else { throw MicrophoneFailure.permissionDenied }
        case .denied:
            throw MicrophoneFailure.permissionDenied
        case .restricted:
            throw MicrophoneFailure.permissionRestricted
        @unknown default:
            throw MicrophoneFailure.permissionDenied
        }

        guard !audio.isRunning else { return }

        do {
            try audio.startEngine(deviceUID: configStore.config.microphone)
        } catch AudioCaptureError.noInputDevice {
            throw MicrophoneFailure.noInputDevice
        } catch AudioCaptureError.selectedDeviceUnavailable(_) {
            throw MicrophoneFailure.selectedDeviceUnavailable
        } catch {
            fputs("[murmur] audio.startEngine failed: \(error)\n", stderr)
            throw MicrophoneFailure.startFailed(error.localizedDescription)
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func showMicrophoneFailureAlert(_ failure: MicrophoneFailure) {
        guard !microphoneAlertVisible else { return }
        microphoneAlertVisible = true

        let alert = NSAlert()
        alert.messageText = failure.title
        alert.informativeText = failure.message
        alert.alertStyle = .warning

        if failure.canOpenSettings {
            alert.addButton(withTitle: L("alert.microphone.open_settings"))
        }
        alert.addButton(withTitle: L("common.cancel"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        microphoneAlertVisible = false

        if failure.canOpenSettings, response == .alertFirstButtonReturn {
            openMicrophoneSettings()
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Tray

    private func setupTray() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            let trayImage: NSImage? = {
                // Debug (SPM) builds: load from SPM resource bundle next to binary
                let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
                let spmBundle = execDir.flatMap {
                    Bundle(url: $0.appendingPathComponent("murmur_murmur.bundle"))
                }
                // Prefer @2x for Retina; set logical size to 18pt so it renders sharp
                // Debug builds: images are in Resources/ subdir; release builds: at bundle root
                for subdir in ["Resources", nil as String?] {
                    if let url2x = spmBundle?.url(forResource: "tray@2x", withExtension: "png", subdirectory: subdir),
                       let img = NSImage(contentsOf: url2x) {
                        img.size = NSSize(width: 18, height: 18)
                        return img
                    }
                    if let url = spmBundle?.url(forResource: "tray", withExtension: "png", subdirectory: subdir),
                       let img = NSImage(contentsOf: url) {
                        return img
                    }
                }
                // Fallback for main bundle (not currently used)
                return NSImage(named: "tray")
            }()
            if let img = trayImage {
                img.isTemplate = true
                btn.image = img
            } else {
                btn.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Murmur")
            }
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L("menu.history"),  action: #selector(openHistory),   keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: L("menu.hotwords"), action: #selector(openHotwords), keyEquivalent: "w"))
        menu.addItem(NSMenuItem(title: L("menu.stats"),    action: #selector(openStats),    keyEquivalent: "u"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("menu.settings"), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("menu.quit"),     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openStats() {
        if let w = statsWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let hosting = NSHostingController(rootView: StatsView(store: historyStore))
        let win = EscapableWindow(contentViewController: hosting)
        win.title = L("window.stats.title")
        win.setContentSize(NSSize(width: 640, height: 640))
        win.styleMask = [.titled, .closable, .resizable]
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        statsWindow = win
    }

    @objc private func openHistory() {
        if let w = historyWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: HistoryView(store: historyStore)
        )
        let win = EscapableWindow(contentViewController: hosting)
        win.title = L("window.history.title")
        win.setContentSize(NSSize(width: 640, height: 560))
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow = win
    }

    @objc private func openHotwords() {
        if let w = hotwordsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: HotwordsView(store: hotwordStore, historyStore: historyStore, config: configStore.config)
        )
        let win = EscapableWindow(contentViewController: hosting)
        win.title = L("window.hotwords.title")
        win.setContentSize(NSSize(width: 520, height: 500))
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hotwordsWindow = win
    }

    @objc private func openSettings() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = SettingsRoot(
            config: configStore.config,
            onSave: { [weak self] in
                guard let self = self else { return }
                do {
                    try self.configStore.save()
                } catch {
                    // Defer alert so it runs after the SwiftUI action returns (avoids runModal re-entrancy)
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "无法保存设置"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .warning
                        alert.runModal()
                    }
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.ptt.updateConfig(self.configStore.config)
                    self.keyboard.stop()
                    self.setupKeyboard()
                }
            },
            onConfigChange: { [weak self] newConfig in
                self?.configStore.config = newConfig
            }
        )
        let hosting = NSHostingController(
            rootView: NavigationStack { root }
                .frame(minWidth: 560, minHeight: 620)
        )
        let win = EscapableWindow(contentViewController: hosting)
        win.title = L("window.settings.title")
        win.setContentSize(NSSize(width: 580, height: 640))
        win.styleMask = [.titled, .closable, .resizable]
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow { settingsWindow = nil }
        if (notification.object as? NSWindow) === historyWindow  { historyWindow  = nil }
        if (notification.object as? NSWindow) === hotwordsWindow { hotwordsWindow = nil }
        if (notification.object as? NSWindow) === statsWindow    { statsWindow    = nil }
    }
}
