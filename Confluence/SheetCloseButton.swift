import SwiftUI

/// A close control that mimics the standard macOS window close button — a single red dot
/// (no minimise/zoom) that shows an ✕ on hover and greys out when the window is inactive,
/// following the OS the way the real traffic-light close does. Placed top-left of a sheet.
struct SheetCloseButton: View {
    let action: () -> Void
    @Environment(\.controlActiveState) private var activeState
    @State private var hovering = false

    /// System accent set to Graphite → macOS renders the traffic lights monochrome, so match it.
    /// AppleAquaColorVariant == 6 is the long-standing Graphite marker in the global domain.
    private var isGraphite: Bool {
        UserDefaults.standard.integer(forKey: "AppleAquaColorVariant") == 6
    }

    private var fill: Color {
        if activeState == .inactive { return Color(nsColor: .quaternaryLabelColor) }
        return isGraphite
            ? Color(nsColor: .systemGray)          // Graphite: monochrome window controls
            : Color(red: 1.0, green: 0.37, blue: 0.35) // standard close-button red
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(fill)
                Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
                if hovering, activeState != .inactive {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.black.opacity(0.55))
                }
            }
            .frame(width: 13, height: 13)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(.cancelAction)
        .help("Close")
        .accessibilityLabel("Close")
    }
}
