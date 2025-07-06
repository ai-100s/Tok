//
//  AliyunTokenManager.swift
//  Hex
//
//  Created by Claude AI on 1/25/25.
//

import Foundation

/// 阿里云 Token 管理器，负责获取和缓存 Token
actor AliyunTokenManager {
    private let appKey: String
    private let accessKeyId: String
    private let accessKeySecret: String
    private let baseURL = "https://nls-meta.cn-shanghai.aliyuncs.com/"
    
    /// Token 缓存过期前的提前刷新时间（5分钟）
    private static let tokenRefreshBuffer: TimeInterval = 5 * 60
    
    init(appKey: String, accessKeyId: String, accessKeySecret: String) {
        self.appKey = appKey
        self.accessKeyId = accessKeyId
        self.accessKeySecret = accessKeySecret
    }
    
    /// 获取有效的 Token，自动处理缓存和刷新
    func getValidToken(settings: HexSettings) async throws -> String {
        // 检查缓存的 Token 是否仍然有效
        if isTokenValid(settings: settings) {
            TokLogger.log("Using cached Aliyun token")
            return settings.aliyunCachedToken
        }
        
        // Token 无效或即将过期，获取新的 Token
        TokLogger.log("Fetching new Aliyun token for appKey: \(appKey.prefix(8))...")
        return try await fetchNewToken()
    }
    
    /// 测试 AppKey 有效性
    func testAppKey() async -> Bool {
        guard !appKey.isEmpty, !accessKeyId.isEmpty, !accessKeySecret.isEmpty else {
            TokLogger.log("Aliyun AppKey, AccessKeyId, or AccessKeySecret is empty", level: .warn)
            return false
        }
        
        do {
            TokLogger.log("Testing Aliyun credentials connection...")
            let _ = try await fetchNewToken()
            TokLogger.log("Aliyun credentials test successful")
            return true
        } catch {
            TokLogger.log("Aliyun credentials test failed: \(error)", level: .error)
            return false
        }
    }
    
    // MARK: - Private Methods
    
    /// 检查缓存的 Token 是否有效
    private func isTokenValid(settings: HexSettings) -> Bool {
        guard !settings.aliyunCachedToken.isEmpty,
              let expiration = settings.aliyunTokenExpiration else {
            return false
        }
        
        // 检查 Token 是否即将过期（提前5分钟刷新）
        let now = Date()
        let refreshTime = expiration.addingTimeInterval(-Self.tokenRefreshBuffer)
        
        return now < refreshTime
    }
    
    /// 从阿里云获取新的 Token
    private func fetchNewToken() async throws -> String {
        guard let url = URL(string: baseURL) else {
            throw AliyunTokenError.invalidURL
        }
        
        // 生成签名参数
        let signedParameters = AliyunSignatureGenerator.generateSignedParameters(
            accessKeyId: accessKeyId,
            accessKeySecret: accessKeySecret
        )
        
        // 构建表单数据
        // 注意：signedParameters中的值已经在签名生成过程中进行了URL编码，这里不需要再次编码
        let formData = signedParameters.map { key, value in
            "\(key)=\(value)"
        }.joined(separator: "&")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30.0
        request.httpBody = formData.data(using: .utf8)
        
        TokLogger.log("Requesting Aliyun token from: \(url.absoluteString)")
        TokLogger.log("Request parameters: \(signedParameters.keys.joined(separator: ", "))")
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AliyunTokenError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            let errorMessage = try parseErrorResponse(responseData)
            TokLogger.log("Aliyun token request failed: \(httpResponse.statusCode) - \(errorMessage)", level: .error)
            throw AliyunTokenError.apiError(httpResponse.statusCode, errorMessage)
        }
        
        // 解析响应
        let tokenResponse = try JSONDecoder().decode(AliyunTokenResponse.self, from: responseData)
        
        guard let token = tokenResponse.token?.id,
              let expiration = tokenResponse.token?.expireTime else {
            throw AliyunTokenError.invalidTokenResponse
        }
        
        TokLogger.log("Successfully obtained Aliyun token, expires at: \(expiration)")
        
        return token
    }
    
    /// 获取有效的 Token 并返回 Token 和过期时间
    func getValidTokenWithExpiration(settings: HexSettings) async throws -> (token: String, expiration: Date) {
        // 检查缓存的 Token 是否仍然有效
        if isTokenValid(settings: settings) {
            TokLogger.log("Using cached Aliyun token")
            return (settings.aliyunCachedToken, settings.aliyunTokenExpiration!)
        }
        
        // Token 无效或即将过期，获取新的 Token
        TokLogger.log("Fetching new Aliyun token for appKey: \(appKey.prefix(8))...")
        let (token, expiration) = try await fetchNewTokenWithExpiration()
        
        return (token, expiration)
    }
    
    /// 从阿里云获取新的 Token 和过期时间
    private func fetchNewTokenWithExpiration() async throws -> (token: String, expiration: Date) {
        guard let url = URL(string: baseURL) else {
            throw AliyunTokenError.invalidURL
        }
        
        // 生成签名参数
        let signedParameters = AliyunSignatureGenerator.generateSignedParameters(
            accessKeyId: accessKeyId,
            accessKeySecret: accessKeySecret
        )
        
        // 构建表单数据
        // 注意：signedParameters中的值已经在签名生成过程中进行了URL编码，这里不需要再次编码
        let formData = signedParameters.map { key, value in
            "\(key)=\(value)"
        }.joined(separator: "&")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30.0
        request.httpBody = formData.data(using: .utf8)
        
        TokLogger.log("Requesting Aliyun token from: \(url.absoluteString)")
        TokLogger.log("Request parameters: \(signedParameters.keys.joined(separator: ", "))")
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AliyunTokenError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            let errorMessage = try parseErrorResponse(responseData)
            TokLogger.log("Aliyun token request failed: \(httpResponse.statusCode) - \(errorMessage)", level: .error)
            throw AliyunTokenError.apiError(httpResponse.statusCode, errorMessage)
        }
        
        // 解析响应
        let tokenResponse = try JSONDecoder().decode(AliyunTokenResponse.self, from: responseData)
        
        guard let token = tokenResponse.token?.id,
              let expireTime = tokenResponse.token?.expireTime else {
            throw AliyunTokenError.invalidTokenResponse
        }
        
        let expiration = Date(timeIntervalSince1970: TimeInterval(expireTime))
        
        TokLogger.log("Successfully obtained Aliyun token, expires at: \(expiration)")
        
        return (token, expiration)
    }
    
    /// 解析错误响应
    private func parseErrorResponse(_ data: Data) throws -> String {
        struct ErrorResponse: Codable {
            let message: String?
            let code: String?
            let requestId: String?
            
            private enum CodingKeys: String, CodingKey {
                case message = "Message"
                case code = "Code"
                case requestId = "RequestId"
            }
        }
        
        do {
            let errorResponse = try JSONDecoder().decode(ErrorResponse.self, from: data)
            return errorResponse.message ?? "Unknown error"
        } catch {
            return String(data: data, encoding: .utf8) ?? "Unknown error"
        }
    }
}

// MARK: - Data Models

/// Token 响应结构（基于官方文档格式）
struct AliyunTokenResponse: Codable {
    let requestId: String?
    let nlsRequestId: String?
    let token: Token?
    
    struct Token: Codable {
        let id: String?
        let expireTime: Int?
        let userId: String?
        
        private enum CodingKeys: String, CodingKey {
            case id = "Id"
            case expireTime = "ExpireTime"
            case userId = "UserId"
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case requestId = "RequestId"
        case nlsRequestId = "NlsRequestId"
        case token = "Token"
    }
}

/// Token 相关错误
enum AliyunTokenError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidTokenResponse
    case apiError(Int, String)
    case networkError(Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 Token API URL"
        case .invalidResponse:
            return "无效的 API 响应"
        case .invalidTokenResponse:
            return "无效的 Token 响应格式"
        case .apiError(let code, let message):
            return "Token API 错误 (\(code)): \(message)"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        }
    }
    
    var failureReason: String? {
        switch self {
        case .invalidURL, .invalidResponse, .invalidTokenResponse:
            return "请检查 AppKey 配置或联系技术支持"
        case .apiError:
            return "请检查 AppKey 是否正确或重试"
        case .networkError:
            return "请检查网络连接"
        }
    }
}