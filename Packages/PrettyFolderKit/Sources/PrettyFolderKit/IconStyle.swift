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
/// the top-left corner, so the same style works for every icon size.
public struct IconStyle: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var mode: FitMode

    /// Smallest allowed side, as a fraction of the canvas.
    public static let minimumSide = 0.08

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

    /// Keeps the rectangle inside the canvas and above the minimum size.
    /// Anything that is not a finite number falls back to the standard rectangle.
    private mutating func clamp() {
        guard [x, y, width, height].allSatisfy(\.isFinite) else {
            (x, y, width, height) = (Self.standard.x, Self.standard.y, Self.standard.width, Self.standard.height)
            return
        }
        width = min(max(width, Self.minimumSide), 1)
        height = min(max(height, Self.minimumSide), 1)
        x = min(max(x, 0), 1 - width)
        y = min(max(y, 0), 1 - height)
    }
}

/// Where a picture sits in its rectangle, and how big it is there. It belongs to one folder's
/// picture: a new picture starts in the middle, at the size Fill or Fit gives it.
///
/// Zoomed in, more of the picture sticks out of the rectangle and is cut off; zoomed out, it
/// leaves room around it. On each axis it goes as far as that allows, from 0 (against the left
/// or top edge) to 1 (against the right or bottom edge), with 0.5 in the middle. So a picture
/// bigger than its rectangle always covers it, and a smaller one always stays inside.
public struct PicturePlacement: Codable, Sendable, Hashable {
    public let x: Double
    public let y: Double
    /// How big the picture is next to the size Fill or Fit gives it.
    public let zoom: Double

    /// From a quarter of that size to eight times as big.
    public static let zoomRange: ClosedRange<Double> = 0.25...8

    /// In the middle, at the size Fill or Fit gives it: where every picture starts.
    public static let natural = PicturePlacement(x: 0.5, y: 0.5)

    public init(x: Double, y: Double, zoom: Double = 1) {
        self.x = Self.clamped(x)
        self.y = Self.clamped(y)
        self.zoom = Self.clampedZoom(zoom)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.decode(Double.self, forKey: .x),
            y: try container.decode(Double.self, forKey: .y),
            // Pictures placed before they could be zoomed have none.
            zoom: try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        )
    }

    /// The same size, in the middle.
    public var centered: PicturePlacement { PicturePlacement(x: 0.5, y: 0.5, zoom: zoom) }

    /// Between the edges; anything that isn't a finite number is the middle.
    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0.5
    }

    /// Within `zoomRange`; anything that isn't a finite number is the natural size.
    public static func clampedZoom(_ zoom: Double) -> Double {
        zoom.isFinite ? min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound) : 1
    }
}
