import PRKitCore
import PRKitDesign
import SwiftUI

/// Linear's own logo, in its own colour.
public struct LinearMark: View {
    public var size: CGFloat = 16

    public var body: some View {
        Image("LinearMark")
            .resizable()
            .frame(width: size, height: size)
            .foregroundStyle(LinearPalette.brand)
            .accessibilityHidden(true)
    }
}

/// Linear's status circle in the state's own colour: how full it is comes from `state_type`, all the wire says.
public struct LinearStateCircle: View {
    public let ticket: PRListTicket
    private static let size: CGFloat = 13

    public var body: some View {
        Group {
            switch ticket.found == true ? ticket.stateType : nil {
            case "completed":
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
            case "canceled":
                Image(systemName: "xmark.circle.fill")
                    .resizable()
            case "started":
                ZStack {
                    Circle().strokeBorder(lineWidth: 1.5)
                    LinearStatePie().padding(3)
                }
            case "unstarted":
                Circle().strokeBorder(lineWidth: 1.5)
            default:
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            }
        }
        .frame(width: Self.size, height: Self.size)
        .foregroundStyle(LinearPalette.color(of: ticket))
        .frame(width: PrListGrid.state)
        .accessibilityHidden(true)
    }
}

/// The filled half of a started state's circle.
private struct LinearStatePie: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(
            center: center, radius: rect.width / 2, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

public enum LinearPalette {
    public static let brand = hex(0x5E6AD2)

    /// The state's colour from Linear, else Linear's default for its type. Todo and Backlog stay grey: Linear's
    /// `#e2e2e2` can't be seen as a ring on white. Not found is the app's waiting tone.
    public static func color(of ticket: PRListTicket) -> Color {
        guard ticket.found == true else {
            return ticket.found == nil ? Color.secondary : Color.toneWaiting
        }
        switch ticket.stateType {
        case "unstarted", "backlog": return Color.secondary
        default: break
        }
        if let value = ticket.stateColor.flatMap(parsed) {
            return hex(value)
        }
        return switch ticket.stateType {
        case "started": hex(0xF2C94C)
        case "completed": brand
        case "canceled": hex(0x95A2B3)
        case "triage": hex(0xFC7840)
        default: Color.secondary
        }
    }

    /// `#5e6ad2` as a number; `nil` for anything else.
    public static func parsed(_ text: String) -> UInt32? {
        guard text.count == 7, text.hasPrefix("#") else {
            return nil
        }
        return UInt32(text.dropFirst(), radix: 16)
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
