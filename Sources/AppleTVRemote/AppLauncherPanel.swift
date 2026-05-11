import SwiftUI
import AppKit

/// Compact app launcher that slides out to the left of the remote.
/// Built for our 320pt-wide popover annex (not their 600pt main-window grid).
/// Reads `connection.appList` for content, `AppIconCache` for artwork.
struct AppLauncherPanel: View {
    @EnvironmentObject private var connection: CompanionConnection
    @ObservedObject private var iconCache: AppIconCache = .shared
    @Binding var isPresented: Bool
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 60, maximum: 80), spacing: 12, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 8) {
            header
            searchBar
            Divider()
            grid
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.thickMaterial)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3.fill")
                .foregroundStyle(.secondary)
            Text("Apps")
                .font(.headline)
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close app launcher")
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var grid: some View {
        ScrollView {
            if filteredApps.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filteredApps, id: \.id) { app in
                        appCell(app)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if connection.appList.isEmpty {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading apps…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        } else {
            Text("No matches")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        }
    }

    private func appCell(_ app: (id: String, name: String)) -> some View {
        Button {
            connection.launchApp(bundleID: app.id, completion: { _ in })
            isPresented = false
        } label: {
            VStack(spacing: 4) {
                iconView(for: app)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(app.name)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: 70)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func iconView(for app: (id: String, name: String)) -> some View {
        if let nsImage = iconCache.icon(for: app.id) {
            Image(nsImage: nsImage).resizable().scaledToFit()
        } else {
            // No iTunes lookup result — give every app something recognisable
            // (coloured tile with the first letter) instead of a generic
            // placeholder that reads as a missing icon.
            placeholderTile(for: app)
        }
    }

    private func placeholderTile(for app: (id: String, name: String)) -> some View {
        let colors = colorPair(for: app.id)
        let initial = app.name.first.map { String($0).uppercased() } ?? "?"
        return RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(LinearGradient(colors: colors,
                                 startPoint: .topLeading,
                                 endPoint: .bottomTrailing))
            .overlay(
                Text(initial)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            )
    }

    /// Deterministic per-bundle-ID hue so the same app always gets the same
    /// colour tile — easier for the user to recognise across sessions.
    private func colorPair(for id: String) -> [Color] {
        let hash = id.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let hue = Double(abs(hash) % 360) / 360.0
        return [
            Color(hue: hue, saturation: 0.55, brightness: 0.78),
            Color(hue: hue, saturation: 0.70, brightness: 0.52),
        ]
    }

    private var filteredApps: [(id: String, name: String)] {
        guard !query.isEmpty else { return connection.appList }
        let q = query.lowercased()
        return connection.appList.filter { $0.name.lowercased().contains(q) }
    }
}
