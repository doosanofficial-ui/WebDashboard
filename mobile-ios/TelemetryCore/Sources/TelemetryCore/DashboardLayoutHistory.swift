import Foundation

/// Rect-only commands keep unrelated configuration and neighboring edits intact.
public struct DashboardLayoutHistory: Equatable, Sendable {
    private struct RectChange: Equatable, Sendable {
        let widgetID: String
        let before: DashboardRect
        let after: DashboardRect
    }
    private struct Command: Equatable, Sendable {
        let profileID: String
        let pageID: String
        let orientation: DashboardOrientation
        let changes: [RectChange]
    }
    private var past: [Command] = []
    private var future: [Command] = []
    public init() {}

    private func matches(_ command: Command?, profile: DashboardProfile, undo: Bool) -> Bool {
        guard let command, profile.id == command.profileID,
              let page = profile.pages.first(where: { $0.id == command.pageID }),
              page.orientation == command.orientation else { return false }
        return command.changes.allSatisfy { change in
            page.widgets.first(where: { $0.id == change.widgetID })?.rect == (undo ? change.after : change.before)
        }
    }
    public func canUndo(in profile: DashboardProfile) -> Bool { matches(past.last, profile: profile, undo: true) }
    public func canRedo(in profile: DashboardProfile) -> Bool { matches(future.last, profile: profile, undo: false) }

    private mutating func record(_ command: Command) {
        past.append(command)
        if past.count > 50 { past.removeFirst(past.count - 50) }
        future.removeAll()
    }

    @discardableResult
    public mutating func commit(profile: inout DashboardProfile, expectedProfileID: String,
                                expectedPage: DashboardPage, widgetID: String, rect: DashboardRect) -> Bool {
        guard profile.id == expectedProfileID,
              profile.pages.first(where: { $0.id == expectedPage.id }) == expectedPage,
              let original = expectedPage.widgets.first(where: { $0.id == widgetID }), original.rect != rect,
              (try? profile.updateWidgetRect(pageID: expectedPage.id, widgetID: widgetID, rect: rect)) != nil else { return false }
        record(.init(profileID: profile.id, pageID: expectedPage.id, orientation: expectedPage.orientation,
                     changes: [.init(widgetID: widgetID, before: original.rect, after: rect)]))
        return true
    }

    /// Dashboard rects and the grid are both measured in cells, not screen points.
    @discardableResult
    public mutating func snap(profile: inout DashboardProfile, pageID: String, grid: Int = 1) -> Bool {
        guard grid > 0, let page = profile.pages.first(where: { $0.id == pageID }) else { return false }
        let changes: [RectChange] = page.widgets.compactMap { widget in
            let rect = widget.rect.snapped(to: grid)
            return rect == widget.rect ? nil : .init(widgetID: widget.id, before: widget.rect, after: rect)
        }
        guard !changes.isEmpty else { return false }
        profile.snapToGrid(pageID: pageID, grid: grid)
        record(.init(profileID: profile.id, pageID: pageID, orientation: page.orientation, changes: changes))
        return true
    }

    private func apply(_ command: Command, profile: inout DashboardProfile, undo: Bool) -> Bool {
        var updated = profile
        for change in command.changes {
            guard (try? updated.updateWidgetRect(pageID: command.pageID, widgetID: change.widgetID,
                rect: undo ? change.before : change.after)) != nil else { return false }
        }
        profile = updated
        return true
    }

    @discardableResult
    public mutating func undo(profile: inout DashboardProfile) -> Bool {
        guard canUndo(in: profile), let command = past.last,
              apply(command, profile: &profile, undo: true) else { return false }
        past.removeLast(); future.append(command)
        return true
    }
    @discardableResult
    public mutating func redo(profile: inout DashboardProfile) -> Bool {
        guard canRedo(in: profile), let command = future.last,
              apply(command, profile: &profile, undo: false) else { return false }
        future.removeLast(); past.append(command)
        return true
    }
}
