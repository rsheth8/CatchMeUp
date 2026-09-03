import SwiftUI

// MARK: - Graph model

struct BrainGraphNode: Identifiable, Hashable {
    let id: String
    let label: String
    let definition: String
    let weight: Int
    let recordingIDs: [UUID]
    let materialIDs: [UUID]
    let position: CGPoint
}

struct BrainGraphEdge: Identifiable, Hashable {
    var id: String { source < target ? "\(source)|\(target)" : "\(target)|\(source)" }
    let source: String
    let target: String
    let weight: Int
}

struct BrainGraph: Hashable {
    let nodes: [BrainGraphNode]
    let edges: [BrainGraphEdge]

    static func build(from recordings: [Recording], materials: [SupplementalMaterial] = []) -> BrainGraph {
        struct Candidate {
            var label: String
            var definition: String
            var recordings: Set<UUID> = []
            var materials: Set<UUID> = []
        }

        var candidates: [String: Candidate] = [:]
        var conceptsByRecording: [[String]] = []

        for recording in recordings where recording.recap != nil {
            guard let recap = recording.recap else { continue }
            var episode: [(String, String)] = []

            for term in recap.terms ?? [] {
                let label = term.term.trimmingCharacters(in: .whitespacesAndNewlines)
                guard label.count >= 2, label.count <= 42 else { continue }
                episode.append((label, term.definition))
            }

            // Note headings fill in useful structure when a recap has few
            // explicit glossary terms (especially meeting brains).
            if episode.count < 6 {
                for note in (recap.detailedNotes ?? []).prefix(8 - episode.count) {
                    let label = note.heading.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard label.count >= 3, label.count <= 42 else { continue }
                    episode.append((label, note.content))
                }
            }

            var seen: Set<String> = []
            var episodeIDs: [String] = []
            for (label, definition) in episode.prefix(12) {
                let id = normalized(label)
                guard !id.isEmpty, seen.insert(id).inserted else { continue }
                var candidate = candidates[id] ?? Candidate(label: label, definition: definition)
                candidate.recordings.insert(recording.id)
                if candidate.definition.isEmpty { candidate.definition = definition }
                candidates[id] = candidate
                episodeIDs.append(id)
            }
            if !episodeIDs.isEmpty { conceptsByRecording.append(episodeIDs) }
        }

        for material in materials where material.state.isReady {
            var episodeIDs: [String] = []
            for concept in material.concepts.prefix(12) {
                let label = concept.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard label.count >= 3, label.count <= 42 else { continue }
                let id = normalized(label)
                guard !id.isEmpty else { continue }
                let definition = concept.pageNumbers.first.flatMap { number in
                    material.pages.first { $0.number == number }?.text
                }.map { String($0.prefix(280)) } ?? ""
                var candidate = candidates[id] ?? Candidate(label: label, definition: definition)
                candidate.materials.insert(material.id)
                if candidate.definition.isEmpty { candidate.definition = definition }
                candidates[id] = candidate
                episodeIDs.append(id)
            }
            if !episodeIDs.isEmpty { conceptsByRecording.append(episodeIDs) }
        }

        let rankedIDs = candidates.keys.sorted { lhs, rhs in
            let left = (candidates[lhs]?.recordings.count ?? 0) + (candidates[lhs]?.materials.count ?? 0)
            let right = (candidates[rhs]?.recordings.count ?? 0) + (candidates[rhs]?.materials.count ?? 0)
            if left != right { return left > right }
            return lhs < rhs
        }
        let selectedIDs = Array(rankedIDs.prefix(16))
        let selected = Set(selectedIDs)

        var edgeWeights: [String: Int] = [:]
        for episode in conceptsByRecording {
            let ids = episode.filter { selected.contains($0) }
            guard ids.count > 1 else { continue }
            for i in 0..<(ids.count - 1) {
                for j in (i + 1)..<ids.count {
                    let pair = [ids[i], ids[j]].sorted()
                    edgeWeights["\(pair[0])|\(pair[1])", default: 0] += 1
                }
            }
        }

        let edges = edgeWeights
            .map { key, weight -> BrainGraphEdge in
                let pair = key.split(separator: "|", maxSplits: 1).map(String.init)
                return BrainGraphEdge(source: pair[0], target: pair[1], weight: weight)
            }
            .sorted {
                if $0.weight != $1.weight { return $0.weight > $1.weight }
                return $0.id < $1.id
            }
            .prefix(34)

        let positions = layout(ids: selectedIDs, edges: Array(edges))
        let nodes = selectedIDs.compactMap { id -> BrainGraphNode? in
            guard let candidate = candidates[id] else { return nil }
            return BrainGraphNode(
                id: id,
                label: candidate.label,
                definition: candidate.definition,
                weight: candidate.recordings.count + candidate.materials.count,
                recordingIDs: candidate.recordings.sorted { $0.uuidString < $1.uuidString },
                materialIDs: candidate.materials.sorted { $0.uuidString < $1.uuidString },
                position: positions[id] ?? .zero
            )
        }

        return BrainGraph(nodes: nodes, edges: Array(edges))
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    /// A small deterministic force layout. It has the organic feel of a
    /// knowledge graph but never jumps around between launches.
    private static func layout(ids: [String], edges: [BrainGraphEdge]) -> [String: CGPoint] {
        guard !ids.isEmpty else { return [:] }
        let goldenAngle = Double.pi * (3 - sqrt(5.0))
        var points: [String: CGPoint] = [:]
        for (index, id) in ids.enumerated() {
            let radius = 0.20 + 0.055 * Double(index)
            let angle = goldenAngle * Double(index)
            points[id] = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }

        for _ in 0..<90 {
            var delta = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGPoint.zero) })

            for i in ids.indices {
                for j in ids.index(after: i)..<ids.endIndex {
                    let a = ids[i], b = ids[j]
                    guard let pa = points[a], let pb = points[b] else { continue }
                    var dx = pa.x - pb.x, dy = pa.y - pb.y
                    let distanceSquared = max(0.025, dx * dx + dy * dy)
                    let scale = 0.0032 / distanceSquared
                    dx *= scale; dy *= scale
                    delta[a] = CGPoint(x: (delta[a]?.x ?? 0) + dx, y: (delta[a]?.y ?? 0) + dy)
                    delta[b] = CGPoint(x: (delta[b]?.x ?? 0) - dx, y: (delta[b]?.y ?? 0) - dy)
                }
            }

            for edge in edges {
                guard let a = points[edge.source], let b = points[edge.target] else { continue }
                let dx = b.x - a.x, dy = b.y - a.y
                let distance = max(0.01, hypot(dx, dy))
                let pull = (distance - 0.42) * (0.010 + 0.002 * CGFloat(edge.weight))
                let fx = dx / distance * pull, fy = dy / distance * pull
                delta[edge.source] = CGPoint(x: (delta[edge.source]?.x ?? 0) + fx,
                                             y: (delta[edge.source]?.y ?? 0) + fy)
                delta[edge.target] = CGPoint(x: (delta[edge.target]?.x ?? 0) - fx,
                                             y: (delta[edge.target]?.y ?? 0) - fy)
            }

            for id in ids {
                guard let point = points[id], let movement = delta[id] else { continue }
                let x = max(-0.84, min(0.84, point.x + movement.x - point.x * 0.012))
                let y = max(-0.82, min(0.82, point.y + movement.y - point.y * 0.012))
                points[id] = CGPoint(x: x, y: y)
            }
        }
        return points
    }
}

// MARK: - Brain detail preview

struct MiniBrainGraph: View {
    let graph: BrainGraph
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard !graph.nodes.isEmpty else {
                let rect = CGRect(x: size.width / 2 - 12, y: size.height / 2 - 12, width: 24, height: 24)
                context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.22)))
                return
            }
            let points = positions(in: size)
            for edge in graph.edges.prefix(18) {
                guard let a = points[edge.source], let b = points[edge.target] else { continue }
                var path = Path(); path.move(to: a); path.addLine(to: b)
                context.stroke(path, with: .color(tint.opacity(0.20)), lineWidth: 1)
            }
            for (index, node) in graph.nodes.prefix(10).enumerated() {
                guard let point = points[node.id] else { continue }
                let diameter: CGFloat = index == 0 ? 12 : 7
                let rect = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                                  width: diameter, height: diameter)
                context.fill(Path(ellipseIn: rect), with: .color(index == 0 ? tint : tint.opacity(0.60)))
            }
        }
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func positions(in size: CGSize) -> [String: CGPoint] {
        Dictionary(uniqueKeysWithValues: graph.nodes.map { node in
            (node.id, CGPoint(x: (node.position.x + 1) * size.width / 2,
                              y: (node.position.y + 1) * size.height / 2))
        })
    }
}

// MARK: - Full graph

struct BrainGraphScreen: View {
    let brain: Brain
    let recordings: [Recording]

    @Environment(\.dismiss) private var dismiss
    @Environment(MaterialStore.self) private var materialStore

    var body: some View {
        NavigationStack {
            BrainGraphView(brain: brain, recordings: recordings,
                           materials: materialStore.materials(inBrain: brain.id))
                .navigationTitle("Neural map")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: UUID.self) { RecapDetailView(recordingID: $0) }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

struct BrainGraphView: View {
    let brain: Brain
    let recordings: [Recording]
    let materials: [SupplementalMaterial]
    private let graph: BrainGraph

    @State private var selectedID: String?
    @State private var resetToken = 0
    @State private var selectedMaterial: SupplementalMaterial?

    init(brain: Brain, recordings: [Recording], materials: [SupplementalMaterial] = []) {
        self.brain = brain
        self.recordings = recordings
        self.materials = materials
        self.graph = BrainGraph.build(from: recordings, materials: materials)
    }

    var body: some View {
        let graph = graph
        VStack(spacing: 10) {
            mapToolbar(graph)

            ZStack(alignment: .bottom) {
                graphSurface(graph)

                if let node = graph.nodes.first(where: { $0.id == selectedID }) {
                    conceptInspector(node, graph: graph)
                        .padding(12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Label("Drag to explore · pinch to zoom · tap to focus",
                          systemImage: "hand.draw.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay { Capsule().strokeBorder(Color.hairline) }
                        .padding(.bottom, 12)
                }
            }
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.top, 8)
        .padding(.bottom, Metric.gutter)
        .background(AmbientBackground(tint: brain.mode.accent))
        .sheet(item: $selectedMaterial) { material in
            MaterialDetailView(materialID: material.id, tint: brain.mode.accent)
        }
    }

    private func mapToolbar(_ graph: BrainGraph) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                Label("\(graph.nodes.count)", systemImage: "circle.hexagongrid.fill")
                Label("\(graph.edges.count)", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(graph.nodes.count) concepts, \(graph.edges.count) connections")

            Spacer()

            Menu {
                ForEach(graph.nodes.sorted { $0.label < $1.label }) { node in
                    Button(node.label) {
                        Haptics.tap()
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                            selectedID = node.id
                        }
                    }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Find a concept")

            Button(action: resetMap) {
                Image(systemName: "scope")
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Recenter map")
        }
    }

    private func graphSurface(_ graph: BrainGraph) -> some View {
        graphCanvas(graph)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RadialGradient(colors: [brain.mode.accent.opacity(0.16), .clear],
                                   center: .topLeading, startRadius: 0, endRadius: 380)
                    RadialGradient(colors: [Color.mint.opacity(0.10), .clear],
                                   center: .bottomTrailing, startRadius: 0, endRadius: 340)
                }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.18), brain.mode.accent.opacity(0.15)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }
            .shadow(color: brain.mode.accent.opacity(0.08), radius: 24, y: 12)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func graphCanvas(_ graph: BrainGraph) -> some View {
        InteractiveBrainGraphCanvas(
            graph: graph,
            mode: brain.mode,
            selectedID: $selectedID,
            resetToken: resetToken
        )
    }

    private func conceptInspector(_ node: BrainGraphNode, graph: BrainGraph) -> some View {
        let related = graph.edges
            .filter { $0.source == node.id || $0.target == node.id }
            .sorted { $0.weight > $1.weight }
            .prefix(4)
            .compactMap { edge in
                graph.nodes.first { $0.id == (edge.source == node.id ? edge.target : edge.source) }
            }
        let sources = recordings.filter { node.recordingIDs.contains($0.id) }
        let materialSources = materials.filter { node.materialIDs.contains($0.id) }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(nodeTint(node).gradient)
                    .frame(width: 30, height: 30)
                    .overlay { Circle().strokeBorder(.white.opacity(0.45)) }
                    .shadow(color: nodeTint(node).opacity(0.35), radius: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(node.label).font(.headline)
                    Text("\(node.weight) supporting source\(node.weight == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.quick) { selectedID = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
            }

            if !node.definition.isEmpty {
                Text(node.definition)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if !related.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(related) { neighbor in
                            Button(neighbor.label) {
                                Haptics.tap()
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                    selectedID = neighbor.id
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(nodeTint(neighbor))
                        }
                    }
                }
            }

            ForEach(sources.prefix(2)) { recording in
                NavigationLink(value: recording.id) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.fill").foregroundStyle(nodeTint(node))
                        Text(recording.displayTitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }

            ForEach(materialSources.prefix(2)) { material in
                Button {
                    selectedMaterial = material
                    Haptics.tap()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: material.kind.symbol).foregroundStyle(nodeTint(node))
                        Text(material.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(nodeTint(node).opacity(0.28))
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private func resetMap() {
        Haptics.tap()
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
            resetToken += 1
            selectedID = nil
        }
    }

    private func nodeTint(_ node: BrainGraphNode) -> Color {
        let checksum = nodeChecksum(node)
        switch checksum % 4 {
        case 0: return .mint
        case 1: return brain.mode.accentLight
        default: return brain.mode.accent
        }
    }

    private func nodeChecksum(_ node: BrainGraphNode) -> Int {
        node.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    }

}

// MARK: - GPU-backed interaction surface

/// The complete graph is drawn in one Canvas and hit-tested by one gesture.
/// That avoids a stack of competing node/canvas recognizers and keeps direct
/// manipulation on the lightest possible rendering path.
private struct InteractiveBrainGraphCanvas: View {
    let graph: BrainGraph
    let mode: Mode
    @Binding var selectedID: String?
    let resetToken: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var nodeOffsets: [String: CGSize] = [:]
    @State private var dragTarget: DragTarget?
    @State private var dragOrigin: CGSize = .zero
    @State private var zoomOrigin: CGFloat?

    private enum DragTarget: Equatable {
        case node(String)
        case canvas
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(
                minimumInterval: 1 / 60,
                paused: reduceMotion || selectedID == nil || dragTarget != nil
            )) { timeline in
                Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
                    let points = renderedPositions(in: size)
                    drawDotField(context: &context, size: size)
                    drawEdges(context: &context, points: points,
                              phase: timeline.date.timeIntervalSinceReferenceDate)
                    drawNodes(context: &context, points: points,
                              phase: timeline.date.timeIntervalSinceReferenceDate)
                    drawLabels(context: &context, points: points, size: size)
                } symbols: {
                    ForEach(graph.nodes) { node in
                        GraphNodeLabelSymbol(lines: labelLines(node.label), tint: nodeTint(node))
                            .tag(node.id)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: geometry.size))
            .simultaneousGesture(zoomGesture)
        }
        .onChange(of: resetToken) { _, _ in
            withAnimation(.spring(response: 0.48, dampingFraction: 0.86)) {
                scale = 1
                pan = .zero
                nodeOffsets = [:]
            }
        }
        .accessibilityLabel("Interactive neural map")
        .accessibilityHint("Use the concept search above to focus a concept")
    }

    // MARK: Gestures

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                var target = dragTarget
                if target == nil {
                    let points = renderedPositions(in: size)
                    if let node = nearestNode(to: value.startLocation, points: points) {
                        target = .node(node.id)
                        dragOrigin = nodeOffsets[node.id] ?? .zero
                    } else {
                        target = .canvas
                        dragOrigin = pan
                    }
                    dragTarget = target
                }

                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    switch target {
                    case .node(let id):
                        nodeOffsets[id] = CGSize(
                            width: dragOrigin.width + value.translation.width / scale,
                            height: dragOrigin.height + value.translation.height / scale
                        )
                    case .canvas:
                        pan = CGSize(width: dragOrigin.width + value.translation.width,
                                     height: dragOrigin.height + value.translation.height)
                    case nil:
                        break
                    }
                }
            }
            .onEnded { value in
                let distance = hypot(value.translation.width, value.translation.height)
                if distance < 7 {
                    switch dragTarget {
                    case .node(let id):
                        Haptics.tap()
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            selectedID = selectedID == id ? nil : id
                        }
                    case .canvas:
                        withAnimation(.quick) { selectedID = nil }
                    case nil:
                        break
                    }
                }
                dragTarget = nil
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomOrigin == nil { zoomOrigin = scale }
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    scale = min(2.6, max(0.72, (zoomOrigin ?? scale) * value.magnification))
                }
            }
            .onEnded { _ in zoomOrigin = nil }
    }

    private func nearestNode(to point: CGPoint,
                             points: [String: CGPoint]) -> BrainGraphNode? {
        graph.nodes
            .compactMap { node -> (BrainGraphNode, CGFloat)? in
                guard let p = points[node.id] else { return nil }
                return (node, hypot(point.x - p.x, point.y - p.y))
            }
            .filter { $0.1 <= 46 }
            .min { $0.1 < $1.1 }?
            .0
    }

    // MARK: Drawing

    private func drawEdges(context: inout GraphicsContext,
                           points: [String: CGPoint],
                           phase: TimeInterval) {
        for edge in graph.edges {
            guard let a = points[edge.source], let b = points[edge.target] else { continue }
            let active = selectedID == nil || selectedID == edge.source || selectedID == edge.target
            var path = Path(); path.move(to: a); path.addLine(to: b)

            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: [mode.accent.opacity(0.05),
                                      mode.accent.opacity(active ? 0.42 : 0.055),
                                      Color.mint.opacity(active ? 0.28 : 0.025)]),
                    startPoint: a,
                    endPoint: b
                ),
                style: StrokeStyle(lineWidth: active ? min(2.2, 0.6 + CGFloat(edge.weight) * 0.34) : 0.45,
                                   lineCap: .round)
            )

            if active, selectedID != nil, !reduceMotion, dragTarget == nil {
                context.stroke(
                    path,
                    with: .color(Color.mint.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round,
                                       dash: [1, 13], dashPhase: -CGFloat(phase * 24))
                )
            }
        }
    }

    private func drawNodes(context: inout GraphicsContext,
                           points: [String: CGPoint],
                           phase: TimeInterval) {
        for node in graph.nodes {
            guard let point = points[node.id] else { continue }
            let selected = node.id == selectedID
            let connected = selectedID == nil || selected || graph.edges.contains {
                ($0.source == selectedID && $0.target == node.id) ||
                ($0.target == selectedID && $0.source == node.id)
            }
            let degree = graph.edges.lazy.filter { $0.source == node.id || $0.target == node.id }.count
            let diameter = min(42, 21 + CGFloat(degree) * 1.7 + CGFloat(node.weight - 1) * 3)
            let tint = nodeTint(node)
            let opacity = connected ? 1.0 : 0.25
            let pulse = selected && !reduceMotion && dragTarget == nil
                ? 1 + 0.045 * sin(phase * 3.2) : 1

            let auraDiameter = (diameter + 18) * pulse
            let aura = CGRect(x: point.x - auraDiameter / 2, y: point.y - auraDiameter / 2,
                              width: auraDiameter, height: auraDiameter)
            context.fill(Path(ellipseIn: aura), with: .color(tint.opacity(0.10 * opacity)))
            context.stroke(Path(ellipseIn: aura),
                           with: .color(tint.opacity((selected ? 0.44 : 0.14) * opacity)),
                           lineWidth: 1)

            let orbDiameter = diameter * (selected ? 1.10 : 1)
            let orb = CGRect(x: point.x - orbDiameter / 2, y: point.y - orbDiameter / 2,
                             width: orbDiameter, height: orbDiameter)
            context.fill(
                Path(ellipseIn: orb),
                with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.92 * opacity),
                                      tint.opacity(0.92 * opacity),
                                      tint.opacity(0.56 * opacity)]),
                    startPoint: CGPoint(x: orb.minX, y: orb.minY),
                    endPoint: CGPoint(x: orb.maxX, y: orb.maxY)
                )
            )
            context.stroke(Path(ellipseIn: orb),
                           with: .color(.white.opacity(0.42 * opacity)), lineWidth: 0.8)
        }
    }

    private func drawLabels(context: inout GraphicsContext,
                            points: [String: CGPoint],
                            size: CGSize) {
        for node in graph.nodes {
            guard let point = points[node.id],
                  let symbol = context.resolveSymbol(id: node.id) else { continue }
            let degree = graph.edges.lazy.filter { $0.source == node.id || $0.target == node.id }.count
            let diameter = min(42, 21 + CGFloat(degree) * 1.7 + CGFloat(node.weight - 1) * 3)
            let vertical = diameter / 2 + symbol.size.height / 2 + 5
            let horizontal = diameter / 2 + symbol.size.width / 2 + 5
            let diagonal: CGFloat = 0.70
            let rawCenter: CGPoint
            switch nodeChecksum(node) % 8 {
            case 0: rawCenter = CGPoint(x: point.x, y: point.y - vertical)
            case 1: rawCenter = CGPoint(x: point.x + horizontal * diagonal, y: point.y - vertical * diagonal)
            case 2: rawCenter = CGPoint(x: point.x + horizontal, y: point.y)
            case 3: rawCenter = CGPoint(x: point.x + horizontal * diagonal, y: point.y + vertical * diagonal)
            case 4: rawCenter = CGPoint(x: point.x, y: point.y + vertical)
            case 5: rawCenter = CGPoint(x: point.x - horizontal * diagonal, y: point.y + vertical * diagonal)
            case 6: rawCenter = CGPoint(x: point.x - horizontal, y: point.y)
            default: rawCenter = CGPoint(x: point.x - horizontal * diagonal, y: point.y - vertical * diagonal)
            }
            let center = CGPoint(
                x: min(size.width - symbol.size.width / 2 - 5,
                       max(symbol.size.width / 2 + 5, rawCenter.x)),
                y: min(size.height - symbol.size.height / 2 - 5,
                       max(symbol.size.height / 2 + 5, rawCenter.y))
            )
            let rect = labelRect(center: center, size: symbol.size)

            let connected = selectedID == nil || selectedID == node.id || graph.edges.contains {
                ($0.source == selectedID && $0.target == node.id) ||
                ($0.target == selectedID && $0.source == node.id)
            }
            var labelContext = context
            labelContext.opacity = connected ? 1 : 0.25
            labelContext.draw(symbol, at: center)

            if node.id == selectedID {
                context.stroke(Path(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerRadius: rect.height / 2 + 2),
                               with: .color(nodeTint(node).opacity(0.55)), lineWidth: 1)
            }
        }
    }

    private func labelRect(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
               width: size.width, height: size.height)
    }

    private func labelLines(_ label: String) -> [String] {
        guard label.count > 15 else { return [label] }
        let words = label.split(separator: " ").map(String.init)
        guard words.count > 1 else { return [String(label.prefix(17)) + "…"] }
        var first = ""
        var index = 0
        while index < words.count {
            let candidate = first.isEmpty ? words[index] : "\(first) \(words[index])"
            guard candidate.count <= 15 || first.isEmpty else { break }
            first = candidate
            index += 1
        }
        let remaining = words.dropFirst(index).joined(separator: " ")
        let second = remaining.count > 18 ? String(remaining.prefix(17)) + "…" : remaining
        return second.isEmpty ? [first] : [first, second]
    }

    private func drawDotField(context: inout GraphicsContext, size: CGSize) {
        let step: CGFloat = 32
        for x in stride(from: step / 2, through: size.width, by: step) {
            for y in stride(from: step / 2, through: size.height, by: step) {
                let dot = CGRect(x: x - 0.65, y: y - 0.65, width: 1.3, height: 1.3)
                context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.042)))
            }
        }
    }

    // MARK: Geometry

    private func renderedPositions(in size: CGSize) -> [String: CGPoint] {
        let horizontalInset: CGFloat = 66
        let verticalInset: CGFloat = 64
        let width = max(1, size.width - horizontalInset * 2)
        let height = max(1, size.height - verticalInset * 2)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        return Dictionary(uniqueKeysWithValues: graph.nodes.map { node in
            let offset = nodeOffsets[node.id] ?? .zero
            let raw = CGPoint(x: horizontalInset + (node.position.x + 1) * width / 2 + offset.width,
                              y: verticalInset + (node.position.y + 1) * height / 2 + offset.height)
            return (node.id, CGPoint(
                x: center.x + (raw.x - center.x) * scale + pan.width,
                y: center.y + (raw.y - center.y) * scale + pan.height
            ))
        })
    }

    private func nodeTint(_ node: BrainGraphNode) -> Color {
        switch nodeChecksum(node) % 4 {
        case 0: return .mint
        case 1: return mode.accentLight
        default: return mode.accent
        }
    }

    private func nodeChecksum(_ node: BrainGraphNode) -> Int {
        node.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    }
}

private struct GraphNodeLabelSymbol: View {
    let lines: [String]
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
            }
        }
        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.cardBG.opacity(0.92), in: Capsule())
        .overlay { Capsule().strokeBorder(tint.opacity(0.20), lineWidth: 0.8) }
    }
}
