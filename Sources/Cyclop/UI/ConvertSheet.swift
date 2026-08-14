import SwiftUI

/// The compression picker: three finished files, chosen by their weight.
///
/// It shows results rather than a setting. A quality slider would say "72%",
/// which tells nobody anything — the same number lands at 200 KB on a
/// screenshot and 3 MB on a photograph. So the encoding is done first and the
/// user picks from what came out.
///
/// Sits over the shelf rather than in a window: the panel never activates, so
/// a sheet or a modal has nowhere to appear.
struct ConvertSheet: View {
    let url: URL
    let onPick: (Converter.Variant) -> Void
    let onCancel: () -> Void

    @State private var variants: [Converter.Variant] = []
    @State private var hovered: UUID?

    /// Read once, on appear. The shelf's rule is that disk access waits for the
    /// user to ask, and opening this is the asking.
    @State private var original: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if variants.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBox(cornerRadius: 8).frame(height: 26)
                }
            } else {
                ForEach(variants) { variant in
                    row(variant)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .task {
            original = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            variants = await Converter.variants(for: url)
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

    private func row(_ variant: Converter.Variant) -> some View {
        Button { onPick(variant) } label: {
            HStack(spacing: 8) {
                Text(variant.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Text(Converter.size(variant.bytes))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .monospacedDigit()
                if let change = change(variant) {
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
                    .fill(hovered == variant.id ? Theme.surfaceHover : Theme.surface)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? variant.id : nil }
        .animation(Theme.contentAnimation, value: hovered)
    }

    /// "−79%", and "+4%" when a rung came out heavier than the original.
    ///
    /// That happens on files already compressed once, and hiding it would be
    /// the one case where the picker lies: the row would read as a saving while
    /// handing over a bigger file.
    private func change(_ variant: Converter.Variant) -> String? {
        guard let original, original > 0 else { return nil }
        let delta = Double(variant.bytes - original) / Double(original) * 100
        let rounded = Int(delta.rounded())
        guard rounded != 0 else { return "0%" }
        return rounded < 0 ? "−\(-rounded)%" : "+\(rounded)%"
    }
}
