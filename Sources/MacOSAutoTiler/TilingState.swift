import CoreGraphics

/// Which windows are tiled where, in which order, and which ones the user chose to float.
struct TilingState {
    private(set) var layouts: [SpaceKey: SpaceLayout] = [:]
    private(set) var floatingWindowIDs: Set<CGWindowID> = []

    func layout(for space: SpaceKey) -> SpaceLayout {
        layouts[space] ?? SpaceLayout()
    }

    func space(of windowID: CGWindowID) -> SpaceKey? {
        layouts.first { $0.value.windowIDs.contains(windowID) }?.key
    }

    func isFloating(_ window: ObservedWindow) -> Bool {
        !window.isTilable || floatingWindowIDs.contains(window.windowID)
    }

    /// Brings the layouts in line with the windows in the snapshot.
    ///
    /// - A window in a visible layout stays there as long as it is tiled and on screen. Moving it to another
    ///   visible layout is the job of a drop: right after one, the snapshot still reports the window where the
    ///   user released it, which may be a different display than the slot it was dropped into.
    /// - A window in a hidden layout stays there until it dies or shows up on screen (e.g. moved in Mission
    ///   Control), in which case it joins the space it is on.
    /// - Windows in no layout are appended to the space they are on, front to back.
    mutating func reconcile(with snapshot: WindowSnapshot, liveWindowIDs: Set<CGWindowID>) {
        precondition(snapshot.isComplete, "reconcile requires a snapshot with fully resolved spaces")
        floatingWindowIDs.formIntersection(liveWindowIDs)

        let tiled = snapshot.windows.filter { !isFloating($0) }
        let tiledIDs = Set(tiled.map(\.windowID))
        let visibleSpaces = Set(snapshot.visibleSpaces.values)

        for space in Array(layouts.keys) {
            layouts[space]!.windowIDs.removeAll { windowID in
                if visibleSpaces.contains(space) {
                    return !tiledIDs.contains(windowID)
                }
                return !liveWindowIDs.contains(windowID) || tiledIDs.contains(windowID)
            }
        }
        for window in tiled where space(of: window.windowID) == nil {
            layouts[window.space, default: SpaceLayout()].windowIDs.append(window.windowID)
        }
    }

    mutating func remove(_ windowID: CGWindowID) {
        guard let space = space(of: windowID) else { return }
        layouts[space]!.windowIDs.removeAll { $0 == windowID }
    }

    /// Moves the window into `space` at `slot`, clamped to the valid range.
    mutating func insert(_ windowID: CGWindowID, into space: SpaceKey, at slot: Int) {
        remove(windowID)
        var layout = self.layout(for: space)
        layout.windowIDs.insert(windowID, at: slot.clamped(to: 0...layout.windowIDs.count))
        layouts[space] = layout
    }

    mutating func setFloating(_ windowID: CGWindowID, _ floating: Bool) {
        if floating {
            floatingWindowIDs.insert(windowID)
            remove(windowID)
        } else {
            floatingWindowIDs.remove(windowID)
        }
    }

    mutating func updateLayout(for space: SpaceKey, _ update: (inout SpaceLayout) -> Void) {
        var layout = self.layout(for: space)
        update(&layout)
        layouts[space] = layout
    }
}
