//
//  AliyunSignatureGenerator.swift
//  Hex
//
//  Created by Claude AI on 1/25/25.
//

import Foundation
import CommonCrypto

/// 阿里云 API 签名生成器
/// 实现阿里云官方 HMAC-SHA1 签名算法
struct AliyunSignatureGenerator {
    
    /// 生成阿里云 API 签名
    /// - Parameters:
    ///   - accessKeyId: 阿里云 Access Key ID
    ///   - accessKeySecret: 阿里云 Access Key Secret
    ///   - timestamp: ISO8601 格式的时间戳
    ///   - nonce: 唯一随机字符串
    /// - Returns: 生成的请求参数字典，包含签名
    static func generateSignedParameters(
        accessKeyId: String,
        accessKeySecret: String,
        timestamp: String? = nil,
        nonce: String? = nil
    ) -> [String: String] {
        
        // 生成时间戳和随机数
        let finalTimestamp = timestamp ?? generateTimestamp()
        let finalNonce = nonce ?? generateNonce()
        
        // 构建基础参数
        var parameters: [String: String] = [
            "Action": "CreateToken",
            "Version": "2019-02-28",
            "Format": "JSON",
            "RegionId": "cn-shanghai",
            "AccessKeyId": accessKeyId,
            "SignatureMethod": "HMAC-SHA1",
            "SignatureVersion": "1.0",
            "Timestamp": finalTimestamp,
            "SignatureNonce": finalNonce
        ]
        
        // 生成签名
        let signature = generateSignature(
            parameters: parameters,
            accessKeySecret: accessKeySecret,
            httpMethod: "POST"
        )
        
        // 添加签名到参数中
        parameters["Signature"] = signature
        
        return parameters
    }
    
    /// 生成 HMAC-SHA1 签名
    /// - Parameters:
    ///   - parameters: 请求参数
    ///   - accessKeySecret: Access Key Secret
    ///   - httpMethod: HTTP 方法
    /// - Returns: 生成的签名
    private static func generateSignature(
        parameters: [String: String],
        accessKeySecret: String,
        httpMethod: String
    ) -> String {
        
        // 1. 参数排序和编码
        let canonicalQueryString = canonicalizeParameters(parameters)
        
        // 2. 构建签名字符串
        let stringToSign = constructStringToSign(
            httpMethod: httpMethod,
            canonicalQueryString: canonicalQueryString
        )
        
        // 3. 计算 HMAC-SHA1 签名
        let signature = calculateHMACSHA1(
            stringToSign: stringToSign,
            key: accessKeySecret + "&"
        )
        
        // 4. Base64 编码
        let base64Signature = Data(signature).base64EncodedString()
        
        return base64Signature
    }
    
    /// 规范化参数
    /// - Parameter parameters: 请求参数
    /// - Returns: 规范化后的查询字符串
    private static func canonicalizeParameters(_ parameters: [String: String]) -> String {
        // 排序参数
        let sortedParameters = parameters.sorted { $0.key < $1.key }
        
        // 编码并连接
        let encodedPairs = sortedParameters.map { key, value in
            "\(percentEncode(key))=\(percentEncode(value))"
        }
        
        return encodedPairs.joined(separator: "&")
    }
    
    /// 构建签名字符串
    /// - Parameters:
    ///   - httpMethod: HTTP 方法
    ///   - canonicalQueryString: 规范化的查询字符串
    /// - Returns: 签名字符串
    private static func constructStringToSign(
        httpMethod: String,
        canonicalQueryString: String
    ) -> String {
        return "\(httpMethod)&\(percentEncode("/"))&\(percentEncode(canonicalQueryString))"
    }
    
    /// 计算 HMAC-SHA1
    /// - Parameters:
    ///   - stringToSign: 要签名的字符串
    ///   - key: 签名密钥
    /// - Returns: HMAC-SHA1 结果
    private static func calculateHMACSHA1(stringToSign: String, key: String) -> [UInt8] {
        let keyData = key.data(using: .utf8)!
        let dataData = stringToSign.data(using: .utf8)!
        
        var result = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        
        keyData.withUnsafeBytes { keyBytes in
            dataData.withUnsafeBytes { dataBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),
                       keyBytes.baseAddress, keyData.count,
                       dataBytes.baseAddress, dataData.count,
                       &result)
            }
        }
        
        return result
    }
    
    /// URL 编码（遵循 RFC 3986 标准）
    /// - Parameter string: 要编码的字符串
    /// - Returns: 编码后的字符串
    private static func percentEncode(_ string: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        
        return string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }
    
    /// 生成 ISO8601 时间戳
    /// - Returns: ISO8601 格式的时间戳
    private static func generateTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
    
    /// 生成唯一随机字符串
    /// - Returns: UUID 字符串
    private static func generateNonce() -> String {
        return UUID().uuidString
    }
}

// MARK: - 扩展方法用于测试

extension AliyunSignatureGenerator {
    /// 验证签名生成的正确性
    /// - Parameters:
    ///   - accessKeyId: Access Key ID
    ///   - accessKeySecret: Access Key Secret
    ///   - expectedSignature: 期望的签名结果
    ///   - timestamp: 时间戳
    ///   - nonce: 随机数
    /// - Returns: 是否匹配
    static func verifySignature(
        accessKeyId: String,
        accessKeySecret: String,
        expectedSignature: String,
        timestamp: String,
        nonce: String
    ) -> Bool {
        let parameters = generateSignedParameters(
            accessKeyId: accessKeyId,
            accessKeySecret: accessKeySecret,
            timestamp: timestamp,
            nonce: nonce
        )
        
        return parameters["Signature"] == expectedSignature
    }
    
    /// 生成测试用的参数组合
    /// - Returns: 用于测试的参数字典
    static func generateTestParameters() -> [String: String] {
        return generateSignedParameters(
            accessKeyId: "testAccessKeyId",
            accessKeySecret: "testAccessKeySecret",
            timestamp: "2019-03-25T09:07:52Z",
            nonce: "8d1e6a7a-f44e-40d5-aedb-fe4a1c80f434"
        )
    }
}