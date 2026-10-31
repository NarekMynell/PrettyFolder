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
