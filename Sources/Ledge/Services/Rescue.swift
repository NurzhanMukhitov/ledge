import AVFoundation
import Foundation

/// The formats macOS refuses to open at all — WMV, MKV, FLV, WebM.
///
/// Everything the system can read goes through AVFoundation, as it always has.
/// This exists only for the gap `AVURLAsset.audiovisualTypes()` leaves, and it
/// closes it the same way MP3 was closed: a binary inside the bundle, so nobody
/// receiving this build has to install anything.
///
/// Run as a separate process rather than linked. ffmpeg here is LGPL, Ledge is
/// MIT, and a process boundary means there is no linking to argue about at all.
enum Rescue {

    /// The bundled binary, or `nil` in a build assembled without it — in which
    /// case the unreadable formats simply stay unreadable and say so.
    static var tool: URL? {
        guard let url = Bundle.main.url(forResource: "ffmpeg", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path)
        else { return nil }
        return url
    }

    static var isAvailable: Bool { tool != nil }

    /// Re-wraps an unreadable file as MP4 that AVFoundation can then work on.
    ///
    /// The picture is re-encoded because the codec is the problem, not the
    /// container — and it goes through `h264_videotoolbox`, the same hardware
    /// encoder the rest of the app uses. Sound becomes AAC.
    static func toMP4(_ url: URL, to out: URL, progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        await run([
            "-i", url.path,
            "-c:v", "h264_videotoolbox", "-b:v", "6M",
            "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart",
            out.path,
        ], producing: out, progress: progress, of: url)
    }

    /// Sound only, straight to AAC in an m4a.
    static func toM4A(_ url: URL, to out: URL, progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        await run(["-i", url.path, "-vn", "-c:a", "aac", "-b:a", "192k", out.path],
                  producing: out, progress: progress, of: url)
    }

    /// Sound as raw PCM in a wav, which `MP3Encoder` then turns into an MP3.
    ///
    /// Two steps rather than asking ffmpeg for the MP3 directly: its LAME
    /// support would have to be compiled in, and LAME is already here. One copy
    /// of one encoder, used by both paths.
    static func toWAV(_ url: URL, to out: URL, progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        await run(["-i", url.path, "-vn", "-c:a", "pcm_s16le", "-ar", "44100", "-ac", "2", out.path],
                  producing: out, progress: progress, of: url)
    }

    /// MP3 in two steps: the tool decodes to a temporary wav, `MP3Encoder`
    /// encodes that. The alternative was compiling LAME into ffmpeg as well,
    /// which would put a second copy of the same encoder in the bundle.
    static func toMP3(_ url: URL, to out: URL, progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Decoding is the long half, so it owns most of the bar; the encode that
        // follows is quick and finishes it.
        guard await toWAV(url, to: scratch, progress: { progress($0 * 0.8) }) else { return false }
        guard await VideoConverter.extractMP3(scratch, to: out) else { return false }
        progress(1)
        return true
    }

    /// Runs the tool, reporting how far along it is.
    ///
    /// Progress comes off `-progress pipe:1`, which prints `out_time_us=` lines
    /// as it goes. Parsing the human-readable output instead would break the
    /// first time the format of that output changed.
    private static func run(
        _ arguments: [String],
        producing out: URL,
        progress: @escaping @Sendable (Double) -> Void,
        of source: URL
    ) async -> Bool {
        guard let tool else { return false }

        let seconds = CMTimeGetSeconds((try? await AVURLAsset(url: source).load(.duration)) ?? .zero)
        let total = seconds.isFinite && seconds > 0 ? seconds : 0

        let process = Process()
        process.executableURL = tool
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                             "-progress", "pipe:1"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do { try process.run() } catch {
            NSLog("Ledge: ffmpeg failed to start: \(error.localizedDescription)")
            return false
        }

        // Cancelling the task has to reach the process, which knows nothing
        // about Swift concurrency: terminate it, and the read below ends.
        let watchdog = Task {
            while process.isRunning {
                if Task.isCancelled { process.terminate(); return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { watchdog.cancel() }

        var buffer = ""
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
            buffer += String(decoding: chunk, as: UTF8.self)
            while let line = buffer.firstIndex(of: "\n") {
                let text = String(buffer[..<line])
                buffer = String(buffer[buffer.index(after: line)...])
                if total > 0, text.hasPrefix("out_time_us=") ,
                   let value = Double(text.dropFirst("out_time_us=".count)) {
                    progress(min(value / 1_000_000 / total, 1))
                }
            }
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0, !Task.isCancelled else {
            try? FileManager.default.removeItem(at: out)
            return false
        }
        progress(1)
        return true
    }
}
