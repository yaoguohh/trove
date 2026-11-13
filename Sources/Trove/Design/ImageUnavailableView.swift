import SwiftUI

/// What every image surface (card, peek, inspector) shows when the clip's file is gone.
struct ImageUnavailableView: View {
    let symbolSize: CGFloat
    let textSize: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: symbolSize, weight: .medium))
            Text("Image unavailable")
                .font(.system(size: textSize, weight: .semibold))
        }
        .foregroundStyle(Theme.Text.t3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
