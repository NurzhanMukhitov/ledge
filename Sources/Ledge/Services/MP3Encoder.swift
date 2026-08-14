import Foundation

/// MP3, which macOS cannot write on its own.
///
/// `afconvert -f MPG3` answers `fmt?`: the system decodes MP3 everywhere and
/// encodes it nowhere. AAC is the native answer and a better codec at the same
/// size, but "give me an mp3" is a real requirement that m4a does not satisfy —
/// so LAME rides inside the bundle.
///
/// Loaded with `dlopen` rather than linked, and that is a licence decision
/// before it is a technical one. LAME is LGPL, Ledge is MIT; dynamic loading
/// keeps them compatible, static linking would not. It also buys graceful
/// degradation: a build assembled without the library still runs, and simply
/// does not offer MP3.
private struct LAME {
    let handle: UnsafeMutableRawPointer

    let initialise: @convention(c) () -> OpaquePointer?
    let setSampleRate: @convention(c) (OpaquePointer?, Int32) -> Int32
    let setChannels: @convention(c) (OpaquePointer?, Int32) -> Int32
    let setBitrate: @convention(c) (OpaquePointer?, Int32) -> Int32
    let setQuality: @convention(c) (OpaquePointer?, Int32) -> Int32
    let initParams: @convention(c) (OpaquePointer?) -> Int32
    let encode: @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int16>?, Int32, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    let flush: @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    let close: @convention(c) (OpaquePointer?) -> Int32

    /// Resolved once. A failure here is not an error to report anywhere: it
    /// means this build has no MP3, which the menu asks about before offering
    /// the item.
    static let shared: LAME? = {
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("libmp3lame.dylib"),
              let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL)
        else { return nil }

        func symbol<T>(_ name: String) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }

        guard let initialise: @convention(c) () -> OpaquePointer? = symbol("lame_init"),
              let setSampleRate: @convention(c) (OpaquePointer?, Int32) -> Int32 = symbol("lame_set_in_samplerate"),
              let setChannels: @convention(c) (OpaquePointer?, Int32) -> Int32 = symbol("lame_set_num_channels"),
              let setBitrate: @convention(c) (OpaquePointer?, Int32) -> Int32 = symbol("lame_set_brate"),
              let setQuality: @convention(c) (OpaquePointer?, Int32) -> Int32 = symbol("lame_set_quality"),
              let initParams: @convention(c) (OpaquePointer?) -> Int32 = symbol("lame_init_params"),
              let encode: @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int16>?, Int32, UnsafeMutablePointer<UInt8>?, Int32) -> Int32 = symbol("lame_encode_buffer_interleaved"),
              let flush: @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32 = symbol("lame_encode_flush"),
              let close: @convention(c) (OpaquePointer?) -> Int32 = symbol("lame_close")
        else {
            dlclose(handle)
            return nil
        }

        return LAME(
            handle: handle, initialise: initialise, setSampleRate: setSampleRate,
            setChannels: setChannels, setBitrate: setBitrate, setQuality: setQuality,
            initParams: initParams, encode: encode, flush: flush, close: close
        )
    }()
}

/// Interleaved 16-bit PCM in, MP3 frames out.
final class MP3Encoder {
    /// Whether this build can make an MP3 at all.
    static var isAvailable: Bool { LAME.shared != nil }

    private let lame: LAME
    private let flags: OpaquePointer
    private let channels: Int

    init?(sampleRate: Int, channels: Int, bitrate: Int = 192) {
        guard let lame = LAME.shared, let flags = lame.initialise() else { return nil }
        _ = lame.setSampleRate(flags, Int32(sampleRate))
        _ = lame.setChannels(flags, Int32(channels))
        _ = lame.setBitrate(flags, Int32(bitrate))
        // 2 is LAME's "high quality, still quick". 0 is slower for a difference
        // nobody extracting a soundtrack is going to hear.
        _ = lame.setQuality(flags, 2)
        guard lame.initParams(flags) >= 0 else {
            _ = lame.close(flags)
            return nil
        }
        self.lame = lame
        self.flags = flags
        self.channels = channels
    }

    deinit { _ = lame.close(flags) }

    /// `samples` counts frames, not values: for stereo the buffer holds twice
    /// that many `Int16`s. Getting this wrong encodes half the audio at double
    /// speed, which is the classic way this call goes wrong.
    func encode(_ pcm: UnsafeMutablePointer<Int16>, samples: Int) -> Data {
        // LAME's own worst case, from its documentation: the output can exceed
        // the input on pathological frames, so the buffer is sized for it
        // rather than for the average.
        var out = [UInt8](repeating: 0, count: Int(Double(samples) * 1.25) + 7200)
        let written = out.withUnsafeMutableBufferPointer { buffer in
            lame.encode(flags, pcm, Int32(samples), buffer.baseAddress, Int32(buffer.count))
        }
        guard written > 0 else { return Data() }
        return Data(out[0..<Int(written)])
    }

    /// The last frames, plus the VBR tag LAME wants to write. Skipping this
    /// leaves a file that plays but reports the wrong duration.
    func finish() -> Data {
        var out = [UInt8](repeating: 0, count: 7200)
        let written = out.withUnsafeMutableBufferPointer { buffer in
            lame.flush(flags, buffer.baseAddress, Int32(buffer.count))
        }
        guard written > 0 else { return Data() }
        return Data(out[0..<Int(written)])
    }
}
