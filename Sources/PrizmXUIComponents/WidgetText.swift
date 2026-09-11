import SwiftUI
import PrizmXServices

/// Icon + uppercase label, then the metric line. Shared by 1×1 Home tiles
/// (latency / connections / upload / download) so those three pieces line up.
public struct WidgetMetricBlock<Accessory: View, Value: View>: View {
    public var title: String
    public var systemImage: String
    @ViewBuilder public var accessory: () -> Accessory
    @ViewBuilder public var value: () -> Value

    public init(
        title: String,
        systemImage: String,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder value: @escaping () -> Value
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory
        self.value = value
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(
                title: title,
                systemImage: systemImage,
                size: .small,
                accessory: accessory
            )
            value()
        }
    }
}

extension WidgetMetricBlock where Accessory == EmptyView {
    public init(
        title: String,
        systemImage: String,
        @ViewBuilder value: @escaping () -> Value
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            accessory: { EmptyView() },
            value: value
        )
    }
}

/// Big value + smaller unit, baseline-aligned.
public struct WidgetSplitValue: View {
    public var value: String
    public var unit: String

    public init(value: String, unit: String = "") {
        self.value = value
        self.unit = unit
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(WidgetTypography.metric)
                .lineLimit(1)
            if !unit.isEmpty {
                Text(unit)
                    .font(WidgetTypography.unit)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Two protocol counts on the Connections headline: `10 TCP / 8 UDP`.
public struct WidgetProtocolSplitValue: View {
    public var tcp: Int
    public var udp: Int

    public init(tcp: Int, udp: Int) {
        self.tcp = tcp
        self.udp = udp
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            WidgetSplitValue(value: "\(tcp)", unit: "TCP")
            Text("/")
                .font(WidgetTypography.unit)
                .foregroundStyle(.tertiary)
            WidgetSplitValue(value: "\(udp)", unit: "UDP")
        }
        .lineLimit(1)
        .minimumScaleFactor(0.55)
    }
}

/// Rate headline from bytes/second.
public struct WidgetRateValue: View {
    public var bytesPerSecond: Double

    public init(bytesPerSecond: Double) {
        self.bytesPerSecond = bytesPerSecond
    }

    public var body: some View {
        let parts = ByteRateFormatter.parts(fromBytesPerSecond: bytesPerSecond)
        WidgetSplitValue(value: parts.value, unit: parts.unit)
    }
}

/// Byte-count headline.
public struct WidgetByteValue: View {
    public var bytes: UInt64

    public init(bytes: UInt64) {
        self.bytes = bytes
    }

    public var body: some View {
        let parts = ByteRateFormatter.parts(bytes)
        WidgetSplitValue(value: parts.value, unit: parts.unit)
    }
}

/// Regular label over emphasized value.
public struct WidgetFootStat: View {
    public var title: String
    public var value: String

    public init(title: String, value: String) {
        self.title = title
        self.value = value
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(WidgetTypography.footLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(WidgetTypography.footValue)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct WidgetFootRow: View {
    public var items: [(title: String, value: String)]

    public init(items: [(title: String, value: String)]) {
        self.items = items
    }

    public var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    WidgetFootStat(title: item.title, value: item.value)
                }
            }
        }
    }
}

/// Icon + secondary explanation text.
public struct WidgetHint: View {
    public var systemImage: String
    public var text: String

    public init(systemImage: String, text: String) {
        self.systemImage = systemImage
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(.secondary)
            Text(text)
                .font(WidgetTypography.hint)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 16)
    }
}

/// Large node / profile name line.
public struct WidgetNameLine: View {
    public var text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(WidgetTypography.name)
            .lineLimit(1)
            .minimumScaleFactor(0.45)
    }
}

/// Quiet centered empty state for cards.
public struct WidgetQuietEmpty: View {
    public var text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
    }
}
