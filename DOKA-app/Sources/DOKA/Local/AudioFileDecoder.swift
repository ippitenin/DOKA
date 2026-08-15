import Foundation
import AVFoundation

/// Извлечение звуковой дорожки из аудио/видеофайла в WAV 16 кГц mono Int16
/// (формат `WavWriter`) — единый вход локальных движков: нормализует и
/// mp3/m4a/flac, и видеоконтейнеры mp4/mov, которые сами движки не читают.
/// Сервер Nexara декодирует видео на своей стороне — локально это наша работа.
enum AudioFileDecoder {
    enum DecoderError: LocalizedError {
        case noAudioTrack
        case readFailed

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return L("transcribe.local.noAudioTrack")
            case .readFailed: return L("transcribe.error.readFailed")
            }
        }
    }

    /// Декодирует файл во временный WAV; вызывающий удаляет файл сам.
    /// Работа идёт в отвязанной задаче (не блокирует главный поток),
    /// отмена внешней задачи пробрасывается внутрь.
    static func decodeToWav(_ sourceURL: URL) async throws -> (url: URL, duration: TimeInterval) {
        let worker = Task.detached(priority: .userInitiated) {
            try await decodeWork(sourceURL)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func decodeWork(_ sourceURL: URL) async throws -> (url: URL, duration: TimeInterval) {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw DecoderError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: WavWriter.sampleRate,
            AVNumberOfChannelsKey: WavWriter.channels,
            AVLinearPCMBitDepthKey: WavWriter.bitsPerSample,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DecoderError.readFailed }
        reader.add(output)

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("doka-local-\(UUID().uuidString).wav")
        let writer = try WavWriter(url: wavURL)

        guard reader.startReading() else {
            writer.cancelAndDelete()
            throw DecoderError.readFailed
        }
        while let sample = output.copyNextSampleBuffer() {
            guard !Task.isCancelled else {
                reader.cancelReading()
                writer.cancelAndDelete()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length,
                                              dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                  let pointer else { continue }
            writer.append(Data(bytes: pointer, count: length))
        }
        guard reader.status == .completed, writer.dataBytes > 0 else {
            writer.cancelAndDelete()
            if reader.status == .cancelled { throw CancellationError() }
            throw DecoderError.readFailed
        }
        let duration = writer.duration
        try writer.finalize()
        return (wavURL, duration)
    }
}
