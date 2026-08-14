import SwiftUI

struct ShelfPane: View {
    @ObservedObject var shelf: ShelfStore
    var isTargeted: Bool

    /// Which card the pointer is over — decided by the pane, not by the cards.
    ///
    /// Per-card `onHover` breaks on the shelf's most repetitive gesture:
    /// deleting cards one after another. Hover events are made of mouse
    /// movement, and when a deleted card's neighbour slides under a pointer
    /// that has not moved, there are no events — the neighbour never learns it
    /// is hovered, its ✕ never appears, and the click meant to delete it
    /// selects it instead, until a stray wiggle of the mouse fixes everything.
    /// So the pane tracks the pointer and every card's frame itself, and
    /// re-decides on either change: the pointer moving, or the cards moving
    /// under it. Scrolling the strip is the same case and heals the same way.
    @State private var hoveredID: UUID?
    @State private var hoverPoint: CGPoint?
    @State private var frames: [UUID: CGRect] = [:]

    /// The file whose compression rungs are on screen. Non-nil replaces the
    /// strip rather than covering it: the panel is 159 points tall under the
    /// notch, and a picker floating over the cards would have to shrink to fit
    /// beside them for no gain — nobody drags a card while choosing a rung.
    @State private var compressing: URL?

    var body: some View {
        VStack(spacing: 0) {
            if let compressing {
                ConvertSheet(
                    url: compressing,
                    onPick: { choice in
                        let source = compressing
                        self.compressing = nil
                        // Owned by the pane, not by the picker: a video encode
                        // runs for minutes, and a task started inside the list
                        // would die the moment the list closed behind it.
                        Task {
                            switch choice {
                            case .image(let variant):
                                // Instant: the bytes were encoded to be shown in
                                // the list, so there is nothing left to wait for.
                                if let produced = await Task.detached(
                                    operation: { Converter.save(variant, from: source) }
                                ).value {
                                    shelf.add([produced])
                                }
                            case .video(let rung):
                                guard let out = VideoConverter.output(
                                    for: source, prefix: rung.prefix, ext: "mp4"
                                ) else { return }
                                let id = shelf.reserve(out, determinate: true)
                                shelf.attach(id, Task {
                                    let done = await VideoConverter.compress(
                                        source, to: rung, output: out
                                    ) { fraction in
                                        Task { @MainActor in shelf.advance(id, to: fraction) }
                                    }
                                    done ? shelf.complete(id) : shelf.abandon(id)
                                })
                            }
                        }
                    },
                    onCancel: { self.compressing = nil }
                )
            } else if shelf.items.isEmpty {
                dropHint
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items) { item in
                            ShelfCard(
                                item: item,
                                shelf: shelf,
                                isHovered: hoveredID == item.id,
                                onCompress: { compressing = $0 }
                            )
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: CardFramesKey.self,
                                            value: [item.id: geo.frame(in: .named("shelf"))]
                                        )
                                    }
                                )
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(maxHeight: .infinity)
                }
                .coordinateSpace(name: "shelf")
                .onContinuousHover(coordinateSpace: .named("shelf")) { phase in
                    switch phase {
                    case .active(let point):
                        hoverPoint = point
                        rehit()
                    case .ended:
                        hoverPoint = nil
                        hoveredID = nil
                    }
                }
                .onPreferenceChange(CardFramesKey.self) { new in
                    frames = new
                    rehit()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
        }
        .padding(.top, 2)
    }

    /// The one decision both signals feed: which frame holds the last known
    /// pointer position.
    private func rehit() {
        guard let hoverPoint else { return }
        hoveredID = frames.first(where: { $0.value.contains(hoverPoint) })?.key
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                isTargeted ? Color.white.opacity(0.6) : Theme.hairline,
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isTargeted ? Theme.surface : .clear)
            )
            .overlay(
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(isTargeted ? .white : Theme.tertiary)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Theme.contentAnimation, value: isTargeted)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !shelf.selection.isEmpty {
                Text(localized("Selected: %d", shelf.selection.count))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer()
            if !shelf.selection.isEmpty {
                Button("Deselect") { shelf.clearSelection() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            Button("Clear") { shelf.clear() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.top, 2)
    }
}

private struct CardFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct ShelfCard: View {
    let item: ShelfItem
    @ObservedObject var shelf: ShelfStore
    /// Handed down from the pane, which is the one place that can know it
    /// correctly when cards move under a stationary pointer.
    let isHovered: Bool
    /// Raised to the pane: the rungs need the whole body to list themselves in,
    /// which a card 86 points wide does not have.
    let onCompress: (URL) -> Void

    private var isSelected: Bool { shelf.isSelected(item) }

    /// What a conversion would act on: the selection when this card belongs to
    /// it, otherwise this card alone — the same rule dragging follows, so the
    /// menu and the mouse never disagree about what "this" means.
    private var scope: [URL] { shelf.dragURLs(startingAt: item) }

    var body: some View {
        VStack(spacing: 6) {
            // Fit, not fill: a screenshot is landscape and a file icon is
            // square, and forcing either into the other's box is what squashed
            // the wide ones. The box is wide enough for a 16:10 frame, so a
            // square icon simply centres in it.
            Image(nsImage: item.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 68, height: 40)
            // The name and what it is are one block, tight together, so the
            // gap that separates them from the picture stays the only gap on
            // the card — three evenly spaced rows read as three unrelated
            // things rather than a picture with a caption.
            VStack(spacing: 1) {
                Text(item.name)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 24, alignment: .top)
                Text(item.meta)
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
        }
        // Dimmed, not greyed out: the card is a placeholder for a file that
        // does not exist yet, and it should read as one at a glance across a
        // strip of real ones.
        .opacity(item.isPending ? 0.45 : 1)
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(width: 86, height: 102)
        .overlay(alignment: .bottom) {
            // Only where the number is real. A bar that cannot move would be a
            // decoration pretending to be an instrument.
            if let progress = item.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hairline)
                        Capsule().fill(Color.white.opacity(0.7))
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 2)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .animation(Theme.contentAnimation, value: progress)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.18) : (isHovered ? Theme.surfaceHover : Theme.surface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(isSelected ? 0.55 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        // Owns clicks and drags: a group drag needs one dragging item per file,
        // which SwiftUI's onDrag cannot express. It must stay *below* the close
        // button, otherwise it swallows every click aimed at it.
        // No drag source while the file is being made: dragging it into Finder
        // would hand over a path to nothing, and double-clicking would open the
        // same nothing.
        .overlay {
            if !item.isPending {
                ShelfDragSource(
                    urls: { shelf.dragURLs(startingAt: item) },
                    onClick: { modifiers in shelf.select(item, modifiers: modifiers) },
                    onDoubleClick: { shelf.open(item) }
                )
            }
        }
        .overlay(alignment: .topLeading) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .padding(4)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            if item.isPending {
                // Everything else acts on a file, and there is not one yet.
                Button("Cancel") { shelf.remove(item) }
            } else {
            Button("Copy") { shelf.copy(item) }
            Button("Open") { shelf.open(item) }
            Button("Show in Finder") { shelf.reveal(item) }
            // Converting lives in the menu rather than on the card: it is a
            // thing done to a file now and then, not a thing looked at, and
            // every pixel spent on it would come off the preview — which is
            // what makes the shelf readable at a glance.
            if Converter.isImage(item.url) {
                Divider()
                if !Converter.isJPEG(item.url) {
                    let url = item.url
                    Button("To JPEG") { convert { Converter.toJPEG(url) } }
                }
                Button("Compress…") { onCompress(item.url) }
                let images = scope.filter(Converter.isImage)
                Button("To PDF") { convert { Converter.imagesToPDF(images) } }
                let url = item.url
                Button("Remove Metadata") { convert { Converter.stripMetadata(url) } }
            }
            // Video goes through AVFoundation, which every Mac already has —
            // the same VideoToolbox encoder ffmpeg would have driven, without
            // asking anyone to install it. MP3 is the one exception, and it is
            // hidden rather than broken when the bundle was built without LAME.
            if VideoConverter.isVideo(item.url) {
                Divider()
                let url = item.url
                if !VideoConverter.isMP4(url) {
                    Button("To MP4") {
                        run(url, prefix: "MP4", ext: "mp4") { await VideoConverter.toMP4(url, to: $0) }
                    }
                }
                Button("Compress…") { onCompress(url) }
                Button("Audio (m4a)") {
                    run(url, prefix: localized("Audio"), ext: "m4a") { await VideoConverter.extractM4A(url, to: $0) }
                }
                if MP3Encoder.isAvailable {
                    Button("Audio (mp3)") {
                        run(url, prefix: localized("Audio"), ext: "mp3") { await VideoConverter.extractMP3(url, to: $0) }
                    }
                }
            }
            Divider()
            Button("Remove from Shelf") { shelf.remove(item) }
            }
        }
        .animation(Theme.contentAnimation, value: isHovered)
        .animation(Theme.contentAnimation, value: isSelected)
    }

    /// Runs the conversion off the main actor and lands the result on the shelf.
    ///
    /// Detached because decoding and re-encoding a 40-megapixel photo takes
    /// long enough to be felt: on the main actor it would freeze the panel
    /// mid-hover, and the panel closes when the pointer leaves it.
    private func convert(_ work: @escaping @Sendable () -> URL?) {
        Task {
            guard let produced = await Task.detached(priority: .userInitiated, operation: work).value else { return }
            shelf.add([produced])
        }
    }

    /// Video work: the card goes up first, the file arrives into it.
    ///
    /// The name is settled before anything starts, because a card has to be
    /// called something and because the result must not land on a name some
    /// other conversion has taken in the meantime. Failure removes the card
    /// rather than leaving it stuck: the file it named was never made.
    private func run(
        _ source: URL,
        prefix: String,
        ext: String,
        _ work: @escaping (URL) async -> Bool
    ) {
        guard let out = VideoConverter.output(for: source, prefix: prefix, ext: ext) else { return }
        // Remux and audio extraction happen inside one system call that does not
        // report back, so their cards show an ellipsis rather than a number.
        let id = shelf.reserve(out, determinate: false)
        shelf.attach(id, Task {
            await work(out) ? shelf.complete(id) : shelf.abandon(id)
        })
    }
}
