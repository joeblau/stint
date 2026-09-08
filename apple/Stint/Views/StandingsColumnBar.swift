import SwiftUI

/// Four favorite columns as icon buttons plus a fifth that opens the full, reorderable list.
struct StandingsColumnBar: View {
    @Binding var selectedID: String
    @Binding var orderIDs: String
    let compact: Bool
    @State private var showsList = false
    @Environment(\.colorScheme) private var colorScheme

    private var order: [StandingsColumn] { StandingsColumn.order(from: orderIDs) }
    private var favorites: [StandingsColumn] { Array(order.prefix(StandingsColumn.favoriteCount)) }
    private var selected: StandingsColumn { StandingsColumn(rawValue: selectedID) ?? .gap }

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(favorites) { column in
                Button { selectedID = column.id } label: { icon(column.symbol, active: selected == column) }
                    .buttonStyle(.plain)
                    .help(column.title)
                    .accessibilityLabel(column.title)
                    .accessibilityHint(column.detail)
                    .accessibilityAddTraits(selected == column ? .isSelected : [])
            }
            Button { showsList.toggle() } label: {
                icon(favorites.contains(selected) ? "ellipsis" : selected.symbol, active: !favorites.contains(selected))
            }
            .buttonStyle(.plain)
            .help("All columns")
            .accessibilityLabel("More columns")
            .accessibilityValue(selected.title)
            .accessibilityHint("Shows every column. Tap one to use it; drag to reorder favorites.")
            .popover(isPresented: $showsList, arrowEdge: .top) {
                StandingsColumnList(selectedID: $selectedID, orderIDs: $orderIDs)
                    .preferredColorScheme(colorScheme)
            }
        }
    }

    private func icon(_ symbol: String, active: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: compact ? 12 : 15, weight: .semibold))
            .foregroundStyle(active ? Color.primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 28 : 34)
            .background(Color.primary.opacity(active ? 0.18 : 0.06), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Every column in favorite order. Tapping a row shows that column; dragging reorders the list,
/// and the first four rows are the favorite buttons.
struct StandingsColumnList: View {
    @Binding var selectedID: String
    @Binding var orderIDs: String
    private var order: [StandingsColumn] { StandingsColumn.order(from: orderIDs) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Column").font(.headline)
            Text("Tap to show. Drag to reorder; the top \(StandingsColumn.favoriteCount) are your buttons.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(Array(order.enumerated()), id: \.element) { index, column in
                    let isSelected = column.id == selectedID
                    let isFavorite = index < StandingsColumn.favoriteCount
                    HStack(spacing: 10) {
                        Image(systemName: column.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isSelected ? StintPalette.red : .secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(column.title).font(.system(size: 13, weight: .semibold))
                            Text(column.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        if isSelected {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.primary)
                        }
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 10))
                            .foregroundStyle(isFavorite ? StintPalette.red : .secondary.opacity(0.5))
                        #if os(macOS)
                        Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.6))
                        #endif
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedID = column.id }
                    .listRowBackground(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(isSelected ? 0.14 : (isFavorite ? 0.04 : 0))))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(column.title)
                    .accessibilityValue(isFavorite ? "favorite" : "")
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { selectedID = column.id }
                    .accessibilityAction(named: "Move up") { move(column, by: -1) }
                    .accessibilityAction(named: "Move down") { move(column, by: 1) }
                    .accessibilityIdentifier("standings-column-row-\(column.id)")
                }
                .onMove { source, destination in
                    var reordered = order
                    reordered.move(fromOffsets: source, toOffset: destination)
                    orderIDs = StandingsColumn.stored(reordered)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            Button("Reset Order") { orderIDs = StandingsColumn.stored(StandingsColumn.defaultOrder) }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300, height: 660)
    }

    private func move(_ column: StandingsColumn, by offset: Int) {
        var reordered = order
        guard let index = reordered.firstIndex(of: column) else { return }
        let target = index + offset
        guard reordered.indices.contains(target) else { return }
        reordered.swapAt(index, target)
        orderIDs = StandingsColumn.stored(reordered)
    }
}

/// The value cell for one car in the standings list. Highlighted values render as filled chips so
/// they stay legible on light (day) and dark (night) glass alike.
struct StandingsCell: View {
    let column: StandingsColumn
    let row: RaceTiming.Row?
    let isLeader: Bool

    private enum Tone {
        case neutral, sessionBest, personalBest, slower, gained, lost, caution
        var background: Color {
            switch self {
            case .neutral: Color.primary.opacity(0.12)
            case .sessionBest: Color(hex: "#8E3BFF")
            case .personalBest: Color(hex: "#1E9E5A")
            case .slower, .caution: Color(hex: "#F2C230")
            case .gained: Color(hex: "#1E9E5A")
            case .lost: Color(hex: "#D62828")
            }
        }
        var foreground: Color {
            switch self {
            case .neutral: Color.primary
            case .slower, .caution: Color.black.opacity(0.85)
            default: StintPalette.white
            }
        }
    }

    var body: some View {
        Group {
            switch column {
            case .sectors: sectors
            case .tyres: tyre
            case .time: lap(row?.lastLap, highlight: row?.lastLapHighlight ?? .none)
            case .best: lap(row?.bestLap, highlight: row?.bestLapHighlight ?? .none)
            case .diff: diff
            case .pit: pit
            case .gap, .interval: chip(text, tone: .neutral)
            default: plain(text)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(column.title) \(accessibilityText)")
    }

    private var text: String {
        guard let row else { return "—" }
        switch column {
        case .gap: return gapText(row.gap, leader: "LEADER")
        case .interval: return isLeader ? "LEADER" : gapText(row.interval, leader: "—")
        case .laps: return "\(row.lapsCompleted)"
        case .time: return row.lastLap.map(RaceTiming.lapString) ?? "—"
        case .best: return row.bestLap.map(RaceTiming.lapString) ?? "—"
        case .diff:
            guard let diff = row.diff else { return "—" }
            if diff == 0 { return "–" }
            return diff > 0 ? "▲\(diff)" : "▼\(-diff)"
        case .pit:
            switch row.pit {
            case .none: return "—"
            case .inLane: return "IN PIT"
            case .out: return "OUT"
            case .stops(let count, let last): return "\(count)× \(String(format: "%.1fs", last))"
            }
        case .sectors, .tyres: return ""
        }
    }

    private func plain(_ value: String) -> some View {
        Text(value).foregroundStyle(isLeader ? Color.primary : .secondary)
    }

    private func chip(_ value: String, tone: Tone) -> some View {
        Text(value)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(tone.background, in: RoundedRectangle(cornerRadius: 4))
    }

    private func lap(_ seconds: Double?, highlight: RaceTiming.Highlight) -> some View {
        Group {
            if let seconds {
                switch highlight {
                case .sessionBest: chip(RaceTiming.lapString(seconds), tone: .sessionBest)
                case .personalBest: chip(RaceTiming.lapString(seconds), tone: .personalBest)
                case .none: chip(RaceTiming.lapString(seconds), tone: .neutral)
                }
            } else {
                plain("—")
            }
        }
    }

    private var diff: some View {
        Group {
            if let diff = row?.diff, diff != 0 {
                chip(diff > 0 ? "▲\(diff)" : "▼\(-diff)", tone: diff > 0 ? .gained : .lost)
            } else {
                plain(text)
            }
        }
    }

    private var pit: some View {
        Group {
            switch row?.pit ?? .none {
            case .inLane: chip("IN PIT", tone: .caution)
            case .out: chip("OUT", tone: .personalBest)
            case .stops: chip(text, tone: .neutral)
            default: plain(text)
            }
        }
    }

    private func gapText(_ gap: RaceTiming.Gap?, leader: String) -> String {
        switch gap {
        case .leader: leader
        case .time(let seconds): String(format: "+%.3f", seconds)
        case .laps(let laps): "+\(laps) LAP\(laps == 1 ? "" : "S")"
        case nil: "—"
        }
    }

    private var sectors: some View {
        HStack(spacing: 2) {
            ForEach(0..<RaceTiming.sectorCount, id: \.self) { index in
                if let sector = row?.sectors[index], let time = sector.time {
                    chip(String(format: "%.1f", time), tone: sectorTone(sector.highlight))
                } else {
                    chip("–", tone: .slower).opacity(0.35)
                }
            }
        }
    }

    private func sectorTone(_ highlight: RaceTiming.Highlight) -> Tone {
        switch highlight {
        case .sessionBest: .sessionBest
        case .personalBest: .personalBest
        case .none: .slower
        }
    }

    private var tyre: some View {
        HStack(spacing: 5) {
            if let tyre = row?.tyre {
                Text(tyre.compound)
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .foregroundStyle(tyre.compound == "H" ? Color.black : StintPalette.white)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Self.compoundColor(tyre.compound)))
                    .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                plain("\(tyre.age)")
            } else {
                plain("—")
            }
        }
    }

    static func compoundColor(_ compound: String) -> Color {
        switch compound {
        case "S": Color(hex: "#E10600")
        case "M": Color(hex: "#F2C230")
        case "H": Color(hex: "#F5F5F5")
        case "I": Color(hex: "#1E9E5A")
        case "W": Color(hex: "#3A8DFF")
        default: Color(hex: "#A7A7A7")
        }
    }

    private var accessibilityText: String {
        switch column {
        case .sectors:
            return (0..<RaceTiming.sectorCount).map { index in
                row?.sectors[index].time.map { String(format: "%.1f", $0) } ?? "unavailable"
            }.joined(separator: ", ")
        case .tyres:
            guard let tyre = row?.tyre else { return "unavailable" }
            return "\(tyre.compound), \(tyre.age) laps"
        default: return text
        }
    }
}
