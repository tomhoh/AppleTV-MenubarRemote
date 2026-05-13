import SwiftUI
import AppleTVProtocol

/// Circular clickpad with tap-for-direction and drag-for-swipe gestures.
struct ClickpadView: View {
    @EnvironmentObject private var session: RemoteSession
    @State private var pressedRegion: Region?

    @State private var dragBaseline: CGPoint?
    @State private var totalDragDistance: CGFloat = 0
    @State private var pressStartTime: TimeInterval?
    private let swipeThreshold: CGFloat = 22   // pt of drag per arrow fire (smaller pad = shorter threshold)
    private let tapMaxTotal: CGFloat = 8       // total motion under this → tap
    private let longPressDuration: TimeInterval = 0.5   // held > this on centre → edit-apps mode

    private let diameter = RemoteTheme.clickpadDiameter
    private let innerDiameter = RemoteTheme.clickpadInnerDiameter

    var body: some View {
        ZStack {
            ringLayer
            quadrantHighlight
            selectButton
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged(handleDragChanged)
                .onEnded(handleDragEnded)
        )
    }

    // MARK: - Layers

    private var ringLayer: some View {
        Circle()
            .fill(RemoteTheme.clickpadRingMaterial)
            .overlay(
                Circle()
                    .stroke(RemoteTheme.clickpadInsetGradient,
                            lineWidth: RemoteTheme.clickpadBevelDepth)
            )
    }

    @ViewBuilder
    private var quadrantHighlight: some View {
        if let region = pressedRegion, region != .select {
            QuadrantWedge(region: region)
                .fill(Color.white.opacity(0.22))
                .frame(width: diameter, height: diameter)
                .blendMode(.plusLighter)
                .transition(.opacity)
        }
    }

    private var selectButton: some View {
        Circle()
            .fill(RemoteTheme.clickpadSelectMaterial)
            .overlay(
                Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .frame(width: innerDiameter, height: innerDiameter)
            .scaleEffect(pressedRegion == .select ? RemoteTheme.pressedScale : 1.0)
            .animation(RemoteTheme.pressAnimation, value: pressedRegion)
    }

    // MARK: - Drag → tap or swipe routing

    private func handleDragChanged(_ value: DragGesture.Value) {
        if dragBaseline == nil {
            dragBaseline = value.location
            totalDragDistance = 0
            pressStartTime = ProcessInfo.processInfo.systemUptime
            return
        }
        guard let baseline = dragBaseline else { return }

        let dx = value.location.x - baseline.x
        let dy = value.location.y - baseline.y
        let absX = abs(dx), absY = abs(dy)

        totalDragDistance = max(totalDragDistance,
                                hypot(value.translation.width,
                                      value.translation.height))

        guard max(absX, absY) >= swipeThreshold else { return }

        // For continuous swipe motion we use the protocol's swipe gesture
        // (which is what tvOS interprets as a flick), one per threshold step.
        let direction: SwipeDirection
        let region: Region
        if absX >= absY {
            if dx > 0 { direction = .right; region = .right }
            else      { direction = .left;  region = .left  }
        } else {
            if dy > 0 { direction = .down;  region = .down  }
            else      { direction = .up;    region = .up    }
        }
        session.dispatchSwipe(direction)
        flash(region)

        dragBaseline = value.location
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        let heldFor = pressStartTime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        defer {
            dragBaseline = nil
            totalDragDistance = 0
            pressStartTime = nil
        }
        guard totalDragDistance < tapMaxTotal else { return }

        // Held the centre for > longPressDuration without moving → edit-apps
        // mode (the Siri Remote's "long-press select to wiggle apps" gesture).
        if heldFor > longPressDuration, isInsideSelectArea(value.startLocation) {
            session.dispatchEditApps()
            flash(.select)
        } else {
            handleTap(at: value.startLocation)
        }
    }

    private func isInsideSelectArea(_ location: CGPoint) -> Bool {
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        let dx = location.x - center.x
        let dy = location.y - center.y
        return (dx * dx + dy * dy).squareRoot() <= innerDiameter / 2
    }

    // MARK: - Tap region detection

    private func handleTap(at location: CGPoint) {
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let innerRadius = innerDiameter / 2

        let region: Region
        let command: RemoteCommand
        if distance <= innerRadius {
            region = .select
            command = .select
        } else {
            let angle = atan2(dy, dx)
            switch angle {
            case (-Double.pi / 4)...(Double.pi / 4):       region = .right; command = .right
            case (Double.pi / 4)...(3 * Double.pi / 4):    region = .down;  command = .down
            case (-3 * Double.pi / 4)...(-Double.pi / 4):  region = .up;    command = .up
            default:                                       region = .left;  command = .left
            }
        }
        session.dispatch(command)
        flash(region)
    }

    private func flash(_ region: Region) {
        withAnimation(.easeOut(duration: 0.08)) {
            pressedRegion = region
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeOut(duration: 0.16)) {
                pressedRegion = nil
            }
        }
    }

    enum Region {
        case up, down, left, right, select
    }
}

// MARK: - Quadrant wedge shape

private struct QuadrantWedge: Shape {
    let region: ClickpadView.Region

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        let startAngle: Angle
        switch region {
        case .right:  startAngle = .degrees(-45)
        case .down:   startAngle = .degrees(45)
        case .left:   startAngle = .degrees(135)
        case .up:     startAngle = .degrees(-135)
        case .select: return Path()
        }
        let endAngle = startAngle + .degrees(90)

        var path = Path()
        path.move(to: center)
        path.addArc(center: center,
                    radius: radius,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    clockwise: false)
        path.closeSubpath()
        return path
    }
}
