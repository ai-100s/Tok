//
//  AliyunFileTranscriptionClient.swift
//  Hex
//
//  Created by Claude AI on 1/25/25.
//

import Foundation
import Dependencies
import WhisperKit

/// 阿里云文件转录引擎，基于文件上传极速版 API 实现
actor AliyunFileTranscriptionEngine {
    private let appKey: String
    private let accessKeyId: String
    private let accessKeySecret: String
    private let tokenManager: AliyunTokenManager
    private let baseURL = "https://nls-gateway-cn-shanghai.aliyuncs.com/stream/v1/FlashRecognizer"
    
    init(appKey: String, accessKeyId: String, accessKeySecret: String) {
        self.appKey = appKey
        self.accessKeyId = accessKeyId
        self.accessKeySecret = accessKeySecret
        self.tokenManager = AliyunTokenManager(appKey: appKey, accessKeyId: accessKeyId, accessKeySecret: accessKeySecret)
    }
    
    /// 测试 AppKey 有效性
    func testAppKey() async -> Bool {
        return await tokenManager.testAppKey()
    }
    
    /// 转录音频文件
    func transcribe(
        audioURL: URL,
        model: TranscriptionModelType,
        options: DecodingOptions,
        settings: HexSettings?,
        progressCallback: @escaping (Progress) -> Void
    ) async throws -> String {
        guard model.provider == .aliyun && model.isFileBasedTranscription else {
            throw TranscriptionError.invalidModel(model.rawValue)
        }
        
        let progress = Progress(totalUnitCount: 100)
        progressCallback(progress)
        
        // 检查文件大小限制 (阿里云限制 100MB)
        let fileSize = try getFileSize(url: audioURL)
        if fileSize > 100 * 1024 * 1024 {
            throw TranscriptionError.fileTooLarge(fileSize, 100 * 1024 * 1024)
        }
        
        progress.completedUnitCount = 10
        progressCallback(progress)
        
        // 获取有效的 Token
        guard let settings = settings else {
            throw TranscriptionError.aliyunAPIKeyMissing
        }
        
        let (token, expiration) = try await tokenManager.getValidTokenWithExpiration(settings: settings)
        
        // 更新设置中的缓存（这里需要通过某种机制更新，暂时记录日志）
        TokLogger.log("Token obtained, expires at: \(expiration)")
        
        progress.completedUnitCount = 20
        progressCallback(progress)
        
        // 直接转录音频文件
        TokLogger.log("Starting Aliyun file transcription with model: \(model.displayName)")
        let result = try await performDirectTranscription(
            audioURL: audioURL,
            model: model,
            options: options,
            token: token,
            progressCallback: progressCallback
        )
        
        progress.completedUnitCount = 100
        progressCallback(progress)
        
        // 应用设置（如禁用自动大写）
        var finalResult = result
        if settings.disableAutoCapitalization {
            finalResult = finalResult.lowercased()
        }
        
        TokLogger.log("Aliyun file transcription completed: \(finalResult.prefix(50))...")
        return finalResult
    }
    
    // MARK: - Private Methods
    
    /// 直接转录音频文件（使用官方 Flash Recognizer API）
    private func performDirectTranscription(
        audioURL: URL,
        model: TranscriptionModelType,
        options: DecodingOptions,
        token: String,
        progressCallback: @escaping (Progress) -> Void
    ) async throws -> String {
        // 构建请求 URL 和查询参数
        var urlComponents = URLComponents(string: baseURL)!
        urlComponents.queryItems = [
            URLQueryItem(name: "appkey", value: appKey),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "format", value: "wav"),
            URLQueryItem(name: "sample_rate", value: "16000")
        ]
        
        guard let url = urlComponents.url else {
            throw AliyunFileTranscriptionError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("nls-gateway-cn-shanghai.aliyuncs.com", forHTTPHeaderField: "Host")
        request.timeoutInterval = 300  // 5分钟超时
        
        // 读取音频文件数据
        let audioData = try Data(contentsOf: audioURL)
        request.httpBody = audioData
        
        TokLogger.log("Sending Aliyun file transcription request, file size: \(audioData.count) bytes")
        TokLogger.log("Request URL: \(url.absoluteString)")
        
        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 50
        progressCallback(progress)
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AliyunFileTranscriptionError.invalidResponse
        }
        
        progress.completedUnitCount = 80
        progressCallback(progress)
        
        if httpResponse.statusCode != 200 {
            let errorMessage = try parseErrorResponse(responseData)
            TokLogger.log("Aliyun file transcription failed: \(httpResponse.statusCode) - \(errorMessage)", level: .error)
            throw AliyunFileTranscriptionError.apiError(httpResponse.statusCode, errorMessage)
        }
        
        // 解析响应
        let responseString = String(data: responseData, encoding: .utf8) ?? ""
        TokLogger.log("Aliyun file transcription response: \(responseString)")
        
        // 尝试解析 JSON 响应
        if let jsonResponse = try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] {
            // 首先检查是否成功
            if let status = jsonResponse["status"] as? Int, status == 20000000 {
                TokLogger.log("Aliyun file transcription status: SUCCESS (20000000)")
                
                // 优先从 flash_result.sentences 提取结果
                if let flashResult = jsonResponse["flash_result"] as? [String: Any],
                   let sentences = flashResult["sentences"] as? [[String: Any]] {
                    let transcriptionText = sentences.compactMap { sentence in
                        sentence["text"] as? String
                    }.joined(separator: "")
                    
                    if !transcriptionText.isEmpty {
                        TokLogger.log("Aliyun file transcription completed successfully from flash_result")
                        return transcriptionText
                    }
                }
                
                // 回退到传统 result 字段
                if let result = jsonResponse["result"] as? String, !result.isEmpty {
                    TokLogger.log("Aliyun file transcription completed successfully from result field")
                    return result
                }
                
                // 如果都为空，但状态显示成功，记录警告但不抛错
                TokLogger.log("Aliyun file transcription succeeded but no text content found", level: .warn)
                return ""
            } else if let errorMessage = jsonResponse["message"] as? String {
                throw AliyunFileTranscriptionError.transcriptionFailed(errorMessage)
            }
        }
        
        // 如果不是 JSON 格式，可能是直接的文本响应
        if !responseString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            TokLogger.log("Aliyun file transcription completed with text response")
            return responseString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        throw AliyunFileTranscriptionError.emptyResult
    }
    
    // MARK: - Helper Methods
    
    private func getFileSize(url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int ?? 0
    }
    
    
    private func parseErrorResponse(_ data: Data) throws -> String {
        // 首先尝试解析为字符串
        if let responseString = String(data: data, encoding: .utf8) {
            TokLogger.log("Raw error response: \(responseString)")
            
            // 尝试解析 JSON 错误响应
            if let jsonData = responseString.data(using: .utf8),
               let jsonResponse = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                
                // 检查各种可能的错误字段
                if let message = jsonResponse["message"] as? String {
                    return message
                } else if let error = jsonResponse["error"] as? String {
                    return error
                } else if let code = jsonResponse["code"] as? String {
                    return "Error code: \(code)"
                } else if let status = jsonResponse["status"] as? String {
                    return "Status: \(status)"
                }
            }
            
            // 如果不是 JSON 格式，返回原始字符串
            return responseString
        }
        
        return "Unknown error"
    }
}

// MARK: - Data Models

/// 文件转录相关错误
enum AliyunFileTranscriptionError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case emptyResult
    case transcriptionFailed(String)
    case apiError(Int, String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的文件转录 API URL"
        case .invalidResponse:
            return "无效的 API 响应"
        case .emptyResult:
            return "转录结果为空"
        case .transcriptionFailed(let message):
            return "转录任务失败: \(message)"
        case .apiError(let code, let message):
            return "文件转录 API 错误 (\(code)): \(message)"
        }
    }
    
    var failureReason: String? {
        switch self {
        case .transcriptionFailed:
            return "请检查音频文件格式和质量"
        case .apiError:
            return "请检查 AppKey 和 Token 配置或重试"
        default:
            return "请联系技术支持或重试"
        }
    }
}

/// 阿里云文件转录客户端（非 actor 包装器，用于依赖注入）
struct AliyunFileTranscriptionClient {
    let appKey: String
    let accessKeyId: String
    let accessKeySecret: String
    
    func testAppKey() async -> Bool {
        let engine = AliyunFileTranscriptionEngine(appKey: appKey, accessKeyId: accessKeyId, accessKeySecret: accessKeySecret)
        return await engine.testAppKey()
    }
    
    func transcribe(
        audioURL: URL,
        model: TranscriptionModelType,
        options: DecodingOptions,
        settings: HexSettings?,
        progressCallback: @escaping (Progress) -> Void
    ) async throws -> String {
        let engine = AliyunFileTranscriptionEngine(appKey: appKey, accessKeyId: accessKeyId, accessKeySecret: accessKeySecret)
        return try await engine.transcribe(
            audioURL: audioURL,
            model: model,
            options: options,
            settings: settings,
            progressCallback: progressCallback
        )
    }
}