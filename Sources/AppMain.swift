import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildStatusItem()
        model.start()
        showSettings()

        model.objectWillChange
            .throttle(for: .milliseconds(400), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshStatusMenu() }
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered,
                                  defer: false)
            window.title = "HingeFlow"
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("HingeFlowSettings")
            window.center()
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleEffect() {
        model.setAutomatic(!model.automatic)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "laptopcomputer.and.arrow.down",
                                     accessibilityDescription: "HingeFlow")
        item.button?.toolTip = "HingeFlow"
        statusItem = item
        refreshStatusMenu()
    }

    private func refreshStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let state = NSMenuItem(title: "HingeFlow · \(model.statusTitle)", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        if let angle = model.sensorAngle {
            let angleItem = NSMenuItem(title: L10n.format("Lid angle: %d°", Int(angle.rounded())),
                                       action: nil,
                                       keyEquivalent: "")
            angleItem.isEnabled = false
            menu.addItem(angleItem)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.text("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let toggle = NSMenuItem(title: L10n.text(model.automatic ? "Pause effect" : "Resume effect"),
                                action: #selector(toggleEffect),
                                keyEquivalent: "p")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.text("Quit HingeFlow"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.text("HingeFlow Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("Quit HingeFlow"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }
}

@main
enum HingeFlowMain {
    static func main() {
        if CommandLine.arguments.contains("--localization-probe") {
            print(L10n.text("Settings…"))
            print(L10n.format("Lid angle: %d°", 42))
            exit(0)
        }

        if CommandLine.arguments.contains("--self-test") {
            do {
                try SelfCheck.run()
                exit(0)
            } catch {
                fputs("HingeFlow self-check failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
