import Charts
import SwiftUI
import PrizmXServices

public enum TrafficWaveformSeries: Hashable, Sendable {
    case both
    case download
    case upload

    public var plottedLanes: [TrafficWaveformSeries] {
        switch self {
        case .both: [.download, .upload]
        case .download, .upload: [self]
        }
    }

    fileprivate var plotKey: String {
        switch self {
        case .upload: "upload"
        case .download: "download"
        case .both: "both"
        }
    }

    public func rate(in point: SpeedPoint) -> Double {
        switch self {
        case .download: point.downloadBytesPerSecond
        case .upload: point.uploadBytesPerSecond
        case .both: max(point.downloadBytesPerSecond, point.uploadBytesPerSecond)
        }
    }

    public func peak(in points: [SpeedPoint]) -> Double {
        points.map { rate(in: $0) }.max() ?? 0
    }

    public var strokeColor: Color {
        switch self {
        case .upload: WidgetChrome.trafficUpload
        case .download: WidgetChrome.trafficDownload
        case .both: WidgetChrome.trafficDownload
        }
    }

    public var areaFill: LinearGradient {
        areaFill(mirroredBelow: false)
    }

    public func areaFill(mirroredBelow: Bool) -> LinearGradient {
        // Visible even when the filled band is thin (idle flat line at ~10%
        // height samples only the faint end of a weak gradient).
        LinearGradient(
            colors: [strokeColor.opacity(0.35), strokeColor.opacity(0.06)],
            startPoint: mirroredBelow ? .bottom : .top,
            endPoint: mirroredBelow ? .top : .bottom
        )
    }
}

/// Dual-line throughput waveform (download / upload).
public struct TrafficWaveform: View {
    public var points: [SpeedPoint]
    public var showsArea: Bool
    public var series: TrafficWaveformSeries
    public var yMax: Double?
    /// Draw through the view bounds (no plot inset). Use as a card background.
    public var fillsCard: Bool
    /// Fraction of card height used by the waveform (1 = full height).
    public var verticalFill: Double
    /// Upload above the origin, download below. Menubar uses this so both
    /// rates share one plot without overlapping.
    public var splitAxis: Bool

    public init(
        points: [SpeedPoint],
        showsArea: Bool = false,
        series: TrafficWaveformSeries = .both,
        yMax: Double? = nil,
        fillsCard: Bool = false,
        verticalFill: Double = 1,
        splitAxis: Bool = false
    ) {
        self.points = points
        self.showsArea = showsArea
        self.series = series
        self.yMax = yMax
        self.fillsCard = fillsCard
        self.verticalFill = verticalFill
        self.splitAxis = splitAxis
    }

    public var body: some View {
        chartMarks
            .chartYScale(domain: domainMin...domainMax)
            .chartXScale(range: .plotDimension(startPadding: 0, endPadding: 0))
            .chartYScale(range: .plotDimension(startPadding: fillsCard ? 0 : 4, endPadding: fillsCard ? 0 : 4))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartPlotStyle { plot in
                plot.padding(0)
            }
            .accessibilityLabel(Text("Throughput"))
    }

    @ViewBuilder
    private var chartMarks: some View {
        if splitAxis {
            splitBarChart
        } else {
            overlayLineChart
        }
    }

    private var splitBarChart: some View {
        Chart {
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(Color.secondary.opacity(0.22))
                .lineStyle(StrokeStyle(lineWidth: 0.5))
            ForEach(plotSamples) { sample in
                AreaMark(
                    x: .value("Tick", sample.index),
                    yStart: .value("Base", 0),
                    yEnd: .value("Rate", sample.rate),
                    series: .value("Lane", sample.lane.plotKey)
                )
                .foregroundStyle(
                    sample.lane.areaFill(mirroredBelow: sample.lane == .download)
                )
                .opacity(sample.isStub ? 0.45 : 1)
                .interpolationMethod(.linear)
                LineMark(
                    x: .value("Tick", sample.index),
                    y: .value("Rate", sample.rate),
                    series: .value("Lane", sample.lane.plotKey)
                )
                .foregroundStyle(sample.lane.strokeColor.opacity(sample.isStub ? 0.4 : 1))
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private var overlayLineChart: some View {
        Chart {
            ForEach(plotSamples) { sample in
                if showsArea {
                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        yStart: .value("Base", domainMin),
                        yEnd: .value("Rate", sample.rate),
                        series: .value("Lane", sample.lane.plotKey)
                    )
                    .foregroundStyle(sample.lane.areaFill)
                    .interpolationMethod(interpolation)
                }
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Rate", sample.rate),
                    series: .value("Lane", sample.lane.plotKey)
                )
                .foregroundStyle(sample.lane.strokeColor)
                .interpolationMethod(interpolation)
                .lineStyle(Self.lineStroke)
            }
        }
    }

    private static let lineStroke = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)

    private struct PlotSample: Identifiable {
        var id: String { "\(lane.plotKey)-\(pointID)" }
        var pointID: Int
        var index: Int
        var timestamp: Date
        var rate: Double
        var lane: TrafficWaveformSeries
        var isStub: Bool
    }

    private var plotSamples: [PlotSample] {
        let floor = plotMax * 0.06
        return series.plottedLanes.flatMap { lane in
            points.enumerated().map { index, point in
                let raw = lane.rate(in: point)
                let stub = splitAxis && raw < floor
                let magnitude = splitAxis ? max(raw, floor) : raw
                let signed = (splitAxis && lane == .download) ? -magnitude : magnitude
                return PlotSample(
                    pointID: point.id,
                    index: index,
                    timestamp: point.timestamp,
                    rate: signed,
                    lane: lane,
                    isStub: stub
                )
            }
        }
    }

    /// Catmull-Rom on a flat zero series fabricates a bulge; keep idle linear.
    private var interpolation: InterpolationMethod {
        series.peak(in: points) < 1 ? .linear : .catmullRom
    }

    private var plotMax: Double {
        if splitAxis {
            let peak = max(
                TrafficWaveformSeries.upload.peak(in: points),
                TrafficWaveformSeries.download.peak(in: points)
            )
            return max(yMax ?? RateAxisScale.plotCeiling(peak), 1)
        }
        return max(yMax ?? RateAxisScale.plotCeiling(series.peak(in: points)), 1)
    }

    /// Overlay: idle sits near the floor. Split: symmetric around y=0.
    private var domainMin: Double {
        if splitAxis { return -domainMax }
        let fraction = series.peak(in: points) < 1 ? 0.02 : 0.12
        return -(domainMax * fraction)
    }

    private var domainMax: Double {
        let fill = min(max(verticalFill, 0.2), 1)
        return plotMax / fill
    }
}

public enum RateAxisScale {
    /// Tight 1 / 2 / 5 × 10ⁿ ceiling so the stroke fills the plot.
    /// Menu-bar split charts use this; a 10ⁿ domain flattens typical rates.
    public static func plotCeiling(_ bytesPerSecond: Double) -> Double {
        let value = max(bytesPerSecond, 1_000)
        let exponent = floor(log10(value))
        let magnitude = pow(10, exponent)
        let coefficient = value / magnitude
        let nice: Double
        if coefficient <= 1 {
            nice = 1
        } else if coefficient <= 2 {
            nice = 2
        } else if coefficient <= 5 {
            nice = 5
        } else {
            nice = 10
        }
        return nice * magnitude
    }

    /// Round up to 10ⁿ B/s (1K / 10K / 100K / 1M / …). Idle uses a 1 KB/s floor.
    public static func niceCeiling(_ bytesPerSecond: Double) -> Double {
        let value = max(bytesPerSecond, 1_000)
        let exponent = floor(log10(value) + 1e-12)
        let rung = pow(10, exponent)
        if value <= rung { return rung }
        return rung * 10
    }

    /// Compact axis labels (`10K`, `5M`, `1G`) — `/s` is implied by the rate card.
    public static func label(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond <= 0 { return "0" }
        let magnitude = bytesPerSecond
        if magnitude >= 1_000_000_000 {
            return compact(magnitude / 1_000_000_000) + "G"
        }
        if magnitude >= 1_000_000 {
            return compact(magnitude / 1_000_000) + "M"
        }
        if magnitude >= 1_000 {
            return compact(magnitude / 1_000) + "K"
        }
        return compact(magnitude) + "B"
    }

    private static func compact(_ value: Double) -> String {
        if abs(value - value.rounded()) < 0.05 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.1f", value)
    }
}

/// Y-axis labels aligned to the waveform plot (no zero tick).
public struct RateYAxisLegend: View {
    public var maxBytesPerSecond: Double
    public var plotFraction: CGFloat

    public init(maxBytesPerSecond: Double, plotFraction: CGFloat = WidgetChrome.plotFraction) {
        self.maxBytesPerSecond = maxBytesPerSecond
        self.plotFraction = plotFraction
    }

    public var body: some View {
        let top = RateAxisScale.niceCeiling(maxBytesPerSecond)
        GeometryReader { geo in
            let topY = geo.size.height * (1 - plotFraction)
            let midY = geo.size.height * (1 - plotFraction * 0.5)
            tickLabel(RateAxisScale.label(top), width: geo.size.width, originY: topY)
            tickLabel(RateAxisScale.label(top / 2), width: geo.size.width, originY: midY)
        }
        .accessibilityHidden(true)
    }

    private func tickLabel(_ text: String, width: CGFloat, originY: CGFloat) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, alignment: .trailing)
            .position(x: width / 2, y: originY)
    }
}

/// Rolling 24-hour bars for the Ranking card. Drawn with stacks (not Swift
/// Charts) so the plot keeps a real height inside the widget GeometryReader.
public struct RankingHourlyChart: View {
    public var samples: [RankingHourSample]
    @State private var hoveredIndex: Int?

    public init(samples: [RankingHourSample]) {
        self.samples = samples
    }

    public var body: some View {
        let peak = max(samples.map(\.bytes).max() ?? 0, 1)
        VStack(spacing: 4) {
            GeometryReader { geo in
                let gap: CGFloat = 1.5
                let count = max(samples.count, 1)
                let barWidth = max(
                    2,
                    (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count)
                )
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(samples) { sample in
                            RankingHourBar(
                                sample: sample,
                                peak: peak,
                                barWidth: barWidth,
                                plotHeight: geo.size.height,
                                isHovered: hoveredIndex == sample.index
                            )
                            #if os(macOS)
                            .onHover { inside in
                                if inside {
                                    hoveredIndex = sample.index
                                } else if hoveredIndex == sample.index {
                                    hoveredIndex = nil
                                }
                            }
                            #endif
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                    if let hoveredIndex,
                       let sample = samples.first(where: { $0.index == hoveredIndex }) {
                        let originX = CGFloat(hoveredIndex) * (barWidth + gap)
                        let tooltipWidth: CGFloat = 156
                        let gapFromBar: CGFloat = 8
                        let fitsRight = originX + barWidth + gapFromBar + tooltipWidth
                            <= geo.size.width
                        let tooltipX = fitsRight
                            ? originX + barWidth + gapFromBar
                            : max(0, originX - tooltipWidth - gapFromBar)
                        RankingHourTooltip(sample: sample)
                            .offset(x: tooltipX, y: 4)
                            .allowsHitTesting(false)
                    }
                }
            }
            HStack {
                Text(xLabel(for: 0))
                Spacer(minLength: 0)
                Text(xLabel(for: 8))
                Spacer(minLength: 0)
                Text(xLabel(for: 16))
                Spacer(minLength: 0)
                Text(xLabel(for: 23))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .accessibilityLabel("Hourly traffic")
    }

    private func xLabel(for slot: Int) -> String {
        if slot == 23 { return "Now" }
        guard let sample = samples.first(where: { $0.index == slot }) else { return "" }
        return RankingHourBar.hourLabel(sample.hour)
    }
}

private struct RankingHourBar: View {
    var sample: RankingHourSample
    var peak: Double
    var barWidth: CGFloat
    var plotHeight: CGFloat
    var isHovered: Bool

    var body: some View {
        let ratio = CGFloat(sample.bytes / peak)
        let barHeight = sample.bytes <= 0 ? 3 : max(4, plotHeight * ratio)
        Color.clear
            .frame(width: barWidth, height: plotHeight)
            .overlay(alignment: .bottom) {
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 2,
                    style: .continuous
                )
                .fill(WidgetChrome.accent.opacity(fillOpacity))
                .frame(height: barHeight)
                .scaleEffect(x: isHovered ? 1.15 : 1, y: isHovered ? 1.06 : 1, anchor: .bottom)
                .shadow(color: WidgetChrome.accent.opacity(isHovered ? 0.45 : 0), radius: 4, y: 0)
                .animation(.easeOut(duration: 0.12), value: isHovered)
            }
            .contentShape(Rectangle())
    }

    private var fillOpacity: Double {
        if isHovered { return 1 }
        return sample.bytes <= 0 ? 0.28 : 1
    }

    static func hourLabel(_ hour: Int) -> String {
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return hour < 12 ? "\(twelve)AM" : "\(twelve)PM"
    }
}

private struct RankingHourTooltip: View {
    var sample: RankingHourSample

    var body: some View {
        let start = sample.startedAt
        let end = start.addingTimeInterval(3_600)
        VStack(alignment: .leading, spacing: 3) {
            Text("\(start.formatted(date: .abbreviated, time: .omitted))  \(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))")
                .foregroundStyle(.secondary)
            metric("All", UInt64(sample.bytes))
            metric("Proxy", sample.proxyBytes)
            metric("Direct", sample.directBytes)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .fixedSize()
    }

    private func metric(_ title: String, _ bytes: UInt64) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(ByteRateFormatter.byteCount(bytes))
                .fontWeight(.semibold)
        }
    }
}

public enum TrafficBarPalette: Sendable {
    case upload
    case download

    public var direct: Color {
        switch self {
        case .upload: WidgetChrome.trafficUpload.opacity(0.45)
        case .download: WidgetChrome.trafficDownload.opacity(0.40)
        }
    }

    public var proxy: Color {
        switch self {
        case .upload: WidgetChrome.trafficUpload
        case .download: WidgetChrome.trafficDownload
        }
    }
}

/// Hover payload for the Traffic card tooltip (card coordinate space).
struct TrafficBarHover: Equatable {
    var source: String
    var point: CGPoint
    var direct: UInt64
    var proxy: UInt64
}

/// Linear bar split into Direct (leading) and Proxy (trailing).
/// Values live in a card-level hover tooltip so they stay inside the widget.
public struct TrafficSplitBar: View {
    static let coordinateSpaceName = "prizmx.trafficCard"
    static let height: CGFloat = 8

    public var direct: UInt64
    public var proxy: UInt64
    public var palette: TrafficBarPalette
    var source: String
    @Binding var hover: TrafficBarHover?

    public init(direct: UInt64, proxy: UInt64, palette: TrafficBarPalette) {
        self.init(
            direct: direct,
            proxy: proxy,
            palette: palette,
            source: "",
            hover: .constant(nil)
        )
    }

    init(
        direct: UInt64,
        proxy: UInt64,
        palette: TrafficBarPalette,
        source: String,
        hover: Binding<TrafficBarHover?>
    ) {
        self.direct = direct
        self.proxy = proxy
        self.palette = palette
        self.source = source
        self._hover = hover
    }

    public var body: some View {
        let isHovered = hover?.source == source
        GeometryReader { geo in
            let total = direct &+ proxy
            let gap: CGFloat = 3
            let usable = max(0, geo.size.width - gap)
            let directWidth = total == 0 ? 0 : usable * CGFloat(direct) / CGFloat(total)
            let proxyWidth = total == 0 ? usable : usable - directWidth
            HStack(spacing: gap) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(palette.direct)
                    .frame(width: directWidth)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(palette.proxy)
                    .frame(width: proxyWidth)
            }
            .opacity(isHovered || total > 0 ? 1 : 0.28)
            // Ranking hour bars scale x (thickness) 1.15 / y (length) 1.06 from
            // the baseline; a horizontal track swaps those axes.
            .scaleEffect(
                x: isHovered ? 1.06 : 1,
                y: isHovered ? 1.15 : 1,
                anchor: .center
            )
            .shadow(
                color: palette.proxy.opacity(isHovered ? 0.45 : 0),
                radius: 4,
                y: 0
            )
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Self.height)
        .contentShape(Rectangle())
        #if os(macOS)
        .onContinuousHover(coordinateSpace: .named(Self.coordinateSpaceName)) { phase in
            switch phase {
            case .active(let location):
                hover = TrafficBarHover(
                    source: source,
                    point: location,
                    direct: direct,
                    proxy: proxy
                )
            case .ended:
                if hover?.source == source {
                    hover = nil
                }
            }
        }
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Direct \(ByteRateFormatter.byteCount(direct)), Proxy \(ByteRateFormatter.byteCount(proxy))"
        )
    }
}

struct TrafficBarTooltip: View {
    var direct: UInt64
    var proxy: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            metric("All", direct &+ proxy)
            metric("Proxy", proxy)
            metric("Direct", direct)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 156, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    private func metric(_ title: String, _ bytes: UInt64) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(ByteRateFormatter.byteCount(bytes))
                .fontWeight(.semibold)
        }
    }
}
