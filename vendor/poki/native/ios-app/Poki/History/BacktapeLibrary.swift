import SwiftUI
import UIKit

// Backtape's library (issue 356; the owner, 2026-11-15: like the Photos library, but for text). One
// timeline, latest on top, at four zooms: weeks, days, hours and every 10 minutes. Pinching moves
// between them and so does the glass bar at the bottom, which is the same zoom under the thumb. A
// tile is mostly its summary; the icons sit in one row in the corner, each as large as its share of
// the time, with their colours as a soft glow behind them only.

// MARK: Zoom

enum BacktapeZoom: Int, CaseIterable, Identifiable {
    case all, hours, days, weeks

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .hours: "Zoom Hours"
        case .days: "Zoom Days"
        case .weeks: "Zoom Weeks"
        }
    }

    var forget: String {
        switch self {
        case .all: "Forget These 10 Minutes"
        case .hours: "Forget This Hour"
        case .days: "Forget This Day"
        case .weeks: "Forget This Week"
        }
    }

    /// How the model is told the length of what it describes.
    var period: String {
        switch self {
        case .all: "10 minutes"
        case .hours: "an hour"
        case .days: "a day"
        case .weeks: "a week"
        }
    }

    func start(_ date: Date) -> Date {
        let calendar = Calendar.current
        switch self {
        case .all: return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 600).rounded(.down) * 600)
        case .hours: return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        case .days: return calendar.startOfDay(for: date)
        case .weeks: return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }

    func end(_ start: Date) -> Date {
        let calendar = Calendar.current
        switch self {
        case .all: return start.addingTimeInterval(600)
        case .hours: return start.addingTimeInterval(3600)
        case .days: return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        case .weeks: return calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86_400)
        }
    }

    /// The group a tile is listed under: its day, or for a day its week. Weeks stand alone.
    func group(_ start: Date) -> Date? {
        switch self {
        case .all, .hours: return BacktapeZoom.days.start(start)
        case .days: return BacktapeZoom.weeks.start(start)
        case .weeks: return nil
        }
    }

    /// Notes are kept by their start. An hour, a day and a week can start at the same second as a
    /// block of 10 minutes, so each zoom keeps its notes a fraction of a second apart.
    func key(_ start: Date) -> Date { start.addingTimeInterval(Double(rawValue) * 0.25) }

    var finer: BacktapeZoom? { BacktapeZoom(rawValue: rawValue - 1) }
    var coarser: BacktapeZoom? { BacktapeZoom(rawValue: rawValue + 1) }
}

// MARK: Tiles

struct BacktapeTile: Identifiable, Hashable {
    let zoom: BacktapeZoom
    let span: HistorySpan
    var id: String { "\(zoom.rawValue)-\(Int(span.start.timeIntervalSince1970))" }
    var start: Date { span.start }
    var end: Date { span.end }

    static func == (a: BacktapeTile, b: BacktapeTile) -> Bool { a.id == b.id && a.span.entries.count == b.span.entries.count }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum BacktapeRow: Identifiable {
    case week(BacktapeTile)
    case wide(BacktapeTile)
    case pair(BacktapeTile, BacktapeTile)
    case line(BacktapeTile)

    var id: String {
        switch self {
        case .week(let tile), .wide(let tile), .line(let tile): tile.id
        case .pair(let first, _): first.id
        }
    }
}

struct BacktapeGroup: Identifiable {
    let start: Date?
    let rows: [BacktapeRow]
    var id: Date { start ?? .distantPast }
}

struct BacktapeLayout {
    var tiles: [BacktapeZoom: [BacktapeTile]] = [:]
    var groups: [BacktapeZoom: [BacktapeGroup]] = [:]
    var isEmpty: Bool { tiles[.all]?.isEmpty ?? true }

    /// Every zoom's tiles and rows, latest first, from reads that are newest first.
    static func build(_ entries: [HistoryEntry]) -> BacktapeLayout {
        var layout = BacktapeLayout()
        for zoom in BacktapeZoom.allCases {
            var kept: [Date: [HistoryEntry]] = [:]
            for entry in entries { kept[zoom.start(entry.at), default: []].append(entry) }
            let tiles = kept.map { start, entries in
                BacktapeTile(zoom: zoom, span: HistorySpan(start: start, end: zoom.end(start), entries: entries))
            }
            .sorted { $0.start > $1.start }
            layout.tiles[zoom] = tiles

            var order: [Date?] = []
            var members: [Date?: [BacktapeTile]] = [:]
            for tile in tiles {
                let group = zoom.group(tile.start)
                if members[group] == nil { order.append(group) }
                members[group, default: []].append(tile)
            }
            layout.groups[zoom] = order.map { BacktapeGroup(start: $0, rows: rows(members[$0] ?? [], zoom: zoom)) }
        }
        return layout
    }

    /// The busiest tile of a group goes wide. Half width tiles come in pairs only, so when one would
    /// be left over the second busiest goes wide too.
    private static func rows(_ tiles: [BacktapeTile], zoom: BacktapeZoom) -> [BacktapeRow] {
        if zoom == .weeks { return tiles.map { .week($0) } }
        if zoom == .all { return tiles.map { .line($0) } }
        let ranked = tiles.sorted { $0.span.entries.count > $1.span.entries.count }
        var wide: Set<String> = []
        if let first = ranked.first { wide.insert(first.id) }
        if (tiles.count - 1) % 2 == 1, ranked.count > 1 { wide.insert(ranked[1].id) }
        var rows: [BacktapeRow] = []
        var waiting: BacktapeTile?
        for tile in tiles {
            if wide.contains(tile.id) {
                rows.append(.wide(tile))
            } else if let first = waiting {
                rows.append(.pair(first, tile))
                waiting = nil
            } else {
                waiting = tile
            }
        }
        if let last = waiting { rows.append(.wide(last)) }
        return rows
    }
}

// MARK: Apps

/// Apps as Backtape names and draws them: system services get a plain name and symbol, and an app
/// that is gone from the iPhone is marked as deleted.
@MainActor
enum BacktapeApps {
    private static let services: [String: (name: String, symbol: String)] = [
        "com.apple.springboard": ("Home Screen", "square.grid.2x2"),
        "com.apple.screenshotservicesservice": ("Screenshot", "camera.viewfinder"),
        "com.apple.incallservice": ("Call", "phone"),
        "com.apple.coreauthui": ("Passcode", "lock"),
        "com.apple.sharingviewservice": ("Sharing", "square.and.arrow.up"),
        "com.apple.passbookuiservice": ("Wallet", "wallet.pass"),
    ]

    static func service(_ app: String) -> (name: String, symbol: String)? { services[app.lowercased()] }

    static func name(_ app: String) -> String {
        if let service = service(app) { return AppLocalization.bundle.localizedString(forKey: service.name, value: service.name, table: nil) }
        return HistoryNames.app(app)
    }

    /// Each app's share of a span's reads, the largest first.
    static func shares(_ span: HistorySpan) -> [(app: String, share: Double)] {
        var counts: [String: Int] = [:]
        for entry in span.entries where !entry.app.isEmpty { counts[entry.app, default: 0] += 1 }
        let total = Double(max(1, counts.values.reduce(0, +)))
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (app: $0.key, share: Double($0.value) / total) }
    }
}

struct BacktapeAppIcon: View {
    var app: String
    var size: CGFloat
    var order: Int
    @State private var up = false
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        Group {
            if let service = BacktapeApps.service(app) {
                Image(systemName: service.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Color(.tertiarySystemFill), in: Circle())
            } else {
                AppIconView(app: app, size: size)
            }
        }
        // The slow float of the old Game Center bubbles, a little out of step with its neighbours.
        .offset(y: up ? -1.5 : 1.5)
        .rotationEffect(.degrees(up ? 2 : -2))
        .onAppear {
            guard !still else { return }
            withAnimation(.easeInOut(duration: 2.4 + Double(order % 4) * 0.5).repeatForever(autoreverses: true)) { up = true }
        }
        .accessibilityLabel(Text(verbatim: BacktapeApps.name(app)))
    }
}

/// A span's icons in one overlapping row, each as large as its share of the time.
struct BacktapeIconRow: View {
    var span: HistorySpan
    var limit: Int
    var small: CGFloat
    var large: CGFloat

    var body: some View {
        let shares = Array(BacktapeApps.shares(span).prefix(limit))
        HStack(spacing: -5) {
            ForEach(Array(shares.enumerated()), id: \.element.app) { index, item in
                BacktapeAppIcon(app: item.app, size: (small + (large - small) * sqrt(item.share)).rounded(), order: index)
                    .zIndex(Double(limit - index))
            }
        }
    }
}

// MARK: Glow

/// The colour of each app, taken from its icon.
@MainActor
enum BacktapeTint {
    private static var hues: [String: Double] = [:]

    /// The hue of an app's icon, weighted towards its colourful pixels. Without an icon, or for a
    /// grey one, a hue made from the app's name.
    static func hue(_ app: String) -> Double {
        if let hit = hues[app] { return hit }
        if let image = AppIconStore.shared.icon(app), let found = vivid(image) {
            hues[app] = found
            return found
        }
        var sum: UInt32 = 7
        for scalar in app.unicodeScalars { sum = sum &* 31 &+ scalar.value }
        return Double(sum % 360) / 360
    }

    private static func vivid(_ image: UIImage) -> Double? {
        guard let picture = image.cgImage else { return nil }
        let side = 16
        var data = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(picture, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for offset in stride(from: 0, to: data.count, by: 4) {
            let r = Double(data[offset]) / 255, g = Double(data[offset + 1]) / 255, b = Double(data[offset + 2]) / 255
            let weight = (max(r, g, b) - min(r, g, b)) * max(r, g, b)
            red += r * weight
            green += g * weight
            blue += b * weight
            total += weight
        }
        // Too little colour in the icon (black, white, grey) to name a hue.
        guard total > 6 else { return nil }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(red: red / total, green: green / total, blue: blue / total, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha), saturation > 0.15 else { return nil }
        return Double(hue)
    }

    /// A hue between two hues, the short way round the wheel.
    private static func between(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var gap = b - a
        if gap > 0.5 { gap -= 1 }
        if gap < -0.5 { gap += 1 }
        return a + gap * t
    }

    /// The glow's colours: each app's own hue, light and clean, laid out by share. Between two apps
    /// the colour travels round the colour wheel, so a mix is never grey or dirty.
    static func stops(_ span: HistorySpan, dark: Bool) -> [Gradient.Stop] {
        let shares = BacktapeApps.shares(span).filter { BacktapeApps.service($0.app) == nil }.prefix(5)
        let total = max(0.0001, shares.reduce(0) { $0 + $1.share })
        var points: [(hue: Double, at: Double)] = []
        var edge = 0.0
        for item in shares {
            let width = item.share / total
            points.append((hue(item.app), edge + width / 2))
            edge += width
        }
        func color(_ hue: Double) -> Color {
            Color(hue: hue - floor(hue), saturation: dark ? 0.62 : 0.42, brightness: 1)
        }
        guard let first = points.first else { return [] }
        var stops = [Gradient.Stop(color: color(first.hue), location: 0)]
        for (index, point) in points.enumerated() {
            stops.append(Gradient.Stop(color: color(point.hue), location: point.at))
            guard index + 1 < points.count else { continue }
            let next = points[index + 1]
            for step in [1.0 / 3, 2.0 / 3] {
                stops.append(Gradient.Stop(color: color(between(point.hue, next.hue, step)), location: point.at + (next.at - point.at) * step))
            }
        }
        if let last = points.last { stops.append(Gradient.Stop(color: color(last.hue), location: 1)) }
        return stops
    }
}

/// Colour lives only here: a soft pool behind the icons that fades into the plain card.
struct BacktapeGlow: View {
    var span: HistorySpan
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let stops = BacktapeTint.stops(span, dark: scheme == .dark)
        if !stops.isEmpty {
            LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
                .mask {
                    RadialGradient(colors: [.black, .black.opacity(0)], center: UnitPoint(x: 0.6, y: 0.46), startRadius: 6, endRadius: 86)
                }
                .blur(radius: 18)
                .opacity(scheme == .dark ? 0.52 : 0.68)
                .allowsHitTesting(false)
        }
    }
}

// MARK: Summaries

/// Finds or writes the tiles' notes. Kept notes come first for every tile on screen; new ones are
/// written one at a time, starting next to where the owner is looking or has just zoomed.
@MainActor
@Observable
final class BacktapeNotes {
    static let shared = BacktapeNotes()

    private(set) var notes: [String: BacktapeNote] = [:]
    @ObservationIgnored private var wanted: [String: BacktapeTile] = [:]
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored var focus: Date?

    private init() {}

    func appeared(_ tile: BacktapeTile) {
        wanted[tile.id] = tile
        guard notes[tile.id] == nil else { return }
        let me = generation
        Task {
            let kept = await HistoryStore.shared.note(start: tile.zoom.key(tile.start))
            guard generation == me else { return }
            if let kept { notes[tile.id] = kept }
            work()
        }
    }

    func disappeared(_ tile: BacktapeTile) {
        wanted[tile.id] = nil
    }

    /// Whether a note is still to come for this tile, so its place is held.
    func waiting(_ tile: BacktapeTile) -> Bool {
        notes[tile.id] == nil && !failed.contains(tile.id) && tile.end < Date() && BacktapeWriter.available
    }

    /// History changed (something was forgotten): every note is looked up again.
    func reset() {
        generation = UUID()
        worker?.cancel()
        worker = nil
        notes = [:]
        failed = []
    }

    private func next() -> BacktapeTile? {
        let centre = focus ?? Date()
        return wanted.values
            .filter { notes[$0.id] == nil && !failed.contains($0.id) && $0.end < Date() }
            .min { abs($0.start.timeIntervalSince(centre)) < abs($1.start.timeIntervalSince(centre)) }
    }

    private func work() {
        guard worker == nil, BacktapeWriter.available, HistoryLock.shared.unlocked else { return }
        let me = generation
        worker = Task {
            defer { if generation == me { worker = nil } }
            let store = HistoryStore.shared
            let sourceGeneration = await store.summaryGeneration()
            while !Task.isCancelled, generation == me, HistoryLock.shared.unlocked, let tile = next() {
                let key = tile.zoom.key(tile.start)
                let kept = await store.note(start: key)
                guard !Task.isCancelled, generation == me else { return }
                if let kept {
                    notes[tile.id] = kept
                    continue
                }
                // A tile may still hold text from before deletion. Reread every span from the store.
                let entries = await store.entries(from: tile.start, to: tile.end)
                guard !Task.isCancelled, generation == me else { return }
                let written = await BacktapeWriter.write(entries, period: tile.zoom.period)
                guard !Task.isCancelled, generation == me else { return }
                if let written {
                    let saved = await store.keep(written, start: key, generation: sourceGeneration)
                    guard !Task.isCancelled, generation == me, saved else { return }
                    notes[tile.id] = written
                } else {
                    failed.insert(tile.id)
                }
            }
        }
    }
}

// MARK: Tile

struct BacktapeTileView: View {
    enum Kind { case week, wide, half, line }

    var tile: BacktapeTile
    var kind: Kind
    var note: BacktapeNote?
    var waiting: Bool
    var lit: Bool
    /// A 10 minute row grows with the text size, so two lines of summary always fit inside it.
    @ScaledMetric(relativeTo: .footnote) private var lineHeight = 60.0
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth = 70.0

    private var height: CGFloat {
        switch kind {
        case .week: 184
        case .wide: 128
        case .half: 146
        case .line: max(60, lineHeight)
        }
    }

    private var lines: Int {
        switch kind {
        case .week: 6
        case .wide: 4
        case .half: 5
        case .line: 2
        }
    }

    private var radius: CGFloat { kind == .week ? 22 : kind == .line ? 16 : 20 }

    private var text: String? {
        if let note {
            let body = note.body.isEmpty ? note.title : note.body
            // The small models often begin a sentence without its capital.
            return body.isEmpty ? nil : body.prefix(1).uppercased() + body.dropFirst()
        }
        if waiting { return nil }
        let summary = tile.span.summary
        return summary.isEmpty ? tile.span.title : summary
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if kind == .line { line } else { card }
        }
        .frame(height: height)
        .background(alignment: .topTrailing) {
            BacktapeGlow(span: tile.span)
                .frame(width: kind == .line ? 130 : 200, height: kind == .line ? 80 : 100)
                .offset(x: 22, y: kind == .line ? -9 : -28)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(shape)
        // Where a zoom landed: the tiles lighten for a moment. No outline and no colour.
        .overlay { shape.fill(Color.primary.opacity(lit ? 0.09 : 0)).allowsHitTesting(false) }
        .contentShape(shape)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: kind == .week ? 12 : 8) {
            HStack(alignment: .center, spacing: 8) {
                label
                Spacer(minLength: 4)
                switch kind {
                case .week: BacktapeIconRow(span: tile.span, limit: 6, small: 18, large: 40)
                case .wide: BacktapeIconRow(span: tile.span, limit: 6, small: 16, large: 32)
                default: BacktapeIconRow(span: tile.span, limit: 4, small: 14, large: 26)
                }
            }
            .frame(height: kind == .week ? 40 : 30)
            summary
        }
        .padding(.horizontal, kind == .half ? 12 : 14)
        .padding(.vertical, kind == .half ? 10 : 12)
    }

    private var line: some View {
        HStack(spacing: 10) {
            Text(verbatim: tile.start.formatted(Date.FormatStyle().hour().minute().locale(AppLocalization.locale)))
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: timeWidth, alignment: .leading)
            summary
            BacktapeIconRow(span: tile.span, limit: 3, small: 24, large: 24)
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder private var label: some View {
        let locale = AppLocalization.locale
        switch tile.zoom {
        case .weeks:
            Text(verbatim: BacktapeLabels.week(tile.start)).font(.system(.title2, design: .rounded, weight: .bold))
        case .days:
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: tile.start.formatted(Date.FormatStyle().day().locale(locale)))
                    .font(.system(kind == .wide ? .title3 : .headline, design: .rounded, weight: .bold))
                Text(verbatim: tile.start.formatted(Date.FormatStyle().weekday(.abbreviated).locale(locale)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        default:
            Text(verbatim: tile.start.formatted(Date.FormatStyle().hour().locale(locale)))
                .font(.system(kind == .wide ? .title3 : .headline, design: .rounded, weight: .bold))
        }
    }

    /// The summary's place has its final size from the start, so nothing moves when the text comes.
    private var summary: some View {
        ZStack(alignment: .topLeading) {
            if let text {
                Text(verbatim: text)
                    .font(kind == .half ? .caption : .footnote)
                    .lineLimit(lines)
                    .multilineTextAlignment(.leading)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(0..<min(lines, 4), id: \.self) { index in
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 9)
                            .frame(maxWidth: index == min(lines, 4) - 1 ? 150 : .infinity, alignment: .leading)
                    }
                }
                .padding(.top, kind == .line ? 0 : 3)
                .transition(.opacity)
            }
        }
        // A row's words sit on its middle line, beside the time and the icons; a card's start at its top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: kind == .line ? .leading : .topLeading)
        .animation(.easeOut(duration: 0.3), value: text)
    }
}

@MainActor
enum BacktapeLabels {
    static func week(_ start: Date) -> String {
        let last = (Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start)
        return (start..<last).formatted(Date.IntervalFormatStyle().month(.abbreviated).day().locale(AppLocalization.locale))
    }

    static func day(_ start: Date) -> String {
        start.formatted(Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().locale(AppLocalization.locale))
    }

    static func name(_ tile: BacktapeTile) -> String {
        let locale = AppLocalization.locale
        switch tile.zoom {
        case .weeks: return week(tile.start)
        case .days: return tile.start.formatted(Date.FormatStyle().weekday(.wide).month(.abbreviated).day().locale(locale))
        case .hours: return tile.start.formatted(Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().hour().locale(locale))
        case .all: return tile.start.formatted(Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().hour().minute().locale(locale))
        }
    }
}

// MARK: Zoom bar

/// The one glass slider: Weeks, Days, Hours, All. A tap or a slide across it moves the zoom.
struct BacktapeZoomBar: View {
    var zoom: BacktapeZoom
    var pick: (BacktapeZoom) -> Void
    @Namespace private var space
    private let order: [BacktapeZoom] = [.weeks, .days, .hours, .all]
    private let width: CGFloat = 292

    var body: some View {
        HStack(spacing: 0) {
            ForEach(order) { item in
                Text(LocalizedStringKey(item.title))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(item == zoom ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background {
                        // A plain fill, not glass: no glass on glass.
                        if item == zoom {
                            Capsule().fill(Color.primary.opacity(0.1)).matchedGeometryEffect(id: "thumb", in: space)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { pick(item) }
                    .accessibilityAddTraits(item == zoom ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .frame(width: width)
        .glassSurface(in: Capsule())
        .gesture(
            DragGesture(minimumDistance: 10).onChanged { value in
                let index = min(order.count - 1, max(0, Int(value.location.x / (width / CGFloat(order.count)))))
                if order[index] != zoom { pick(order[index]) }
            }
        )
    }
}

// MARK: Library

/// Where the tiles are on screen, kept outside the view's state so scrolling redraws nothing.
final class BacktapeFrames {
    var frames: [String: CGRect] = [:]
}

struct BacktapeLibrary: View {
    var layout: BacktapeLayout
    @ObservedObject var capture = HistoryCapture.shared
    @ObservedObject var lock = HistoryLock.shared
    @State private var notes = BacktapeNotes.shared
    @State private var zoom: BacktapeZoom = .hours
    @State private var inward = true
    @State private var point: UnitPoint = .center
    @State private var target: String?
    @State private var lit: Set<String> = []
    @State private var pinched = false
    @State private var frames = BacktapeFrames()
    @State private var size: CGSize = .zero
    @State private var asking: BacktapeTile?
    @State private var pin = ""
    @State private var wrong = false
    @State private var copied = 0
    @State private var forgotten = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                tape(zoom)
                    .id(zoom)
                    .transition(.asymmetric(
                        insertion: .scale(scale: inward ? 0.72 : 1.35, anchor: point).combined(with: .opacity),
                        removal: .scale(scale: inward ? 1.6 : 0.6, anchor: point).combined(with: .opacity)
                    ))
            }
            .coordinateSpace(.named("backtape"))
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        guard !pinched else { return }
                        if value.magnification > 1.25, let finer = zoom.finer {
                            pinched = true
                            go(finer, at: value.startLocation)
                        } else if value.magnification < 0.8, let coarser = zoom.coarser {
                            pinched = true
                            go(coarser, at: value.startLocation)
                        }
                    }
                    .onEnded { _ in pinched = false }
            )
            .onAppear { size = geometry.size }
            .onChange(of: geometry.size) { _, new in size = new }
        }
        .safeAreaInset(edge: .bottom) {
            BacktapeZoomBar(zoom: zoom) { go($0, at: nil) }
                .padding(.bottom, 8)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: zoom)
        .sensoryFeedback(.success, trigger: copied)
        .sensoryFeedback(.impact(weight: .heavy), trigger: forgotten)
        .alert(LocalizedStringKey(asking?.zoom.forget ?? "Forget"), isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            SecureField("PIN", text: $pin).keyboardType(.numberPad)
            Button("Forget", role: .destructive) {
                let tile = asking
                asking = nil
                if lock.unlock(pin: pin), let tile {
                    Task { await forget(tile) }
                } else {
                    wrong = true
                }
                pin = ""
            }
            Button("Cancel", role: .cancel) { pin = "" }
        } message: {
            Text("Enter the Screen History PIN to forget this. It cannot be brought back.")
        }
        .alert("Wrong PIN", isPresented: $wrong) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: One zoom's list

    private func tape(_ zoom: BacktapeZoom) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(layout.groups[zoom] ?? []) { group in
                        if let start = group.start {
                            Text(verbatim: zoom == .days ? BacktapeLabels.week(start) : BacktapeLabels.day(start))
                                .font(.system(.title3, design: .rounded, weight: .bold))
                                .padding(.top, 14)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 2)
                        }
                        ForEach(group.rows) { row in
                            switch row {
                            case .week(let tile): cell(tile, .week)
                            case .wide(let tile): cell(tile, .wide)
                            case .line(let tile): cell(tile, .line)
                            case .pair(let first, let second):
                                HStack(spacing: 6) {
                                    cell(first, .half)
                                    cell(second, .half)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .onAppear {
                if let target { proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: point.y)) }
            }
        }
    }

    private func cell(_ tile: BacktapeTile, _ kind: BacktapeTileView.Kind) -> some View {
        BacktapeTileView(tile: tile, kind: kind, note: notes.notes[tile.id], waiting: notes.waiting(tile), lit: lit.contains(tile.id))
            .id(tile.id)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("backtape")) } action: { frames.frames[tile.id] = $0 }
            .onAppear { notes.appeared(tile) }
            .onDisappear {
                notes.disappeared(tile)
                frames.frames[tile.id] = nil
            }
            // A tap opens a week, a day or an hour, the same as pinching in on it.
            .onTapGesture {
                if let finer = tile.zoom.finer { go(finer, from: tile) }
            }
            // Raw screen text is only ever copied, never shown, and forgetting works on exactly what
            // the tile covers at this zoom.
            .contextMenu {
                Section(BacktapeLabels.name(tile)) {
                    Button { Task { await copy(tile) } } label: { Label("Copy Screen Text", systemImage: "doc.on.doc") }
                    Button(role: .destructive) { ask(tile) } label: { Label(LocalizedStringKey(tile.zoom.forget), systemImage: "trash") }
                }
                Section {
                    ForEach(tile.span.apps.prefix(6), id: \.self) { app in
                        Text(verbatim: BacktapeApps.name(app))
                    }
                }
            }
    }

    // MARK: Zooming

    /// Moves to `next`, keeping the place: zooming in, the tile under the fingers opens and its
    /// latest part lands where it was; zooming out, the parts close into the one tile that holds
    /// them. The tiles that came out of the move are outlined for a moment.
    private func go(_ next: BacktapeZoom, from tile: BacktapeTile? = nil, at location: CGPoint? = nil) {
        guard next != zoom else { return }
        let height = max(1, size.height)
        let centre = CGPoint(x: size.width / 2, y: height / 2)
        let spot = location ?? tile.flatMap { frames.frames[$0.id] }.map { CGPoint(x: $0.midX, y: $0.midY) } ?? centre
        let anchor = tile ?? nearest(spot)
        let goingIn = next.rawValue < zoom.rawValue
        let tiles = layout.tiles[next] ?? []
        var marked: [BacktapeTile] = []
        var landing: BacktapeTile?
        if let anchor {
            if goingIn {
                marked = tiles.filter { $0.start >= anchor.start && $0.start < anchor.end }
                landing = marked.first
            } else {
                landing = tiles.first { $0.start <= anchor.start && anchor.start < $0.end }
                marked = landing.map { [$0] } ?? []
            }
        }
        inward = goingIn
        point = UnitPoint(x: min(0.9, max(0.1, spot.x / max(1, size.width))), y: min(0.8, max(0.2, spot.y / height)))
        target = landing?.id
        notes.focus = landing?.start
        withAnimation(.spring(duration: 0.46, bounce: 0.12)) {
            zoom = next
            lit = Set(marked.map(\.id))
        }
        Task {
            try? await Task.sleep(for: .milliseconds(1100))
            withAnimation(.easeOut(duration: 0.5)) { lit = [] }
        }
    }

    private func nearest(_ spot: CGPoint) -> BacktapeTile? {
        let tiles = layout.tiles[zoom] ?? []
        var best: (id: String, distance: CGFloat)?
        for (id, frame) in frames.frames where id.hasPrefix("\(zoom.rawValue)-") {
            let dx = max(frame.minX - spot.x, 0, spot.x - frame.maxX)
            let dy = max(frame.minY - spot.y, 0, spot.y - frame.maxY)
            let distance = dx + dy
            if best == nil || distance < best!.distance { best = (id, distance) }
        }
        guard let best else { return tiles.first }
        return tiles.first { $0.id == best.id } ?? tiles.first
    }

    // MARK: Copy and forget

    private func copy(_ tile: BacktapeTile) async {
        let entries = await HistoryStore.shared.entries(from: tile.start, to: tile.end)
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLocalization.locale)
        UIPasteboard.general.string = entries.map { entry in
            "[\(entry.at.formatted(style))] \(HistoryNames.app(entry.app)) \(entry.title)\n\(entry.text)"
        }
        .joined(separator: "\n\n")
        copied += 1
    }

    /// Forgetting is confirmed with Face ID or Touch ID, or with Poki's PIN where those are off.
    private func ask(_ tile: BacktapeTile) {
        if lock.usesBiometrics {
            Task {
                if await lock.confirm(AppLocalization.bundle.localizedString(forKey: tile.zoom.forget, value: tile.zoom.forget, table: nil)) { await forget(tile) }
            }
        } else {
            pin = ""
            asking = tile
        }
    }

    private func forget(_ tile: BacktapeTile) async {
        await capture.delete(from: tile.start, to: tile.end)
        forgotten += 1
    }
}
