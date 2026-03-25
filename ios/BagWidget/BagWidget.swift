import WidgetKit
import SwiftUI
import AppIntents

private let appGroup  = "group.app.bitbag"

// #1C1C1E — iOS standard dark widget background (secondarySystemBackground dark variant).
// Hardcoded so it's always dark regardless of device colour scheme.
private let bgColor   = Color(red: 0.110, green: 0.110, blue: 0.118)
private let btcOrange = Color(red: 0.969, green: 0.576, blue: 0.102)   // #F7931A
private let posGreen  = Color(red: 0.0,   green: 0.784, blue: 0.588)   // #00C896
private let negRed    = Color(red: 1.0,   green: 0.278, blue: 0.341)   // #FF4757
private let secondary = Color(red: 0.533, green: 0.533, blue: 0.667)   // #8888AA
private let dimText   = Color(red: 0.333, green: 0.333, blue: 0.439)   // #555570

// MARK: - Configuration intent

enum ChartTimeframe: String, AppEnum {
    case day1   = "1D"
    case week1  = "1W"
    case month1 = "1M"
    case year1  = "1Y"
    case year5  = "5Y"
    case all    = "ALL"

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Timeframe")
    static var caseDisplayRepresentations: [ChartTimeframe: DisplayRepresentation] = [
        .day1:   "1 Day",
        .week1:  "1 Week",
        .month1: "1 Month",
        .year1:  "1 Year",
        .year5:  "5 Years",
        .all:    "All Time",
    ]

    var days: Int {
        switch self {
        case .day1:   return 1
        case .week1:  return 7
        case .month1: return 30
        case .year1:  return 365
        case .year5:  return 1825
        case .all:    return 0
        }
    }
}

struct BagWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Bag Widget"
    static var description = IntentDescription("Configure your Bitcoin widget.")

    @Parameter(title: "Chart Timeframe", default: .week1)
    var timeframe: ChartTimeframe

    @Parameter(title: "Show Price Change %", default: true)
    var showChange: Bool
}

// MARK: - Data model

struct BagEntry: TimelineEntry {
    let date: Date
    let price: String
    let netWorth: String?
    let change: String
    let isPositive: Bool
    let updatedAt: String
    let fastFee: String?
    let chartPrices: [Double]
    var showChange: Bool = true
}

extension BagEntry {
    static func load(showChange: Bool = true) -> BagEntry {
        let ud = UserDefaults(suiteName: appGroup)
        let price      = ud?.string(forKey: "widget_price") ?? "—"
        let netWorth   = ud?.string(forKey: "widget_net_worth")
        let change     = ud?.string(forKey: "widget_change") ?? ""
        let isPositive = ud?.bool(forKey: "widget_change_positive") ?? true
        let updatedAt  = ud?.string(forKey: "widget_updated_at") ?? ""
        let showFee    = ud?.bool(forKey: "widget_show_fee") ?? false
        let fastFee    = showFee ? ud?.string(forKey: "widget_fast_fee") : nil

        var chartPrices: [Double] = []
        if let json = ud?.string(forKey: "widget_chart_prices"),
           let data = json.data(using: .utf8),
           let arr = try? JSONDecoder().decode([Double].self, from: data) {
            chartPrices = arr
        }

        return BagEntry(date: Date(), price: price, netWorth: netWorth,
                        change: change, isPositive: isPositive,
                        updatedAt: updatedAt, fastFee: fastFee,
                        chartPrices: chartPrices, showChange: showChange)
    }

    static var placeholder: BagEntry {
        BagEntry(date: Date(), price: "$84,234", netWorth: "$42,117",
                 change: "+2.4%", isPositive: true, updatedAt: "12:00",
                 fastFee: nil, chartPrices: [], showChange: true)
    }
}

// MARK: - Timeline provider

/// Intent-aware provider for BagWidget.
struct BagIntentProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BagEntry { .placeholder }

    func snapshot(for configuration: BagWidgetIntent, in context: Context) async -> BagEntry {
        context.isPreview ? .placeholder : .load(showChange: configuration.showChange)
    }

    func timeline(for configuration: BagWidgetIntent, in context: Context) async -> Timeline<BagEntry> {
        // Persist chosen timeframe to the app group so Flutter reads it on next open
        // and fetches chart data for the correct timeframe (mirrors Android configure activity).
        UserDefaults(suiteName: appGroup)?.set(
            configuration.timeframe.days, forKey: "widget_timeframe_days")

        let entry = BagEntry.load(showChange: configuration.showChange)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        return Timeline(entries: [entry], policy: .after(next))
    }
}

// MARK: - Sparkline shape (full-bleed background)

struct SparklineShape: Shape {
    let prices: [Double]

    func path(in rect: CGRect) -> Path {
        guard prices.count >= 2,
              let lo = prices.min(), let hi = prices.max() else { return Path() }
        let range = hi - lo
        var path = Path()
        for (i, p) in prices.enumerated() {
            let x = rect.width * CGFloat(i) / CGFloat(prices.count - 1)
            let y = range > 0
                ? rect.height * CGFloat(1 - (p - lo) / range)
                : rect.height / 2
            let pt = CGPoint(x: x, y: y)
            i == 0 ? path.move(to: pt) : path.addLine(to: pt)
        }
        return path
    }
}

// MARK: - Small widget (2×2) — dark card, no chart

struct SmallView: View {
    let e: BagEntry
    private var changeColor: Color { e.isPositive ? posGreen : negRed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("BTC")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(btcOrange)
                Spacer()
                Text(e.updatedAt)
                    .font(.system(size: 8))
                    .foregroundColor(dimText)
            }
            Spacer(minLength: 4)
            Text("NET WORTH")
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(secondary)
                .tracking(0.5)
            if let nw = e.netWorth {
                Text(nw)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(e.price)
                .font(.system(size: 12))
                .foregroundColor(secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                if e.showChange {
                    Text(e.change)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(changeColor)
                }
                if let fee = e.fastFee {
                    Spacer()
                    Text("⚡\(fee)")
                        .font(.system(size: 9))
                        .foregroundColor(btcOrange)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Medium widget (4×2) — full-bleed sparkline background, content overlaid

struct MediumView: View {
    let e: BagEntry
    private var changeColor: Color { e.isPositive ? posGreen : negRed }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Full-bleed sparkline drawn behind everything
            if e.chartPrices.count >= 2 {
                SparklineShape(prices: e.chartPrices)
                    .stroke(e.isPositive ? posGreen : negRed,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .opacity(0.30)
                    .padding(.top, 28)   // keep line out of the top text row

                // Scrim at bottom so text stays readable over the sparkline
                LinearGradient(
                    colors: [Color.black.opacity(0), Color.black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            // Content overlay
            VStack(alignment: .leading, spacing: 0) {
                // Top row: BTC · price · change · time
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("BTC")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(btcOrange)
                    Text(e.price)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                    if e.showChange {
                        Text(e.change)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(changeColor)
                    }
                    Spacer()
                    Text(e.updatedAt)
                        .font(.system(size: 8))
                        .foregroundColor(dimText)
                }

                Spacer(minLength: 0)

                // Net worth block
                Text("NET WORTH")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(secondary)
                    .tracking(0.5)
                    .padding(.bottom, 1)
                if let nw = e.netWorth {
                    Text(nw)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }

                // Optional fee row
                if let fee = e.fastFee {
                    HStack(spacing: 3) {
                        Text("⚡")
                            .font(.system(size: 8))
                        Text(fee)
                            .font(.system(size: 9))
                            .foregroundColor(btcOrange)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Entry view

struct BagWidgetEntryView: View {
    let entry: BagEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        if family == .systemMedium {
            MediumView(e: entry)
        } else {
            SmallView(e: entry)
        }
    }
}

// MARK: - Widget

struct BagWidget: Widget {
    let kind = "BagWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: BagWidgetIntent.self,
                               provider: BagIntentProvider()) { entry in
            BagWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) { bgColor }
        }
        .configurationDisplayName("Bag")
        .description("BTC price and portfolio value.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
