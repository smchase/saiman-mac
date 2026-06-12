import SwiftUI
import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load environment variables from .env file
        DotEnv.load()

        // Verify configuration
        if !Config.shared.isConfigured {
            showConfigurationAlert()
        }

        // Setup spotlight panel
        SpotlightPanelController.shared.setup()

        // Request notification permission
        NotificationManager.shared.requestPermission()

        // Setup menu bar
        setupMenuBar()

        // Setup global hotkey (Option+Space)
        setupGlobalHotkey()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        let viewModel = SpotlightPanelController.shared.viewModel

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage.coolSIcon(size: 18)
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create popover for conversation list
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 280, height: 400)
        popover?.behavior = .transient
        popover?.animates = false
        popover?.delegate = self
        popover?.contentViewController = NSHostingController(
            rootView: MenuBarView(viewModel: viewModel)
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidShow(_ notification: Notification) {
        NotificationCenter.default.post(name: .menuBarPopoverDidShow, object: nil)
    }

    // MARK: - Global Hotkey

    private func setupGlobalHotkey() {
        // Register global hotkey using Carbon API
        // Option+Space
        let keyCode: UInt32 = 49 // Space
        let modifiers: UInt32 = UInt32(optionKey)

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x5341494D) // "SAIM" as 4-char code
        hotKeyID.id = 1

        // Install event handler for hot key events
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            DispatchQueue.main.async {
                SpotlightPanelController.shared.toggle()
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, nil)

        // Register the hotkey
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        if status != noErr {
            Logger.shared.error("[Hotkey] Failed to register hotkey, error: \(status)")
        } else {
            Logger.shared.info("[Hotkey] Registered Option+Space successfully")
        }
    }

    // MARK: - Configuration Alert

    private func showConfigurationAlert() {
        let missing = Config.shared.missingConfiguration.joined(separator: ", ")

        let alert = NSAlert()
        alert.messageText = "Configuration Required"
        alert.informativeText = """
            The following environment variables are not set:
            \(missing)

            Please set these variables and restart the app.

            Example:
            export AWS_ACCESS_KEY_ID="your-key"
            export AWS_SECRET_ACCESS_KEY="your-secret"
            export AWS_REGION="us-east-1"
            export EXA_API_KEY="your-exa-key"
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let menuBarPopoverDidShow = Notification.Name("menuBarPopoverDidShow")
}
