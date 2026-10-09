import AppKit

// Draws emulator frames into the layer and turns mouse and key events into emulator input.
@MainActor
final class EmulatorView: NSView {
    let emulator: Emulator
    private let port: Int
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let frameLayer = CALayer()
    private(set) var deviceWidth = 0
    private(set) var deviceHeight = 0
    private var frameCount = 0
    private var isTouching = false
    private var systemNavigationKey: String?
    var hasActiveMouseTouch: Bool { isTouching }
    private var fpsTimer: Timer?
    private var streamTask: Task<Void, Never>?
    private var cameraMonitorTask: Task<Void, Never>?
    private var isCameraInUse = false
    private var isCameraRecording = false
    private var cameraScreenshotsResumeAt = Date.distantPast
    // Frames carry the attempt they came from, so a late one cannot show after that attempt ended.
    private var streamGeneration = 0
    private(set) var currentImage: CGImage?
    // Scroll wheel drag in device pixels, nil while no finger is down.
    var scrollFinger: CGPoint?
    var scrollReleaseTimer: Timer?

    override var acceptsFirstResponder: Bool { true }

    init(emulator: Emulator, port: Int) {
        self.emulator = emulator
        self.port = port
        super.init(frame: .zero)
        wantsLayer = true
        // The frame lives on its own layer sized to the fitted rect, so corners can be rounded.
        frameLayer.contentsGravity = .resize
        frameLayer.masksToBounds = true
        // No implicit animations, or every frame would crossfade and every resize would lag.
        frameLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
        layer?.addSublayer(frameLayer)
        applyAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(applyAppearance), name: .appearanceDidChange, object: nil)

        errorLabel.stringValue = "Waiting for emulator on port \(port)..."
        errorLabel.textColor = .white
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])

        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.printFps() }
        }
        cameraMonitorTask = Task { await monitorCameraUse() }
        streamTask = Task { await streamForever() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() { applyAppearance() }

    // Keeps retrying so the window survives the emulator being killed and restarted.
    private func streamForever() async {
        while !Task.isCancelled {
            let isRecording = await MainActor.run { self.isCameraRecording }
            if isRecording {
                // Camera2 recording must own the emulator's graphics path. The
                // monitor closes the gRPC stream when RECORD starts.
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }

            streamGeneration += 1
            let generation = streamGeneration
            do {
                try await emulator.streamFrames { image in
                    Task { @MainActor in
                        if generation == self.streamGeneration { self.show(image) }
                    }
                } pauseWhen: { [weak self] in
                    await MainActor.run {
                        guard let self else { return false }
                        return self.isCameraRecording || Date() < self.cameraScreenshotsResumeAt
                    }
                }
            } catch {
                print("stream on port \(port) ended: \(error)")
                // streamFrames normally shuts down the failed transport itself. This second
                // call also covers failures while creating the transport and makes the retry
                // boundary explicit: no input or screenshot RPC is allowed to reuse a dead
                // connection after a deadlineExceeded/unavailable error.
                emulator.stopDisplayStream()
            }
            streamGeneration += 1
            if isCameraRecording || Date() < cameraScreenshotsResumeAt {
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            // Drop the stale frame so the message shows on black, not over the last screen.
            frameLayer.contents = nil
            currentImage = nil
            let isRunning = AvdCatalog.runningEmulators().values.contains { $0.grpcPort == port }
            errorLabel.stringValue = isRunning ? "Waiting for emulator on port \(port)..." : "Emulator stopped"
            errorLabel.isHidden = false
            // A failed screenshot is transient around Camera2 Activity transitions. Keep the
            // retry fast so Back/Home does not look like it froze the emulator for two seconds.
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // Camera opens before recording starts. Polling the camera service lets normal
    // display streaming continue for all other apps while avoiding the Android 10
    // camera/display readback conflict for the complete Camera session.
    private func monitorCameraUse() async {
        while !Task.isCancelled {
            let serial = AvdCatalog.runningEmulators().values.first { $0.grpcPort == port }?.adbSerial
            let state = await Task.detached {
                guard let serial else { return AvdCatalog.CameraState(isInUse: false, isRecording: false) }
                return AvdCatalog.cameraState(serial: serial)
            }.value
            let inUse = state.isInUse
            let recording = state.isRecording
            if inUse != isCameraInUse || recording != isCameraRecording {
                if isCameraRecording && !recording {
                    cameraScreenshotsResumeAt = Date().addingTimeInterval(0.7)
                }
                isCameraInUse = inUse
                isCameraRecording = recording
                if recording {
                    print("camera recording: pausing screenshots")
                    emulator.stopDisplayStream()
                } else if inUse {
                    print("camera preview: using gRPC display stream")
                } else {
                    print("camera closed: using gRPC display stream")
                }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func show(_ image: CGImage) {
        // Rotation changes the frame size, so take it from every frame.
        if image.width != deviceWidth || image.height != deviceHeight { needsLayout = true }
        deviceWidth = image.width
        deviceHeight = image.height
        currentImage = image
        errorLabel.isHidden = true
        frameLayer.contents = image
        frameCount += 1
    }

    private func printFps() {
        guard Settings.isFpsPrinted, frameCount > 0 else { return }
        print("fps: \(frameCount)")
        frameCount = 0
    }

    // Where the phone actually shows inside the view after aspect fit and padding, in view points.
    var phoneRect: CGRect {
        // Padding never takes more than a quarter of the shorter side, so the phone always has room.
        let padding = min(CGFloat(Settings.phonePadding), min(bounds.width, bounds.height) / 4)
        let area = bounds.insetBy(dx: padding, dy: padding)
        guard deviceWidth > 0 else { return .zero }
        let scale = min(area.width / CGFloat(deviceWidth), area.height / CGFloat(deviceHeight))
        let size = CGSize(width: CGFloat(deviceWidth) * scale, height: CGFloat(deviceHeight) * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        frameLayer.frame = phoneRect
    }

    // Pixel on the phone under a view point, nil when the point is outside the phone.
    func devicePoint(for viewPoint: NSPoint) -> (x: Int, y: Int)? {
        let rect = phoneRect
        let fractionX = (viewPoint.x - rect.minX) / rect.width
        let fractionY = (rect.maxY - viewPoint.y) / rect.height
        guard (0...1).contains(fractionX), (0...1).contains(fractionY) else { return nil }
        return (Int(fractionX * CGFloat(deviceWidth - 1)), Int(fractionY * CGFloat(deviceHeight - 1)))
    }

    private func sendTouch(_ event: NSEvent, isDown: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        let rect = phoneRect
        // Drags and the release may leave the phone rect, so clamp instead of dropping them.
        let clamped = NSPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
        guard let device = devicePoint(for: clamped) else { return }

        // The Android navigation bar is part of the streamed screen. During a Camera2
        // transition, sending its tap as a normal gRPC touch can share a connection with a
        // stuck screenshot RPC, so map the three system buttons directly to adb instead.
        if isDown {
            if systemNavigationKey == nil,
               let key = systemNavigationKey(at: device.x, y: device.y) {
                systemNavigationKey = key
                // Do not leave the last Camera/QR frame painted while the old display
                // transport is being torn down. Android handles the ADB key immediately,
                // but the replacement screenshot stream may need a few polling rounds to
                // observe the Activity transition.
                streamGeneration += 1
                frameLayer.contents = nil
                currentImage = nil
                errorLabel.stringValue = "Refreshing emulator display..."
                errorLabel.isHidden = false
                // Android 10 may still return one cached Camera2 readback immediately
                // after the Activity handles Back/Home. Keep the replacement stream from
                // starting until the camera/display handoff has settled.
                cameraScreenshotsResumeAt = max(
                    cameraScreenshotsResumeAt,
                    Date().addingTimeInterval(1.2))
                emulator.sendSystemKey(name: key)
            }
            if systemNavigationKey != nil { return }
        } else if systemNavigationKey != nil {
            systemNavigationKey = nil
            return
        }

        // The Camera shutter is on the right-side control rail. Stop display
        // readback before forwarding the press; waiting for dumpsys to notice
        // RECORD is too late on Android 10 and can wedge the emulator's color
        // buffers. The preview resumes after Camera leaves RECORD.
        if isCameraInUse && device.x >= Int(Double(deviceWidth) * 0.84) {
            cameraScreenshotsResumeAt = max(
                cameraScreenshotsResumeAt,
                Date().addingTimeInterval(1.0))
            if isDown { emulator.stopDisplayStream() }
        }
        emulator.sendTouch(x: device.x, y: device.y, isDown: isDown)
    }

    private func systemNavigationKey(at x: Int, y: Int) -> String? {
        guard deviceWidth > 0, deviceHeight > 0 else { return nil }
        if deviceWidth >= deviceHeight {
            guard x >= deviceWidth - max(72, deviceWidth / 16) else { return nil }
            switch Double(y) / Double(deviceHeight) {
            case 0..<0.34: return "AppSwitch"
            case 0.34..<0.66: return "GoHome"
            default: return "GoBack"
            }
        } else {
            guard y >= deviceHeight - max(72, deviceHeight / 16) else { return nil }
            switch Double(x) / Double(deviceWidth) {
            case 0..<0.34: return "GoBack"
            case 0.34..<0.66: return "GoHome"
            default: return "AppSwitch"
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard phoneRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        isTouching = true
        sendTouch(event, isDown: true)
    }

    override func mouseDragged(with event: NSEvent) {
        if isTouching { sendTouch(event, isDown: true) }
    }

    override func mouseUp(with event: NSEvent) {
        guard isTouching else { return }
        isTouching = false
        sendTouch(event, isDown: false)
    }

    override func keyDown(with event: NSEvent) {
        // Leave Cmd shortcuts to the system so they still act like normal Mac shortcuts.
        if event.modifierFlags.contains(.command) { return super.keyDown(with: event) }
        let specialKeys: [UInt16: String] = [
            36: "Enter", 76: "Enter", 51: "Backspace", 117: "Delete", 48: "Tab", 53: "GoBack",
            123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
        ]
        if let name = specialKeys[event.keyCode] {
            switch name {
            case "GoBack", "GoHome", "AppSwitch": emulator.sendSystemKey(name: name)
            default: emulator.sendKey(name: name)
            }
        } else if let text = event.characters, !text.isEmpty {
            emulator.sendKey(text: text)
        }
    }

    @objc private func applyAppearance() {
        layer?.backgroundColor = Settings.backgroundColor.cgColor
        window?.backgroundColor = Settings.backgroundColor
        frameLayer.cornerRadius = CGFloat(Settings.cornerRadius)
        needsLayout = true
    }

    func stop() {
        streamTask?.cancel()
        cameraMonitorTask?.cancel()
        fpsTimer?.invalidate()
        releaseScrollFinger()
    }
}
