import SwiftUI
import MapKit

struct RaceView: View {
    private enum Mode: String, CaseIterable { case calendar = "Calendar", race = "Race" }
    @State private var mode = Mode.race
    @AppStorage("hud-auto-hide") private var autoHideHUD = true
    @AppStorage("standings-column") private var standingsColumnID = StandingsColumn.gap.rawValue
    @AppStorage("standings-column-order") private var standingsOrderIDs = StandingsColumn.stored(StandingsColumn.defaultOrder)
    @State private var flight: MapFlight?
    @State private var transitioning = false
    @State private var transitionDestination = Mode.race
    @State private var transitionTask: Task<Void, Never>?
    @State private var session = RaceSession()
    @State private var showsSettings = false
    @State private var showsLighting = false
    @State private var library = ReplayLibrary()
    @State private var isScrubbing = false
    @State private var wasPlayingBeforeScrub = false
    @State private var calendarFade = 1.0
    @State private var raceFade = 1.0
    @State private var flightBegan = 0.0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 800
            let edge = HUDLayout.edgeInset
            let standingsWidth: CGFloat = compact ? 155 : 245
            let playerWidth = min(430, max(240, geometry.size.width - 2 * (standingsWidth + edge + 12)))
            ZStack {
                RaceMapView(session: session, frameTime: session.time,
                            active: scenePhase == .active && (mode == .race || transitioning),
                            playbackEnabled: mode == .race && !transitioning)
                    .ignoresSafeArea()
                    .opacity(transitioning && transitionDestination == .race ? raceFade : 1)
                    .accessibilityLabel("Race map. Tap to show controls.")
                    .accessibilityIdentifier("race-map")
                    .simultaneousGesture(TapGesture().onEnded { session.overlays.reveal() })
                    .simultaneousGesture(DragGesture(minimumDistance: 2).onChanged { _ in session.overlays.reveal() })
                SeasonCalendarView(active: mode == .calendar || transitioning, transitioning: transitioning,
                                   flight: flight, onFlightComplete: finishTransition, onOpenRace: openRace,
                                   library: library)
                    .opacity(mode == .calendar ? (transitioning && transitionDestination == .calendar ? calendarFade : 1) : 0)
                    .allowsHitTesting(mode == .calendar && !transitioning)
                ZStack {
                    HStack(alignment: .top, spacing: 8) {
                        standings(compact: compact)
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 16) {
                            if let recording = session.replay?.recordings.first(where: { $0.driver.id == session.selectedDriverID }) {
                                TelemetryGaugeView(telemetry: TelemetryEstimator.estimate(recording: recording, at: session.time),
                                                   diameter: compact ? 170 : 210)
                            }
                            Spacer(minLength: 8)
                            mapControls
                        }
                    }
                    VStack {
                        Spacer()
                        playback.frame(width: playerWidth)
                    }
                }
                .padding(edge)
                .opacity(mode == .race && !transitioning && session.overlays.isVisible ? 1 : 0)
                .animation(.easeInOut(duration: reduceMotion ? 0 : 0.35), value: session.overlays.isVisible)
                .animation(.easeInOut(duration: reduceMotion ? 0 : 0.25), value: transitioning)
                .allowsHitTesting(mode == .race && !transitioning && session.overlays.isVisible)
                .accessibilityHidden(mode != .race || transitioning || !session.overlays.isVisible)

            }
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    if mode == .calendar || session.overlays.isVisible {
                        modeTabs
                            .padding(4)
                            .glassPanel(in: Capsule())
                            .padding(.top, edge)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: reduceMotion ? 0 : 0.35), value: session.overlays.isVisible)
            }
            // macOS input is handled by RaceMapView's event monitor. SwiftUI hover
            // callbacks during layout can otherwise keep restarting the idle timer.
            #if os(iOS)
            .onContinuousHover { phase in
                if case .active = phase { session.overlays.reveal() }
            }
            #endif
        }
        .preferredColorScheme(mode == .race && session.lightingIsDay ? .light : .dark)
        .tint(StintPalette.red)
        .buttonStyle(.plain)
        #if os(iOS)
        .ignoresSafeArea(.container, edges: .bottom)
        .statusBarHidden(true)
        #endif
        .onDisappear { transitionTask?.cancel() }
        .onChange(of: showsSettings) { session.overlays.reveal() }
        .onChange(of: autoHideHUD) { session.overlays.reveal() }
        .onChange(of: library.error) {
            if let error = library.error { session.error = error; library.error = nil }
        }
        .alert("Replay unavailable", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil; session.overlays.reveal() }
        } message: { Text(session.error ?? "") }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            session.overlays.reveal()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(transitioning ? 16 : 100)) } catch { return }
                let now = ProcessInfo.processInfo.systemUptime
                if transitioning, let flight {
                    let progress = min(1, max(0, (now - flightBegan) / max(0.001, flight.duration)))
                    // Crossfades ride the flight: the destination fades in while the camera is already moving.
                    calendarFade = min(1, progress / 0.25)
                    raceFade = max(0, (progress - 0.8) / 0.2)
                } else {
                    calendarFade = 1
                    raceFade = 1
                }
                session.overlays.update(at: now, isInteracting: showsSettings || showsLighting
                                        || mode == .calendar || transitioning || isScrubbing || session.error != nil || voiceOverEnabled, autoHideEnabled: autoHideHUD)
            }
        }
    }

    private func openRace(_ circuit: DemoCircuit) {
        guard !transitioning else { return }
        transitioning = true
        transitionDestination = .race
        session.overlays.reveal()
        transitionTask = Task { @MainActor in
            do {
                let race = Season2026.races.first { $0.circuitID == circuit.id }
                let saved = race.map { library.isSaved($0) } ?? false
                let replay: RaceReplay
                if saved, let race { replay = try await library.load(race) }
                else { replay = try await Task.detached(priority: .userInitiated) { try circuit.load() }.value }
                guard !Task.isCancelled else { return }
                session.install(replay, source: saved ? "OPENF1" : "SIMULATED")
                session.demoCircuit = circuit
                // Let the retained race map prepare its exact fitted/follow camera.
                try await Task.sleep(for: .milliseconds(80))
                beginFlight(to: .race)
            } catch {
                transitioning = false
                session.error = error.localizedDescription
            }
        }
    }

    private func switchMode(_ target: Mode) {
        guard target != mode, !transitioning else { return }
        transitioning = true
        transitionDestination = target
        session.overlays.reveal()
        beginFlight(to: target)
    }

    private func beginFlight(to target: Mode) {
        let globeCamera = MKMapCamera(lookingAtCenter: .init(latitude: 20, longitude: 15),
                                      fromDistance: 40_000_000, pitch: 0, heading: 0)
        let trackCamera = session.displayedCamera?.copy() as? MKMapCamera
            ?? MKMapCamera(lookingAtCenter: session.selectedPosition?.point.coordinate ?? .init(latitude: 0, longitude: 0),
                           fromDistance: 3500, pitch: 48, heading: 0)
        flight = MapFlight(start: target == .calendar ? trackCamera : nil,
                           destination: target == .calendar ? globeCamera : trackCamera,
                           duration: reduceMotion ? 0 : 2.4, toGlobe: target == .calendar,
                           satellite: session.satellite, day: session.lightingIsDay)
        flightBegan = ProcessInfo.processInfo.systemUptime
        if target == .calendar {
            calendarFade = 0
            mode = .calendar
        }
    }

    private func finishTransition() {
        withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.35)) { mode = transitionDestination }
        transitionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            transitioning = false
            flight = nil
            session.overlays.reveal()
        }
    }

    private var modeTabs: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases, id: \.self) { tab in
                Button {
                    switchMode(tab)
                } label: {
                    Text(tab.rawValue).font(.system(size: 13, weight: .semibold))
                        .frame(width: 86, height: 34)
                        .foregroundStyle(mode == tab ? StintPalette.white : Color.primary)
                        .background(mode == tab ? StintPalette.red : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .disabled(transitioning)
                .accessibilityIdentifier("tab-\(tab.rawValue.lowercased())")
                .accessibilityAddTraits(mode == tab ? .isSelected : [])
            }
        }
    }

    private func standings(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("STANDINGS").font(.system(size: 10, weight: .semibold)).tracking(1.4)
                Spacer()
                Text("\(session.sourceName == "SIMULATED" ? "DEMO" : "REPLAY") · \(session.positions.count)")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            StandingsColumnBar(selectedID: $standingsColumnID, orderIDs: $standingsOrderIDs, compact: compact)
            let column = StandingsColumn(rawValue: standingsColumnID) ?? .gap
            let rows = session.timingRows
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(session.standings) { car in
                        Button {
                            session.overlays.reveal()
                            session.selectedDriverID = car.id
                        } label: {
                            HStack(spacing: compact ? 7 : 10) {
                                Text(car.racePosition.map(String.init) ?? "—")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary).frame(width: 18)
                                Capsule().fill(Color(hex: car.driver.color)).frame(width: 3, height: 23)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(compact ? car.id : car.driver.name.components(separatedBy: " ").last ?? car.id)
                                        .font(.system(size: 12, weight: .bold, design: .rounded)).lineLimit(1)
                                    if !compact {
                                        Text(car.driver.team ?? car.id)
                                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                                StandingsCell(column: column, row: rows[car.id], isLeader: car.racePosition == 1)
                            }
                            .padding(.horizontal, compact ? 12 : 16).padding(.vertical, compact ? 9 : 7)
                            .background(Color.primary.opacity(car.id == session.selectedDriverID ? 0.16 : 0),
                                        in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel("\(car.driver.name), \(car.driver.team ?? ""), position \(car.racePosition.map(String.init) ?? "unavailable")")
                        .accessibilityIdentifier("driver-\(car.id)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, compact ? -12 : -16)
            if let car = session.selectedPosition {
                Divider().opacity(0.5)
                HStack {
                    Text(car.driver.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(car.speedKPH.map { "\(Int($0.rounded())) km/h" } ?? "—")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(compact ? 12 : 16)
        .frame(width: compact ? 155 : 245)
        .frame(maxHeight: .infinity)
        .glassPanel()
        .accessibilityIdentifier("standings-panel")
    }

    private var mapControls: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                control("map", label: "Map appearance") { showsSettings.toggle() }
                    .popover(isPresented: $showsSettings, arrowEdge: .trailing) { settings }
                Divider().frame(width: 24)
                control(session.lighting.symbol, label: "Map lighting", active: session.lighting != .night) { showsLighting.toggle() }
                    .accessibilityValue(session.lighting.rawValue)
                    .popover(isPresented: $showsLighting, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Lighting").font(.headline)
                            ForEach(RaceLighting.allCases) { mode in
                                Button {
                                    session.lighting = mode
                                    session.overlays.reveal()
                                } label: {
                                    HStack {
                                        Label(mode.rawValue, systemImage: mode.symbol)
                                        Spacer()
                                        if session.lighting == mode { Image(systemName: "checkmark") }
                                    }.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("lighting-\(mode.id)")
                            }
                            if session.lighting == .raceTime {
                                Text(session.lightingTimeLabel).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(20).frame(width: 230)
                    }
            }
            .glassPanel(in: Capsule())
            control(session.tilted ? "view.3d" : "view.2d", label: "Toggle map tilt", active: session.tilted) { session.tilted.toggle() }
                .glassPanel(in: Circle())
            control(session.followsDriver ? "point.forward.to.point.capsulepath" : "car.rear.tilt.road.lanes.curved.right",
                    label: session.followsDriver ? "Zoom out" : "Follow car", active: session.followsDriver) {
                if session.followsDriver { session.overview() }
                else { session.toggleFollow() }
            }
            .accessibilityIdentifier("follow-toggle")
            .glassPanel(in: Circle())
            control(autoHideHUD ? "eye.slash" : "eye", label: "Auto-hide HUD", active: !autoHideHUD) {
                autoHideHUD.toggle()
            }
            .glassPanel(in: Circle())
            .accessibilityIdentifier("hud-auto-hide")
            .accessibilityValue(autoHideHUD ? "On" : "Off")
            .accessibilityHint(autoHideHUD ? "Controls fade after five seconds. Turn off to keep them visible." : "Controls stay visible. Turn on to fade after five seconds.")
        }
    }

    private func control(_ symbol: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            session.overlays.reveal()
            action()
        } label: {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label).help(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Map appearance").font(.title3.bold())
            Picker("Base map", selection: $session.satellite) {
                Text("Map").tag(false)
                Text("Satellite").tag(true)
            }.pickerStyle(.segmented)
            Toggle("Driver labels", isOn: $session.showLabels)
            Toggle("Tilt map", isOn: $session.tilted)
            Toggle("Rotate with followed driver", isOn: $session.followsHeading)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Car size"); Spacer(); Text(session.carScale, format: .number.precision(.fractionLength(1))) + Text("×") }
                Slider(value: $session.carScale, in: 0.6...2)
            }
        }
        .font(.system(size: 13)).padding(22).frame(width: 300)
    }

    private var playback: some View {
        HStack(spacing: 12) {
            Button { session.overlays.reveal(); session.time = 0 } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 12)).frame(width: 26, height: 40)
            }
            .accessibilityLabel("Restart replay")
            Button { session.overlays.reveal(); session.togglePlayback() } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(StintPalette.white)
                    .frame(width: 38, height: 38).background(StintPalette.red, in: Circle())
            }
            .accessibilityLabel(session.isPlaying ? "Pause replay" : "Play replay")
            .keyboardShortcut(.space, modifiers: [])
            Text(timestamp(session.time)).font(.system(size: 11, weight: .medium, design: .monospaced)).frame(width: 40)
            Slider(value: Binding(get: { session.time }, set: { session.time = $0 }), in: 0...max(1, session.duration), onEditingChanged: { editing in
                session.overlays.reveal()
                isScrubbing = editing
                if editing {
                    wasPlayingBeforeScrub = session.isPlaying
                    session.isPlaying = false
                } else { session.isPlaying = wasPlayingBeforeScrub && session.time < session.duration }
            })
            .accessibilityLabel("Replay position")
            Button {
                session.overlays.reveal()
                let rates = [0.5, 1.0, 2.0, 4.0]
                let index = rates.firstIndex(of: session.playbackRate) ?? 1
                session.playbackRate = rates[(index + 1) % rates.count]
            } label: {
                Text("\(session.playbackRate.formatted())×")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).frame(width: 30, height: 40)
            }
            .accessibilityLabel("Playback speed")
        }
        .padding(.horizontal, 14).padding(.vertical, 8).glassPanel()
    }

    private func timestamp(_ time: Double) -> String { String(format: "%02d:%02d", Int(time) / 60, Int(time) % 60) }
}

private struct GlassPanel<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            content
                .foregroundStyle(.primary)
                .glassEffect(.regular.tint((colorScheme == .dark ? StintPalette.asphalt : StintPalette.white).opacity(0.06)), in: shape)
        } else {
            content
                .foregroundStyle(.primary)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
        }
    }
}

extension View {
    func glassPanel() -> some View { glassPanel(in: RoundedRectangle(cornerRadius: 22)) }
    func glassPanel<S: InsettableShape>(in shape: S) -> some View { modifier(GlassPanel(shape: shape)) }
}
