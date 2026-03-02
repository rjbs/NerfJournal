import SwiftUI

struct CategoryLabel: View {
    let category: Category?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(category.map { $0.color.swatch } ?? Color.gray)
                .frame(width: 8, height: 8)
            Text(category?.name ?? "Other")
        }
    }
}
