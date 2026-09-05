import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
import PrizmXServices

/// System-widget sizes: 1×1 small, 2×1 medium, 2×2 large.
public enum WidgetSize: String, Sendable, Codable {
    case small
    case medium
    case large

    /// Columns in a 4-wide small-cell grid.
    public var columns: Int {
        switch self {
        case .small: 1
        case .medium, .large: 2
        }
    }

    public var rows: Int {
        switch self {
        case .small, .medium: 1
        case .large: 2
        }
    }

    public func pixelSize(unit: CGFloat, spacing: CGFloat) -> CGSize {
        CGSize(
            width: unit * CGFloat(columns) + spacing * CGFloat(columns - 1),
            height: unit * CGFloat(rows) + spacing * CGFloat(rows - 1)
        )
    }
}

private struct WidgetUnitKey: EnvironmentKey {
    static let defaultValue: CGFloat = 160
}

extension EnvironmentValues {
    public var widgetUnit: CGFloat {
        get { self[WidgetUnitKey.self] }
        set { self[WidgetUnitKey.self] = newValue }
    }
}

/// 4 small cells per row. Two smalls + gap = one medium/large width;
/// two mediums stacked + gap = one large height.
public enum WidgetGrid {
    public static let columns = 4
    public static let spacing: CGFloat = 16
    public static let minUnit: CGFloat = 140
    public static let maxUnit: CGFloat = 180

    /// Cell edge length for a 4-column board. Clamped so cards neither wrap nor stretch empty.
    public static func unit(for contentWidth: CGFloat) -> CGFloat {
        let raw = (contentWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        return min(maxUnit, max(minUnit, raw))
    }

    public static func boardWidth(unit: CGFloat) -> CGFloat {
        CGFloat(columns) * unit + CGFloat(columns - 1) * spacing
    }

    public static func boardHeight(rows: Int, unit: CGFloat) -> CGFloat {
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * unit + CGFloat(rows - 1) * spacing
    }
}

/// macOS type ramp for Home cards. Labels use 11pt (`subheadline` / smallSystemFont),
/// not `caption2` (10pt, Apple's floor for incidental text).
public enum WidgetTypography {
    public static let cardTitle = Font.caption.weight(.semibold)
    public static let metric = Font.title.monospacedDigit().weight(.semibold)
    public static let name = Font.title.weight(.semibold)
    public static let unit = Font.caption.monospacedDigit()
    public static let footLabel = Font.subheadline
    public static let footValue = Font.body.monospacedDigit().weight(.semibold)
    public static let hint = Font.caption
    public static let switchTitle = Font.subheadline.weight(.semibold)
    public static let switchSubtitle = Font.caption
}

public enum WidgetChrome {
    public static let padding: CGFloat = 16
    public static let cornerRadius: CGFloat = 12
    public static let plotFraction: CGFloat = 0.8

    #if os(macOS)
    /// Resolves a dark/light pair against the window appearance.
    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    #endif

    /// Canvas behind Home cards. System Settings light: white window with
    /// 248-gray groups; dark keeps the system window background.
    public static var page: Color {
        #if os(macOS)
        adaptive(dark: .windowBackgroundColor, light: .white)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// Group fill measured from System Settings: 248 gray on the white
    /// window in light; sRGB 40/40/40 lift on the dark window.
    public static var fill: Color {
        #if os(macOS)
        adaptive(
            dark: NSColor(srgbRed: 40 / 255, green: 40 / 255, blue: 40 / 255, alpha: 1),
            light: NSColor(srgbRed: 248 / 255, green: 248 / 255, blue: 248 / 255, alpha: 1)
        )
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    /// Settings group shadow: soft lift in light, flat in dark.
    public static var cardShadow: Color {
        #if os(macOS)
        adaptive(dark: .clear, light: NSColor.black.withAlphaComponent(0.08))
        #else
        Color.black.opacity(0.08)
        #endif
    }

    /// Segmented-control track: light gray trough on white, faint lift in dark.
    public static var chipTrack: Color {
        #if os(macOS)
        adaptive(
            dark: NSColor.white.withAlphaComponent(0.08),
            light: NSColor.black.withAlphaComponent(0.08)
        )
        #else
        Color.primary.opacity(0.06)
        #endif
    }

    /// Selected chip: white pill in light (Settings), faint white lift in dark.
    public static var chipSelected: Color {
        #if os(macOS)
        adaptive(dark: NSColor.white.withAlphaComponent(0.14), light: .white)
        #else
        Color.primary.opacity(0.12)
        #endif
    }

    /// Light segmented pills sit on a shadow; dark chips are flat.
    public static var chipShadow: Color {
        #if os(macOS)
        adaptive(dark: .clear, light: NSColor.black.withAlphaComponent(0.14))
        #else
        Color.black.opacity(0.14)
        #endif
    }

    public static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

/// Fixed-size card shell: Settings-style fill, no stroke. `padded` insets content.
public struct WidgetCard<Content: View>: View {
    @Environment(\.widgetUnit) private var unit

    public var size: WidgetSize
    public var padded: Bool
    @ViewBuilder public var content: () -> Content

    public init(
        size: WidgetSize,
        padded: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.size = size
        self.padded = padded
        self.content = content
    }

    public var body: some View {
        let pixel = size.pixelSize(unit: unit, spacing: WidgetGrid.spacing)
        content()
            .padding(padded ? WidgetChrome.padding : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(WidgetChrome.shape)
            .background(WidgetChrome.fill, in: WidgetChrome.shape)
            .shadow(color: WidgetChrome.cardShadow, radius: 2.5, y: 1.5)
            .frame(width: pixel.width, height: pixel.height)
    }
}

/// Top-leading icon + uppercase title, optional headline, trailing accessory.
public struct WidgetHeader<Accessory: View>: View {
    public var title: String
    public var systemImage: String?
    public var headline: String?
    public var size: WidgetSize
    @ViewBuilder public var accessory: () -> Accessory

    public init(
        title: String,
        systemImage: String? = nil,
        headline: String? = nil,
        size: WidgetSize = .small,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.systemImage = systemImage
        self.headline = headline
        self.size = size
        self.accessory = accessory
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(WidgetTypography.cardTitle)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                Text(title.uppercased())
                    .font(WidgetTypography.cardTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                accessory()
            }
            if let headline {
                Text(headline)
                    .font(
                        size == .small
                            ? .title2.monospacedDigit().weight(.semibold)
                            : .title.monospacedDigit().weight(.semibold)
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
            }
        }
    }
}

extension WidgetHeader where Accessory == EmptyView {
    public init(
        title: String,
        systemImage: String? = nil,
        headline: String? = nil,
        size: WidgetSize = .small
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            headline: headline,
            size: size,
            accessory: { EmptyView() }
        )
    }
}

/// Thin wrapper: `WidgetCard` + `WidgetHeader` + content.
public struct InfoWidget<Content: View, Accessory: View>: View {
    public var title: String
    public var systemImage: String?
    public var headline: String?
    public var size: WidgetSize
    @ViewBuilder public var accessory: () -> Accessory
    @ViewBuilder public var content: () -> Content

    public init(
        title: String,
        systemImage: String? = nil,
        headline: String? = nil,
        size: WidgetSize = .small,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.headline = headline
        self.size = size
        self.accessory = accessory
        self.content = content
    }

    public var body: some View {
        WidgetCard(size: size) {
            VStack(alignment: .leading, spacing: 10) {
                WidgetHeader(
                    title: title,
                    systemImage: systemImage,
                    headline: headline,
                    size: size,
                    accessory: accessory
                )
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

extension InfoWidget where Accessory == EmptyView {
    public init(
        title: String,
        systemImage: String? = nil,
        headline: String? = nil,
        size: WidgetSize = .small,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            headline: headline,
            size: size,
            accessory: { EmptyView() },
            content: content
        )
    }
}
