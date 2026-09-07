import SwiftUI
import PrizmXServices

/// Switch row with leading icon, used by the Capture card.
public struct WidgetSwitchRow: View {
    public var title: String
    public var subtitle: String
    public var systemImage: String?
    public var enabled: Bool
    @Binding public var isOn: Bool

    public init(
        title: String,
        subtitle: String,
        systemImage: String? = nil,
        isOn: Binding<Bool>,
        enabled: Bool = true
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self._isOn = isOn
        self.enabled = enabled
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(WidgetTypography.switchTitle)
                Text(subtitle)
                    .font(WidgetTypography.switchSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rate (Upload / Download)

/// 1×1 rate card: waveform is the full-bleed background; labels sit on top.
public struct RateCard: View {
    public var title: String
    public var systemImage: String
    public var series: TrafficWaveformSeries
    public var livePoints: [SpeedPoint]

    public init(
        title: String,
        systemImage: String,
        series: TrafficWaveformSeries,
        livePoints: [SpeedPoint]
    ) {
        self.title = title
        self.systemImage = systemImage
        self.series = series
        self.livePoints = livePoints
    }

    public var body: some View {
        card(points: livePoints)
    }

    private func card(points: [SpeedPoint]) -> some View {
        let seriesMax = series.peak(in: points)
        let rate = points.last.map { series.rate(in: $0) } ?? 0
        return WidgetCard(size: .small, padded: false) {
            ZStack {
                TrafficWaveform(
                    points: points,
                    showsArea: true,
                    series: series,
                    yMax: RateAxisScale.niceCeiling(seriesMax),
                    fillsCard: true,
                    verticalFill: Double(WidgetChrome.plotFraction)
                )

                VStack(alignment: .leading, spacing: 6) {
                    WidgetHeader(
                        title: title,
                        systemImage: systemImage,
                        size: .small
                    )
                    WidgetRateValue(bytesPerSecond: rate)
                }
                .padding(WidgetChrome.padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)

                RateYAxisLegend(maxBytesPerSecond: seriesMax)
                    .padding(.trailing, 8)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Traffic totals

/// Day/Month totals: Upload/Download rows with Direct / Proxy bars.
public struct TrafficCard<Accessory: View>: View {
    public var totals: TrafficTotals
    @ViewBuilder public var accessory: () -> Accessory

    public init(
        totals: TrafficTotals,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.totals = totals
        self.accessory = accessory
    }

    public var body: some View {
        WidgetCard(size: .medium) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(
                    title: "Traffic",
                    systemImage: "arrow.up.arrow.down",
                    size: .medium,
                    accessory: accessory
                )
                WidgetByteValue(bytes: totals.combined)
                VStack(spacing: 10) {
                    directionRow(
                        title: "Upload",
                        direct: totals.uploadDirect,
                        proxy: totals.uploadProxy,
                        palette: .upload
                    )
                    directionRow(
                        title: "Download",
                        direct: totals.downloadDirect,
                        proxy: totals.downloadProxy,
                        palette: .download
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func directionRow(
        title: String,
        direct: UInt64,
        proxy: UInt64,
        palette: TrafficBarPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(WidgetTypography.footLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            TrafficSplitBar(direct: direct, proxy: proxy, palette: palette)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension TrafficCard where Accessory == EmptyView {
    public init(totals: TrafficTotals) {
        self.init(totals: totals, accessory: { EmptyView() })
    }
}

// MARK: - Ranking

/// Hourly chart + ranked list by App / Domain / Policy.
public struct RankingCard<Accessory: View>: View {
    public var rows: [TrafficRankRow]
    public var hourly: [RankingHourSample]
    public var emptyText: String
    public var iconImage: @Sendable (TrafficRankRow) -> Image?
    @ViewBuilder public var accessory: () -> Accessory

    public init(
        rows: [TrafficRankRow],
        hourly: [RankingHourSample],
        emptyText: String = "No traffic yet",
        iconImage: @escaping @Sendable (TrafficRankRow) -> Image? = { _ in nil },
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.rows = rows
        self.hourly = hourly
        self.emptyText = emptyText
        self.iconImage = iconImage
        self.accessory = accessory
    }

    public var body: some View {
        WidgetCard(size: .large) {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(
                    title: "Ranking",
                    systemImage: "waveform.path.ecg",
                    size: .large,
                    accessory: accessory
                )
                if rows.isEmpty && hourly.isEmpty {
                    WidgetQuietEmpty(text: emptyText)
                } else {
                    GeometryReader { geo in
                        let visibleRows = RankingLayout.rows(fitting: geo.size.height)
                        VStack(spacing: RankingLayout.stackSpacing) {
                            RankingHourlyChart(samples: hourly)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                .frame(minHeight: RankingLayout.chartMinHeight)
                            RankingList(rows: Array(rows.prefix(visibleRows)), iconImage: iconImage)
                                .frame(height: RankingLayout.listHeight(rows: visibleRows))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

extension RankingCard where Accessory == EmptyView {
    public init(
        rows: [TrafficRankRow],
        hourly: [RankingHourSample],
        emptyText: String = "No traffic yet",
        iconImage: @escaping @Sendable (TrafficRankRow) -> Image? = { _ in nil }
    ) {
        self.init(
            rows: rows,
            hourly: hourly,
            emptyText: emptyText,
            iconImage: iconImage,
            accessory: { EmptyView() }
        )
    }
}

enum RankingLayout {
    static let maxRows = 5
    static let minRows = 3
    static let rowHeight: CGFloat = 28
    static let rowSpacing: CGFloat = 6
    static let stackSpacing: CGFloat = 8
    static let chartMinHeight: CGFloat = 72

    static func listHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * rowSpacing
    }

    static func rows(fitting height: CGFloat) -> Int {
        let required = chartMinHeight + stackSpacing + listHeight(rows: maxRows)
        return height >= required ? maxRows : minRows
    }
}

public struct RankingList: View {
    public var rows: [TrafficRankRow]
    public var iconImage: @Sendable (TrafficRankRow) -> Image?

    public init(
        rows: [TrafficRankRow],
        iconImage: @escaping @Sendable (TrafficRankRow) -> Image? = { _ in nil }
    ) {
        self.rows = rows
        self.iconImage = iconImage
    }

    public var body: some View {
        VStack(spacing: RankingLayout.rowSpacing) {
            ForEach(rows) { row in
                HStack(alignment: .center, spacing: 8) {
                    RankingRowIcon(row: row, image: iconImage(row))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.name)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(ByteRateFormatter.byteCount(row.bytes))
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(WidgetChrome.chipTrack)
                                .frame(width: max(6, geo.size.width * row.fraction), height: 3)
                        }
                        .frame(height: 3)
                    }
                }
                .frame(height: RankingLayout.rowHeight)
            }
        }
    }
}

struct RankingRowIcon: View {
    var row: TrafficRankRow
    var image: Image?

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: row.systemImage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - Outbound

/// Proxy mode card: status, Rule/Global/Direct picker, mode hint.
/// There is no master switch — TUN (Capture) owns connection state.
public struct OutboundCard<PickerContent: View>: View {
    public var title: String
    public var systemImage: String
    public var headline: String
    public var hintIcon: String
    public var hintText: String
    @ViewBuilder public var picker: () -> PickerContent

    public init(
        title: String = "Mode",
        systemImage: String = "arrow.triangle.branch",
        headline: String,
        hintIcon: String,
        hintText: String,
        @ViewBuilder picker: @escaping () -> PickerContent
    ) {
        self.title = title
        self.systemImage = systemImage
        self.headline = headline
        self.hintIcon = hintIcon
        self.hintText = hintText
        self.picker = picker
    }

    public var body: some View {
        WidgetCard(size: .medium) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(
                    title: title,
                    systemImage: systemImage,
                    size: .medium
                )
                WidgetSplitValue(value: headline)
                Spacer(minLength: 0)
                picker()
                    .padding(.bottom, 6)
                WidgetHint(systemImage: hintIcon, text: hintText)
            }
        }
    }
}

// MARK: - Takeover

/// Network takeover card: which pipes capture traffic.
/// System Proxy → mixed-port in the main app; TUN → the Packet Tunnel.
/// Distinct from the sidebar's Debug → Capture (HTTP recording).
public struct TakeoverCard: View {
    public var headline: String
    public var proxyIsOn: Binding<Bool>
    public var tunIsOn: Binding<Bool>

    public init(
        headline: String,
        proxyIsOn: Binding<Bool>,
        tunIsOn: Binding<Bool>
    ) {
        self.headline = headline
        self.proxyIsOn = proxyIsOn
        self.tunIsOn = tunIsOn
    }

    public var body: some View {
        WidgetCard(size: .medium) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(
                    title: "Takeover",
                    systemImage: "network",
                    size: .medium
                )
                WidgetSplitValue(value: headline)
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    WidgetSwitchRow(
                        title: "System Proxy",
                        subtitle: "HTTP & HTTPS via mixed-port",
                        systemImage: "globe",
                        isOn: proxyIsOn
                    )
                    Divider()
                    WidgetSwitchRow(
                        title: "TUN",
                        subtitle: "All traffic via utun",
                        systemImage: "shield.lefthalf.filled",
                        isOn: tunIsOn
                    )
                }
            }
        }
    }
}

// MARK: - Profile

public struct ProfileCard<Accessory: View>: View {
    public var name: String?
    public var isSubscription: Bool
    public var updatedText: String
    public var expiresText: String?
    public var usedBytes: UInt64
    public var totalBytes: UInt64
    public var formatLabel: String
    @ViewBuilder public var accessory: () -> Accessory

    public init(
        name: String?,
        isSubscription: Bool,
        updatedText: String,
        expiresText: String? = nil,
        usedBytes: UInt64 = 0,
        totalBytes: UInt64 = 0,
        formatLabel: String,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.name = name
        self.isSubscription = isSubscription
        self.updatedText = updatedText
        self.expiresText = expiresText
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.formatLabel = formatLabel
        self.accessory = accessory
    }

    public var body: some View {
        WidgetCard(size: .medium) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(
                    title: "Profile",
                    systemImage: "doc.text",
                    size: .medium,
                    accessory: accessory
                )
                if let name {
                    WidgetNameLine(text: name)
                    Spacer(minLength: 0)
                    if isSubscription {
                        subscriptionStats
                    } else {
                        WidgetFootRow(items: [
                            ("Kind", "Local"),
                            ("Format", formatLabel)
                        ])
                    }
                } else {
                    WidgetSplitValue(value: "None")
                    Spacer(minLength: 0)
                    WidgetQuietEmpty(text: "Add a profile from More → Profiles")
                }
            }
        }
    }

    private var subscriptionStats: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetFootRow(items: subscriptionFootItems)
            if totalBytes > 0 {
                let fraction = min(1, Double(usedBytes) / Double(totalBytes))
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                HStack {
                    Text(ByteRateFormatter.byteCount(usedBytes))
                    Spacer()
                    Text(ByteRateFormatter.byteCount(totalBytes))
                }
                .font(.caption.monospacedDigit().weight(.semibold))
            }
        }
    }

    private var subscriptionFootItems: [(title: String, value: String)] {
        var items: [(title: String, value: String)] = [("Updated", updatedText)]
        if let expiresText, !expiresText.isEmpty {
            items.append(("Expires", expiresText))
        }
        return items
    }
}

extension ProfileCard where Accessory == EmptyView {
    public init(
        name: String?,
        isSubscription: Bool,
        updatedText: String,
        expiresText: String? = nil,
        usedBytes: UInt64 = 0,
        totalBytes: UInt64 = 0,
        formatLabel: String
    ) {
        self.init(
            name: name,
            isSubscription: isSubscription,
            updatedText: updatedText,
            expiresText: expiresText,
            usedBytes: usedBytes,
            totalBytes: totalBytes,
            formatLabel: formatLabel,
            accessory: { EmptyView() }
        )
    }
}

// MARK: - Node

public struct NodeCard<Accessory: View>: View {
    public var name: String
    public var protocolText: String
    public var latencyText: String
    public var groupText: String
    @ViewBuilder public var accessory: () -> Accessory

    public init(
        name: String,
        protocolText: String,
        latencyText: String,
        groupText: String,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.name = name
        self.protocolText = protocolText
        self.latencyText = latencyText
        self.groupText = groupText
        self.accessory = accessory
    }

    public var body: some View {
        WidgetCard(size: .medium) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(
                    title: "Node",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    size: .medium,
                    accessory: accessory
                )
                WidgetNameLine(text: name)
                Spacer(minLength: 0)
                WidgetFootRow(items: [
                    ("Protocol", protocolText),
                    ("Latency", latencyText),
                    ("Group", groupText)
                ])
            }
        }
    }
}

extension NodeCard where Accessory == EmptyView {
    public init(name: String, protocolText: String, latencyText: String, groupText: String) {
        self.init(
            name: name,
            protocolText: protocolText,
            latencyText: latencyText,
            groupText: groupText,
            accessory: { EmptyView() }
        )
    }
}

// MARK: - Latency

public struct LatencyCard<Accessory: View>: View {
    public var value: String
    public var unit: String
    public var routerText: String?
    public var dnsText: String?
    @ViewBuilder public var accessory: () -> Accessory

    public init(
        value: String,
        unit: String,
        routerText: String? = nil,
        dnsText: String? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.value = value
        self.unit = unit
        self.routerText = routerText
        self.dnsText = dnsText
        self.accessory = accessory
    }

    public var body: some View {
        WidgetCard(size: .small) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(
                    title: "Latency",
                    systemImage: "gauge.with.dots.needle.67percent",
                    size: .small,
                    accessory: accessory
                )
                WidgetSplitValue(value: value, unit: unit)
                Spacer(minLength: 0)
                WidgetFootRow(items: optionalFootItems([
                    ("Router", routerText),
                    ("DNS", dnsText)
                ]))
            }
        }
    }
}

extension LatencyCard where Accessory == EmptyView {
    public init(
        value: String,
        unit: String,
        routerText: String? = nil,
        dnsText: String? = nil
    ) {
        self.init(
            value: value,
            unit: unit,
            routerText: routerText,
            dnsText: dnsText,
            accessory: { EmptyView() }
        )
    }
}

// MARK: - Connections

public struct ConnectionsCard<Accessory: View>: View {
    public var count: Int
    public var processesText: String?
    public var devicesText: String?
    @ViewBuilder public var accessory: () -> Accessory

    public init(
        count: Int,
        processesText: String? = nil,
        devicesText: String? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.count = count
        self.processesText = processesText
        self.devicesText = devicesText
        self.accessory = accessory
    }

    public var body: some View {
        WidgetCard(size: .small) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(
                    title: "Connections",
                    systemImage: "link",
                    size: .small,
                    accessory: accessory
                )
                WidgetSplitValue(value: "\(count)")
                Spacer(minLength: 0)
                WidgetFootRow(items: optionalFootItems([
                    ("Processes", processesText),
                    ("Devices", devicesText)
                ]))
            }
        }
    }
}

extension ConnectionsCard where Accessory == EmptyView {
    public init(
        count: Int,
        processesText: String? = nil,
        devicesText: String? = nil
    ) {
        self.init(
            count: count,
            processesText: processesText,
            devicesText: devicesText,
            accessory: { EmptyView() }
        )
    }
}

private func optionalFootItems(
    _ items: [(title: String, value: String?)]
) -> [(title: String, value: String)] {
    items.compactMap { item in
        guard let value = item.value, !value.isEmpty else { return nil }
        return (item.title, value)
    }
}
