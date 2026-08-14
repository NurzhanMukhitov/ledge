import AVFoundation
import UniformTypeIdentifiers

/// Video on the shelf: repackaged, made smaller, or reduced to its soundtrack.
///
/// AVFoundation throughout, so nothing has to be installed and nothing has to be
/// shipped — the hardware encoder it reaches is the same VideoToolbox one
/// `ffmpeg` would have driven. The single exception is MP3, which macOS cannot
/// write; `MP3Encoder` carries that.
///
/// Every entry point takes the destination it is to write and answers whether it
/// managed. The name is decided before the work starts because the shelf shows a
/// card for the file while it is still being made, and a card has to be called
/// something.
enum VideoConverter {

    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    static func isMP4(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .mpeg4Movie)
    }

    static func output(for url: URL, prefix: String, ext: String) -> URL? {
        Converter.destination(named: url.deletingPathExtension().lastPathComponent, prefix: prefix, ext: ext)
    }

    // MARK: - To MP4

    /// Repackaging, not re-encoding.
    ///
    /// A QuickTime screen recording is already H.264 sitting in a `.mov`, and
    /// what makes it awkward to send is the container, not the codec. Passthrough
    /// rewrites the container in seconds and loses nothing; re-encoding it to
    /// reach the same place would cost minutes and a generation of quality.
    static func toMP4(_ url: URL, to out: URL) async -> Bool {
        await export(AVURLAsset(url: url), preset: AVAssetExportPresetPassthrough, to: out, as: .mp4)
    }

    /// AAC in an m4a, straight out of AVFoundation.
    static func extractM4A(_ url: URL, to out: URL) async -> Bool {
        await export(AVURLAsset(url: url), preset: AVAssetExportPresetAppleM4A, to: out, as: .m4a)
    }

    /// Handed to the system whole, which is why neither of these reports a
    /// percentage: the work happens inside one call that returns when it is done.
    private static func export(_ asset: AVURLAsset, preset: String, to out: URL, as type: AVFileType) async -> Bool {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return false }
        do {
            try await session.export(to: out, as: type)
            return true
        } catch {
            NSLog("Cyclop: export failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: out)
            return false
        }
    }

    // MARK: - Compress

    /// A rung of the ladder, described but not yet encoded.
    ///
    /// Unlike the picture ladder, these sizes are arithmetic rather than
    /// measurement: bitrate times duration. Encoding a four-minute recording
    /// three times to put three true numbers on screen would cost minutes of
    /// waiting to make one choice. The estimate is good because the encoder is
    /// being told the bitrate rather than asked for a quality — but it is an
    /// estimate, and the picker says so with a `≈` the picture ladder never
    /// shows.
    struct Rung: Identifiable, Sendable {
        let id = UUID()
        let label: String
        let prefix: String
        let videoBitrate: Int
        let estimate: Int
    }

    private static let audioBitrate = 128_000

    static func rungs(for url: URL) async -> [Rung] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration),
              let rate = try? await track.load(.estimatedDataRate)
        else { return [] }

        let seconds = CMTimeGetSeconds(duration)
        guard seconds > 0, rate > 0 else { return [] }

        // Shares of the source rate rather than fixed numbers: a 4K capture and
        // a phone clip need wildly different absolute bitrates to land in the
        // same place, and the source's own rate already encodes that.
        let steps: [(String, String, Double)] = [
            (localized("Light"), localized("Compressed light"), 0.60),
            (localized("Medium"), localized("Compressed medium"), 0.30),
            (localized("Strong"), localized("Compressed strong"), 0.15),
        ]
        return steps.map { label, prefix, share in
            let video = Int(Double(rate) * share)
            let bytes = Int(Double(video + audioBitrate) / 8 * seconds)
            return Rung(label: label, prefix: prefix, videoBitrate: video, estimate: bytes)
        }
    }

    /// Re-encodes, reporting how far along it is and stopping when told to.
    ///
    /// This is the one operation long enough to need both. A four-gigabyte
    /// recording is minutes of work, and the panel folds away the moment the
    /// pointer leaves it — so the progress goes to the card, which survives the
    /// fold, and cancellation exists because minutes is long enough to change
    /// your mind.
    static func compress(
        _ url: URL,
        to rung: Rung,
        output out: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await videoTrack.load(.naturalSize),
              let duration = try? await asset.load(.duration),
              let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: out, fileType: .mp4)
        else { return false }

        let seconds = CMTimeGetSeconds(duration)

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        guard reader.canAdd(videoOutput) else { return false }
        reader.add(videoOutput)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(abs(size.width)),
            AVVideoHeightKey: Int(abs(size.height)),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: rung.videoBitrate],
        ])
        videoInput.expectsMediaDataInRealTime = false
        // The source's own rotation is metadata, not pixels. Dropped, a video
        // shot on a phone comes out on its side.
        if let transform = try? await videoTrack.load(.preferredTransform) {
            videoInput.transform = transform
        }
        guard writer.canAdd(videoInput) else { return false }
        writer.add(videoInput)

        // Audio is optional: a screen recording made without a microphone has
        // no audio track at all, and demanding one would fail the whole run.
        var audioPair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
            )
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audioPair = (output, input)
            }
        }

        guard reader.startReading(), writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        // Both tracks are drained at once, and this is not an optimisation.
        // `AVAssetReader` decodes a shared window across all of its outputs: read
        // one to the end while the other is untouched, and the window fills with
        // audio nobody is collecting, the video output stops yielding, and the
        // whole run stands still at nought per cent using no CPU at all. Short
        // clips hide it — the window is big enough to hold the whole file — so
        // it only appears on the recordings long enough to matter.
        //
        // Only the picture drives the bar. The soundtrack finishes in a fraction
        // of the time, and letting it push the number about would read as the
        // work restarting.
        let report: @Sendable (Double) -> Void = { time in
            guard seconds > 0 else { return }
            progress(time / seconds)
        }
        // Bound before the concurrent reads so neither task is reading a var
        // the other could still be assigning.
        let audio = audioPair
        async let videoDone = pump(videoOutput, into: videoInput, reader: reader, report: report)
        async let audioDone = pumpOptional(audio, reader: reader)
        let videoFinished = await videoDone
        let audioFinished = await audioDone
        let finished = videoFinished && audioFinished

        guard finished, reader.status != .failed else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: out)
            return false
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            return false
        }
        progress(1)
        return true
    }

    /// The audio half of the pair, when there is one. A separate function only
    /// because `async let` needs a call to start, not an optional to unwrap.
    private static func pumpOptional(
        _ pair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?,
        reader: AVAssetReader
    ) async -> Bool {
        guard let pair else { return true }
        return await pump(pair.0, into: pair.1, reader: reader, report: nil)
    }

    /// Moves every sample of one track across, waiting when the writer is full.
    /// Answers `false` if the run was cancelled.
    ///
    /// The wait is a sleep rather than a spin: this runs off the main actor for
    /// minutes at a time, and a busy loop would hold a core the encoder itself
    /// wants.
    private static func pump(
        _ output: AVAssetReaderTrackOutput,
        into input: AVAssetWriterInput,
        reader: AVAssetReader,
        report: (@Sendable (Double) -> Void)?
    ) async -> Bool {
        var lastPercent = -1
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                return false
            }
            while !input.isReadyForMoreMediaData {
                if Task.isCancelled {
                    reader.cancelReading()
                    return false
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            input.append(sample)

            if let report {
                // Reported only when the whole number changes. At sixty frames
                // a second this is otherwise sixty published updates a second,
                // each one redrawing a card to say the same thing.
                let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                let percent = Int(time)
                if percent != lastPercent {
                    lastPercent = percent
                    report(time)
                }
            }
        }
        input.markAsFinished()
        return true
    }

    // MARK: - Audio to MP3

    /// PCM out of AVFoundation, MP3 out of LAME.
    ///
    /// Nothing in the system can do the second half, so the audio is decoded to
    /// raw samples here and handed over frame by frame rather than written to a
    /// temporary wav first — a two-hour recording would otherwise want a
    /// gigabyte of scratch space to produce sixty megabytes of output.
    static func extractMP3(_ url: URL, to out: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard MP3Encoder.isAvailable,
              let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset)
        else { return false }

        let sampleRate = 44_100
        let channels = 2
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return false }
        reader.add(output)

        guard let encoder = MP3Encoder(sampleRate: sampleRate, channels: channels),
              reader.startReading(),
              FileManager.default.createFile(atPath: out.path, contents: nil),
              let file = try? FileHandle(forWritingTo: out)
        else { return false }
        defer { try? file.close() }

        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                buffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer
            ) == noErr, let pointer else { continue }

            // Frames, not values: the buffer is interleaved, so its `Int16`
            // count divides by the channel count to give what LAME calls
            // samples. Passing the raw count encodes half the audio at double
            // speed.
            let frames = length / MemoryLayout<Int16>.size / channels
            let data = pointer.withMemoryRebound(to: Int16.self, capacity: length / MemoryLayout<Int16>.size) {
                encoder.encode($0, samples: frames)
            }
            if !data.isEmpty { file.write(data) }
        }

        guard reader.status != .failed else {
            try? FileManager.default.removeItem(at: out)
            return false
        }
        let tail = encoder.finish()
        if !tail.isEmpty { file.write(tail) }
        return true
    }
}
