import SwiftUI

struct SeasonCalendarView: View {
    let active: Bool
    let transitioning: Bool
    let flight: MapFlight?
    let onFlightComplete: () -> Void
    let onOpenRace: (DemoCircuit) -> Void
    let library: ReplayLibrary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: Int?
    @State private var month = Season2026.nextRace(at: Date())?.startMonth ?? 12
    @State private var overviewRequest = UUID()
    @State private var flyoverRequest = UUID()

    private var selection: SeasonRace? { Season2026.races.first { $0.id == selected } }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            GeometryReader { geometry in
                let compact = geometry.size.width < 800
                ZStack {
                    SeasonGlobeView(active: active, flight: flight, onFlightComplete: onFlightComplete, selected: selected, overviewRequest: overviewRequest, flyoverRequest: flyoverRequest, now: timeline.date) { race in
                        select(race)
                    }
                    .ignoresSafeArea()
                    .accessibilityIdentifier("season-globe")
                    HStack(alignment: .top, spacing: 12) {
                        schedule(now: timeline.date, compact: compact)
                            .frame(width: compact ? 210 : 290)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 12) {
                            legend(now: timeline.date)
                            Spacer()
                            Button {
                                selected = nil
                                overviewRequest = UUID()
                            } label: {
                                Label("Entire globe", systemImage: "globe.europe.africa")
                                    .font(.system(size: 12, weight: .medium)).padding(14)
                                    .contentShape(Rectangle())
                            }
                            .glassPanel()
                            .accessibilityIdentifier("entire-globe")
                            if let selection {
                                detail(selection, now: timeline.date).frame(width: compact ? 190 : 245)
                            }
                        }
                    }
                    .padding(HUDLayout.edgeInset)
                    .opacity(transitioning ? 0 : 1)
                    .allowsHitTesting(!transitioning)
                    .animation(.easeInOut(duration: 0.25), value: transitioning)
                }
            }
        }
    }

    private func select(_ race: SeasonRace) {
        selected = race.id
        month = race.startMonth
    }

    private func schedule(now: Date, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("2026").font(.system(size: 27, weight: .semibold, design: .rounded))
                Spacer()
                Text("SEASON CALENDAR").font(.system(size: 9, weight: .bold)).tracking(1)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 16)
            monthCalendar(now: now).padding(.horizontal, 16)
            Divider().padding(.horizontal, 16)
            HStack {
                Text("RACE ORDER").font(.system(size: 9, weight: .bold)).tracking(1.2)
                Spacer()
                Text("\(Season2026.races.count) rounds").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 16)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Season2026.races) { race in
                            HStack(spacing: 0) {
                                Button { select(race) } label: {
                                    HStack(spacing: 10) {
                                        Text(String(format: "%02d", race.round))
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundStyle(race.isCompleted(at: now) ? StintPalette.white : .secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(race.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                            Text("\(race.circuit.title) · \(race.dateLabel)")
                                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.leading, 16).padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .accessibilityIdentifier("calendar-race-\(race.circuitID)")
                                .accessibilityLabel("Round \(race.round), \(race.name), \(race.dateLabel), \(race.status(at: now))")
                                downloadControl(race, now: now)
                                    .padding(.trailing, 6)
                            }
                            .opacity(race.isCompleted(at: now) || race.id == selected ? 1 : 0.55)
                            .background(StintPalette.white.opacity(race.id == selected ? 0.1 : 0))
                            .overlay(alignment: .leading) {
                                if race.id == selected {
                                    Capsule().fill(StintPalette.red).frame(width: 3).padding(.vertical, 10)
                                }
                            }
                            .id(race.id)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: selected) {
                    if let selected { withAnimation { proxy.scrollTo(selected, anchor: .center) } }
                }
            }
            if library.downloadingCircuitID != nil {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: library.progress)
                    Text(library.progressLabel).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
            }
            Text("Race weekends · local dates")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .padding(.horizontal, 16).padding(.bottom, 14)
        }
        .glassPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("season-schedule")
    }

    @ViewBuilder private func downloadControl(_ race: SeasonRace, now: Date) -> some View {
        if library.downloadingCircuitID == race.circuitID {
            Button { library.cancelDownload() } label: {
                ZStack {
                    Circle().stroke(.primary.opacity(0.2), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: min(1, max(0, library.progress)))
                        .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: library.progress)
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                }.frame(width: 18, height: 18)
                    .frame(width: 36, height: 40).contentShape(Rectangle())
            }
            .accessibilityLabel("Cancel download for \(race.name)")
            .accessibilityValue("\(Int(library.progress * 100)) percent. \(library.progressLabel)")
            .help("Cancel download")
            .accessibilityIdentifier("cancel-download-\(race.circuitID)")
        } else {
            let saved = library.isSaved(race)
            Button {
                select(race)
                if saved { onOpenRace(race.circuit) }
                else { library.download(race) }
            } label: {
                Image(systemName: saved ? "play.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(saved ? StintPalette.white : .secondary)
                    .frame(width: 36, height: 40).contentShape(Rectangle())
            }
            .disabled(!saved && (now < race.endDate || library.downloadingCircuitID != nil))
            .accessibilityIdentifier("download-race-\(race.circuitID)")
            .accessibilityLabel(saved ? "Play saved replay for \(race.name)" : "Download replay for \(race.name)")
            .accessibilityValue(saved ? "Saved on this device" : "Not downloaded")
            .help(saved ? "Play saved replay" : now < race.endDate ? "Available after the race" : "Download from OpenF1")
        }
    }

    private func monthCalendar(now: Date) -> some View {
        let calendar = Calendar(identifier: .gregorian)
        let first = calendar.date(from: DateComponents(year: 2026, month: month, day: 1))!
        let offset = (calendar.component(.weekday, from: first) + 5) % 7
        let days = calendar.range(of: .day, in: .month, for: first)!.count
        return VStack(spacing: 7) {
            HStack {
                Button { changeMonth(by: -1) } label: { Image(systemName: "chevron.left").frame(width: 26, height: 28).contentShape(Rectangle()) }
                    .disabled(month == 1).accessibilityLabel("Previous month")
                Spacer()
                Text(first.formatted(.dateTime.month(.wide))).font(.system(size: 13, weight: .semibold))
                    .accessibilityIdentifier("calendar-month")
                Spacer()
                Button { changeMonth(by: 1) } label: { Image(systemName: "chevron.right").frame(width: 26, height: 28).contentShape(Rectangle()) }
                    .disabled(month == 12).accessibilityLabel("Next month")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 4) {
                ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, day in
                    Text(day).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                }
                ForEach(0..<((offset + days + 6) / 7 * 7), id: \.self) { cell in
                    let day = cell - offset + 1
                    if day > 0 && day <= days {
                        let race = Season2026.races.first { $0.includes(month: month, day: day) }
                        Button { if let race { selected = race.id } } label: {
                            Text(String(day)).font(.system(size: 11, weight: race == nil ? .regular : .bold, design: .rounded))
                                .frame(maxWidth: .infinity).frame(height: 25)
                                .foregroundStyle(race.map { $0.id == selected || $0.isCompleted(at: now) ? StintPalette.white : StintPalette.pitGray } ?? .secondary)
                                .background(race == nil ? .clear : race?.id == selected ? StintPalette.red : StintPalette.white.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .disabled(race == nil)
                        .accessibilityIdentifier("calendar-day-\(month)-\(day)")
                        .accessibilityLabel(race.map { "\($0.name), \(month)/\(day)/2026, \($0.status(at: now))" } ?? "\(month)/\(day)/2026")
                    } else { Color.clear.frame(height: 25) }
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { gesture in
            let movement = gesture.predictedEndTranslation
            guard abs(movement.width) > 40, abs(movement.width) > abs(movement.height) * 1.5 else { return }
            changeMonth(by: movement.width < 0 ? 1 : -1)
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar-month-grid")
        .accessibilityHint("Swipe left for next month or right for previous month")
    }

    private func changeMonth(by offset: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            month = min(12, max(1, month + offset))
        }
    }

    private func legend(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AROUND THE WORLD").font(.system(size: 9, weight: .bold)).tracking(1.4)
            Label("Completed", systemImage: "circle.fill").foregroundStyle(StintPalette.white)
            Label("Upcoming", systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
        .font(.system(size: 10)).padding(14).glassPanel()
    }

    private func detail(_ race: SeasonRace, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ROUND \(race.round) · \(race.status(at: now).uppercased())")
                .font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            Text(race.name).font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(race.circuit.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            Text("\(race.dateLabel) 2026").font(.system(size: 13, weight: .medium, design: .monospaced))
            if let previous = Season2026.races.first(where: { $0.round == race.round - 1 }) {
                let leg = GlobeFlight(from: previous.point.coordinate, to: race.point.coordinate)
                Label("From \(previous.cityName) · \(Int(leg.distanceKm.rounded())) km · \(leg.durationLabel)", systemImage: "airplane")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel("Flight from \(previous.cityName): \(Int(leg.distanceKm.rounded())) kilometers, \(leg.durationLabel)")
                    .accessibilityIdentifier("calendar-flight-leg")
            }
            Button { flyoverRequest = UUID() } label: {
                HStack {
                    Label("Fly over circuit", systemImage: "video")
                    Spacer()
                    Image(systemName: "play.fill").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.2), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("flyover-circuit")
            .help("Take a low, slow lap of the circuit. Drag, pinch, or rotate to explore freely.")
            Button { onOpenRace(race.circuit) } label: {
                HStack {
                    Text(library.isSaved(race) ? "Play saved replay" : "Open race")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(StintPalette.white)
                .padding(12).background(StintPalette.red, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("open-calendar-race")
            Text(library.isSaved(race) ? "Saved on this device · OpenF1" : "Simulated replay")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            Link("Race data by OpenF1", destination: URL(string: "https://openf1.org")!)
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(16).glassPanel()
    }
}
