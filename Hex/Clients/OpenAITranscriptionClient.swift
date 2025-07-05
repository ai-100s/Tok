//
//  OpenAITranscriptionClient.swift
//  Hex
//
//  Created by Claude AI on 1/25/25.
//

import Foundation
import Dependencies
import WhisperKit

/// OpenAI 转录引擎，基于官方 Speech-to-Text API 实现
actor OpenAITranscriptionEngine {
    private let apiKey: String
    private let baseURL = "https://api.openai.com/v1"
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    /// 测试 API 密钥有效性
    func testAPIKey() async -> Bool {
        guard !apiKey.isEmpty else { return false }
        
        do {
            var request = URLRequest(url: URL(string: "\(baseURL)/models")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10.0
            
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            print("[OpenAI] API key test failed: \(error)")
            return false
        }
    }
    
    /// 转录音频文件
    func transcribe(
        audioURL: URL,
        model: TranscriptionModelType,
        options: DecodingOptions,
        settings: HexSettings?,
        progressCallback: @escaping (Progress) -> Void
    ) async throws -> String {
        guard model.provider == .openai else {
            throw TranscriptionError.invalidModel(model.rawValue)
        }
        
        let progress = Progress(totalUnitCount: 100)
        progressCallback(progress)
        
        // 检查文件大小限制 (OpenAI 限制 25MB)
        let fileSize = try getFileSize(url: audioURL)
        if fileSize > 25 * 1024 * 1024 {
            throw TranscriptionError.fileTooLarge(fileSize, 25 * 1024 * 1024)
        }
        
        progress.completedUnitCount = 10
        progressCallback(progress)
        
        // 准备请求
        var request = URLRequest(url: URL(string: "\(baseURL)/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        // 创建 multipart 表单数据
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // 添加音频文件
        let audioData = try Data(contentsOf: audioURL)
        let filename = audioURL.lastPathComponent
        let mimeType = getMimeType(for: audioURL)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        
        // 添加模型参数
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append(model.rawValue.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        
        // 添加语言参数（如果指定）
        if let language = options.language, language != "auto" {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append(language.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        
        // 添加响应格式
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json".data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        
        // 添加时间戳设置
        if !options.withoutTimestamps {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\n".data(using: .utf8)!)
            body.append("segment".data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        request.timeoutInterval = 300  // 5分钟超时
        
        progress.completedUnitCount = 30
        progressCallback(progress)
        
        // 发送请求
        print("[OpenAI] Sending transcription request for model: \(model.displayName)")
        TokLogger.log("OpenAI transcription started with model: \(model.displayName), file size: \(fileSize) bytes")
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        
        progress.completedUnitCount = 80
        progressCallback(progress)
        
        if httpResponse.statusCode != 200 {
            let errorMessage = try parseErrorResponse(responseData)
            TokLogger.log("OpenAI transcription failed: \(httpResponse.statusCode) - \(errorMessage)", level: .error)
            throw TranscriptionError.apiError(httpResponse.statusCode, errorMessage)
        }
        
        // 解析响应
        struct OpenAITranscriptionResponse: Codable {
            let text: String
        }
        
        let transcriptionResponse = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: responseData)
        
        progress.completedUnitCount = 100
        progressCallback(progress)
        
        // 应用设置（如禁用自动大写）
        var result = transcriptionResponse.text
        if let settings = settings, settings.disableAutoCapitalization {
            result = result.lowercased()
        }
        
        TokLogger.log("OpenAI transcription completed with \(model.displayName): \(result.prefix(50))...")
        return result
    }
    
    // MARK: - Helper Methods
    
    private func getFileSize(url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int ?? 0
    }
    
    private func getMimeType(for url: URL) -> String {
        let pathExtension = url.pathExtension.lowercased()
        switch pathExtension {
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        case "m4a":
            return "audio/m4a"
        case "flac":
            return "audio/flac"
        case "mp4":
            return "audio/mp4"
        case "mpeg":
            return "audio/mpeg"
        case "mpga":
            return "audio/mpeg"
        case "webm":
            return "audio/webm"
        default:
            return "audio/wav"  // 默认为 wav
        }
    }
    
    private func parseErrorResponse(_ data: Data) throws -> String {
        struct ErrorResponse: Codable {
            struct Error: Codable {
                let message: String
                let type: String?
                let code: String?
            }
            let error: Error
        }
        
        do {
            let errorResponse = try JSONDecoder().decode(ErrorResponse.self, from: data)
            return errorResponse.error.message
        } catch {
            return String(data: data, encoding: .utf8) ?? "Unknown error"
        }
    }
}

/// OpenAI 转录客户端（非 actor 包装器，用于依赖注入）
struct OpenAITranscriptionClient {
    let apiKey: String
    
    func testAPIKey() async -> Bool {
        let engine = OpenAITranscriptionEngine(apiKey: apiKey)
        return await engine.testAPIKey()
    }
    
    func transcribe(
        audioURL: URL,
        model: TranscriptionModelType,
        options: DecodingOptions,
        settings: HexSettings?,
        progressCallback: @escaping (Progress) -> Void
    ) async throws -> String {
        let engine = OpenAITranscriptionEngine(apiKey: apiKey)
        return try await engine.transcribe(
            audioURL: audioURL,
            model: model,
            options: options,
            settings: settings,
            progressCallback: progressCallback
        )
    }
}