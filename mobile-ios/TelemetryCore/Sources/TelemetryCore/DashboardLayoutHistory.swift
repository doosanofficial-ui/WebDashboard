import Foundation

/// Rect-only commands keep unrelated configuration and neighboring edits intact.
public struct DashboardLayoutHistory: Equatable, Sendable {
    private struct Command: Equatable, Sendable {
        let profileID: String
        let pageID: String
        let orientation: DashboardOrientation
        let widgetID: String
        let before: DashboardRect
        let after: DashboardRect
    }
    private var past: [Command] = []
    private var future: [Command] = []
    public init() {}

    private func matches(_ command: Command?, profile: DashboardProfile, undo: Bool) -> Bool {
        guard let command, profile.id == command.profileID,
              let page = profile.pages.first(where: { $0.id == command.pageID }),
              page.orientation == command.orientation,
              let widget = page.widgets.first(where: { $0.id == command.widgetID }) else { return false }
        return widget.rect == (undo ? command.after : command.before)
    }
    public func canUndo(in profile: DashboardProfile) -> Bool { matches(past.last, profile: profile, undo: true) }
    public func canRedo(in profile: DashboardProfile) -> Bool { matches(future.last, profile: profile, undo: false) }

    @discardableResult
    public mutating func commit(profile: inout DashboardProfile, expectedProfileID: String,
                                expectedPage: DashboardPage, widgetID: String, rect: DashboardRect) -> Bool {
        guard profile.id == expectedProfileID,
              profile.pages.first(where: { $0.id == expectedPage.id }) == expectedPage,
              let original = expectedPage.widgets.first(where: { $0.id == widgetID }), original.rect != rect,
              (try? profile.updateWidgetRect(pageID: expectedPage.id, widgetID: widgetID, rect: rect)) != nil else { return false }
        past.append(.init(profileID: profile.id, pageID: expectedPage.id, orientation: expectedPage.orientation,
                          widgetID: widgetID, before: original.rect, after: rect))
        if past.count > 50 { past.removeFirst(past.count - 50) }
        future.removeAll()
        return true
    }
    @discardableResult
    public mutating func undo(profile: inout DashboardProfile) -> Bool {
        guard canUndo(in: profile), let command = past.last,
              (try? profile.updateWidgetRect(pageID: command.pageID, widgetID: command.widgetID, rect: command.before)) != nil else { return false }
        past.removeLast(); future.append(command)
        return true
    }
    @discardableResult
    public mutating func redo(profile: inout DashboardProfile) -> Bool {
        guard canRedo(in: profile), let command = future.last,
              (try? profile.updateWidgetRect(pageID: command.pageID, widgetID: command.widgetID, rect: command.after)) != nil else { return false }
        future.removeLast(); past.append(command)
        return true
    }
}
