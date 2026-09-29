import SwiftUI

private enum MusicLayout {
    static let contentInset: CGFloat = 28
    static let trackArtworkSize: CGFloat = 42
}

private enum MusicPalette {
    static let spotifyGreen = Color(red: 29.0 / 255, green: 185.0 / 255, blue: 84.0 / 255)
}

private enum CollectionMotion {
    static let animation = Animation.easeInOut(duration: 0.24)
}

private enum Destination: String {
    case madeForYou = "Made for You"
    case search = "Search"
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    var interface: AppInterface = .text
    @State private var destination: Destination = .madeForYou
    @State private var selectedCollection: MusicItem?
    @State private var contentWidth: CGFloat = 1_080
    @State private var searchFocusRequest: NativeSearchField.FocusRequest?
    @State private var songsExpanded = false
    @State private var coverFlight: CoverFlight?
    @State private var selectedCoverImage: CGImage?
    @State private var navigationExpanded = false
    @State private var collectionReturnID: UUID?
    @State private var collectionReturning = false
    @State private var pendingCollectionReturn: Destination?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if let error = model.error {
                    errorBanner(error)
                }
                if model.connected {
                    if interface == .text {
                        MinimalLibraryView(model: model, selectedCollection: $selectedCollection,
                                           openCollection: { activate($0, from: .zero, image: nil) },
                                           closeCollection: { closeCollection() },
                                           searchVisible: destination == .search,
                                           searchFocusRequest: searchFocusRequest,
                                           hideSearch: {
                                               searchFocusRequest = .init(focused: false)
                                               destination = .madeForYou
                                           })
                    } else {
                    ZStack(alignment: .topLeading) {
                        Group {
                            if destination == .search { searchContent }
                            else { recommendations }
                        }
                        // Keep the source scroll position for Back, including lazy grids.
                        .opacity(selectedCollection == nil || collectionReturnID != nil ? 1 : 0)
                        .allowsHitTesting(selectedCollection == nil)
                        .accessibilityHidden(selectedCollection != nil)

                        if let selectedCollection {
                            collectionDetail(selectedCollection)
                                .scrollDisabled(coverFlight != nil)
                                .allowsHitTesting(!collectionReturning)
                                .background(Color(nsColor: .windowBackgroundColor))
                                .opacity(collectionReturning || coverFlight?.started == false ? 0 : 1)
                                // Only fade on entry. Ending the flight must not fade
                                // the destination cover up from zero after its overlay vanishes.
                                .animation(.easeOut(duration: 0.12), value: coverFlight?.started == false)
                                .animation(reduceMotion ? nil : CollectionMotion.animation, value: collectionReturning)
                        }

                        if let flight = coverFlight {
                            flyingCover(flight)
                                .transition(.identity)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .coordinateSpace(name: CollectionCoverSpace.content)
                    .clipped()
                    }
                } else {
                    if interface == .text { minimalSignIn }
                    else { signIn }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            if model.connected && interface == .artwork {
                Divider()
                PlaybackBar(model: model)
            }
        }
        .frame(minWidth: interface == .text ? 280 : 800, minHeight: interface == .text ? 500 : 550)
        .tint(.mint)
        .background {
            InterfaceWindow(interface: interface, collectionOpen: selectedCollection != nil,
                            reduceMotion: reduceMotion, title: model.windowTitle)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .toolbar {
            if interface == .artwork {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 12) {
                    navigationButtons
                    Spacer(minLength: 16)
                    if model.busy || model.collectionLoading || model.searchLoading {
                        ProgressView().controlSize(.small)
                    }
                    if model.connected {
                        searchField.frame(width: 280)
                        Menu {
                            Button("Refresh") { Task { await model.refresh() } }
                                .disabled(model.busy)
                            Button("Reconnect Spotify") { Task { await model.connect() } }
                                .disabled(model.busy)
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Settings")
                        .accessibilityLabel("Settings")
                    }
                }
                // One expanding native item keeps the trailing field anchored on macOS 14+.
                // Reserve the titlebar's traffic lights and outer insets.
                .frame(width: max(0, contentWidth - 128))
            }
            }
        }
        .task {
            if model.connected { await model.refresh() }
        }
        .onChange(of: model.query) { _, _ in songsExpanded = false }
        .onChange(of: interface) { _, _ in
            coverFlight = nil
            collectionReturnID = nil
            collectionReturning = false
            pendingCollectionReturn = nil
            navigationExpanded = selectedCollection != nil
        }
        .onChange(of: model.connected) { _, connected in
            if !connected { closeCollection() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .topsFocusSearch)) { _ in
            guard model.connected else { return }
            showSearch()
            searchFocusRequest = .init(focused: true)
        }
        .onExitCommand {
            if selectedCollection != nil { closeCollection() }
            else if interface == .text, destination == .search {
                searchFocusRequest = .init(focused: false)
                destination = .madeForYou
            }
        }
    }

    private var navigationButtons: some View {
        CollectionNavigationButtons(expanded: navigationExpanded,
                                    canGoBack: selectedCollection != nil,
                                    back: { returnFromCollection(to: destination) }) {
            returnFromCollection(to: .madeForYou)
        }
    }

    private var searchField: some View {
        NativeSearchField(text: searchText, focusRequest: searchFocusRequest, enabled: model.connected) {
            showSearch()
            Task { await model.search() }
        }
        .frame(height: 28)
    }

    private var searchText: Binding<String> {
        Binding(get: { model.query }, set: { value in
            showSearch()
            model.query = value
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.clearSearch()
            }
        })
    }

    private func showSearch() {
        closeCollection(resignSearch: false)
        destination = .search
    }

    private func closeCollection(resignSearch: Bool = true) {
        if resignSearch { searchFocusRequest = .init(focused: false) }
        collectionReturnID = nil
        collectionReturning = false
        pendingCollectionReturn = nil
        guard selectedCollection != nil else { return }
        navigationExpanded = false
        coverFlight = nil
        selectedCoverImage = nil
        selectedCollection = nil
        model.closeCollection()
    }

    private func returnFromCollection(to target: Destination) {
        searchFocusRequest = .init(focused: false)
        guard collectionReturnID == nil else { return }
        guard selectedCollection != nil else {
            if destination != target { destination = target }
            return
        }
        if reduceMotion {
            closeCollection(resignSearch: false)
            if destination != target { destination = target }
            return
        }
        if coverFlight != nil {
            // Finish an entrance already in motion before returning, instead of
            // dropping its moving cover and snapping to the detail's final frame.
            pendingCollectionReturn = target
            return
        }

        let returnID = UUID()
        collectionReturnID = returnID
        // Prepare the destination behind the detail first. Home and Back then
        // share exactly the same animation and deferred teardown, even from Search.
        if destination != target { destination = target }
        DispatchQueue.main.async {
            guard collectionReturnID == returnID else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withAnimation(CollectionMotion.animation, completionCriteria: .removed) {
                navigationExpanded = false
                collectionReturning = true
            } completion: {
                guard collectionReturnID == returnID else { return }
                // Keep the detail and toolbar intact until the return finishes.
                withTransaction(transaction) { closeCollection(resignSearch: false) }
            }
        }
    }

    private func activate(_ item: MusicItem, from frame: CGRect, image: CGImage?) {
        searchFocusRequest = .init(focused: false)
        if item.kind == "track" {
            Task { await model.play(item) }
        } else {
            selectedCoverImage = image
            if !reduceMotion, frame.width > 0, frame.height > 0 {
                coverFlight = CoverFlight(item: item, image: image, frame: frame)
            } else {
                navigationExpanded = true
            }
            selectedCollection = item
            Task {
                guard selectedCollection?.id == item.id else { return }
                await model.openCollection(item)
            }
        }
    }

    private func flyingCover(_ flight: CoverFlight) -> some View {
        Group {
            if let image = flight.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Artwork(url: flight.item.imageURL)
            }
        }
        .frame(width: flight.frame.width, height: flight.frame.height)
        .clipShape(RoundedRectangle(cornerRadius: flight.item.kind == "artist" ? flight.frame.width / 2 : 10))
        .position(x: flight.frame.midX, y: flight.frame.midY)
    }

    private func moveCover(to frame: CGRect, for item: MusicItem) {
        guard let flight = coverFlight, flight.item.id == item.id,
              frame.width > 0, frame.height > 0 else { return }
        if flight.started {
            // A window resize can move the destination even while scrolling is locked.
            coverFlight?.frame = frame
            return
        }
        // Wait until the destination has a layout before beginning the flight.
        DispatchQueue.main.async {
            guard coverFlight?.id == flight.id, coverFlight?.started == false else { return }
            withAnimation(CollectionMotion.animation, completionCriteria: .removed) {
                navigationExpanded = true
                coverFlight?.started = true
                coverFlight?.frame = frame
            } completion: {
                guard coverFlight?.id == flight.id else { return }
                // Swap the overlay for the already-rendered cover in one frame.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { coverFlight = nil }
                if let target = pendingCollectionReturn {
                    pendingCollectionReturn = nil
                    returnFromCollection(to: target)
                }
            }
        }
    }

    private var recommendations: some View {
        Group {
            if model.visibleHomeShelves.isEmpty {
                emptyState(
                    symbol: model.busy ? "waveform" : "sparkles",
                    title: model.busy ? "Finding your mixes…" : "Your mixes belong here",
                    detail: model.busy ? "Loading your recommendations from Spotify." : "Refresh to load your Made for You collection."
                )
            } else {
                ArtworkScrollView {
                    LazyVStack(alignment: .leading, spacing: 31) {
                        ForEach(model.visibleHomeShelves) { shelf in
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(shelf.title)
                                        .font(.system(size: 18, weight: .semibold))
                                    Spacer(minLength: 14)
                                    if shelf.nextOffset != nil {
                                        Button("Show more") {
                                            Task { await model.loadMore(shelf) }
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.system(size: 12, weight: .medium))
                                        .accessibilityLabel("Show more from \(shelf.title)")
                                        .disabled(model.busy)
                                    }
                                }
                                itemGrid(shelf.items)
                            }
                            .onAppear { model.prefetchHomeCollections(approaching: shelf.id) }
                        }
                    }
                    .padding(.horizontal, MusicLayout.contentInset)
                    .padding(.top, 24)
                    .padding(.bottom, 30)
                }
            }
        }
    }

    private var searchContent: some View {
        Group {
            if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyState(symbol: "magnifyingglass", title: "Find your next listen", detail: "Search songs, artists, albums, and playlists.")
            } else if model.results.isEmpty {
                emptyState(
                    symbol: "magnifyingglass",
                    title: model.searchLoading ? "Searching…" : "No results yet",
                    detail: model.searchLoading ? "Looking through Spotify's catalog." : "Try a song, artist, album, or playlist."
                )
            } else {
                ArtworkScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(searchSections) { section in
                            VStack(alignment: .leading, spacing: 13) {
                                Text(section.title)
                                    .font(.system(size: 18, weight: .semibold))
                                if section.kind == "track" {
                                    LazyVStack(spacing: 3) {
                                        ForEach(songsExpanded ? section.items : Array(section.items.prefix(7))) { item in
                                            TrackRow(item: item, isCurrent: model.nowPlaying?.id == item.id, artworkSize: 56) {
                                                Task { await model.play(item) }
                                            }
                                        }
                                    }
                                    if section.items.count > 7 {
                                        Button(songsExpanded ? "Collapse" : "Expand") {
                                            songsExpanded.toggle()
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.system(size: 12, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.top, 3)
                                        .accessibilityLabel(songsExpanded ? "Collapse songs" : "Expand songs")
                                    }
                                } else {
                                    itemGrid(section.items)
                                        .onAppear { model.prefetchCollections(section.items) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, MusicLayout.contentInset)
                    .padding(.top, 24)
                    .padding(.bottom, 30)
                }
            }
        }
    }

    private var searchSections: [SearchSection] {
        let grouped = Dictionary(grouping: model.results) { item in
            item.kind.lowercased()
        }
        let preferredOrder = ["track", "artist", "playlist", "album"]
        let order = preferredOrder.filter { grouped[$0] != nil }
            + grouped.keys.filter { !preferredOrder.contains($0) }.sorted()
        return order.map { kind in
            SearchSection(kind: kind, items: grouped[kind] ?? [])
        }
    }

    private func itemGrid(_ items: [MusicItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 210), spacing: 18, alignment: .top)], alignment: .leading, spacing: 23) {
            ForEach(items) { item in
                MusicCard(item: item, isCurrent: model.nowPlaying?.id == item.id) { frame, image in
                    activate(item, from: frame, image: image)
                }
            }
        }
    }

    private func collectionDetail(_ selected: MusicItem) -> some View {
        let collection = model.collection?.item.id == selected.id ? model.collection : nil
        return ArtworkScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack(alignment: .top, spacing: 28) {
                    Artwork(url: collection?.item.imageURL ?? selected.imageURL,
                            cornerRadius: selected.kind == "artist" ? 98 : 10,
                            initialImage: selectedCoverImage,
                            onImageChange: { image in
                                if let image { selectedCoverImage = image }
                            })
                        .frame(width: 196, height: 196)
                        .opacity(coverFlight == nil ? 1 : 0)
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named(CollectionCoverSpace.content))
                        } action: { frame in
                            moveCover(to: frame, for: selected)
                        }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(collection?.item.title ?? selected.title)
                            .font(.system(size: 29, weight: .bold))
                            .lineLimit(3)
                        Text(collection?.item.subtitle ?? selected.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        Button {
                            guard let collection else { return }
                            Task { await model.play(collection.item, context: collection.item) }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(collection?.tracks.contains(where: \.isPlayable) != true || !model.connected)
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error = model.collectionError {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Retry") {
                            Task {
                                guard selectedCollection?.id == selected.id else { return }
                                await model.retryCollection(selected)
                            }
                        }
                        .disabled(model.collectionLoading)
                    }
                    .padding(14)
                    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                }

                if let collection {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(collection.tracks) { track in
                            TrackRow(item: track.musicItem, isCurrent: model.nowPlaying?.id == track.uri,
                                     durationMS: track.durationMS, isPlayable: track.isPlayable) {
                                Task { await model.play(track.musicItem, context: selected) }
                            }
                            .onAppear {
                                Task { await model.loadMoreCollectionIfNeeded(near: track.id) }
                            }
                        }
                    }
                    if collection.tracks.isEmpty && !model.collectionLoading {
                        Text("No songs are available in this collection.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 35)
                    }
                    if collection.nextOffset != nil {
                        Button("Show more songs") {
                            Task { await model.loadMoreCollection() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.collectionLoading)
                        .frame(maxWidth: .infinity)
                    }
                }

                if model.collectionLoading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(collection == nil ? "Loading songs…" : "Loading more songs…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }
            }
            .padding(MusicLayout.contentInset)
        }
        .id(selected.id)
    }

    private var minimalSignIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tops").font(.system(size: 22, weight: .medium))
            Text("Your music. Less noise.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button(model.busy ? "Connecting…" : "Connect Spotify") {
                Task { await model.connect() }
            }
            .disabled(model.busy)
            .font(.system(size: 13, weight: .medium))
            .buttonStyle(.borderless)
            .tint(MusicPalette.spotifyGreen)
            Text("Sign-in opens in your browser.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var signIn: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(MusicPalette.spotifyGreen)
                .padding(.bottom, 7)
            Text("Your music. Less noise.")
                .font(.system(size: 29, weight: .bold))
            Button {
                Task { await model.connect() }
            } label: {
                HStack(spacing: 9) {
                    if model.busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.right")
                    }
                    Text(model.busy ? "Connecting…" : "Connect Spotify")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(MusicPalette.spotifyGreen)
            .foregroundStyle(.black)
            .controlSize(.large)
            .disabled(model.busy)
            .padding(.top, 8)

            Text("Experimental · Personal use\nSign-in opens in your browser.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 14)
        }
        .padding(35)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 31, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.error = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(14)
        .background(Color.orange.opacity(0.09))
    }
}

/// Keep both controls in one stable toolbar slot. Inserting/removing a native
/// toolbar button changes AppKit's layout immediately and can rebuild its view.
private struct CollectionNavigationButtons: View {
    let expanded: Bool
    let canGoBack: Bool
    let back: () -> Void
    let home: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: 28)
            }
            .help("Back")
            .accessibilityLabel("Back")
            .accessibilityHidden(!canGoBack)
            .allowsHitTesting(canGoBack)
            .focusable(canGoBack)
            .opacity(expanded ? 1 : 0)
            .offset(x: expanded ? 0 : -8)

            Button(action: home) {
                Image(systemName: "house")
                    .frame(width: 28, height: 28)
            }
            .help("Made for You")
            .accessibilityLabel("Made for You")
            .offset(x: expanded ? 40 : 0)
        }
        .buttonStyle(CollectionNavigationButtonStyle())
        .font(.system(size: 18))
        .frame(width: 68, height: 28, alignment: .leading)
        .animation(reduceMotion ? nil : CollectionMotion.animation, value: expanded)
    }
}

private struct CollectionNavigationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.72 : 1)
            // A pressed Home button moves away from the pointer. Its press
            // feedback must not inherit the slide/fade animation around it.
            .animation(nil, value: configuration.isPressed)
    }
}

private enum CollectionCoverSpace: Hashable {
    case content
}

private struct CoverFlight {
    let id = UUID()
    let item: MusicItem
    let image: CGImage?
    var frame: CGRect
    var started = false
}

private struct SearchSection: Identifiable {
    let kind: String
    let items: [MusicItem]
    var id: String { kind }
    var title: String {
        switch kind {
        case "track": return "Songs"
        case "playlist": return "Playlists"
        case "album": return "Albums"
        case "artist": return "Artists"
        default: return kind.capitalized
        }
    }
}

private enum ArtworkViewportSpace: Hashable {
    case scrollView
}

private struct ArtworkViewportKey: EnvironmentKey {
    static let defaultValue: CGSize? = nil
}

private extension EnvironmentValues {
    var artworkViewportSize: CGSize? {
        get { self[ArtworkViewportKey.self] }
        set { self[ArtworkViewportKey.self] = newValue }
    }
}

private struct ArtworkScrollView<Content: View>: View {
    let content: Content
    @State private var viewportSize: CGSize = .zero

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            content.environment(\.artworkViewportSize, viewportSize == .zero ? nil : viewportSize)
        }
        .coordinateSpace(name: ArtworkViewportSpace.scrollView)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
    }
}

private struct Artwork: View {
    let url: URL?
    var cornerRadius: CGFloat = 8
    var onImageChange: ((CGImage?) -> Void)?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.artworkViewportSize) private var viewportSize
    @State private var image: CGImage?
    @State private var isInViewport = false

    init(url: URL?, cornerRadius: CGFloat = 8, initialImage: CGImage? = nil,
         onImageChange: ((CGImage?) -> Void)? = nil) {
        self.url = url
        self.cornerRadius = cornerRadius
        self.onImageChange = onImageChange
        _image = State(initialValue: initialImage)
    }

    var body: some View {
        GeometryReader { geometry in
            let request = (viewportSize == nil || isInViewport) ? url.map {
                ArtworkRequest(url: $0, pointSize: max(geometry.size.width, geometry.size.height), displayScale: displayScale)
            } : nil
            Group {
                if let image {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color.primary.opacity(0.045))
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: min(geometry.size.width * 0.24, 36), weight: .light))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .onGeometryChange(for: Bool.self) { proxy in
                guard let viewportSize else { return true }
                return CGRect(origin: .zero, size: viewportSize)
                    .intersects(proxy.frame(in: .named(ArtworkViewportSpace.scrollView)))
            } action: { visible in
                isInViewport = visible
                if !visible { releaseImage() }
            }
            .task(id: request) {
                guard let request else { return }
                do {
                    let thumbnail = try await ArtworkLoader.shared.image(for: request)
                    try Task.checkCancellation()
                    image = thumbnail
                    onImageChange?(thumbnail)
                } catch {
                    // Failed or cancelled artwork keeps the lightweight placeholder.
                }
            }
            .onDisappear { releaseImage() }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }

    private func releaseImage() {
        guard image != nil else { return }
        image = nil
        onImageChange?(nil)
        ArtworkLoader.shared.releaseVisibleImage()
    }
}

private struct MusicCard: View {
    let item: MusicItem
    let isCurrent: Bool
    let action: (CGRect, CGImage?) -> Void
    @State private var hovered = false
    @State private var coverFrame: CGRect = .zero
    @State private var coverImage: CGImage?

    var body: some View {
        Button { action(coverFrame, coverImage) } label: {
            VStack(alignment: .leading, spacing: 9) {
                Artwork(url: item.imageURL, cornerRadius: item.kind == "artist" ? 120 : 9,
                        onImageChange: { coverImage = $0 })
                    .aspectRatio(1, contentMode: .fit)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named(CollectionCoverSpace.content))
                    } action: { coverFrame = $0 }
                    .overlay(alignment: .bottomTrailing) {
                        if hovered || isCurrent {
                            Image(systemName: isCurrent ? "waveform.circle.fill" : (item.kind == "track" ? "play.circle.fill" : "arrow.up.left.circle.fill"))
                                .font(.system(size: 35))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.black, Color.mint)
                                .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                                .padding(10)
                        }
                    }
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCurrent ? Color.mint : Color.primary)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(item.kind == "track" ? "Play" : "Open") \(item.title), \(item.subtitle)")
        .help("\(item.kind == "track" ? "Play" : "Open") \(item.title)")
    }
}

private struct TrackRow: View {
    let item: MusicItem
    let isCurrent: Bool
    var artworkSize: CGFloat = MusicLayout.trackArtworkSize
    var durationMS: Int? = nil
    var isPlayable = true
    let play: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: play) {
            HStack(spacing: 13) {
                Artwork(url: item.imageURL, cornerRadius: 5)
                    .frame(width: artworkSize, height: artworkSize)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isCurrent ? Color.mint : Color.primary)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !isPlayable {
                    Text("Unavailable")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if let durationMS {
                    Text(duration(durationMS))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: isCurrent ? "waveform" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isCurrent ? Color.mint : Color.secondary)
                    .opacity(hovered || isCurrent ? 1 : 0)
                    .padding(.trailing, 9)
            }
            .padding(.vertical, 7)
            .padding(.trailing, 7)
            .background(Color.primary.opacity(hovered ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isPlayable)
        .opacity(isPlayable ? 1 : 0.5)
        .onHover { hovered = $0 }
        .accessibilityLabel("Play \(item.title), \(item.subtitle)")
    }

    private func duration(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct PlaybackBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var playback: PlaybackState
    @State private var seekPosition: Double = 0
    @State private var scrubbing = false

    init(model: AppModel) {
        self.model = model
        self.playback = model.playback
    }

    var body: some View {
        HStack(spacing: 18) {
            Group {
                if model.connected, let nowPlaying = model.nowPlaying {
                    HStack(spacing: 11) {
                        Artwork(url: nowPlaying.imageURL, cornerRadius: 6)
                            .frame(width: MusicLayout.trackArtworkSize, height: MusicLayout.trackArtworkSize)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(nowPlaying.title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text(nowPlaying.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Color.clear
                }
            }
            .frame(width: 245, height: MusicLayout.trackArtworkSize, alignment: .leading)
            .accessibilityHidden(!model.connected || model.nowPlaying == nil)

            HStack(spacing: 16) {
                transportButton("backward.end.fill", label: "Previous track") {
                    await model.previous()
                }
                Button {
                    Task { await model.togglePlayback() }
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 33))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                .help(playback.isPlaying ? "Pause" : "Play")
                .disabled(!model.connected || model.nowPlaying == nil)

                transportButton("forward.end.fill", label: "Next track") {
                    await model.next()
                }
            }

            HStack(spacing: 8) {
                Text(time(scrubbing ? seekPosition : playback.positionMS))
                    .frame(width: 35, alignment: .trailing)
                Slider(value: $seekPosition, in: 0...max(playback.durationMS, 1)) { editing in
                    scrubbing = editing
                    if !editing {
                        let target = seekPosition
                        Task { await model.seek(target) }
                    }
                }
                .controlSize(.mini)
                .tint(MusicPalette.spotifyGreen)
                .disabled(model.nowPlaying == nil || playback.durationMS <= 0)
                .accessibilityLabel("Playback position")
                Text(time(playback.durationMS))
                    .frame(width: 35, alignment: .leading)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Image(systemName: playback.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { playback.volume }, set: { model.setVolume($0) }), in: 0...100)
                .controlSize(.mini)
                .tint(MusicPalette.spotifyGreen)
                .disabled(!playback.volumeAvailable)
                .help(playback.volumeAvailable ? "System volume" : "This output device does not support system volume control")
                .accessibilityLabel("System volume")
                .accessibilityValue(playback.volumeAvailable ? "\(Int(playback.volume.rounded())) percent" : "Unavailable for this output device")
            }
            .frame(width: 122)
        }
        .padding(.horizontal, MusicLayout.contentInset)
        .padding(.vertical, 14)
        .background(.bar)
        .onAppear {
            seekPosition = max(0, min(playback.positionMS, playback.durationMS))
        }
        .onChange(of: playback.positionMS) { _, value in
            if !scrubbing { seekPosition = max(0, min(value, playback.durationMS)) }
        }
        .onChange(of: playback.durationMS) { _, value in
            seekPosition = max(0, min(seekPosition, value))
        }
    }

    private func transportButton(_ symbol: String, label: String, action: @escaping @MainActor () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .padding(3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
        .disabled(!model.connected || model.nowPlaying == nil)
    }

    private func time(_ milliseconds: Double) -> String {
        guard milliseconds.isFinite else { return "0:00" }
        let seconds = max(0, Int(milliseconds / 1_000))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
