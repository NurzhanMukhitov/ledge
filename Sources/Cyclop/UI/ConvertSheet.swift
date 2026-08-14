import SwiftUI

/// What the picker hands back once a rung is chosen. The work itself belongs to
/// the pane: encoding a video outlives this view, and a `Task` started here
/// would be cancelled the moment the list disappears.
enum ConvertChoice {
    case image(Converter.Variant)
    case video(VideoConverter.Rung)
}

/// The compression picker: rungs chosen by weight rather than by setting.
///
/// A quality slider would say "72%", which tells nobody anything — the same
/// number lands at 200 KB on a screenshot and 3 MB on a photograph. So the
/// answers are worked out first and the user picks from what came out.
///
/// Pictures and video differ in one honest way. A picture is encoded three
/// times up front, so its numbers are measured. A video would take minutes to
/// encode three times, so its numbers are bitrate times duration — arithmetic,
/// marked `≈`, and never dressed up as measurement.
///
/// Sits over the shelf rather than in a window: the panel never activates, so a
/// sheet or a modal has nowhere to appear.
struct ConvertSheet: View {
    let url: URL
    let onPick: (ConvertChoice) -> Void
    let onCancel: () -> Void

    private struct Row: Identifiable {
        let id = UUID()
        let label: String
        let size: String
        let estimated: Bool
        let choice: ConvertChoice
    }

    @State private var rows: [Row] = []
    @State private var failed = false
    @State private var hovered: UUID?
    @State private var original: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if failed {
                Text(localized("Nothing to compress here."))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            } else if rows.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBox(cornerRadius: 8).frame(height: 26)
                }
            } else {
                ForEach(rows) { row in
                    self.row(row)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .task {
            original = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if VideoConverter.isVideo(url) {
                rows = await VideoConverter.rungs(for: url).map {
                    Row(label: $0.label, size: Converter.size($0.estimate), estimated: true, choice: .video($0))
                }
            } else {
                rows = await Converter.variants(for: url).map {
                    Row(label: $0.label, size: Converter.size($0.bytes), estimated: false, choice: .image($0))
                }
            }
            failed = rows.isEmpty
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(url.lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let original {
                Text(Converter.size(original))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Button { onCancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func row(_ row: Row) -> some View {
        Button { onPick(row.choice) } label: {
            HStack(spacing: 8) {
                Text(row.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Text(row.estimated ? "≈ \(row.size)" : row.size)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .monospacedDigit()
                if let change = change(row) {
                    Text(change)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered == row.id ? Theme.surfaceHover : Theme.surface)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? row.id : nil }
        .animation(Theme.contentAnimation, value: hovered)
    }

    /// "−79%", and "+4%" when a rung came out heavier than the original.
    ///
    /// That happens on files already compressed once, and hiding it would be
    /// the one case where the picker lies: the row would read as a saving while
    /// handing over a bigger file.
    private func change(_ row: Row) -> String? {
        guard let original, original > 0 else { return nil }
        let bytes: Int
        switch row.choice {
        case .image(let variant): bytes = variant.bytes
        case .video(let rung): bytes = rung.estimate
        }
        let delta = Double(bytes - original) / Double(original) * 100
        let rounded = Int(delta.rounded())
        guard rounded != 0 else { return "0%" }
        return rounded < 0 ? "−\(-rounded)%" : "+\(rounded)%"
    }
}
