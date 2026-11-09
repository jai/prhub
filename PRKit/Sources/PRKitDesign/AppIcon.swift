import SwiftUI

/// Every icon that means something, by what it means: one place to change a symbol, so a meaning never has two icons
/// and two meanings never share one (DESIGN.md, Status). A review is always a person; a check is never one.
public enum AppIcon: String {
    // A PR's checks.
    case checksPass = "circle.fill"
    case checksFail = "xmark.circle.fill"
    case checksRunning = "clock.fill"
    case checkSkipped = "minus.circle.fill"
    case checksNone = "minus.circle"

    // A PR's review, and one reviewer's.
    case reviewApproved = "person.fill.checkmark"
    case reviewChangesRequested = "person.fill.xmark"
    case reviewNeeded = "person.fill.questionmark"
    case reviewNotRequired = "person"
    case reviewCommented = "person.bubble.fill"
    case reviewDismissed = "person.slash.fill"
    case reviewWaiting = "person.badge.clock.fill"

    // A PR's state and merge.
    case merged = "arrow.triangle.merge"
    case closed = "xmark.circle"
    case draft = "pencil.circle"
    case outOfDate = "arrow.down.circle"
    case blocked = "lock.fill"
    case conflicts = "exclamationmark.triangle.fill"
    case mergeableFailing = "exclamationmark.circle.fill"
    case unknown = "questionmark.circle"

    // How something stands: an alert's severity, a monitor's health.
    case ok = "checkmark.circle.fill"
    case degraded = "exclamationmark.square.fill"
    case down = "exclamationmark.octagon.fill"
    case info = "info.circle.fill"
    case problem = "exclamationmark.triangle"
    case waiting = "clock"
    case stale = "clock.badge.exclamationmark"

    // Alerts and reminders.
    case paging = "bell.and.waves.left.and.right.fill"
    case reminderActive = "bell.badge.fill"
    case deliveryPending = "bell.badge"
    case deliveryFailed = "bell.slash"
    case quietHours = "moon"

    // Threads and agent messages.
    case machine = "desktopcomputer"
    case machineNotAnswering = "desktopcomputer.trianglebadge.exclamationmark"
    case automation = "repeat"
    case serverGone = "icloud.slash"
    case replied = "arrowshape.turn.up.left.fill"
    case awaitingReply = "bubble.left.and.text.bubble.right"
    case conversationClosed = "lock"
    case readOnly = "pencil.slash"
    case dismiss = "eye.slash"
    case restore = "arrow.uturn.backward"
    case viewFilter = "line.3.horizontal.decrease.circle"
    case viewFilterOn = "line.3.horizontal.decrease.circle.fill"
    case moveUp = "arrow.up"
    case remove = "minus"

    // Settings: the account, the Worker, alerts and the diff font.
    case signIn = "person.crop.circle"
    case signOut = "rectangle.portrait.and.arrow.right"
    case ownWorker = "server.rack"
    case installApp = "building.2"
    case alertsTurnOn = "bell.circle"
    case alertsOff = "bell.slash.circle"
    case smaller = "arrow.down.right.and.arrow.up.left"
    case bigger = "arrow.up.left.and.arrow.down.right"
    case scanCode = "qrcode.viewfinder"
    case samples = "sparkles.rectangle.stack"
    case settings = "gearshape"

    // A PR's page: asking AI, its checks, what people wrote.
    case askAI = "questionmark.bubble"
    case required = "asterisk"
    case openExternally = "arrow.up.right"
    case taskDone = "checkmark.square.fill"
    case taskOpen = "square"
    case fold = "chevron.down"
    case close = "xmark"

    // Actions.
    case refresh = "arrow.clockwise"
    case copy = "doc.on.doc"
    case done = "checkmark"
    case sending = "arrow.up.circle"
    case offline = "wifi.slash"
    case delivered = "checkmark.circle"
    case toolCall = "wrench.and.screwdriver"
    case resets = "arrow.counterclockwise"
    case share = "square.and.arrow.up"
    case delete = "trash"
    case list = "list.bullet.rectangle"
    case details = "sidebar.right"
    case alertSent = "bell"
    case messageSent = "message"
    case conversation = "text.bubble"
    case compose = "square.and.pencil"
    case openPullRequest = "arrow.triangle.pull"
    case reviewChanges = "plus.forwardslash.minus"
    case openInGitHub = "safari"
    case copyLink = "link"
    case drillIn = "chevron.right"

    // A screenshot on a message: adding one, and where from.
    case attach = "paperclip"
    case attachPhoto = "photo.on.rectangle"
    case attachFile = "folder"
    case attachPaste = "doc.on.clipboard"

    /// The SF Symbol's name, for an API that takes one.
    public var symbol: String { rawValue }
}

extension Image {
    /// A registry icon. Its variant is DESIGN.md's, set once at the app's root.
    public init(_ icon: AppIcon) {
        self.init(systemName: icon.symbol)
    }
}
