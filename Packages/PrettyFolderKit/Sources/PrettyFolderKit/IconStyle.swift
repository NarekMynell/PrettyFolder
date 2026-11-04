import CoreGraphics

/// How the picture is scaled into its rectangle.
public enum FitMode: String, Codable, Sendable, CaseIterable {
    /// Covers the whole rectangle; whatever sticks out is cropped.
    case fill
    /// The whole picture stays visible; it grows until one side touches the rectangle.
    case fit
}

/// Where a picture sits on the folder icon and how it is scaled.
///
/// The rectangle is stored as fractions of the square icon canvas with the origin in
/// the top-left corner, so the same style works for every icon size. It can be bigger than
/// the canvas, which makes the picture bigger too: the folder's outline cuts off whatever
/// lies outside it.
public struct IconStyle: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var mode: FitMode

    /// Smallest allowed side, as a fraction of the canvas.
    public static let minimumSide = 0.08
    /// Largest allowed side: eight times the canvas.
    public static let maximumSide = 8.0

    /// Covers the front of the standard folder with a comfortable margin.
    public static let standard = IconStyle(x: 0.10, y: 0.33, width: 0.80, height: 0.47, mode: .fill)

    public init(x: Double, y: Double, width: Double, height: Double, mode: FitMode) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.mode = mode
        clamp()
    }

    public init(rect: CGRect, mode: FitMode) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, mode: mode)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.decode(Double.self, forKey: .x),
            y: try container.decode(Double.self, forKey: .y),
            width: try container.decode(Double.self, forKey: .width),
            height: try container.decode(Double.self, forKey: .height),
            mode: (try? container.decode(FitMode.self, forKey: .mode)) ?? .fill
        )
    }

    /// The rectangle in unit coordinates, origin top-left.
    public var rect: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.minX
            y = newValue.minY
            width = newValue.width
            height = newValue.height
            clamp()
        }
    }

    /// Where a side of `length` can start on its axis. No longer than the canvas, it stays on
    /// the canvas; longer, it covers all of it: a picture made that big never leaves part of
    /// the folder bare, however it is moved.
    public static func origins(forSide length: Double) -> ClosedRange<Double> {
        min(0, 1 - length)...max(0, 1 - length)
    }

    /// Whether `rect` is a rectangle a style can have as it is: no side below the smallest or
    /// above the largest, and where `origins` lets it be.
    public static func allows(_ rect: CGRect, tolerance: Double = 1e-9) -> Bool {
        func fits(_ origin: Double, _ length: Double) -> Bool {
            let origins = Self.origins(forSide: length)
            return length >= minimumSide - tolerance && length <= maximumSide + tolerance
                && origin >= origins.lowerBound - tolerance && origin <= origins.upperBound + tolerance
        }
        return fits(rect.minX, rect.width) && fits(rect.minY, rect.height)
    }

    /// Keeps the rectangle between the smallest and the largest size and where `origins` lets
    /// it be. Anything that is not a finite number falls back to the standard rectangle.
    private mutating func clamp() {
        guard [x, y, width, height].allSatisfy(\.isFinite) else {
            (x, y, width, height) = (Self.standard.x, Self.standard.y, Self.standard.width, Self.standard.height)
            return
        }
        width = min(max(width, Self.minimumSide), Self.maximumSide)
        height = min(max(height, Self.minimumSide), Self.maximumSide)
        x = x.clamped(to: Self.origins(forSide: width))
        y = y.clamped(to: Self.origins(forSide: height))
    }
}

/// Where a picture sits in its rectangle and how far it is turned. It belongs to one folder's
/// picture: a new picture starts in the middle, upright.
///
/// Its size is always the one Fill or Fit gives it, turned as it is: to make the picture
/// bigger, the rectangle grows. Where it is bigger or smaller than its rectangle, `x` and `y`
/// put it on each axis from 0 (against the left or top edge) to 1 (against the right or bottom
/// edge), with 0.5 in the middle. With Fill they pick the part of the picture that shows; with
/// Fit, where the picture sits. (A picture turned by something other than quarter turns
/// moves along its own sides with Fill: see `IconGeometry.layout`.)
public struct PicturePlacement: Codable, Sendable, Hashable {
    public let x: Double
    public let y: Double
    /// How far the picture is turned counterclockwise, in degrees, above −180 and up to 180.
    public let rotation: Double

    /// In the middle and upright: where every picture starts.
    public static let natural = PicturePlacement(x: 0.5, y: 0.5)

    public init(x: Double, y: Double, rotation: Double = 0) {
        self.x = Self.clamped(x)
        self.y = Self.clamped(y)
        self.rotation = Self.normalized(rotation)
    }

    /// Anything else that was kept with it (a zoom, from a build that had one) is let go;
    /// a placement from before pictures could turn is upright.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.decode(Double.self, forKey: .x),
            y: try container.decode(Double.self, forKey: .y),
            rotation: try container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        )
    }

    /// Upright pictures are saved the way they were before pictures could turn.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        if rotation != 0 { try container.encode(rotation, forKey: .rotation) }
    }

    private enum CodingKeys: String, CodingKey {
        case x, y, rotation
    }

    /// In the middle of its rectangle, however it is turned.
    public var isCentered: Bool { x == 0.5 && y == 0.5 }

    /// The same placement with the picture in the middle of its rectangle.
    public var centered: PicturePlacement {
        PicturePlacement(x: 0.5, y: 0.5, rotation: rotation)
    }

    /// Between the edges; anything that isn't a finite number is the middle.
    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0.5
    }

    /// The same turn between −180 (not included) and 180 degrees; anything that isn't a
    /// finite number is upright. Values a hair from a whole degree are taken as that degree,
    /// so turning by quarter turns never drifts.
    static func normalized(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var turned = degrees.truncatingRemainder(dividingBy: 360)
        if turned <= -180 { turned += 360 }
        if turned > 180 { turned -= 360 }
        let whole = turned.rounded()
        if abs(turned - whole) < 1e-9 { turned = whole }
        return turned == 0 ? 0 : turned
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<Double>) -> CGFloat {
        CGFloat(Double(self).clamped(to: range))
    }
}
