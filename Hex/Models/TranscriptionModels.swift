//
//  TranscriptionModels.swift
//  Hex
//
//  Created by Claude AI on 1/25/25.
//

import Foundation
import SwiftUI

/// 转录提供商类型
enum TranscriptionProvider: String, Codable, CaseIterable {
    case whisperKit = "whisperkit"
    case openai = "openai"

    var displayName: String {
        switch self {
        case .whisperKit:
            return "WhisperKit (本地)"
        case .openai:
            return "OpenAI Whisper (远程)"
        }
    }

    var description: String {
        switch self {
        case .whisperKit:
            return "使用本地模型进行转录，无需网络连接，数据完全私密"
        case .openai:
            return "使用 OpenAI 云端模型，需要 API Key，精度更高"
        }
    }
}

/// 转录模型类型，包含本地和远程模型
enum TranscriptionModelType: String, Codable, CaseIterable, Equatable {
    // 本地 WhisperKit 模型
    case whisperTiny = "openai_whisper-tiny"
    case whisperBase = "openai_whisper-base"
    case whisperLarge = "openai_whisper-large-v3-v20240930"

    // OpenAI 远程模型
    case openaiGpt4oMiniTranscribe = "gpt-4o-mini-transcribe"
    case openaiGpt4oTranscribe = "gpt-4o-transcribe"
    
    var displayName: String {
        switch self {
        case .whisperTiny:
            return "Whisper Tiny (本地)"
        case .whisperBase:
            return "Whisper Base (本地)"
        case .whisperLarge:
            return "Whisper Large (本地)"
        case .openaiGpt4oMiniTranscribe:
            return "GPT-4o Mini Transcribe (经济型)"
        case .openaiGpt4oTranscribe:
            return "GPT-4o Transcribe (高精度)"
        }
    }
    
    var description: String {
        switch self {
        case .whisperTiny:
            return "最小的本地模型，速度快但精度较低"
        case .whisperBase:
            return "平衡的本地模型，速度和精度适中"
        case .whisperLarge:
            return "最大的本地模型，精度高但速度较慢"
        case .openaiGpt4oMiniTranscribe:
            return "OpenAI 经济型转录模型，成本低廉，适合大量转录任务"
        case .openaiGpt4oTranscribe:
            return "OpenAI 高精度转录模型，最佳质量，支持多语言识别"
        }
    }
    
    var provider: TranscriptionProvider {
        switch self {
        case .whisperTiny, .whisperBase, .whisperLarge:
            return .whisperKit
        case .openaiGpt4oMiniTranscribe, .openaiGpt4oTranscribe:
            return .openai
        }
    }
    
    var requiresAPIKey: Bool {
        return provider == .openai
    }
    
    var isLocal: Bool {
        return provider == .whisperKit
    }
    
    var estimatedCostPerMinute: Double {
        switch self {
        case .whisperTiny, .whisperBase, .whisperLarge:
            return 0.0  // 本地模型免费
        case .openaiGpt4oMiniTranscribe:
            return 0.003  // $0.003/分钟 (经济型模型)
        case .openaiGpt4oTranscribe:
            return 0.006  // $0.006/分钟 (高精度模型)
        }
    }

    /// 根据提供商过滤模型
    static func modelsForProvider(_ provider: TranscriptionProvider) -> [TranscriptionModelType] {
        return allCases.filter { $0.provider == provider }
    }
    
    var iconName: String {
        switch self.provider {
        case .whisperKit:
            return "externaldrive"
        case .openai:
            return "cloud"
        }
    }
    
    var iconColor: Color {
        switch self.provider {
        case .whisperKit:
            return .blue
        case .openai:
            return .orange
        }
    }
}



/// 转录错误类型
enum TranscriptionError: Error, LocalizedError {
    case invalidModel(String)
    case fileTooLarge(Int, Int)  // 实际大小, 限制大小
    case apiKeyMissing
    case apiKeyInvalid
    case apiError(Int, String)
    case invalidResponse
    case networkError(Error)
    case unsupportedFileFormat(String)
    case audioProcessingError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidModel(let model):
            return "不支持的模型: \(model)"
        case .fileTooLarge(let actual, let limit):
            let actualMB = Double(actual) / (1024 * 1024)
            let limitMB = Double(limit) / (1024 * 1024)
            return "文件过大: \(String(format: "%.1f", actualMB))MB，限制: \(String(format: "%.1f", limitMB))MB"
        case .apiKeyMissing:
            return "缺少 OpenAI API 密钥"
        case .apiKeyInvalid:
            return "OpenAI API 密钥无效"
        case .apiError(let code, let message):
            return "API 错误 (\(code)): \(message)"
        case .invalidResponse:
            return "无效的 API 响应"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        case .unsupportedFileFormat(let format):
            return "不支持的文件格式: \(format)"
        case .audioProcessingError(let message):
            return "音频处理错误: \(message)"
        }
    }
    
    var failureReason: String? {
        switch self {
        case .apiKeyMissing, .apiKeyInvalid:
            return "请在设置中配置有效的 OpenAI API 密钥"
        case .fileTooLarge:
            return "请使用较小的音频文件或选择本地模型"
        case .unsupportedFileFormat:
            return "请使用支持的音频格式：mp3, wav, m4a, flac"
        case .networkError:
            return "请检查网络连接或切换到本地模型"
        default:
            return nil
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .apiKeyMissing, .apiKeyInvalid:
            return "访问 platform.openai.com 获取 API 密钥"
        case .fileTooLarge, .networkError:
            return "可以尝试使用本地 WhisperKit 模型"
        default:
            return nil
        }
    }
}