#if os(macOS)
import AppKit
import CoreVideo
import Metal
import ScreenCaptureKit

// Capture coordinates are in display-local points with the origin at the top left.
private struct DockGlassRegion: Equatable {
    let windowID: CGWindowID
    let displayID: CGDirectDisplayID
    let scale: CGFloat
    let dock: CGRect
    private(set) var source: CGRect

    @MainActor init?(window: NSWindow, reusing previous: DockGlassRegion? = nil) {
        guard window.windowNumber > 0, let screen = window.screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        windowID = CGWindowID(window.windowNumber)
        displayID = id
        scale = min(screen.backingScaleFactor, 2)
        let frame = window.frame
        let screenBounds = CGRect(origin: .zero, size: screen.frame.size)
        let x = ((frame.minX - screen.frame.minX) * scale).rounded() / scale
        let y = ((screen.frame.maxY - frame.maxY) * scale).rounded() / scale
        dock = CGRect(x: x, y: y, width: frame.width, height: frame.height)
        guard screenBounds.contains(dock) else { return nil }
        let needed = dock.insetBy(dx: -8, dy: -8).integral.intersection(screenBounds)
        if let previous, previous.windowID == windowID, previous.displayID == displayID,
           previous.scale == scale, previous.source.contains(needed) {
            source = previous.source
        } else {
            source = dock.insetBy(dx: -36, dy: -36).integral.intersection(screenBounds)
        }
    }

    var configuration: SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = Int(source.width * scale)
        config.height = Int(source.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    func matches(_ screenRect: CGRect) -> Bool {
        let origin = CGDisplayBounds(displayID).origin
        return screenRect == source || screenRect == source.offsetBy(dx: origin.x, dy: origin.y)
    }

    func sharesCaptureArea(with other: DockGlassRegion) -> Bool {
        windowID == other.windowID && displayID == other.displayID && scale == other.scale && source == other.source
    }

    func fitted(to capture: DockGlassRegion) -> DockGlassRegion? {
        guard windowID == capture.windowID, displayID == capture.displayID, scale == capture.scale,
              capture.source.contains(dock) else { return nil }
        var fitted = self
        fitted.source = capture.source
        return fitted
    }
}

private struct DockGlassFrame {
    let image: CGImage?
    let luminance: CGFloat
}

private final class DockGlassLens {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private var surface: MTLTexture?
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            guard let kernel = library.makeFunction(name: "refractDock") else { return nil }
            pipeline = try device.makeComputePipelineState(function: kernel)
        } catch {
            NSLog("TokenMeter dock glass lens: %@", error.localizedDescription)
            return nil
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device
        self.queue = queue
        self.cache = cache
    }

    func render(_ pixels: CVPixelBuffer, region: DockGlassRegion) -> CGImage? {
        let scale = region.scale
        let width = Int(region.dock.width * scale)
        let height = Int(region.dock.height * scale)
        if surface?.width != width || surface?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                       height: height, mipmapped: false)
            descriptor.usage = .shaderWrite
            descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
            surface = device.makeTexture(descriptor: descriptor)
        }

        var captured: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixels, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 0, &captured)
        guard result == kCVReturnSuccess, let captured, let source = CVMetalTextureGetTexture(captured),
              let surface, let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        var geometry = SIMD4<Float>(Float((region.dock.minX - region.source.minX) * scale),
                                    Float((region.dock.minY - region.source.minY) * scale),
                                    Float(scale), Float(DockBackdropView.cornerRadius))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(surface, index: 1)
        encoder.setBytes(&geometry, length: MemoryLayout.size(ofValue: geometry), index: 0)
        let threads = MTLSize(width: 16, height: 8, depth: 1)
        let groups = MTLSize(width: (width + threads.width - 1) / threads.width,
                             height: (height + threads.height - 1) / threads.height, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        encoder.endEncoding()
        if surface.storageMode == .managed {
            guard let blit = command.makeBlitCommandEncoder() else { return nil }
            blit.synchronize(resource: surface)
            blit.endEncoding()
        }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        withExtendedLifetime(captured) {}

        let rowBytes = width * 4
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { bytes in
            surface.getBytes(bytes.baseAddress!, bytesPerRow: rowBytes,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let format = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: Self.sRGB, bitmapInfo: format, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void refractDock(texture2d<float, access::sample> backdrop [[texture(0)]],
                            texture2d<float, access::write> glass [[texture(1)]],
                            constant float4 &geometry [[buffer(0)]],
                            uint2 pixel [[thread_position_in_grid]]) {
        if (pixel.x >= glass.get_width() || pixel.y >= glass.get_height()) return;
        float scale = geometry.z;
        float radius = geometry.w;
        float2 location = float2(pixel) + 0.5;
        float2 halfSize = float2(glass.get_width(), glass.get_height()) / (2.0 * scale);
        float2 point = location / scale - halfSize;
        float2 edge = abs(point) - halfSize + radius;
        float2 corner = max(edge, 0.0);
        float distance = length(corner);
        float depth = radius - distance - min(max(edge.x, edge.y), 0.0);
        float2 normal = sign(point) * corner / max(distance, 0.001);
        // The bevel tapers into the face. A small lengthwise curve bows lines along the sides.
        float bend = saturate(1.0 - depth / 30.0);
        float profile = bend * (0.55 + 0.45 * bend);
        float2 offset = float2(point.x * 0.08, 0.0) + normal * (20.0 * profile);
        offset.y += 8.0 * abs(normal.x) * profile * (point.y / halfSize.y);
        constexpr sampler sampleBackdrop(coord::pixel, address::clamp_to_edge, filter::linear);
        float3 color = backdrop.sample(sampleBackdrop, geometry.xy + location - offset * scale).rgb;
        glass.write(float4(color, 1.0), pixel);
    }
    """
}

/// Only this queue touches captured pixels. The view receives a rendered dock-sized image.
private final class DockGlassOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "TokenMeter.dock-glass", qos: .userInitiated)
    private var region: DockGlassRegion?
    private var previousPixels = Data()
    private var latestCapture: (pixels: CVPixelBuffer, region: DockGlassRegion)?
    private weak var captureStream: SCStream?
    private let presentationLock = NSLock()
    private var pendingFrame: (stream: SCStream, region: DockGlassRegion, frame: DockGlassFrame?)?
    private lazy var lens = DockGlassLens()
    private static let linearLight = (0...255).map { value -> CGFloat in
        let channel = CGFloat(value) / 255
        return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    var onFrame: (@MainActor (SCStream, DockGlassRegion, DockGlassFrame?) -> Void)?
    var onStop: (@MainActor (SCStream, Error) -> Void)?

    func use(_ region: DockGlassRegion?) {
        queue.async {
            guard self.region != region else { return }
            if let region, self.region?.sharesCaptureArea(with: region) != true {
                self.previousPixels = Data()
            }
            self.region = region
            guard let region else {
                self.latestCapture = nil
                self.previousPixels = Data()
                return
            }
            // A stationary background may produce idle frames. Reuse its latest
            // pixels to render immediately at the dock's new position.
            if let capture = self.latestCapture, let stream = self.captureStream,
               let geometry = region.fitted(to: capture.region) {
                self.render(capture.pixels, geometry: geometry, region: region, stream: stream, skipUnchanged: false)
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let region,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
              let value = attachments[.status] as? Int, let status = SCFrameStatus(rawValue: value) else { return }
        if status == .blank || status == .suspended {
            previousPixels = Data()
            latestCapture = nil
            submit(nil, for: region, stream: stream)
            return
        }
        guard status == .complete, let pixels = sample.imageBuffer,
              let rect = attachments[.screenRect] as? NSDictionary,
              let screenRect = CGRect(dictionaryRepresentation: rect as CFDictionary),
              region.matches(screenRect),
              CVPixelBufferGetWidth(pixels) == Int(region.source.width * region.scale),
              CVPixelBufferGetHeight(pixels) == Int(region.source.height * region.scale) else { return }
        latestCapture = (pixels, region)
        captureStream = stream
        render(pixels, geometry: region, region: region, stream: stream, skipUnchanged: true)
    }

    private func render(_ pixels: CVPixelBuffer, geometry: DockGlassRegion, region: DockGlassRegion,
                        stream: SCStream, skipUnchanged: Bool) {
        guard let luminance = luminance(pixels, region: geometry, skipUnchanged: skipUnchanged) else { return }
        let frame = DockGlassFrame(image: lens?.render(pixels, region: geometry), luminance: luminance)
        submit(frame, for: region, stream: stream)
    }

    private func submit(_ frame: DockGlassFrame?, for region: DockGlassRegion, stream: SCStream) {
        // While the main thread is busy, keep the newest frame ready to display.
        let schedule = presentationLock.withLock {
            let needsDelivery = pendingFrame == nil
            pendingFrame = (stream, region, frame)
            return needsDelivery
        }
        guard schedule else { return }
        DispatchQueue.main.async {
            let latest = self.presentationLock.withLock {
                let frame = self.pendingFrame
                self.pendingFrame = nil
                return frame
            }
            if let latest { self.onFrame?(latest.stream, latest.region, latest.frame) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStop?(stream, error) }
    }

    private func luminance(_ pixels: CVPixelBuffer, region: DockGlassRegion, skipUnchanged: Bool) -> CGFloat? {
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        if skipUnchanged {
            let byteCount = stride * CVPixelBufferGetHeight(pixels)
            if previousPixels.count == byteCount,
               previousPixels.withUnsafeBytes({ memcmp($0.baseAddress!, address, byteCount) == 0 }) {
                return nil
            }
            previousPixels = Data(bytes: address, count: byteCount)
        }

        // Read the column behind the summary, where the labels and numbers actually sit.
        let bytes = address.assumingMemoryBound(to: UInt8.self)
        let light = Self.linearLight
        let left = region.dock.minX - region.source.minX
        let top = region.dock.minY - region.source.minY
        var total: CGFloat = 0
        for row in 0..<12 {
            let y = Int((top + 34 + CGFloat(row) * 6) * region.scale)
            for column in 1...8 {
                let x = Int((left + region.dock.width * (0.22 + CGFloat(column) * 0.06)) * region.scale)
                let pixel = bytes + y * stride + x * 4
                total += 0.2126 * light[Int(pixel[2])] + 0.7152 * light[Int(pixel[1])] + 0.0722 * light[Int(pixel[0])]
            }
        }
        return total / 96
    }
}

/// Serialize ScreenCaptureKit updates so dragging or changing displays cannot start overlapping streams.
@MainActor
private final class DockGlassCapture {
    private var stream: SCStream?
    private var output: DockGlassOutput?
    private var desired: DockGlassRegion?
    private var configured: DockGlassRegion?
    private var updateTask: Task<Void, Never>?
    var present: ((DockGlassFrame?) -> Void)?

    func use(_ region: DockGlassRegion?) {
        guard desired != region else { return }
        desired = region
        output?.use(region)
        if updateTask == nil {
            updateTask = Task { await reconcile() }
        }
    }

    private func reconcile() async {
        defer { updateTask = nil }
        while configured != desired {
            let target = desired
            if target?.displayID != configured?.displayID || target?.windowID != configured?.windowID {
                await stop()
            }
            guard let target else { continue }
            do {
                if let stream {
                    if configured?.sharesCaptureArea(with: target) != true {
                        try await stream.updateConfiguration(target.configuration)
                    }
                } else {
                    try await start(target)
                }
                if stream != nil { configured = target }
            } catch {
                await stop()
                if desired == target {
                    desired = nil
                    present?(nil)
                    NSLog("TokenMeter dock glass capture: %@", error.localizedDescription)
                }
            }
        }
    }

    private func start(_ target: DockGlassRegion) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let desired, desired.windowID == target.windowID, desired.displayID == target.displayID else { return }
        guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
            throw CaptureError.displayUnavailable
        }
        let filter: SCContentFilter
        if let window = content.windows.first(where: { $0.windowID == target.windowID }) {
            filter = SCContentFilter(display: display, excludingWindows: [window])
        } else if let app = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) {
            filter = SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: [])
        } else {
            throw CaptureError.dockUnavailable
        }

        let output = DockGlassOutput()
        output.use(desired)
        output.onFrame = { [weak self] stream, region, frame in
            guard let self, self.stream === stream, self.desired == region else { return }
            self.present?(frame)
        }
        output.onStop = { [weak self] stream, error in
            guard let self, self.stream === stream else { return }
            self.use(nil)
            self.present?(nil)
            NSLog("TokenMeter dock glass capture stopped: %@", error.localizedDescription)
        }
        let stream = SCStream(filter: filter, configuration: target.configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        self.stream = stream
        self.output = output
        try await stream.startCapture()
    }

    private func stop() async {
        let previous = stream
        stream = nil
        output?.use(nil)
        output = nil
        configured = nil
        try? await previous?.stopCapture()
    }

    private enum CaptureError: Error {
        case displayUnavailable
        case dockUnavailable
    }
}

@MainActor
final class DockBackdropView: NSView {
    nonisolated static let cornerRadius: CGFloat = 30
    private let texture = CALayer()
    private let textureMask = CALayer()
    private let bodyMask = CALayer()
    private let edgeMask = CALayer()
    private let fallback = CALayer()
    private let capture = DockGlassCapture()
    private var region: DockGlassRegion?
    private var lastRenderedRegion: DockGlassRegion?
    private var darkBackdrop: Bool?
    private var opacity: Double
    private var active = false
    private var displayAwake = true
    private var authorized = false
    private let onToneChange: (Bool?) -> Void

    init(frame: NSRect, content: NSView, opacity: Double, onToneChange: @escaping (Bool?) -> Void) {
        self.opacity = opacity
        self.onToneChange = onToneChange
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        // The bevel stays refractive while the slider changes coverage of the glass face.
        bodyMask.backgroundColor = NSColor.white.cgColor
        edgeMask.contentsScale = 2
        textureMask.addSublayer(bodyMask)
        textureMask.addSublayer(edgeMask)
        texture.mask = textureMask
        layer?.addSublayer(fallback)
        layer?.addSublayer(texture)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        capture.present = { [weak self] frame in self?.present(frame) }
        updateMaterial()
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        active = true
        let desktop = NSWorkspace.shared.notificationCenter
        desktop.addObserver(self, selector: #selector(displayOptionsChanged(_:)),
                            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        desktop.addObserver(self, selector: #selector(displaySlept(_:)),
                            name: NSWorkspace.screensDidSleepNotification, object: nil)
        desktop.addObserver(self, selector: #selector(displayWoke(_:)),
                            name: NSWorkspace.screensDidWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive(_:)),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)),
                                               name: NSWindow.didChangeScreenNotification, object: window)
        recheckPermission()
    }

    func stop() {
        active = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        updateRegion()
    }

    func recheckPermission() {
        authorized = CGPreflightScreenCaptureAccess()
        updateRegion()
    }

    func updateRegion() {
        let next: DockGlassRegion?
        if active, authorized, displayAwake, !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
           let window, window.isVisible, window.occlusionState.contains(.visible) {
            next = DockGlassRegion(window: window, reusing: region)
        } else {
            next = nil
        }
        if region != next {
            region = next
            if let next {
                let nearby = lastRenderedRegion.map { rendered in
                    rendered.displayID == next.displayID && rendered.dock.size == next.dock.size
                        && hypot(rendered.dock.minX - next.dock.minX, rendered.dock.minY - next.dock.minY) <= 12
                } ?? false
                if !nearby { setTexture(nil) }
            } else {
                present(nil)
            }
        }
        capture.use(next)
    }

    func setOpacity(_ value: Double) {
        opacity = value
        updateMaterial()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        texture.frame = bounds
        fallback.frame = bounds
        let maskBounds = CGRect(origin: .zero, size: bounds.size)
        if edgeMask.bounds.size != maskBounds.size {
            edgeMask.contents = Self.makeEdgeMask(size: maskBounds.size)
        }
        textureMask.frame = maskBounds
        bodyMask.frame = maskBounds
        edgeMask.frame = maskBounds
        CATransaction.commit()
    }

    private static func makeEdgeMask(size: CGSize) -> CGImage? {
        let width = Int(ceil(size.width * 2))
        let height = Int(ceil(size.height * 2))
        guard width > 0, height > 0 else { return nil }

        let radius = cornerRadius
        let stepX = size.width / CGFloat(width)
        let stepY = size.height / CGFloat(height)
        let edgeX = (0..<width).map { x in
            abs((CGFloat(x) + 0.5) * stepX - size.width / 2) - (size.width / 2 - radius)
        }
        let rowBytes = width * 4
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { buffer in
            let pixels = buffer.bindMemory(to: UInt32.self)
            for y in 0..<height {
                let dy = abs((CGFloat(y) + 0.5) * stepY - size.height / 2) - (size.height / 2 - radius)
                for x in 0..<width {
                    let dx = edgeX[x]
                    let depth = radius - hypot(max(dx, 0), max(dy, 0)) - min(max(dx, dy), 0)
                    let t = min(max((26 - depth) / 10, 0), 1)
                    let alpha = UInt32((255 * t * t * (3 - 2 * t)).rounded())
                    // Premultiplied white: each channel is equal to the alpha.
                    pixels[y * width + x] = alpha * 0x01010101
                }
            }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMaterial()
    }

    @objc private func windowChanged(_ notification: Notification) {
        updateRegion()
    }

    @objc private func appBecameActive(_ notification: Notification) {
        recheckPermission()
    }

    @objc private func displayOptionsChanged(_ notification: Notification) {
        updateRegion()
        updateMaterial()
    }

    @objc private func displaySlept(_ notification: Notification) {
        displayAwake = false
        updateRegion()
    }

    @objc private func displayWoke(_ notification: Notification) {
        displayAwake = true
        recheckPermission()
    }

    private func present(_ frame: DockGlassFrame?) {
        let dark = frame.map { frame in
            // A dead band around the black/white contrast crossover prevents flicker.
            let threshold: CGFloat = darkBackdrop.map { $0 ? 0.22 : 0.16 } ?? 0.18
            return frame.luminance < threshold
        }
        let textureChanged = (texture.contents == nil) != (frame?.image == nil)
        setTexture(frame?.image)
        if darkBackdrop != dark {
            darkBackdrop = dark
            onToneChange(dark)
        }
        if textureChanged { updateMaterial() }
    }

    private func setTexture(_ image: CGImage?) {
        lastRenderedRegion = image == nil ? nil : region
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        texture.contents = image
        CATransaction.commit()
    }

    private func updateMaterial() {
        let amount = Float(min(max(opacity, 0), 1))
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let hasRefraction = texture.contents != nil && !reduceTransparency
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        texture.opacity = hasRefraction ? 1 : 0
        bodyMask.opacity = amount
        fallback.backgroundColor = (dark ? NSColor(white: 0.055, alpha: 1) : .white).cgColor
        fallback.opacity = hasRefraction ? 0 : (reduceTransparency && amount > 0 ? 1 : amount)
        CATransaction.commit()
    }
}
#endif
