import EmbersCore
import EmbersData
import SwiftUI

/// Where the period's income came from, and where it went, as one picture: payers on the left, the
/// budget in the middle, groups and their categories fanning out to the right.
struct CashFlowReport: View {
    let flow: CashFlow
    let range: ReportRange
    let onSelect: (SpendingDrill) -> Void

    @Environment(BudgetModel.self) private var budget

    var body: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                tile(budget.money(flow.income), "Income", tint: Flame.seriesIncome)
                tile(budget.money(flow.spending), "Spending", tint: Flame.seriesSpending)
                // The caption says which way, so the figure does not say it again with a minus.
                tile(
                    budget.money(abs(flow.income - flow.spending)),
                    flow.fromSavings > 0 ? "Drawn from savings" : "Kept",
                    tint: Flame.amountColor(flow.income - flow.spending)
                )
                tile(savingsRate, "Savings rate", tint: nil)
            }

            ReportCard(title: String(localized: "Cash flow"), symbol: "arrow.triangle.branch") {
                Text(range.label).font(.subheadline).foregroundStyle(.secondary)
                if flow.isEmpty {
                    Text("Nothing came in or went out.").foregroundStyle(.secondary)
                } else {
                    #if os(iOS)
                    // A phone is too narrow for four columns of labels, so the picture keeps its
                    // shape and scrolls sideways rather than squeezing every name to nothing.
                    ScrollView(.horizontal, showsIndicators: false) {
                        CashFlowDiagram(flow: flow, onSelect: onSelect)
                            .frame(width: 680, height: diagramHeight)
                    }
                    #else
                    CashFlowDiagram(flow: flow, onSelect: onSelect)
                        .frame(height: diagramHeight)
                    #endif
                    Text("Tap a group or category to see what is in it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var diagramHeight: CGFloat { CashFlowDiagram.height(for: flow) }

    private var savingsRate: String {
        guard flow.income > 0 else { return "—" }
        let rate = Double(flow.income - flow.spending) / Double(flow.income)
        return rate.formatted(.percent.precision(.fractionLength(0...1)).locale(.display))
    }

    private func tile(_ value: String, _ caption: LocalizedStringKey, tint: Color?) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(tint ?? .primary)
            Text(caption)
                .font(.caption.weight(.medium))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Flame.cardBackground))
    }
}

/// The diagram itself: boxes in four columns, joined by ribbons as wide as the money they carry.
///
/// Every column adds up to the same total — the larger of income and spending — so the boxes in each
/// stand edge to edge with the ones beside them. Labels sit beside their boxes and are pushed apart
/// where small boxes crowd together, since a name drawn over another is no name at all.
struct CashFlowDiagram: View {
    let flow: CashFlow
    let onSelect: (SpendingDrill) -> Void

    @Environment(BudgetModel.self) private var budget

    static let labelHeight: CGFloat = 34

    /// Tall enough for every label to sit beside its own box.
    ///
    /// Labels are a fixed height and boxes are a share of the picture, so where small boxes crowd
    /// together their labels push each other down. Labels pushed back up to fit drifted beside other
    /// boxes — "Schooling" beside "Mortgage" — so the picture grows instead, until the lowest label
    /// fits. Width plays no part in any height.
    static func height(for flow: CashFlow) -> CGFloat {
        var height: CGFloat = 360
        for _ in 0..<8 {
            let layout = Layout(flow: flow, size: CGSize(width: 1_000, height: height), nodeWidth: 10, gap: 6)
            let lowest = (layout.labels.map { $0.y + labelHeight / 2 } + layout.nodes.map(\.rect.maxY)).max() ?? 0
            guard lowest > height + 0.5 else { return height }
            height = lowest.rounded(.up)
        }
        return height
    }
    private let nodeWidth: CGFloat = 10
    private let gap: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let layout = Layout(flow: flow, size: proxy.size, nodeWidth: nodeWidth, gap: gap)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for ribbon in layout.ribbons {
                        context.fill(ribbon.path, with: .color(ribbon.color.opacity(0.28)))
                    }
                    for node in layout.nodes {
                        context.fill(
                            Path(roundedRect: node.rect, cornerRadius: 2),
                            with: .color(node.color)
                        )
                    }
                }
                ForEach(layout.labels, id: \.id) { label in
                    VStack(alignment: label.leading ? .leading : .trailing, spacing: 0) {
                        Text(name(of: label.node))
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(verbatim: "\(budget.money(label.node.amount)) (\(share(label.node.amount)))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: layout.labelWidth, height: Self.labelHeight, alignment: label.leading ? .leading : .trailing)
                    .position(x: label.x, y: label.y)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let node = layout.nodes.first(where: { $0.hitRect.contains(location) }),
                      let key = node.flowNode.key, node.drillable
                else { return }
                onSelect(SpendingDrill(keys: [key], title: name(of: node.flowNode)))
            }
        }
    }

    private func share(_ amount: MinorUnits) -> String {
        guard flow.total > 0 else { return "" }
        return (Double(amount) / Double(flow.total)).formatted(.percent.precision(.fractionLength(0...1)).locale(.display))
    }

    private func name(of node: CashFlow.Node) -> String {
        if node.foldedCount > 0 { return String(localized: "\(node.foldedCount) others") }
        switch node.key {
        case .category: return ProvidedName.category(node.name) ?? node.name
        case .group: return ProvidedName.group(node.name) ?? node.name
        case .payee: return node.name.isEmpty ? String(localized: "(no payee)") : (ProvidedName.payee(node.name) ?? node.name)
        case .transfer: return String(localized: "Transfer: \(node.name)")
        case nil: return node.name
        }
    }

    // MARK: - Layout

    struct PlacedNode {
        var flowNode: CashFlow.Node
        var rect: CGRect
        var color: Color
        var drillable: Bool

        /// A sliver of a box is still worth tapping, so it is hit as though it were taller.
        var hitRect: CGRect { rect.insetBy(dx: -8, dy: min(0, (rect.height - 24) / 2)) }
    }

    struct Ribbon {
        var path: Path
        var color: Color
    }

    struct Label {
        var id: Int
        var node: CashFlow.Node
        var x: CGFloat
        var y: CGFloat
        var leading: Bool
    }

    /// Where everything goes, worked out once per size.
    struct Layout {
        var nodes: [PlacedNode] = []
        var ribbons: [Ribbon] = []
        var labels: [Label] = []
        var labelWidth: CGFloat

        init(flow: CashFlow, size: CGSize, nodeWidth: CGFloat, gap: CGFloat) {
            let columns = 4
            let step = (size.width - nodeWidth) / CGFloat(columns - 1)
            labelWidth = max(step - nodeWidth - 12, 60)
            let x = (0..<columns).map { CGFloat($0) * step }

            let sources = flow.sources + (flow.fromSavings > 0
                ? [CashFlow.Node(key: nil, name: String(localized: "From savings"), amount: flow.fromSavings, foldedCount: 0, children: [])]
                : [])
            let middle = CashFlow.Node(key: nil, name: String(localized: "Budget"), amount: flow.total, foldedCount: 0, children: [])
            let outs = flow.groups + (flow.saved > 0
                ? [CashFlow.Node(key: nil, name: String(localized: "Kept"), amount: flow.saved, foldedCount: 0, children: [])]
                : [])
            let leaves = flow.groups.flatMap(\.children)

            // One scale for every column, set by the one with the most gaps to leave room for.
            let mostGaps = CGFloat(max(sources.count, outs.count, leaves.count + flow.groups.count) - 1)
            let scale = flow.total > 0 ? max(size.height - mostGaps * gap, 1) / CGFloat(flow.total) : 0
            func height(_ amount: MinorUnits) -> CGFloat { max(CGFloat(amount) * scale, 1.5) }

            func stack(_ items: [CashFlow.Node], at column: Int) -> [CGRect] {
                var y: CGFloat = 0
                return items.map { item in
                    defer { y += height(item.amount) + gap }
                    return CGRect(x: x[column], y: y, width: nodeWidth, height: height(item.amount))
                }
            }

            let sourceRects = stack(sources, at: 0)
            let middleRect = CGRect(x: x[1], y: 0, width: nodeWidth, height: height(flow.total))
            let outRects = stack(outs, at: 2)

            // Each group's categories start level with the group, or below the previous group's.
            var leafRects: [[CGRect]] = []
            var nextY: CGFloat = 0
            for (index, group) in flow.groups.enumerated() {
                var y = max(outRects[index].minY, nextY)
                leafRects.append(group.children.map { child in
                    defer { y += height(child.amount) + gap }
                    return CGRect(x: x[3], y: y, width: nodeWidth, height: height(child.amount))
                })
                nextY = y
            }

            let groupColors = flow.groups.indices.map { index in
                flow.groups[index].foldedCount > 0 ? Flame.categoricalRest : Flame.categoryColor(index)
            }

            // Ribbons, each taking its slice of both ends in order.
            var middleIn = middleRect.minY
            for (index, source) in sources.enumerated() {
                let h = height(source.amount)
                let color = Self.sourceColor(source)
                ribbons.append(Ribbon(
                    path: Self.ribbon(from: sourceRects[index].maxX, sourceRects[index].minY, to: middleRect.minX, middleIn, height: h),
                    color: color
                ))
                middleIn += h
            }
            var middleOut = middleRect.minY
            for (index, out) in outs.enumerated() {
                let h = height(out.amount)
                let color = index < groupColors.count ? groupColors[index] : Flame.seriesIncome
                ribbons.append(Ribbon(
                    path: Self.ribbon(from: middleRect.maxX, middleOut, to: outRects[index].minX, outRects[index].minY, height: h),
                    color: color
                ))
                middleOut += h
            }
            for (groupIndex, group) in flow.groups.enumerated() {
                var groupOut = outRects[groupIndex].minY
                for (childIndex, child) in group.children.enumerated() {
                    let target = leafRects[groupIndex][childIndex]
                    let h = height(child.amount)
                    ribbons.append(Ribbon(
                        path: Self.ribbon(from: outRects[groupIndex].maxX, groupOut, to: target.minX, target.minY, height: h),
                        color: groupColors[groupIndex]
                    ))
                    groupOut += h
                }
            }

            // Boxes, then labels: the first two columns labelled to the right, the last two to the
            // left, so every label sits over the ribbons rather than off the edge.
            var labelID = 0
            func place(_ items: [CashFlow.Node], _ rects: [CGRect], colors: [Color], drillable: Bool, leading: Bool) {
                var lastBottom = -CGFloat.infinity
                var placed: [Label] = []
                for (index, item) in items.enumerated() {
                    nodes.append(PlacedNode(flowNode: item, rect: rects[index], color: colors[index], drillable: drillable))
                    // Pushed down past the label above; `height(for:)` makes the room.
                    let y = max(rects[index].midY, lastBottom + CashFlowDiagram.labelHeight, CashFlowDiagram.labelHeight / 2)
                    lastBottom = y
                    let labelX = leading
                        ? rects[index].maxX + 6 + labelWidth / 2
                        : rects[index].minX - 6 - labelWidth / 2
                    placed.append(Label(id: labelID, node: item, x: labelX, y: y, leading: leading))
                    labelID += 1
                }
                labels += placed
            }

            place(sources, sourceRects, colors: sources.map(Self.sourceColor), drillable: false, leading: true)
            place([middle], [middleRect], colors: [Flame.ember], drillable: false, leading: true)
            place(
                outs, outRects,
                colors: outs.indices.map { $0 < groupColors.count ? groupColors[$0] : Flame.seriesIncome },
                drillable: true, leading: false
            )
            for (groupIndex, group) in flow.groups.enumerated() {
                place(
                    group.children, leafRects[groupIndex],
                    colors: Array(repeating: groupColors[groupIndex], count: group.children.count),
                    drillable: true, leading: false
                )
            }
            // The push in `place` is per group, so the last column could still have a label on one
            // from the group above it; one pass down the whole column settles it.
            let indices = labels.indices
                .filter { nodes[$0].rect.minX == x[3] }
                .sorted { labels[$0].y < labels[$1].y }
            var bottom = -CGFloat.infinity
            for index in indices {
                labels[index].y = max(labels[index].y, bottom + CashFlowDiagram.labelHeight)
                bottom = labels[index].y
            }

            // "Budget" reads rightwards from the middle column and the groups' labels leftwards from
            // the next, over the same ribbons, so at one height they are drawn over each other. It
            // takes the free height nearest its middle.
            let middleIndex = sources.count
            let groupYs = labels[(middleIndex + 1)..<(middleIndex + 1 + outs.count)].map(\.y)
            let lineHeight = CashFlowDiagram.labelHeight
            let lowest = lineHeight / 2, highest = max(lowest, middleRect.maxY - lineHeight / 2)
            let candidates = ([middleRect.midY] + groupYs.flatMap { [$0 - lineHeight, $0 + lineHeight] })
                .map { min(max($0, lowest), highest) }
            if let free = candidates
                .filter({ candidate in groupYs.allSatisfy { abs($0 - candidate) >= lineHeight - 0.5 } })
                .min(by: { abs($0 - middleRect.midY) < abs($1 - middleRect.midY) }) {
                labels[middleIndex].y = free
            }
        }

        /// Income is green; money drawn from savings is not income, so it is the neutral.
        static func sourceColor(_ node: CashFlow.Node) -> Color {
            node.key == nil && node.foldedCount == 0 ? Flame.categoricalRest : Flame.seriesIncome
        }

        /// A band from one box's edge to another's, curving between them.
        static func ribbon(from x0: CGFloat, _ y0: CGFloat, to x1: CGFloat, _ y1: CGFloat, height: CGFloat) -> Path {
            let mid = (x0 + x1) / 2
            var path = Path()
            path.move(to: CGPoint(x: x0, y: y0))
            path.addCurve(to: CGPoint(x: x1, y: y1), control1: CGPoint(x: mid, y: y0), control2: CGPoint(x: mid, y: y1))
            path.addLine(to: CGPoint(x: x1, y: y1 + height))
            path.addCurve(to: CGPoint(x: x0, y: y0 + height), control1: CGPoint(x: mid, y: y1 + height), control2: CGPoint(x: mid, y: y0 + height))
            path.closeSubpath()
            return path
        }
    }
}
