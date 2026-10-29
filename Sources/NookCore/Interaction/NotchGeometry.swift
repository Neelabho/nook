import CoreGraphics
import Foundation

/// Display facts captured from `NSScreen` (kept AppKit-free so layout math is testable).
public struct DisplayDescriptor: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top`: non-zero on notched built-in displays.
    public var safeAreaTop: CGFloat
    /// `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`: menu bar space either side of the notch.
    public var auxiliaryTopLeft: CGRect?
    public var auxiliaryTopRight: CGRect?
    public var isBuiltIn: Bool
    public var scale: CGFloat

    public init(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?, isBuiltIn: Bool, scale: CGFloat) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
        self.isBuiltIn = isBuiltIn
        self.scale = scale
    }
}

/// User calibration of the activation region.
public struct ActivationCalibration: Codable, Equatable, Sendable {
    /// Extra width added to (or removed from) the detected notch width, split evenly on both sides.
    public var extraWidth: Double
    /// Height of the activation strip. `0` means "match the notch / menu bar height".
    public var height: Double
    /// Horizontal nudge of the activation strip and panel.
    public var horizontalOffset: Double

    public init(extraWidth: Double = 0, height: Double = 0, horizontalOffset: Double = 0) {
        self.extraWidth = extraWidth
        self.height = height
        self.horizontalOffset = horizontalOffset
    }

    public static let extraWidthRange: ClosedRange<Double> = -60...240
    public static let heightRange: ClosedRange<Double> = 0...60
    public static let offsetRange: ClosedRange<Double> = -200...200

    public func validated() -> ActivationCalibration {
        ActivationCalibration(
            extraWidth: extraWidth.clamped(to: Self.extraWidthRange),
            height: height.clamped(to: Self.heightRange),
            horizontalOffset: horizontalOffset.clamped(to: Self.offsetRange)
        )
    }
}

public struct NotchLayout: Equatable, Sendable {
    /// The physical notch, if the display has one.
    public var notchRect: CGRect?
    /// Where hovering/dropping activates Nook (screen coordinates, origin bottom-left).
    public var activationRect: CGRect
    /// Frame of the expanded panel.
    public var expandedRect: CGRect
    /// The size of the closed shape drawn at the top of the panel (blends into the notch).
    public var closedShapeSize: CGSize
    /// Frame of the closed notch while the "now playing" peek is shown: the notch band widened by
    /// a wing on each side (album art left, waves right). Also the hover area while it is shown.
    public var peekRect: CGRect
    /// Width of each peek wing.
    public var peekWing: CGFloat
    public var hasNotch: Bool { notchRect != nil }
}

public enum NotchGeometry {
    /// Fallback strip width for displays without a notch.
    public static let fallbackActivationWidth: CGFloat = 200

    public static func notchRect(for display: DisplayDescriptor) -> CGRect? {
        guard display.safeAreaTop > 0,
              let left = display.auxiliaryTopLeft,
              let right = display.auxiliaryTopRight,
              right.minX > left.maxX else { return nil }
        let height = display.safeAreaTop
        return CGRect(x: left.maxX, y: display.frame.maxY - height, width: right.minX - left.maxX, height: height)
    }

    public static func layout(for display: DisplayDescriptor, calibration: ActivationCalibration, expandedSize: CGSize) -> NotchLayout {
        let cal = calibration.validated()
        let notch = notchRect(for: display)
        let menuBarHeight = max(display.frame.maxY - display.visibleFrame.maxY, 24)
        let baseWidth = notch?.width ?? fallbackActivationWidth
        let baseHeight = notch?.height ?? menuBarHeight
        let centerX = (notch?.midX ?? display.frame.midX) + CGFloat(cal.horizontalOffset)

        let width = max(80, baseWidth + CGFloat(cal.extraWidth))
        let height = cal.height > 0 ? CGFloat(cal.height) : baseHeight
        var activation = CGRect(x: centerX - width / 2, y: display.frame.maxY - height, width: width, height: height)
        activation = activation.clampedHorizontally(into: display.frame)

        var panelWidth = min(expandedSize.width, display.frame.width - 16).rounded()
        // Window frames snap to whole points. Match the width's parity to the notch centre so the
        // panel stays exactly centred (e.g. centre 755.5 → odd width).
        let centerIsHalf = (centerX * 2).rounded().truncatingRemainder(dividingBy: 2) != 0
        if centerIsHalf != (panelWidth.truncatingRemainder(dividingBy: 2) != 0) { panelWidth += 1 }
        let panelHeight = min(expandedSize.height, display.frame.height * 0.8)
        var expanded = CGRect(x: centerX - panelWidth / 2, y: display.frame.maxY - panelHeight, width: panelWidth, height: panelHeight)
        expanded = expanded.clampedHorizontally(into: display.frame)

        // Peek: the full notch band, widened by a roughly square wing each side. Whole points,
        // with the same centring parity rule as the panel.
        let wing = (baseHeight * 1.3).rounded()
        var peekWidth = (baseWidth + 2 * wing).rounded()
        if centerIsHalf != (peekWidth.truncatingRemainder(dividingBy: 2) != 0) { peekWidth += 1 }
        var peek = CGRect(x: centerX - peekWidth / 2, y: display.frame.maxY - baseHeight, width: peekWidth, height: baseHeight)
        peek = peek.clampedHorizontally(into: display.frame)

        return NotchLayout(
            notchRect: notch,
            activationRect: activation.integralToScale(display.scale),
            expandedRect: expanded.integralToScale(1),
            closedShapeSize: CGSize(width: width, height: height),
            peekRect: peek.integralToScale(1),
            peekWing: (peek.width - baseWidth) / 2
        )
    }
}

extension CGRect {
    func clampedHorizontally(into bounds: CGRect) -> CGRect {
        var r = self
        if r.minX < bounds.minX { r.origin.x = bounds.minX }
        if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        return r
    }

    /// Snap to device pixels so the panel edge never blurs across a pixel boundary.
    func integralToScale(_ scale: CGFloat) -> CGRect {
        guard scale > 0 else { return self }
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        return CGRect(x: snap(minX), y: snap(minY), width: snap(width), height: snap(height))
    }
}

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
