// Layer 2 — Rendering: pre-renders each planet's name into a layer of a 2D-array
// texture. Caches RGBA bytes by name so unchanged names skip the expensive Core
// Graphics pass; mipmaps eliminate aliasing when labels are small on screen.
import AppKit
import Metal

@MainActor
final class LabelAtlas {

    static let layerWidth  = 640
    static let layerHeight = 144
    static let initialCapacity = 128

    private let device: MTLDevice
    private(set) var texture: MTLTexture?
    private(set) var widthFractions:  [Float] = []
    private(set) var heightFractions: [Float] = []

    private var cache: [String: (data: [UInt8], widthFraction: Float, heightFraction: Float)] = [:]
    private var allocatedSlices = 0
    private var mipLevels: Int = 1
    private var blitQueue: MTLCommandQueue?

    init(device: MTLDevice) {
        self.device = device
        self.blitQueue = device.makeCommandQueue()
    }

    func rebuild(names: [String]) {
        widthFractions.removeAll(keepingCapacity: true)
        heightFractions.removeAll(keepingCapacity: true)
        guard !names.isEmpty else { return }

        ensureTexture(slices: max(names.count, Self.initialCapacity))
        guard let tex = texture else { return }

        for (i, name) in names.enumerated() {
            let entry: (data: [UInt8], widthFraction: Float, heightFraction: Float)
            if let cached = cache[name] {
                entry = cached
            } else {
                entry = renderToRGBA(text: name)
                cache[name] = entry
            }
            tex.replace(region: MTLRegionMake2D(0, 0, Self.layerWidth, Self.layerHeight),
                        mipmapLevel: 0,
                        slice: i,
                        withBytes: entry.data,
                        bytesPerRow: Self.layerWidth * 4,
                        bytesPerImage: Self.layerWidth * Self.layerHeight * 4)
            widthFractions.append(entry.widthFraction)
            heightFractions.append(entry.heightFraction)
        }

        // Regenerate mipmaps after every change so smaller-than-native sampling
        // doesn't alias.
        if mipLevels > 1, let q = blitQueue,
           let cmd = q.makeCommandBuffer(),
           let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cmd.commit()
        }

        let active = Set(names)
        cache = cache.filter { active.contains($0.key) }
    }

    private func ensureTexture(slices: Int) {
        if texture != nil, slices <= allocatedSlices { return }
        let cap = max(slices, Self.initialCapacity)
        let levels = Int(log2(Double(max(Self.layerWidth, Self.layerHeight)))) + 1
        let desc = MTLTextureDescriptor()
        desc.textureType      = .type2DArray
        desc.pixelFormat      = .rgba8Unorm
        desc.width            = Self.layerWidth
        desc.height           = Self.layerHeight
        desc.arrayLength      = cap
        desc.mipmapLevelCount = levels
        desc.usage            = [.shaderRead]
        // Shared so .replace(slice:withBytes:) works directly; mipmap blit is fine on macOS.
        desc.storageMode      = .shared
        texture          = device.makeTexture(descriptor: desc)
        allocatedSlices  = cap
        mipLevels        = levels
    }

    /// Pill background + white text — high contrast against any wallpaper.
    /// Returns the RGBA bytes and the pill's width / height as fractions of the layer.
    private func renderToRGBA(text: String) -> ([UInt8], Float, Float) {
        let w = Self.layerWidth, h = Self.layerHeight
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: w * h * 4)

        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = data.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(data: raw.baseAddress, width: w, height: h,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: cs, bitmapInfo: info)
        }) else { return (data, 0, 0) }

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        // Measure the text first so the pill is sized to fit.
        let font = NSFont.systemFont(ofSize: 40, weight: .semibold)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font:            font,
            .foregroundColor: NSColor.white
        ]
        let attr = NSAttributedString(string: text, attributes: textAttrs)
        let measured = attr.size()

        // Pill geometry — clamp width so the pill never exceeds the layer.
        let pillPadX: CGFloat = 20
        let pillPadY: CGFloat = 10
        let maxPillW = CGFloat(w) - 16
        let pillW = min(measured.width + pillPadX * 2, maxPillW)
        let pillH = measured.height + pillPadY * 2
        let pillX = (CGFloat(w) - pillW) * 0.5
        let pillY = (CGFloat(h) - pillH) * 0.5

        let pillRect = NSRect(x: pillX, y: pillY, width: pillW, height: pillH)
        let pill = NSBezierPath(roundedRect: pillRect, xRadius: pillH * 0.45, yRadius: pillH * 0.45)
        NSColor.black.withAlphaComponent(0.78).setFill()
        pill.fill()

        // Text — clipped to pill width with horizontal centering.
        let textW = min(measured.width, pillW - pillPadX * 2)
        let textRect = NSRect(x: pillX + (pillW - textW) * 0.5,
                              y: pillY + pillPadY,
                              width: textW,
                              height: measured.height)
        attr.draw(in: textRect)

        NSGraphicsContext.restoreGraphicsState()

        return (data,
                min(1.0, Float(pillW) / Float(w)),
                min(1.0, Float(pillH) / Float(h)))
    }
}
