import SwiftUI

/// The two text columns share a window, but retain independent scroll positions.
/// Window sizing belongs to the host so adding a detail never imposes a wider minimum.
struct MinimalLibraryView: View {
    @ObservedObject var model: AppModel
    @Binding var selectedCollection: MusicItem?
    let openCollection: (MusicItem) -> Void
    let closeCollection: () -> Void
    var searchVisible = false
    var searchFocusRequest: NativeSearchField.FocusRequest? = nil
    var hideSearch: () -> Void = {}

    @State private var songsExpanded = false
    @Environment(\.colorScheme) private var colorScheme

    private var palette: MinimalLibraryPalette { .init(colorScheme: colorScheme) }

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
                browseColumn
                    .frame(width: min(320, max(0, geometry.size.width)))

                if let selectedCollection {
                    collectionDetail(selectedCollection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(palette.rule).frame(width: 1)
                        }
                        .clipped()
                        .id(selectedCollection.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .foregroundStyle(palette.ink, palette.secondary)
        .background(palette.paper)
        .onChange(of: model.query) { _, _ in songsExpanded = false }
    }

    private var browseColumn: some View {
        VStack(spacing: 0) {
            if searchVisible {
                HStack(spacing: 9) {
                    NativeSearchField(text: $model.query, focusRequest: searchFocusRequest,
                                      enabled: model.connected) {
                        Task { await model.search() }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)

                    Button("Done", action: hideSearch)
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Close search")
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 5)
            }

            ScrollView {
                if searchVisible { searchResults }
                else { recommendations }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(searchVisible ? "Search results" : "Sections and collections")
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var recommendations: some View {
        if model.visibleHomeShelves.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.busy ? "Loading collections…" : "No collections yet")
                    .font(.system(size: 14, weight: .medium))
                if let error = model.error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if !model.busy {
                    Text("Refresh to load your recommendations.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if !model.busy {
                    Button(model.error == nil ? "Refresh" : "Retry") {
                        Task { await model.refresh() }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.plain)
                    .disabled(!model.connected)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        } else {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.visibleHomeShelves) { shelf in
                    VStack(alignment: .leading, spacing: 0) {
                        sectionTitle(shelf.title)
                        ForEach(shelf.items) { item in
                            collectionRow(item)
                        }
                        if shelf.nextOffset != nil {
                            textRowAction("Show more") {
                                Task { await model.loadMore(shelf) }
                            }
                            .disabled(model.busy || !model.connected)
                            .accessibilityLabel("Show more from \(shelf.title)")
                        }
                    }
                    .onAppear { model.prefetchHomeCollections(approaching: shelf.id) }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusText("Search songs, artists, albums, and playlists.")
        } else if model.results.isEmpty {
            statusText(model.searchLoading ? "Searching…" : "No results. Try another search.")
        } else {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(searchSections, id: \.kind) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        sectionTitle(section.title)
                        if section.kind == "track" {
                            let items = songsExpanded ? section.items : Array(section.items.prefix(7))
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                MinimalTrackRow(
                                    title: item.title, artist: item.subtitle, number: index + 1,
                                    durationMS: nil, isCurrent: model.nowPlaying?.id == item.id,
                                    isPlayable: model.connected
                                ) {
                                    Task { await model.play(item) }
                                }
                            }
                            if section.items.count > 7 {
                                textRowAction(songsExpanded ? "Collapse" : "Expand") {
                                    songsExpanded.toggle()
                                }
                                .accessibilityLabel(songsExpanded ? "Collapse songs" : "Expand songs")
                            }
                        } else {
                            ForEach(section.items) { item in collectionRow(item) }
                        }
                    }
                    .onAppear {
                        if section.kind != "track" { model.prefetchCollections(section.items) }
                    }
                }
            }
            .padding(.top, 9)
            .padding(.bottom, 16)
        }
    }

    private var searchSections: [MinimalSearchSection] {
        let groups = Dictionary(grouping: model.results, by: \.kind)
        return [("track", "Songs"), ("artist", "Artists"),
                ("playlist", "Playlists"), ("album", "Albums")].compactMap { kind, title in
            guard let items = groups[kind], !items.isEmpty else { return nil }
            return MinimalSearchSection(kind: kind, title: title, items: items)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .medium))
            .tracking(-0.35)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func collectionRow(_ item: MusicItem) -> some View {
        MinimalSidebarCollectionRow(item: item, isSelected: selectedCollection?.id == item.id,
                                    enabled: model.connected) {
            if item.kind == "track" {
                Task { await model.play(item) }
            } else {
                openCollection(item)
            }
        } playCollection: {
            Task { await model.play(item, context: item) }
        }
    }

    private func collectionDetail(_ selected: MusicItem) -> some View {
        let collection = model.collection?.item.id == selected.id ? model.collection : nil
        let item = collection?.item ?? selected
        let matchesSelection = model.collection == nil || collection != nil
        let collectionError = matchesSelection ? model.collectionError : nil
        let loading = matchesSelection && model.collectionLoading

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .center, spacing: 12) {
                        HStack(alignment: .center, spacing: 9) {
                            Text(item.title)
                                .font(.system(size: 22, weight: .medium))
                                .tracking(-0.6)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)

                            MinimalCollectionPlaybackButton(
                                model: model, playback: model.playback, collection: item,
                                canPlay: collection?.tracks.contains(where: \.isPlayable) == true
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Close", action: closeCollection)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                            .fixedSize()
                            .accessibilityLabel("Close collection")
                    }
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

                if let collectionError {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(collectionError)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Retry") {
                            Task {
                                guard selectedCollection?.id == selected.id else { return }
                                await model.retryCollection(selected)
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(.plain)
                        .disabled(loading || !model.connected)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }

                if let collection {
                    ForEach(Array(collection.tracks.enumerated()), id: \.element.id) { index, track in
                        MinimalTrackRow(
                            title: track.title, artist: track.artist, number: index + 1,
                            durationMS: track.durationMS,
                            isCurrent: model.nowPlaying?.id == track.uri
                                && model.isCurrentPlaybackContext(collection: collection.item),
                            isPlayable: track.isPlayable && model.connected
                        ) {
                            Task { await model.play(track.musicItem, context: collection.item) }
                        }
                        .onAppear {
                            Task {
                                guard selectedCollection?.id == selected.id,
                                      model.collection?.item.id == selected.id else { return }
                                await model.loadMoreCollectionIfNeeded(near: track.id)
                            }
                        }
                    }

                    if collection.tracks.isEmpty && !loading && collectionError == nil {
                        statusText("No songs are available in this collection.")
                    }
                    if loading {
                        statusText(collection.tracks.isEmpty ? "Loading songs…" : "Loading more songs…")
                    } else if collection.nextOffset != nil && collectionError == nil {
                        textRowAction("Show more songs") {
                            Task {
                                guard selectedCollection?.id == selected.id,
                                      model.collection?.item.id == selected.id else { return }
                                await model.loadMoreCollection()
                            }
                        }
                        .disabled(!model.connected)
                    }
                } else if collectionError == nil {
                    statusText("Loading songs…")
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .background(palette.paper)
        .accessibilityLabel("\(item.title), songs")
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
    }

    private func textRowAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(MinimalRowButtonStyle())
    }
}

private struct MinimalSidebarCollectionRow: View {
    let item: MusicItem
    let isSelected: Bool
    let enabled: Bool
    let activate: () -> Void
    let playCollection: () -> Void

    private enum Action: Hashable { case open, play }
    @State private var hovered = false
    @State private var playHovered = false
    @FocusState private var focusedAction: Action?
    @AccessibilityFocusState private var accessibilityFocusedAction: Action?
    @Environment(\.colorScheme) private var colorScheme

    private var palette: MinimalLibraryPalette { .init(colorScheme: colorScheme) }
    private var hasFocus: Bool { focusedAction != nil || accessibilityFocusedAction != nil }
    private var highlighted: Bool { isSelected || (enabled && (hovered || hasFocus)) }
    private var showPlay: Bool { hovered || hasFocus }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: activate) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .tracking(-0.1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineSpacing(1)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
                .padding(.trailing, item.kind == "track" ? 14 : 0)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedAction, equals: .open)
            .accessibilityFocused($accessibilityFocusedAction, equals: .open)
            .accessibilityLabel("\(item.kind == "track" ? "Play" : "Open") \(item.title), \(item.subtitle)")
            .accessibilityValue(isSelected ? "Selected collection" : "")

            if item.kind != "track" {
                // Keep this lane in the layout and accessibility tree when its
                // glyph is hidden. Text never moves when either action receives focus.
                Button(action: playCollection) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .offset(x: 1)
                        .foregroundStyle(Color(red: 16.0 / 255, green: 33.0 / 255, blue: 20.0 / 255))
                        .frame(width: 28, height: 28)
                        .background(playHovered
                                    ? Color(red: 30.0 / 255, green: 215.0 / 255, blue: 96.0 / 255)
                                    : Color(red: 29.0 / 255, green: 185.0 / 255, blue: 84.0 / 255),
                                    in: Circle())
                        .opacity(showPlay ? 1 : 0)
                        .padding(.leading, 8)
                        .padding(.trailing, 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .focused($focusedAction, equals: .play)
                .accessibilityFocused($accessibilityFocusedAction, equals: .play)
                .accessibilityLabel("Play \(item.title)")
                .accessibilityHidden(false)
                .help("Play \(item.title)")
                .onHover { playHovered = $0 }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(highlighted ? palette.highlightInk : palette.ink,
                         highlighted ? palette.highlightSecondary : palette.secondary)
        .background(isSelected ? palette.selection : highlighted ? palette.hover : .clear)
        .contentShape(Rectangle())
        .disabled(!enabled)
        .onHover { hovered = $0 }
    }
}

private struct MinimalSearchSection {
    let kind: String
    let title: String
    let items: [MusicItem]
}

private struct MinimalCollectionPlaybackButton: View {
    @ObservedObject var model: AppModel
    // Only this small control observes progress ticks; the columns do not.
    @ObservedObject var playback: PlaybackState
    let collection: MusicItem
    let canPlay: Bool
    @State private var hovered = false

    private var isCurrentContext: Bool { model.isCurrentPlaybackContext(collection: collection) }
    private var isPlaying: Bool { isCurrentContext && playback.isPlaying }

    var body: some View {
        Button {
            Task { await model.toggleCollectionPlayback(collection) }
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .offset(x: isPlaying ? 0 : 1)
                .foregroundStyle(Color(red: 16.0 / 255, green: 33.0 / 255, blue: 20.0 / 255))
                .frame(width: 30, height: 30)
                .background(hovered ? Color(red: 30.0 / 255, green: 215.0 / 255, blue: 96.0 / 255)
                            : Color(red: 29.0 / 255, green: 185.0 / 255, blue: 84.0 / 255), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!model.connected || (!canPlay && !isCurrentContext))
        .opacity(model.connected && (canPlay || isCurrentContext) ? 1 : 0.45)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(isPlaying ? "Pause" : "Play") \(collection.title)")
        .help(isPlaying ? "Pause" : "Play")
    }
}

private struct MinimalTrackRow: View {
    let title: String
    let artist: String
    let number: Int
    let durationMS: Int?
    let isCurrent: Bool
    let isPlayable: Bool
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(alignment: .center, spacing: 9) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if !artist.isEmpty {
                        Text(artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let durationMS {
                    Text(Self.duration(durationMS))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(MinimalRowButtonStyle(isSelected: isCurrent))
        .disabled(!isPlayable)
        .opacity(isPlayable ? 1 : 0.5)
        .accessibilityLabel(isPlayable ? "Play \(title), \(artist)" : "\(title), \(artist), unavailable")
        .accessibilityValue(isCurrent ? "Current song" : "")
    }

    private static func duration(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct MinimalRowButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        MinimalRowSurface(label: configuration.label, selected: isSelected, pressed: configuration.isPressed)
    }
}

private struct MinimalRowSurface: View {
    let label: ButtonStyleConfiguration.Label
    let selected: Bool
    let pressed: Bool
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    private var highlighted: Bool { selected || pressed || (hovered && isEnabled) }
    private var palette: MinimalLibraryPalette { .init(colorScheme: colorScheme) }

    var body: some View {
        label
            .foregroundStyle(highlighted ? palette.highlightInk : palette.ink,
                             highlighted ? palette.highlightSecondary : palette.secondary)
            .background(selected || pressed ? palette.selection
                        : hovered && isEnabled ? palette.hover : .clear)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

private struct MinimalLibraryPalette {
    let colorScheme: ColorScheme

    var paper: Color { color(light: 0xfcfbf8, dark: 0x20211f) }
    var ink: Color { color(light: 0x242622, dark: 0xe9eae4) }
    var secondary: Color { color(light: 0x686b63, dark: 0xa5a99e) }
    var rule: Color { color(light: 0xdedfd7, dark: 0x3b3e37) }
    var hover: Color { color(light: 0xe5f1e9, dark: 0x223b2c) }
    var selection: Color { color(light: 0xcfe8d7, dark: 0x2c5138) }
    var highlightInk: Color { color(light: 0x203b2a, dark: 0xe9f3ed) }
    var highlightSecondary: Color { color(light: 0x45624f, dark: 0xb4cbbb) }

    private func color(light: UInt32, dark: UInt32) -> Color {
        let value = colorScheme == .dark ? dark : light
        return Color(red: Double((value >> 16) & 0xff) / 255,
                     green: Double((value >> 8) & 0xff) / 255,
                     blue: Double(value & 0xff) / 255)
    }
}
