//
// Copyright © 2020 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

class VMDisplayMetalWindowController: VMDisplayWindowController, UTMSpiceIODelegate {
    var metalView: VMMetalView!
    var renderer: UTMRenderer?
    
    @objc dynamic var vmDisplay: CSDisplayMetal?
    @objc dynamic var vmInput: CSInput?
    
    private var displaySizeObserver: NSKeyValueObservation?
    private var displaySize: CGSize = .zero
    
    // MARK: - User preferences
    
    @Setting("NoCursorCaptureAlert") private var isCursorCaptureAlertShown: Bool = false
    @Setting("AlwaysNativeResolution") private var isAlwaysNativeResolution: Bool = false
    @Setting("DisplayFixed") private var isDisplayFixed: Bool = false
    private var settingObservations = [NSKeyValueObservation]()
    
    // MARK: - Init
    
    override func windowDidLoad() {
        super.windowDidLoad()
        metalView = VMMetalView(frame: displayView.bounds)
        metalView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        metalView.device = MTLCreateSystemDefaultDevice()
        guard let _ = metalView.device else {
            showErrorAlert(NSLocalizedString("Metal is not supported on this device. Cannot render display.", comment: "VMDisplayMetalWindowController"))
            logger.critical("Cannot find system default Metal device.")
            return
        }
        displayView.addSubview(metalView)
        renderer = UTMRenderer.init(metalKitView: metalView)
        guard let renderer = self.renderer else {
            showErrorAlert(NSLocalizedString("Internal error.", comment: "VMDisplayMetalWindowController"))
            logger.critical("Failed to create renderer.")
            return
        }
        renderer.mtkView(metalView, drawableSizeWillChange: metalView.drawableSize)
        renderer.changeUpscaler(vmConfiguration?.displayUpscalerValue ?? .linear, downscaler: vmConfiguration?.displayDownscalerValue ?? .linear)
        metalView.delegate = renderer
        metalView.inputDelegate = self
        
        settingObservations.append(UserDefaults.standard.observe(\.AlwaysNativeResolution, options: .new) { (defaults, change) in
            self.displaySizeDidChange(size: self.displaySize)
        })
        settingObservations.append(UserDefaults.standard.observe(\.DisplayFixed, options: .new) { (defaults, change) in
            self.displaySizeDidChange(size: self.displaySize)
        })
        
        if vm.state == .vmStopped || vm.state == .vmSuspended {
            enterSuspended(isBusy: false)
            DispatchQueue.global(qos: .userInitiated).async {
                if self.vm.startVM() {
                    self.vm.ioDelegate = self
                }
            }
        } else {
            enterLive()
            vm.ioDelegate = self
        }
    }
    
    override func enterLive() {
        metalView.isHidden = false
        screenshotView.isHidden = true
        renderer!.sourceScreen = vmDisplay
        renderer!.sourceCursor = vmInput
        displaySizeObserver = observe(\.vmDisplay!.displaySize, options: [.initial, .new]) { (_, change) in
            guard let size = change.newValue else { return }
            self.displaySizeDidChange(size: size)
        }
        if vmConfiguration!.shareClipboardEnabled {
            UTMPasteboard.general.requestPollingMode(forHashable: self) // start clipboard polling
        }
        super.enterLive()
        resizeConsoleToolbarItem.isEnabled = false // disable item
    }
    
    override func enterSuspended(isBusy busy: Bool) {
        if !busy {
            metalView.isHidden = true
            screenshotView.image = vm.screenshot?.image
            screenshotView.isHidden = false
        }
        if vmConfiguration!.shareClipboardEnabled {
            UTMPasteboard.general.releasePollingMode(forHashable: self) // stop clipboard polling
        }
        super.enterSuspended(isBusy: busy)
    }
    
    override func captureMouseButtonPressed(_ sender: Any) {
        captureMouse()
    }
}
    
// MARK: - Screen management
extension VMDisplayMetalWindowController {
    func displaySizeDidChange(size: CGSize) {
        if size == .zero {
            logger.debug("Ignoring zero size display")
            return
        }
        DispatchQueue.main.async {
            logger.debug("resizing to: (\(size.width), \(size.height))")
            self.displaySize = size
            guard let window = self.window else { return }
            guard let vmDisplay = self.vmDisplay else { return }
            let currentScreenScale = window.screen?.backingScaleFactor ?? 1.0
            let nativeScale = self.isAlwaysNativeResolution ? 1.0 : currentScreenScale
            // change optional scale if needed
            if self.isDisplayFixed || (!self.isAlwaysNativeResolution && vmDisplay.viewportScale < currentScreenScale) {
                vmDisplay.viewportScale = nativeScale
            }
            let minScaledSize = CGSize(width: size.width * nativeScale / currentScreenScale, height: size.height * nativeScale / currentScreenScale)
            let fullContentWidth = size.width * vmDisplay.viewportScale / currentScreenScale
            let fullContentHeight = size.height * vmDisplay.viewportScale / currentScreenScale
            let contentRect = CGRect(x: window.frame.origin.x,
                                     y: 0,
                                     width: ceil(fullContentWidth),
                                     height: ceil(fullContentHeight))
            var windowRect = window.frameRect(forContentRect: contentRect)
            windowRect.origin.y = window.frame.origin.y + window.frame.height - windowRect.height
            window.contentMinSize = minScaledSize
            window.contentAspectRatio = size
            window.setFrame(windowRect, display: false, animate: true)
            self.metalView.setFrameSize(contentRect.size)
        }
    }
    
    func windowDidChangeScreen(_ notification: Notification) {
        logger.debug("screen changed")
        if let vmDisplay = self.vmDisplay {
            displaySizeDidChange(size: vmDisplay.displaySize)
        }
    }
    
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !isDisplayFixed else { return frameSize }
        guard displaySize != .zero else { return frameSize }
        guard let window = self.window else { return frameSize }
        guard let vmDisplay = self.vmDisplay else { return frameSize }
        let currentScreenScale = window.screen?.backingScaleFactor ?? 1.0
        let targetContentSize = window.contentRect(forFrameRect: CGRect(origin: .zero, size: frameSize)).size
        let targetScaleX = targetContentSize.width * currentScreenScale / displaySize.width
        let targetScaleY = targetContentSize.height * currentScreenScale / displaySize.height
        let targetScale = min(targetScaleX, targetScaleY)
        let scaledSize = CGSize(width: displaySize.width * targetScale / currentScreenScale, height: displaySize.height * targetScale / currentScreenScale)
        let targetFrameSize = window.frameRect(forContentRect: CGRect(origin: .zero, size: scaledSize)).size
        vmDisplay.viewportScale = targetScale
        logger.debug("changed scale \(targetScale)")
        self.metalView.setFrameSize(scaledSize)
        return targetFrameSize
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        if let window = self.window {
            _ = window.makeFirstResponder(metalView)
        }
    }
    
    func windowDidResignKey(_ notification: Notification) {
        if let window = self.window {
            _ = window.makeFirstResponder(nil)
        }
    }
}

// MARK: - Input events
extension VMDisplayMetalWindowController: VMMetalViewInputDelegate {
    private func captureMouse() {
        let action = { () -> Void in
            self.vm.requestInputTablet(false)
            self.metalView?.captureMouse()
        }
        if isCursorCaptureAlertShown {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Captured mouse", comment: "VMDisplayMetalWindowController")
            alert.informativeText = NSLocalizedString("To release the mouse cursor, press ⌃+⌥ (Ctrl+Opt or Ctrl+Alt) at the same time.", comment: "VMDisplayMetalWindowController")
            alert.showsSuppressionButton = true
            alert.beginSheetModal(for: window!) { _ in
                if alert.suppressionButton?.state ?? .off == .on {
                    self.isCursorCaptureAlertShown = false
                }
                DispatchQueue.main.async(execute: action)
            }
        } else {
            action()
        }
    }
    
    private func releaseMouse() {
        vm.requestInputTablet(true)
        metalView?.releaseMouse()
    }
    
    func mouseMove(absolutePoint: CGPoint, button: CSInputButton) {
        guard let window = self.window else { return }
        let currentScreenScale = window.screen?.backingScaleFactor ?? 1.0
        let viewportScale = vmDisplay?.viewportScale ?? 1.0
        let frameSize = metalView.frame.size
        let newX = absolutePoint.x * currentScreenScale / viewportScale
        let newY = (frameSize.height - absolutePoint.y) * currentScreenScale / viewportScale
        let point = CGPoint(x: newX, y: newY)
        logger.debug("move cursor: cocoa (\(absolutePoint.x), \(absolutePoint.y)), native (\(newX), \(newY))")
        vmInput?.sendMouseMotion(button, point: point)
        vmInput?.forceCursorPosition(point) // required to show cursor on screen
    }
    
    func mouseMove(relativePoint: CGPoint, button: CSInputButton) {
        let translated = CGPoint(x: relativePoint.x, y: -relativePoint.y)
        vmInput?.sendMouseMotion(button, point: translated)
    }
    
    func mouseDown(button: CSInputButton) {
        vmInput?.sendMouseButton(button, pressed: true, point: .zero)
    }
    
    func mouseUp(button: CSInputButton) {
        vmInput?.sendMouseButton(button, pressed: false, point: .zero)
    }
    
    func mouseScroll(dy: CGFloat, button: CSInputButton) {
        var scrollDy = dy
        if vmConfiguration?.inputScrollInvert ?? false {
            scrollDy = -scrollDy
        }
        vmInput?.sendMouseScroll(.smooth, button: button, dy: dy)
    }
    
    private func sendExtendedKey(_ button: CSInputKey, keyCode: Int) {
        if (keyCode & 0xFF00) == 0xE000 {
            vmInput?.send(button, code: Int32(0x100 | (keyCode & 0xFF)))
        } else if keyCode >= 0x100 {
            logger.warning("ignored invalid keycode \(keyCode)");
        } else {
            vmInput?.send(button, code: Int32(keyCode))
        }
    }
    
    func keyDown(keyCode: Int) {
        sendExtendedKey(.press, keyCode: keyCode)
    }
    
    func keyUp(keyCode: Int) {
        sendExtendedKey(.release, keyCode: keyCode)
    }
    
    func requestReleaseCapture() {
        releaseMouse()
    }
}
