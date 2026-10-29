import Foundation

/// How a glass surface should render, given the OS and the user's accessibility settings.
public enum GlassRenderingMode: String, Equatable, Sendable {
    /// System Liquid Glass (macOS 26+): the window server lenses/refracts the content behind it.
    case liquidGlass
    /// Blur + tint approximation (older macOS): translucent, but no refraction.
    case material
    /// Reduce Transparency: a solid surface with no see-through.
    case opaque
}

public struct GlassAppearance: Equatable, Sendable {
    public var mode: GlassRenderingMode
    /// Spring/move transitions; false under Reduce Motion (fades only).
    public var animatesTransitions: Bool
    /// The soft accent glow beneath the pill.
    public var showsAccentGlow: Bool
    /// Border strength; raised under Increase Contrast.
    public var borderOpacity: Double
    /// Decorative specular highlight on the upper edge.
    public var showsSpecularHighlight: Bool

    public static func resolve(
        supportsLiquidGlass: Bool,
        reduceTransparency: Bool,
        reduceMotion: Bool,
        increaseContrast: Bool
    ) -> GlassAppearance {
        let mode: GlassRenderingMode = reduceTransparency ? .opaque : (supportsLiquidGlass ? .liquidGlass : .material)
        return GlassAppearance(
            mode: mode,
            animatesTransitions: !reduceMotion,
            showsAccentGlow: mode != .opaque && !increaseContrast,
            borderOpacity: increaseContrast ? 0.7 : (mode == .opaque ? 0.22 : 0.4),
            showsSpecularHighlight: mode != .opaque
        )
    }
}

/// A small bounded LRU cache (artwork thumbnails etc.), so memory never grows without limit.
public struct BoundedCache<Key: Hashable, Value> {
    public let capacity: Int
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    public var count: Int { storage.count }

    public mutating func value(for key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    public mutating func insert(_ value: Value, for key: Key) {
        storage[key] = value
        touch(key)
        while order.count > capacity {
            storage[order.removeFirst()] = nil
        }
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
