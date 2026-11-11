import PRKitCore
import PRKitDesign
import SwiftUI

/// The phone's own navigation-bar and list API where the Mac has none, so a shared screen says what it wants once:
/// on the phone each is exactly the iOS call it names, on the Mac the nearest thing a window has, or nothing.
extension View {
    /// The phone's inline title; a Mac window has no navigation bar to size.
    public func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// The phone's compact gaps between list sections; the Mac's lists keep their own.
    public func compactListSections() -> some View {
        #if os(iOS)
        listSectionSpacing(.compact)
        #else
        self
        #endif
    }

    /// On a wide iPad, keeps every scroll view under it to the width of an iPad in portrait, centred. The phone, the Mac
    /// and narrower iPad windows keep their own margins; a diff's table is UIKit, so it keeps the whole width.
    public func readableContentWidth() -> some View {
        #if os(iOS)
        modifier(ReadableContentWidth())
        #else
        self
        #endif
    }

    /// A bar over the content, held to the same width as the content under it on a wide iPad.
    public func readableBarWidth() -> some View {
        #if os(iOS)
        frame(maxWidth: ReadableContentWidth.widest).frame(maxWidth: .infinity)
        #else
        self
        #endif
    }

    /// A sheet's content: a sheet sets its own width, so on an iPad it swaps the margins of the screen under it for a
    /// form's own. No margin at all would take the corners off its sections.
    public func sheetContentWidth() -> some View {
        #if os(iOS)
        modifier(SheetContentWidth())
        #else
        self
        #endif
    }

    /// The phone's full-screen cover; a sheet over the Mac's window.
    public func fullScreenCoverOrSheet<Content: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }

    /// A sheet's content: the phone's as it is; on the Mac, a Form grouped as the phone draws it, at a size a sheet
    /// can hold — a Mac sheet otherwise shrinks to its content's least.
    public func macSheetSize(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        formStyle(.grouped)
            .frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
        #else
        self
        #endif
    }

    /// Pull to refresh on the phone; a Mac has no pull, so there the toolbar's Refresh and ⌘R run the same action.
    public func refreshableWithCommand(action: @escaping @Sendable () async -> Void) -> some View {
        #if os(macOS)
        refreshable(action: action)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await action() }
                    }
                    .keyboardShortcut("r")
                }
            }
        #else
        refreshable(action: action)
        #endif
    }

    /// The phone's convention for a screen with a reply box: a drag in the content — a scroll as it starts — puts the
    /// keyboard away, and so does a tap (`KeyboardDismissTap`; both still reach the list and what they land on). Both
    /// take the field's focus, so the keyboard slides away; the scroll view's own dismissal dropped it with no
    /// animation, and a List reports no scroll phases to watch. The Mac has no keyboard to put away, so there the field
    /// keeps its focus.
    public func dismissesKeyboard(_ focus: FocusState<Bool>.Binding) -> some View {
        #if os(iOS)
        simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in
            if focus.wrappedValue {
                focus.wrappedValue = false
            }
        })
        .gesture(KeyboardDismissTap { focus.wrappedValue = false })
        #else
        self
        #endif
    }

    /// The Mac's Return in a message field: it sends, and Option-Return starts a new line. On the phone Return starts
    /// a new line and the send button sends.
    public func sendsOnReturn(_ send: @escaping () -> Void) -> some View {
        #if os(macOS)
        onSubmit(send)
        #else
        self
        #endif
    }

    /// A screen pushed onto a navigation stack: on the Mac it slides a short way in from the right and fades up as it
    /// appears. A stack inside the Mac's sidebar swaps its screens in one frame — macOS animates a stack only outside a
    /// split view, with or without an animation around the push — so the motion is the screen's own. The phone's stack
    /// slides its screens itself.
    public func pushedOnMac() -> some View {
        #if os(macOS)
        modifier(MacPushedScreen())
        #else
        self
        #endif
    }

    /// A stack's first screen: on the Mac it slides back in from the left and fades up when Back returns to it
    /// (`atRoot` turning true), the other half of `pushedOnMac`. The phone's stack slides it back itself.
    public func returnedToOnMac(atRoot: Bool) -> some View {
        #if os(macOS)
        modifier(MacReturnedScreen(atRoot: atRoot))
        #else
        self
        #endif
    }

    /// The phone's zoom out of `sourceID` as a cover opens; a Mac sheet comes down as sheets do.
    public func zoomTransition(sourceID: some Hashable, in namespace: Namespace.ID) -> some View {
        #if os(iOS)
        navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        #else
        self
        #endif
    }
}

extension ToolbarItemPlacement {
    /// The phone's top bar, trailing; the Mac's primary-action place in the toolbar.
    public static var barTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }

    /// The phone's top bar, leading; the Mac's navigation place in the toolbar.
    public static var barLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }
}

extension VerticalAlignment {
    /// A message field's send button: on the phone centred on the field's last line; on the
    /// Mac, whose glass button is shorter than the field, on the last line's baseline, so it sits centred on that line
    /// at every text size.
    public static var sendButton: VerticalAlignment {
        #if os(macOS)
        .lastTextBaseline
        #else
        VerticalAlignment(ComposerLine.self)
        #endif
    }

    /// The field's last line on the phone: the button's middle sits on it, so a one-line field and its button are
    /// centred, and a grown field keeps the button by the line being typed.
    private enum ComposerLine: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }
}

extension SearchFieldPlacement {
    /// The phone's drawer under the navigation bar; the Mac's search field in the toolbar.
    public static var drawer: SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: .automatic)
        #else
        .toolbar
        #endif
    }
}

#if os(iOS)
/// A tap that leaves the touch to what it lands on. A SwiftUI `TapGesture` over a `List`, even a simultaneous one, stops
/// the list's `Button` rows firing; a recognizer that does not cancel touches does not.
private struct KeyboardDismissTap: UIGestureRecognizerRepresentable {
    let dismiss: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        recognizer.cancelsTouchesInView = false
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        if recognizer.state == .ended {
            dismiss()
        }
    }
}
#endif

#if os(iOS)
private struct SheetContentWidth: ViewModifier {
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.contentMargins(.horizontal, 20, for: .scrollContent)
        } else {
            content
        }
    }
}

private struct ReadableContentWidth: ViewModifier {
    static let widest: CGFloat = 820
    @State private var margin: CGFloat = 0

    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content
                .contentMargins(.horizontal, margin > 0 ? margin : nil, for: .scrollContent)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    margin = max(0, (width - Self.widest) / 2)
                }
        } else {
            content
        }
    }
}
#endif

#if os(macOS)
/// How far a Mac screen moves as it is pushed or returned to.
private enum MacScreenMotion {
    static let distance: CGFloat = 60
}

private struct MacPushedScreen: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .offset(x: shown ? 0 : MacScreenMotion.distance)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(AppMotion.screen) {
                    shown = true
                }
            }
    }
}

private struct MacReturnedScreen: ViewModifier {
    let atRoot: Bool
    @State private var offset: CGFloat = 0
    @State private var opacity = 1.0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .opacity(opacity)
            .onChange(of: atRoot) { _, atRoot in
                guard atRoot else {
                    return
                }
                offset = -MacScreenMotion.distance
                opacity = 0
                // On the run loop's next turn: set in the same update, SwiftUI would draw only where it ends.
                Task { @MainActor in
                    withAnimation(AppMotion.screen) {
                        offset = 0
                        opacity = 1
                    }
                }
            }
    }
}
#endif

/// Opens a value on the `NavigationStack` around it, for `StackLink`.
public struct StackPush {
    public let path: Binding<NavigationPath>

    public init(path: Binding<NavigationPath>) {
        self.path = path
    }

    @MainActor public func callAsFunction(_ value: some Hashable) {
        path.wrappedValue.append(value)
    }
}

extension EnvironmentValues {
    @Entry public var stackPush: StackPush?
}

extension View {
    /// On a `NavigationStack` with `StackLink`s in it.
    public func stackLinks(in path: Binding<NavigationPath>) -> some View {
        environment(\.stackPush, StackPush(path: path))
    }
}

/// A list row that opens a screen. The phone's is a `NavigationLink`. The Mac's reads the click itself: there a link in a
/// list opens through the list's selection, which keeps the row selected after Back, so it won't open twice, and in a tab
/// reached from the sidebar can select the row and open nothing. A button inside the row still takes its own clicks.
public struct StackLink<Value: Hashable, Label: View>: View {
    public let value: Value
    @ViewBuilder public let label: Label
    @Environment(\.stackPush) private var push

    public init(value: Value, @ViewBuilder label: () -> Label) {
        self.value = value
        self.label = label()
    }

    public var body: some View {
        #if os(iOS)
        NavigationLink(value: value) { label }
        #else
        label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { push?(value) }
            .accessibilityAddTraits(.isButton)
        #endif
    }
}

/// A tab's `NavigationStack`, whose open screens outlast a trip to another tab. The Mac's sidebar takes a tab's view away
/// while it is not showing: on the way out the stack can clear its path, and coming back it can show its root with a path
/// still set. So on the Mac a tab remembers what it had open as it goes, and opens that again as it comes back. The path
/// is a `NavigationPath`, or an array of one type of screen.
public struct TabStack<Path: Equatable, Root: View>: View {
    @Binding public var path: Path
    @ViewBuilder public let root: Root
    private let empty: Path
    private let stack: (Binding<Path>, Root) -> NavigationStack<Path, Root>

    #if os(macOS)
    @State private var leftOpen: Path?
    #endif

    public var body: some View {
        #if os(iOS)
        stack($path, root)
        #else
        stack($path, root)
            .onDisappear { leftOpen = path }
            .onAppear {
                guard let open = leftOpen, open != empty else {
                    return
                }
                leftOpen = nil
                path = empty
                // On the next turn of the run loop, when the new stack is up, and without the push animation: the
                // screens are simply there, as if they had never gone.
                Task { @MainActor in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { path = open }
                }
            }
        #endif
    }
}

extension TabStack where Path == NavigationPath {
    public init(path: Binding<NavigationPath>, @ViewBuilder root: () -> Root) {
        _path = path
        self.root = root()
        empty = NavigationPath()
        stack = { path, root in NavigationStack(path: path) { root } }
    }
}

extension TabStack {
    public init<Screen: Hashable>(path: Binding<[Screen]>, @ViewBuilder root: () -> Root) where Path == [Screen] {
        _path = path
        self.root = root()
        empty = []
        stack = { path, root in NavigationStack(path: path) { root } }
    }
}
