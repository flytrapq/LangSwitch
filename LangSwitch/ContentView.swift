//
//  ContentView.swift
//  LangSwitch
//
//  Created by ANTON NIKEEV on 05.07.2023.
//  Modified: smart switching (last-2-used, like native macOS) + language popups
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
    private var previousSourceID: String? = nil   // source before the current one
    private var currentSourceIDTracked: String? = nil
    private var isManualSwitch = false            // prevents double-update on notification

    // ── Popup windows (created once, reused) ────────────────────────────────
    private var centerPopupWindow: NSPanel? = nil
    private var inlinePopupWindow: NSPanel? = nil
    private var popupTimer: Timer? = nil

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

        // Globe / Fn key monitor — identical logic to original
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
            let remaining = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(allowedFlags)
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
        // If WE triggered this change, skip — history already updated in switchKeyboardLanguage()
        if isManualSwitch {
            isManualSwitch = false
            return
        }
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeUnretainedValue() else { return }
        let newID = srcID(src)
        guard newID != currentSourceIDTracked else { return }

        // The "current" becomes the new "previous"
        previousSourceID = currentSourceIDTracked
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

        // ── Pick target ──────────────────────────────────────────────────────
        // If we have a recorded "previous" source that exists and differs from
        // current → toggle back to it (vanilla macOS behaviour with 3+ languages).
        // Otherwise fall back to cycling forward (original LangSwitch behaviour).
        let targetSrc: TISInputSource
        if let prevID = previousSourceID,
           prevID != curID,
           let prev = sources.first(where: { srcID($0) == prevID }) {
            targetSrc = prev
        } else {
            let idx = sources.firstIndex(where: { srcID($0) == curID }) ?? 0
            targetSrc = sources[(idx + 1) % sources.count]
        }

        // ── Switch ───────────────────────────────────────────────────────────
        TISSelectInputSource(targetSrc)

        // Update history BEFORE the notification fires
        isManualSwitch = true
        previousSourceID     = curID
        currentSourceIDTracked = srcID(targetSrc)

        let name     = localizedName(targetSrc)
        let fromCode = shortCode(currentSrc)
        let toCode   = shortCode(targetSrc)
        print("LangSwitch → \(name) (\(fromCode) → \(toCode))")

        DispatchQueue.main.async { [weak self] in
            self?.showLanguagePopup(name: name, fromCode: fromCode, toCode: toCode)
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // MARK: - Popups
    // ────────────────────────────────────────────────────────────────────────

    private func showLanguagePopup(name: String, fromCode: String, toCode: String) {
        popupTimer?.invalidate()
        showCenterPopup(name: name)
        showInlinePopup(fromCode: fromCode, toCode: toCode)
        popupTimer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: false) { [weak self] _ in
            self?.hidePopups()
        }
    }

    // ── Center popup — replicates macOS input-source chooser (Image 1 style) ─
    // Light frosted-glass rounded rect, language name on a gray highlight bg.

    private func showCenterPopup(name: String) {
        let w: CGFloat = 230, h: CGFloat = 68

        if centerPopupWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                styleMask:   [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel.hasShadow = true
            panel.ignoresMouseEvents = true

            // Frosted-glass outer container — forced light (aqua) appearance
            let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.appearance = NSAppearance(named: .aqua)
            blur.wantsLayer = true
            blur.layer?.cornerRadius = 14
            blur.layer?.masksToBounds = true

            // Gray inner highlight (the "selected row" look from Image 1)
            let highlight = NSView(frame: NSRect(x: 10, y: 10, width: w - 20, height: h - 20))
            highlight.wantsLayer = true
            highlight.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.07).cgColor
            highlight.layer?.cornerRadius = 8
            blur.addSubview(highlight)

            // Language name label
            let label = NSTextField(labelWithString: "")
            label.font = NSFont.systemFont(ofSize: 19, weight: .medium)
            label.textColor = NSColor.labelColor
            label.alignment = .center
            label.frame = NSRect(x: 10, y: 10, width: w - 20, height: h - 20)
            label.tag = 101
            blur.addSubview(label)

            panel.contentView = blur
            centerPopupWindow = panel
        }

        // Update text
        (centerPopupWindow?.contentView?.viewWithTag(101) as? NSTextField)?.stringValue = name

        // Position: screen on which the cursor is, 22% from the bottom
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main ?? NSScreen.screens[0]

        let sf = screen.frame
        centerPopupWindow?.setFrameOrigin(NSPoint(x: sf.midX - w / 2, y: sf.minY + sf.height * 0.22))
        centerPopupWindow?.alphaValue = 1
        centerPopupWindow?.orderFrontRegardless()
    }

    // ── Inline popup — pill near cursor (Image 2 style) ──────────────────────
    // White capsule, "FROM" code in plain text, "TO" code on blue circle.

    private func showInlinePopup(fromCode: String, toCode: String) {
        let slotW: CGFloat = 30, gap: CGFloat = 4, padH: CGFloat = 8, h: CGFloat = 32
        let w = padH + slotW + gap + slotW + padH

        let panel: NSPanel
        if let existing = inlinePopupWindow {
            panel = existing
        } else {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                styleMask:   [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            p.hasShadow = true
            p.ignoresMouseEvents = true
            inlinePopupWindow = p
            panel = p
        }

        // Replace content view with fresh pill (codes change each time)
        let pill = LangSwitchInlinePill(
            frame: NSRect(x: 0, y: 0, width: w, height: h),
            fromCode: fromCode, toCode: toCode,
            slotWidth: slotW, gap: gap, padH: padH
        )
        panel.setContentSize(NSSize(width: w, height: h))
        panel.contentView = pill

        // Place just below the mouse cursor
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouse.x - w / 2, y: mouse.y - h - 8))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func hidePopups() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            centerPopupWindow?.animator().alphaValue = 0
            inlinePopupWindow?.animator().alphaValue = 0
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // MARK: - TIS helpers
    // ────────────────────────────────────────────────────────────────────────

    private func srcID(_ src: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "" }
        return (Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue() as? String) ?? ""
    }

    private func localizedName(_ src: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) else { return "" }
        return (Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue() as? String) ?? ""
    }

    /// Short display code for the inline popup: "ru" → "RU", "en" → "EN", etc.
    private func shortCode(_ src: TISInputSource) -> String {
        if let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages),
           let langs = Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue() as? [String],
           let first = langs.first {
            let base = first.split(separator: "-").first.map(String.init) ?? first
            return String(base.prefix(2)).uppercased()
        }
        return String(localizedName(src).prefix(2)).uppercased()
    }

    // ────────────────────────────────────────────────────────────────────────
    // MARK: - Existing helpers (unchanged from original)
    // ────────────────────────────────────────────────────────────────────────

    func getInputSources() -> [TISInputSource] {
        let inputSourceNSArray = TISCreateInputSourceList(nil, false)
            .takeRetainedValue() as NSArray
        var list = inputSourceNSArray as! [TISInputSource]
        list = list.filter { $0.category == TISInputSource.Category.keyboardInputSource }
        return list.filter { $0.isSelectable }
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
        if let url = URL(string: "https://github.com/Nikeev/LangSwitch") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func checkForUpdates() {
        guard let url = URL(string: "https://api.github.com/repos/Nikeev/LangSwitch/releases/latest") else { return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data = data, error == nil else { self.showAlert(message: "Failed to check for updates."); return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let latest = json["tag_name"] as? String {
                    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
                    self.showAlert(message: latest > "v\(current)"
                        ? "New version \(latest) available! Download from GitHub."
                        : "You're up to date.")
                }
            } catch {
                self.showAlert(message: "Error parsing update info.")
            }
        }.resume()
    }

    func showAlert(message: String) {
        DispatchQueue.main.async {
            let a = NSAlert(); a.messageText = message; a.runModal()
        }
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
    var category: String    { getProperty(kTISPropertyInputSourceCategory)    as! String }
    var isSelectable: Bool  { getProperty(kTISPropertyInputSourceIsSelectCapable) as! Bool }
}

// ────────────────────────────────────────────────────────────────────────────
// MARK: - Inline pill view  (Image 2 style)
// White capsule · "FROM" plain dark · "TO" white on blue circle
// ────────────────────────────────────────────────────────────────────────────

final class LangSwitchInlinePill: NSView {

    private let fromCode: String
    private let toCode:   String
    private let slotW:    CGFloat
    private let gap:      CGFloat
    private let padH:     CGFloat

    init(frame: NSRect, fromCode: String, toCode: String,
         slotWidth: CGFloat, gap: CGFloat, padH: CGFloat) {
        self.fromCode = fromCode
        self.toCode   = toCode
        self.slotW    = slotWidth
        self.gap      = gap
        self.padH     = padH
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Drop a soft shadow behind the pill
        ctx.setShadow(offset: .zero, blur: 6, color: NSColor.black.withAlphaComponent(0.22).cgColor)

        // White pill background
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: (bounds.height - 2) / 2,
                                yRadius: (bounds.height - 2) / 2)
        NSColor.white.setFill()
        pill.fill()

        ctx.setShadow(offset: .zero, blur: 0, color: nil)  // reset shadow

        // ── "from" code (plain text) ──────────────────────────────────────────
        let fromAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.black.withAlphaComponent(0.55)
        ]
        let fromAS = NSAttributedString(string: fromCode, attributes: fromAttrs)
        let fromX  = padH + (slotW - fromAS.size().width) / 2
        let fromY  = (bounds.height - fromAS.size().height) / 2
        fromAS.draw(at: NSPoint(x: fromX, y: fromY))

        // ── "to" code (white text on blue rounded bg) ─────────────────────────
        let circX    = padH + slotW + gap
        let circRect = NSRect(x: circX, y: 2, width: slotW, height: bounds.height - 4)
        let circPath = NSBezierPath(roundedRect: circRect,
                                    xRadius: circRect.height / 2,
                                    yRadius: circRect.height / 2)
        NSColor.systemBlue.setFill()
        circPath.fill()

        let toAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let toAS = NSAttributedString(string: toCode, attributes: toAttrs)
        let toX  = circX + (slotW - toAS.size().width) / 2
        let toY  = (bounds.height - toAS.size().height) / 2
        toAS.draw(at: NSPoint(x: toX, y: toY))
    }
}
