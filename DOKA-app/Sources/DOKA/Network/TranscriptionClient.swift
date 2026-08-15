import Foundation

/// Клиент OpenAI-совместимого API транскрипции (/audio/transcriptions).
/// Конкретный сервис задаётся через ProviderConfig.
struct TranscriptionClient {
    enum ClientError: LocalizedError {
        case noAPIKey
        case notConfigured       // «Свой сервис» без адреса
        case invalidKey          // 401
        case noFunds             // 402
        case rateLimited         // 429
        case server(Int)
        case badResponse         // 2xx, но тело не разобрать
        case network(Error)
        case emptyText

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return L("error.noAPIKey")
            case .notConfigured: return L("error.notConfigured")
            case .invalidKey: return L("error.invalidKey")
            case .noFunds: return L("error.noFunds")
            case .rateLimited: return L("error.rateLimited")
            case .server(let code): return L("error.server", code)
            case .badResponse: return L("error.badResponse")
            case .network: return L("error.network")
            case .emptyText: return L("error.emptyText")
            }
        }
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
    }

    /// Транскрибирует WAV-файл. language == nil — автоопределение.
    func transcribe(fileURL: URL, language: String?, apiKey: String, config: ProviderConfig) async throws -> String {
        let audioData = try Data(contentsOf: fileURL)
        return try await transcribe(audioData: audioData,
                                    fileName: fileURL.lastPathComponent,
                                    language: language,
                                    apiKey: apiKey,
                                    config: config)
    }

    func transcribe(audioData: Data, fileName: String, language: String?,
                    apiKey: String, config: ProviderConfig) async throws -> String {
        var fields: [(name: String, value: String)] = [
            ("model", config.model),
            ("response_format", "json")
        ]
        if let language, language != "auto", !language.isEmpty {
            fields.append(("language", language))
        }

        let boundary = "doka-\(UUID().uuidString)"
        var body = Data()
        for field in fields {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
            body.append("\(field.value)\r\n")
        }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClientError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.server(0)
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            throw ClientError.invalidKey
        case 402:
            throw ClientError.noFunds
        case 429:
            throw ClientError.rateLimited
        default:
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            NSLog("DOKA: сервис распознавания HTTP \(http.statusCode): \(bodyText.prefix(500))")
            throw ClientError.server(http.statusCode)
        }

        guard let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
            NSLog("DOKA: не удалось разобрать ответ сервиса: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "<бинарные данные>")")
            throw ClientError.badResponse
        }
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClientError.emptyText }
        return text
    }

    /// Проверка ключа: короткий WAV с тишиной. 200/400 → ключ рабочий,
    /// 401 → неверный, 402 → верный, но нет средств.
    func validateKey(_ apiKey: String, config: ProviderConfig) async -> Result<Void, ClientError> {
        let silence = WavWriter.silenceWav(duration: 0.5)
        do {
            _ = try await transcribe(audioData: silence,
                                     fileName: "check.wav",
                                     language: nil,
                                     apiKey: apiKey,
                                     config: config)
            return .success(())
        } catch let error as ClientError {
            switch error {
            case .invalidKey, .noFunds, .rateLimited, .network:
                return .failure(error)
            case .emptyText, .server(400), .badResponse:
                // Аутентификация прошла — тишина просто не распозналась.
                return .success(())
            default:
                return .failure(error)
            }
        } catch {
            return .failure(.network(error))
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
