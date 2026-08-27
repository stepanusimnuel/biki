import SwiftUI

extension FruitGrade {
    var displayName: String {
        self == .e ? "Ditolak" : "Grade \(rawValue)"
    }

    var badgeIcon: String {
        switch self {
        case .a, .b: "checkmark.circle.fill"
        case .c, .d: "exclamationmark.triangle.fill"
        case .e: "exclamationmark.circle.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .a, .b: .green
        case .c, .d: .orange
        case .e: .red
        }
    }
}

struct GradeBadge: View {
    let grade: FruitGrade

    var body: some View {
        Label(grade.displayName, systemImage: grade.badgeIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(grade.badgeColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(grade.badgeColor.opacity(0.12), in: Capsule())
    }
}
