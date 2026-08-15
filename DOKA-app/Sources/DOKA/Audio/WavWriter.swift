import Foundation

/// Инкрементальная запись WAV-файла (PCM 16 кГц, моно, Int16).
/// Заголовок дописывается с реальными размерами при finalize().
final class WavWriter {
    static let sampleRate = 16_000
    static let channels = 1
    static let bitsPerSample = 16
    static let bytesPerSecond = sampleRate * channels * bitsPerSample / 8   // 32 000

    let url: URL
    private let handle: FileHandle
    private(set) var dataBytes: Int = 0

    var duration: TimeInterval { TimeInterval(dataBytes) / TimeInterval(Self.bytesPerSecond) }

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(dataSize: 0))
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        do {
            try handle.write(contentsOf: data)
            dataBytes += data.count
        } catch {
            NSLog("DOKA: ошибка записи WAV: \(error.localizedDescription)")
        }
    }

    /// Дописывает корректный заголовок и закрывает файл.
    func finalize() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataSize: dataBytes))
        try handle.close()
    }

    /// Закрывает и удаляет файл (отмена записи).
    func cancelAndDelete() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    /// 44-байтный RIFF/WAVE заголовок для PCM 16 кГц моно 16 бит.
    static func header(dataSize: Int) -> Data {
        var d = Data(capacity: 44)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + dataSize))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)                                  // размер fmt-чанка
        u16(1)                                   // PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(bytesPerSecond))
        u16(UInt16(channels * bitsPerSample / 8)) // block align
        u16(UInt16(bitsPerSample))
        d.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataSize))
        return d
    }

    /// WAV с тишиной заданной длительности — для проверки API-ключа.
    static func silenceWav(duration: TimeInterval) -> Data {
        let dataSize = Int(duration * Double(bytesPerSecond)) & ~1
        var d = header(dataSize: dataSize)
        d.append(Data(count: dataSize))
        return d
    }
}
