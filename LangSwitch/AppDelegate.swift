//
//  ContentView.swift
//  LangSwitch
//
//  Created by ANTON NIKEEV on 05.07.2023.
//  Modified: smart switching (last-2-used, like native macOS)
//            System popups appear automatically via TISSelectInputSource.
//

import SwiftUI
import Carbon
import Foundation
import AppKit
import IOKit.hid
import ServiceManagement


class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarItem: NSStatusItem?
    var aboutWindow: NSWindow?
    let longPressThreshold: TimeInterval = 0.2

    // ── Smart switching state ────────────────────────────────────────────────
    // Mirrors vanilla macOS: Globe always toggles between the last two used
    // languages instead of cycling through all in fixed order.
    //
    // Example with RU / EN / LT:
    //   Using RU → press Globe → EN   (previous)
    //   Using EN → press Globe → RU   (previous, toggles back)
    //   Switch to LT manually
    //   Using LT → press Globe → EN   (previous before LT)
    private var previousSourceID: String? = nil
    private var currentSourceIDTracked: String? = nil
    private var skipNextNotification = false  // prevents double-update after manual switch

    // ────────────────────────────────────────────────────────────────────────
    // MARK: - App launch
    // ────────────────────────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchAtLogin()

        // Seed history with the currently active source
        if let src = TISCopyCurrentKeyboardInputSource()?.takeUnretainedValue() {
            currentSourceIDTracked = srcID(src)
        }

        // Track language changes made by OTHER means (Ctrl+Space, Caps Lock, menu bar)
        // so our "previous" pointer stays accurate.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(onInputSourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )

        // Status bar
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusBarItem?.button?.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        statusBarItem?.isVisible = true

        let menu = NSMenu()
        menu.addItem(withTitle: "About LangSwitch", action: #selector(showAboutWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Hide Icon",         action: #selector(hideStatusBarIcon), keyEquivalent: "")
        menu.addItem(withTitle: "Exit",              action: #selector(exitAction),         keyEquivalent: "")
        statusBarItem?.menu = menu

        if UserDefaults.standard.bool(forKey: "hideStatusBarIcon") {
            statusBarItem?.isVisible = false
        }

        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)

        // Globe / Fn key monitor — identical timing logic to original
        var anotherClicked = false
        var lastPressTime = Date()

        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard event.keyCode == 63 else { return }

            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.function) {
                anotherClicked = false
                lastPressTime = Date()
            }
            if !event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty {
                anotherClicked = true
            }

            let allowedFlags: NSEvent.ModifierFlags = [.capsLock]
            let remaining = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(allowedFlags)

            if remaining.isEmpty && !anotherClicked {
                let elapsed = Date().timeIntervalSince(lastPressTime)
                if elapsed < (self?.longPressThreshold ?? 0.2) {
                    self?.switchKeyboardLanguage()
                }
            }
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // MARK: - External source-change listener
    // ────────────────────────────────────────────────────────────────────────

    @objc private func onInputSourceChanged() {
        // Our own Globe press already updated history — skip this notification
        if skipNextNotification {
            skipNextNotification = false
            return
        }
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeUnretainedValue() else { return }
        let newID = srcID(src)
        guard newID != currentSourceIDTracked else { return }

        previousSourceID       = currentSourceIDTracked
        currentSourceIDTracked = newID
    }

    // ────────────────────────────────────────────────────────────────────────
    // MARK: - Core switching logic
    // ────────────────────────────────────────────────────────────────────────

    func switchKeyboardLanguage() {
        guard let currentSrc = TISCopyCurrentKeyboardInputSource()?.takeUnretainedValue() else { return }
        let sources = getInputSources()
        guard !sources.isEmpty else { return }

        let curID = srcID(currentSrc)

        // Determine target:
        //   • Have a recorded "previous" that differs from current → toggle to it
        //   • Otherwise → cycle forward (original behaviour / first-ever press)
        let targetSrc: TISInputSource
        if let prevID = previousSourceID,
           prevID != curID,
           let prev = sources.first(where: { srcID($0) == prevID }) {
            targetSrc = prev
        } else {
            let idx = sources.firstIndex(where: { srcID($0) == curID }) ?? 0
            targetSrc = sources[(idx + 1) % sources.count]
        }

        // Update history BEFORE the distributed notification fires
        skipNextNotification   = true
        previousSourceID       = curID
        currentSourceIDTracked = srcID(targetSrc)

        // Switch — macOS posts kTISNotifySelectedKeyboardInputSourceChanged
        // automatically, which makes the system show its own native popup.
        TISSelectInputSource(targetSrc)
    }

    // ────────────────────────────────────────────────────────────────────────
    // MARK: - TIS helper
    // ────────────────────────────────────────────────────────────────────────

    private func srcID(_ src: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "" }
        return (Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue() as? String) ?? ""
    }

    // ────────────────────────────────────────────────────────────────────────
    // MARK: - Existing helpers (unchanged from original)
    // ────────────────────────────────────────────────────────────────────────

    func getInputSources() -> [TISInputSource] {
        let arr = TISCreateInputSourceList(nil, false).takeRetainedValue() as NSArray
        let list = arr as! [TISInputSource]
        return list
            .filter { $0.category == TISInputSource.Category.keyboardInputSource }
            .filter { $0.isSelectable }
    }

    @objc func showAboutWindow() {
        if aboutWindow == nil {
            let ww: CGFloat = 300, wh: CGFloat = 180
            let content = NSView(frame: NSRect(x: 0, y: 0, width: ww, height: wh))
            let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

            let vLabel = NSTextField(labelWithString: "LangSwitch v\(ver)")
            vLabel.frame = NSRect(x: (ww - 150) / 2, y: 130, width: 150, height: 20)
            vLabel.alignment = .center
            content.addSubview(vLabel)

            let ghBtn = NSButton(title: "GitHub Page", target: self, action: #selector(openGitHub))
            ghBtn.frame = NSRect(x: (ww - 100) / 2, y: 90, width: 100, height: 30)
            content.addSubview(ghBtn)

            let updBtn = NSButton(title: "Check for Updates", target: self, action: #selector(checkForUpdates))
            updBtn.frame = NSRect(x: (ww - 150) / 2, y: 50, width: 150, height: 30)
            content.addSubview(updBtn)

            aboutWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: ww, height: wh),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            aboutWindow?.contentView = content
            aboutWindow?.center()
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func launchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } catch {
                print("Failed to enable login item: \(error)")
            }
        }
    }

    @objc func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/Nikeev/LangSwitch")!)
    }

    @objc func checkForUpdates() {
        guard let url = URL(string: "https://api.github.com/repos/Nikeev/LangSwitch/releases/latest") else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data, error == nil else { self.showAlert(message: "Failed to check for updates."); return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let latest = json["tag_name"] as? String {
                    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
                    self.showAlert(message: latest > "v\(current)"
                        ? "New version \(latest) available! Download from GitHub."
                        : "You're up to date.")
                }
            } catch { self.showAlert(message: "Error parsing update info.") }
        }.resume()
    }

    func showAlert(message: String) {
        DispatchQueue.main.async { let a = NSAlert(); a.messageText = message; a.runModal() }
    }

    @objc func hideStatusBarIcon() {
        statusBarItem?.isVisible = false
        UserDefaults.standard.set(true, forKey: "hideStatusBarIcon")
    }

    @objc func exitAction() { NSApplication.shared.terminate(nil) }
}

// ────────────────────────────────────────────────────────────────────────────
// MARK: - TISInputSource extension (unchanged from original)
// ────────────────────────────────────────────────────────────────────────────

extension TISInputSource {
    enum Category {
        static var keyboardInputSource: String { kTISCategoryKeyboardInputSource as String }
    }
    private func getProperty(_ key: CFString) -> AnyObject? {
        guard let p = TISGetInputSourceProperty(self, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()
    }
    var category:    String { getProperty(kTISPropertyInputSourceCategory)        as! String }
    var isSelectable: Bool  { getProperty(kTISPropertyInputSourceIsSelectCapable) as! Bool   }
}
