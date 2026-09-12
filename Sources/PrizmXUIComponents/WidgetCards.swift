import SwiftUI
import PrizmXServices

/// Switch tile with leading icon, used by the Takeover card (two-up).
public struct WidgetSwitchRow: View {
    public var title: String
    public var subtitle: String
    public var systemImage: String?
    public var enabled: Bool
    public var compact: Bool
    @Binding public var isOn: Bool

    public init(
        title: String,
        subtitle: String,
        systemImage: String? = nil,
        isOn: Binding<Bool>,
        enabled: Bool = true,
        compact: Bool = false
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self._isOn = isOn
        self.enabled = enabled
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }
                Text(title)
                    .font(WidgetTypography.switchTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            if !compact {
                Text(subtitle)
                    .font(WidgetTypography.switchSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(subtitle)
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

                WidgetMetricBlock(title: title, systemImage: systemImage) {
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
    @State private var barHover: TrafficBarHover?
    @State private var tooltipSize: CGSize = .zero

    public init(
        totals: TrafficTotals,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.totals = totals
        self.accessory = accessory
    }

    public var body: some View {
        WidgetCard(size: .medium) {
            GeometryReader { card in
                VStack(alignment: .leading, spacing: 4) {
                    WidgetHeader(
                        title: "Traffic",
                        systemImage: "arrow.up.arrow.down",
                        size: .medium
                    )
                    HStack(alignment: .center, spacing: 8) {
                        WidgetByteValue(bytes: totals.combined)
                        Spacer(minLength: 8)
                        accessory()
                    }
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
                .frame(width: card.size.width, height: card.size.height, alignment: .topLeading)
                .coordinateSpace(name: TrafficSplitBar.coordinateSpaceName)
                .overlay(alignment: .topLeading) {
                    if let barHover {
                        let origin = tooltipOrigin(
                            cursor: barHover.point,
                            tooltip: tooltipSize,
                            bounds: card.size
                        )
                        TrafficBarTooltip(direct: barHover.direct, proxy: barHover.proxy)
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
                            .offset(x: origin.x, y: origin.y)
                            .allowsHitTesting(false)
                    }
                }
            }
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
            TrafficSplitBar(
                direct: direct,
                proxy: proxy,
                palette: palette,
                source: title,
                hover: $barHover
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Prefer below-right of the cursor; flip and clamp so the tooltip stays in-card.
    private func tooltipOrigin(cursor: CGPoint, tooltip: CGSize, bounds: CGSize) -> CGPoint {
        let gap: CGFloat = 12
        var originX = cursor.x + gap
        var originY = cursor.y + gap
        if originX + tooltip.width > bounds.width {
            originX = cursor.x - gap - tooltip.width
        }
        if originY + tooltip.height > bounds.height {
            originY = cursor.y - gap - tooltip.height
        }
        originX = min(max(0, originX), max(0, bounds.width - tooltip.width))
        originY = min(max(0, originY), max(0, bounds.height - tooltip.height))
        return CGPoint(x: originX, y: originY)
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
            GeometryReader { geo in
                let rowCount = RankingLayout.rows(fitting: geo.size.height)
                VStack(alignment: .leading, spacing: RankingLayout.stackSpacing) {
                    WidgetHeader(
                        title: "Ranking",
                        systemImage: "waveform.path.ecg",
                        size: .large
                    )
                    RankingHourlyChart(samples: hourly)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    accessory()
                        .frame(maxWidth: .infinity)
                    Group {
                        if rows.isEmpty {
                            WidgetQuietEmpty(text: emptyText)
                        } else {
                            RankingList(
                                rows: Array(rows.prefix(rowCount)),
                                iconImage: iconImage
                            )
                        }
                    }
                    .frame(
                        height: RankingLayout.listHeight(rows: rowCount),
                        alignment: .top
                    )
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
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
    static let headerHeight: CGFloat = 20
    static let pickerHeight: CGFloat = 28
    static let chartMinHeight: CGFloat = 72

    static func listHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * rowSpacing
    }

    /// 5 rows when the leftover still fits a usable chart; otherwise 3.
    static func rows(fitting totalHeight: CGFloat) -> Int {
        let chrome = headerHeight + pickerHeight + stackSpacing * 3
        let leftoverForFive = totalHeight - chrome - listHeight(rows: maxRows)
        return leftoverForFive >= chartMinHeight ? maxRows : minRows
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
                        RankingProtocolBar(row: row)
                    }
                }
                .frame(height: RankingLayout.rowHeight)
            }
        }
    }
}

/// Split TCP / UDP bar. Falls back to theme ink when protocol totals are missing.
private struct RankingProtocolBar: View {
    var row: TrafficRankRow

    var body: some View {
        GeometryReader { geo in
            let proto = row.tcpBytes &+ row.udpBytes
            let totalWidth = max(6, geo.size.width * row.fraction)
            HStack(spacing: 1) {
                if proto == 0 {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(WidgetChrome.accent)
                        .frame(width: totalWidth)
                } else {
                    let tcpWidth = totalWidth * CGFloat(row.tcpBytes) / CGFloat(proto)
                    if row.tcpBytes > 0 {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(WidgetChrome.transportTCP)
                            .frame(width: max(2, tcpWidth))
                    }
                    if row.udpBytes > 0 {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(WidgetChrome.transportUDP)
                            .frame(width: max(2, totalWidth - tcpWidth))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 3)
        .help(protocolHelp)
    }

    private var protocolHelp: String {
        "TCP \(ByteRateFormatter.byteCount(row.tcpBytes))  UDP \(ByteRateFormatter.byteCount(row.udpBytes))"
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
            } else if row.systemImage == "terminal" {
                ProcessFallbackIcon()
                    .padding(2)
            } else {
                Image(systemName: row.systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Square app-icon stand-in for processes without a bundle icon.
private struct ProcessFallbackIcon: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.black)
            HStack(spacing: 0) {
                Text(">")
                    .foregroundStyle(Color.white)
                Text("_")
                    .foregroundStyle(Color(white: 0.55))
            }
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .padding(.leading, 3)
            .padding(.top, 2)
        }
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
    public var startedAt: Date?
    public var proxyIsOn: Binding<Bool>
    public var tunIsOn: Binding<Bool>

    public init(
        headline: String,
        startedAt: Date? = nil,
        proxyIsOn: Binding<Bool>,
        tunIsOn: Binding<Bool>
    ) {
        self.headline = headline
        self.startedAt = startedAt
        self.proxyIsOn = proxyIsOn
        self.tunIsOn = tunIsOn
    }

    public var body: some View {
        WidgetCard(size: .medium) {
            GeometryReader { geo in
                let compact = geo.size.height < TakeoverLayout.regularMinHeight
                VStack(alignment: .leading, spacing: 4) {
                    WidgetHeader(
                        title: "Takeover",
                        systemImage: "network",
                        size: .medium
                    ) {
                        sessionClock
                    }
                    WidgetSplitValue(value: headline)
                    Spacer(minLength: 0)
                    HStack(alignment: .top, spacing: 12) {
                        WidgetSwitchRow(
                            title: "System Proxy",
                            subtitle: "HTTP & HTTPS via mixed-port",
                            systemImage: "globe",
                            isOn: proxyIsOn,
                            compact: compact
                        )
                        WidgetSwitchRow(
                            title: "TUN",
                            subtitle: "All traffic via utun",
                            systemImage: "shield.lefthalf.filled",
                            isOn: tunIsOn,
                            compact: compact
                        )
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var sessionClock: some View {
        if startedAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.uptime(from: startedAt, now: context.date))
                    .font(WidgetTypography.unit)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private static func uptime(from start: Date?, now: Date) -> String {
        guard let start else { return "" }
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

enum TakeoverLayout {
    /// Header + metric + two subtitle tiles. Below this, drop switch subtitles.
    static let regularMinHeight: CGFloat = 120
}

// MARK: - LAN

/// Allow LAN summary: listen address, mixed-port, client count (later).
public struct LANCard: View {
    @Binding public var isOn: Bool
    public var address: String
    public var port: Int
    public var deviceCount: Int

    public init(
        isOn: Binding<Bool>,
        address: String,
        port: Int,
        deviceCount: Int = 0
    ) {
        self._isOn = isOn
        self.address = address
        self.port = port
        self.deviceCount = deviceCount
    }

    public var body: some View {
        WidgetCard(size: .medium) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(
                    title: "LAN",
                    systemImage: "laptopcomputer.and.iphone",
                    size: .medium
                ) {
                    Toggle("Allow LAN", isOn: $isOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Other devices can use this Mac as HTTP/SOCKS")
                }
                WidgetSplitValue(value: address)
                Spacer(minLength: 0)
                WidgetFootRow(items: [
                    ("Port", "\(port)"),
                    ("Devices", "\(deviceCount)")
                ])
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
                    WidgetQuietEmpty(text: "Create or import a profile in Profiles")
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
                    .tint(WidgetChrome.accent)
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
    public var dnsText: String?
    public var proxyText: String?
    @ViewBuilder public var accessory: () -> Accessory

    public init(
        value: String,
        unit: String,
        dnsText: String? = nil,
        proxyText: String? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.value = value
        self.unit = unit
        self.dnsText = dnsText
        self.proxyText = proxyText
        self.accessory = accessory
    }

    public var body: some View {
        WidgetCard(size: .small) {
            VStack(alignment: .leading, spacing: 6) {
                WidgetMetricBlock(
                    title: "Latency",
                    systemImage: "gauge.with.dots.needle.67percent",
                    accessory: accessory
                ) {
                    WidgetSplitValue(value: value, unit: unit)
                }
                Spacer(minLength: 0)
                WidgetFootRow(items: optionalFootItems([
                    ("DNS", dnsText),
                    ("Proxy", proxyText)
                ]))
            }
        }
    }
}

extension LatencyCard where Accessory == EmptyView {
    public init(
        value: String,
        unit: String,
        dnsText: String? = nil,
        proxyText: String? = nil
    ) {
        self.init(
            value: value,
            unit: unit,
            dnsText: dnsText,
            proxyText: proxyText,
            accessory: { EmptyView() }
        )
    }
}

// MARK: - Connections

public struct ConnectionsCard: View {
    public var tcpCount: Int
    public var udpCount: Int
    public var processesText: String
    public var hostsText: String

    public init(
        tcpCount: Int,
        udpCount: Int,
        processesText: String = "0",
        hostsText: String = "0"
    ) {
        self.tcpCount = tcpCount
        self.udpCount = udpCount
        self.processesText = processesText
        self.hostsText = hostsText
    }

    public var body: some View {
        WidgetCard(size: .small) {
            VStack(alignment: .leading, spacing: 6) {
                WidgetMetricBlock(
                    title: "Connections",
                    systemImage: "link"
                ) {
                    WidgetProtocolSplitValue(tcp: tcpCount, udp: udpCount)
                }
                Spacer(minLength: 0)
                WidgetFootRow(items: [
                    ("Processes", processesText),
                    ("Hosts", hostsText)
                ])
            }
        }
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
