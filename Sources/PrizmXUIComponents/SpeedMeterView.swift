import SwiftUI
import PrizmXUIEngine

/// Compact live throughput row: uplink / downlink arrows plus formatted rates.
public struct SpeedMeterView: View {
    public var uploadText: String
    public var downloadText: String
    public var axis: Axis

    public enum Axis: Sendable {
        case horizontal
        case vertical
    }

    public init(uploadText: String, downloadText: String, axis: Axis = .horizontal) {
        self.uploadText = uploadText
        self.downloadText = downloadText
        self.axis = axis
    }

    public init(
        uploadBytesPerSecond: Double,
        downloadBytesPerSecond: Double,
        axis: Axis = .horizontal
    ) {
        self.init(
            uploadText: ByteRateFormatter.string(fromBytesPerSecond: uploadBytesPerSecond),
            downloadText: ByteRateFormatter.string(fromBytesPerSecond: downloadBytesPerSecond),
            axis: axis
        )
    }

    public var body: some View {
        let content = Group {
            rateRow(
                systemImage: "arrow.up",
                tint: .orange,
                text: uploadText,
                accessibility: "Upload"
            )
            rateRow(
                systemImage: "arrow.down",
                tint: .cyan,
                text: downloadText,
                accessibility: "Download"
            )
        }

        switch axis {
        case .horizontal:
            HStack(spacing: 16) { content }
        case .vertical:
            VStack(alignment: .leading, spacing: 6) { content }
        }
    }

    private func rateRow(systemImage: String, tint: Color, text: String, accessibility: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 12)
            Text(text)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(accessibility) \(text)"))
    }
}

#Preview {
    SpeedMeterView(uploadBytesPerSecond: 1_200_000, downloadBytesPerSecond: 8_500_000)
        .padding()
}
