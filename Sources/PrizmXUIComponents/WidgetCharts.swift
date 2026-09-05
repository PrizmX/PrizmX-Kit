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
        self == .upload ? Color.secondary : Color.accentColor
    }

    public var areaFill: LinearGradient {
        // Visible even when the filled band is thin (idle flat line at ~10%
        // height samples only the faint end of a weak gradient).
        LinearGradient(
            colors: [strokeColor.opacity(0.35), strokeColor.opacity(0.06)],
            startPoint: .top,
            endPoint: .bottom
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

    public init(
        points: [SpeedPoint],
        showsArea: Bool = false,
        series: TrafficWaveformSeries = .both,
        yMax: Double? = nil,
        fillsCard: Bool = false,
        verticalFill: Double = 1
    ) {
        self.points = points
        self.showsArea = showsArea
        self.series = series
        self.yMax = yMax
        self.fillsCard = fillsCard
        self.verticalFill = verticalFill
    }

    public var body: some View {
        Chart {
            ForEach(points) { point in
                ForEach(series.plottedLanes, id: \.self) { lane in
                    if showsArea {
                        // Fill to the plot floor (domain min), not the y=0
                        // baseline — the baseline floats above the card edge.
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            yStart: .value("Base", domainMin),
                            yEnd: .value("Rate", lane.rate(in: point))
                        )
                        .foregroundStyle(lane.areaFill)
                        .interpolationMethod(.catmullRom)
                    }
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Rate", lane.rate(in: point))
                    )
                    .foregroundStyle(lane.strokeColor)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(Self.lineStroke)
                }
            }
        }
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

    private static let lineStroke = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)

    private var plotMax: Double {
        max(yMax ?? RateAxisScale.niceCeiling(series.peak(in: points)), 1)
    }

    /// Slight below-zero headroom so an idle (flat-zero) wave floats above
    /// the card's bottom edge instead of hugging it like a border.
    private var domainMin: Double {
        -(domainMax * 0.12)
    }

    private var domainMax: Double {
        let fill = min(max(verticalFill, 0.2), 1)
        return plotMax / fill
    }
}

public enum RateAxisScale {
    /// Round up to 1 / 2 / 5 × 10ⁿ. Idle traffic uses a 1 KB/s ceiling so the chart has range.
    public static func niceCeiling(_ bytesPerSecond: Double) -> Double {
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

    public static func ticks(max bytesPerSecond: Double, includeZero: Bool = false) -> [Double] {
        let top = niceCeiling(bytesPerSecond)
        if includeZero {
            return [top, top / 2, 0]
        }
        return [top, top / 2]
    }

    public static func label(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond <= 0 { return "0" }
        return ByteRateFormatter.string(fromBytesPerSecond: bytesPerSecond)
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

/// 24-hour bar chart for the Ranking card.
public struct RankingHourlyChart: View {
    public var samples: [RankingHourSample]

    public init(samples: [RankingHourSample]) {
        self.samples = samples
    }

    public var body: some View {
        let peak = max(samples.map(\.bytes).max() ?? 1, 1)
        let ceiling = RateAxisScale.niceCeiling(peak)
        Chart(samples) { sample in
            BarMark(
                x: .value("Hour", sample.hour),
                y: .value("Bytes", sample.bytes)
            )
            .foregroundStyle(Color.accentColor)
            .cornerRadius(5)
        }
        .chartXScale(domain: -0.5...23.5)
        .chartYScale(domain: 0...ceiling)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { value in
                AxisValueLabel {
                    if let hour = value.as(Int.self) {
                        Text(Self.hourLabel(hour))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: [ceiling, ceiling / 2]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.35))
            }
        }
        .chartLegend(.hidden)
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(ByteRateFormatter.byteCount(UInt64(ceiling)))
                Spacer(minLength: 0)
                Text(ByteRateFormatter.byteCount(UInt64(ceiling / 2)))
                Spacer(minLength: 0)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .padding(.trailing, 2)
            .padding(.bottom, 18)
            .allowsHitTesting(false)
        }
        .accessibilityLabel("Hourly traffic")
    }

    private static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: "12AM"
        case 6: "6AM"
        case 12: "12PM"
        case 18: "6PM"
        default: ""
        }
    }
}

public enum TrafficBarPalette: Sendable {
    case upload
    case download

    public var direct: Color {
        switch self {
        case .upload: Color.orange.opacity(0.55)
        case .download: Color.blue.opacity(0.45)
        }
    }

    public var proxy: Color {
        switch self {
        case .upload: Color.orange
        case .download: Color.cyan
        }
    }
}

/// Linear bar split into Direct (leading) and Proxy (trailing) with overlaid values.
public struct TrafficSplitBar: View {
    public var direct: UInt64
    public var proxy: UInt64
    public var palette: TrafficBarPalette

    public init(direct: UInt64, proxy: UInt64, palette: TrafficBarPalette) {
        self.direct = direct
        self.proxy = proxy
        self.palette = palette
    }

    public var body: some View {
        GeometryReader { geo in
            let total = direct &+ proxy
            let gap: CGFloat = 4
            let usable = max(0, geo.size.width - gap)
            let directWidth = total == 0 ? 0 : usable * CGFloat(direct) / CGFloat(total)
            let proxyWidth = total == 0 ? usable : usable - directWidth
            ZStack {
                HStack(spacing: gap) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(palette.direct)
                        .frame(width: directWidth)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(palette.proxy)
                        .frame(width: proxyWidth)
                }
                HStack {
                    barValue(direct)
                    Spacer(minLength: 8)
                    barValue(proxy)
                }
                .padding(.horizontal, 8)
            }
            .opacity(total == 0 ? 0.28 : 1)
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Direct \(ByteRateFormatter.byteCount(direct)), Proxy \(ByteRateFormatter.byteCount(proxy))"
        )
    }

    private func barValue(_ bytes: UInt64) -> some View {
        let parts = ByteRateFormatter.parts(bytes)
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(parts.value)
                .font(.caption.monospacedDigit().weight(.semibold))
            Text(parts.unit)
                .font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}
