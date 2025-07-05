//
//  AliyunTranscriptionClient.swift
//  Hex
//
//  Created by Claude AI on 1/25/25.
//

import Foundation
import Dependencies
import WhisperKit

/// 阿里云百炼转录引擎，基于 WebSocket 实时流式 API 实现
actor AliyunTranscriptionEngine {
    private let apiKey: String
    private let baseURL = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var currentTaskId: String?

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    deinit {
        webSocket?.cancel()
        urlSession?.invalidateAndCancel()
    }
    
    /// 测试 API 密钥有效性
    func testAPIKey() async -> Bool {
        guard !apiKey.isEmpty else { 
            TokLogger.log("Aliyun API key is empty", level: .warn)
            return false 
        }
        
        do {
            TokLogger.log("Testing Aliyun API key connection...")
            let connected = try await establishWebSocketConnection()
            await closeWebSocketConnection()
            
            if connected {
                TokLogger.log("Aliyun API key test successful")
            } else {
                TokLogger.log("Aliyun API key test failed - connection not established", level: .warn)
            }
            
            return connected
        } catch {
            TokLogger.log("Aliyun API key test failed: \(error)", level: .error)
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
        guard model.provider == .aliyun else {
            throw TranscriptionError.invalidModel(model.rawValue)
        }
        
        let progress = Progress(totalUnitCount: 100)
        progressCallback(progress)
        
        // 加载音频数据
        let audioData = try Data(contentsOf: audioURL)
        
        progress.completedUnitCount = 10
        progressCallback(progress)
        
        // 建立 WebSocket 连接
        TokLogger.log("Establishing WebSocket connection to Aliyun...")
        guard try await establishWebSocketConnection() else {
            TokLogger.log("Failed to establish WebSocket connection to Aliyun", level: .error)
            throw TranscriptionError.webSocketError("Failed to establish WebSocket connection")
        }
        TokLogger.log("WebSocket connection established successfully")

        // 优化：减少初始等待时间，加快启动速度
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms即可保证连接稳定
        
        progress.completedUnitCount = 20
        progressCallback(progress)
        
        // 发送转录任务
        let transcriptionResult = try await performTranscription(
            audioData: audioData,
            model: model,
            options: options,
            settings: settings,
            progressCallback: progressCallback
        )
        
        // 关闭连接
        await closeWebSocketConnection()
        
        progress.completedUnitCount = 100
        progressCallback(progress)
        
        TokLogger.log("Aliyun transcription completed with \(model.displayName): \(transcriptionResult.prefix(50))...")
        return transcriptionResult
    }
    
    // MARK: - WebSocket Management
    
    private func establishWebSocketConnection() async throws -> Bool {
        guard let url = URL(string: baseURL) else {
            throw TranscriptionError.webSocketError("Invalid WebSocket URL")
        }

        var request = URLRequest(url: url)
        // 阿里云 API 需要 bearer 前缀（注意是小写）
        request.setValue("bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-DataInspection")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        // 增加网络稳定性配置
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true

        urlSession = URLSession(configuration: config)
        webSocket = urlSession?.webSocketTask(with: request)

        webSocket?.resume()

        // 验证连接状态
        try await Task.sleep(nanoseconds: 1_000_000_000) // 等待1秒确保连接建立
        
        if let ws = webSocket, ws.state == .running {
            TokLogger.log("WebSocket connection established successfully")
            return true
        } else {
            TokLogger.log("WebSocket connection failed to establish", level: .error)
            return false
        }
    }
    
    private func closeWebSocketConnection() async {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }
    
    // MARK: - Transcription Logic
    
    private func performTranscription(
        audioData: Data,
        model: TranscriptionModelType,
        options: DecodingOptions,
        settings: HexSettings?,
        progressCallback: @escaping (Progress) -> Void
    ) async throws -> String {
        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 20
        progressCallback(progress)

        // 生成当前任务的 TaskId
        currentTaskId = UUID().uuidString

        // 发送任务开始指令
        try await sendRunTaskInstruction(model: model, options: options)

        progress.completedUnitCount = 30
        progressCallback(progress)

        // 开始流式处理：等待任务开始，然后并发发送音频和接收结果
        let result = try await streamAudioAndCollectResults(audioData: audioData, settings: settings, progressCallback: progressCallback)

        progress.completedUnitCount = 90
        progressCallback(progress)

        // 应用设置（如禁用自动大写）
        var finalResult = result
        if let settings = settings, settings.disableAutoCapitalization {
            finalResult = finalResult.lowercased()
        }

        return finalResult
    }

    /// 流式处理音频发送和结果接收，符合官方 Python 实现的时序
    private func streamAudioAndCollectResults(
        audioData: Data,
        settings: HexSettings?,
        progressCallback: @escaping (Progress) -> Void
    ) async throws -> String {
        var latestTranscription: String = ""  // 保存最新的完整转录文本
        var taskStarted = false
        var taskFinished = false
        
        // 时间分析：记录转录开始时间
        let transcriptionStartTime = Date()
        
        // 计算音频时长
        let pcmData = try convertToPCM(audioData: audioData)
        let audioDurationSeconds = Double(pcmData.count) / (16000.0 * 2.0) // 16kHz, 16-bit
        TokLogger.log("[TIMING] Audio duration: \(String(format: "%.3f", audioDurationSeconds))s, starting transcription at \(transcriptionStartTime.timeIntervalSince1970)")

        // 创建并发任务来处理消息接收
        let messageHandlingTask = Task {
            while !taskFinished {
                do {
                    guard let webSocket = webSocket else {
                        throw TranscriptionError.webSocketError("WebSocket is nil")
                    }

                    let message = try await webSocket.receive()

                    switch message {
                    case .data(let data):
                        if let event = try? JSONDecoder().decode(AliyunEvent.self, from: data) {
                            await handleStreamEvent(event: event, latestTranscription: &latestTranscription, taskStarted: &taskStarted, taskFinished: &taskFinished, settings: settings)
                        }
                    case .string(let string):
                        if let data = string.data(using: .utf8),
                           let event = try? JSONDecoder().decode(AliyunEvent.self, from: data) {
                            await handleStreamEvent(event: event, latestTranscription: &latestTranscription, taskStarted: &taskStarted, taskFinished: &taskFinished, settings: settings)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    TokLogger.log("Error in message handling: \(error)", level: .error)
                    break
                }
            }
        }

        // 优化：更频繁的检查任务状态，减少等待时间
        while !taskStarted && !taskFinished {
            try await Task.sleep(nanoseconds: 25_000_000) // 25ms更频繁检查
        }

        if taskFinished {
            messageHandlingTask.cancel()
            throw TranscriptionError.webSocketError("Task failed to start")
        }

        TokLogger.log("Task started, beginning audio transmission")

        // 开始发送音频数据
        try await sendAudioDataStreaming(audioData: audioData, settings: settings, progressCallback: progressCallback)

        // 发送完成指令
        try await sendFinishTaskInstruction()
        TokLogger.log("Finish task instruction sent")

        // 优化：更频繁的检查完成状态
        while !taskFinished {
            try await Task.sleep(nanoseconds: 25_000_000) // 25ms更频繁检查
        }

        messageHandlingTask.cancel()
        
        // 时间分析：计算转录总耗时和效率
        let transcriptionEndTime = Date()
        let transcriptionDuration = transcriptionEndTime.timeIntervalSince(transcriptionStartTime)
        let transcriptionEfficiency = audioDurationSeconds / transcriptionDuration
        
        TokLogger.log("[TIMING] Transcription completed in \(String(format: "%.3f", transcriptionDuration))s")
        TokLogger.log("[TIMING] Transcription efficiency: \(String(format: "%.2f", transcriptionEfficiency))x (\(String(format: "%.1f", transcriptionEfficiency * 100))% real-time)")
        TokLogger.log("[TIMING] Audio: \(String(format: "%.3f", audioDurationSeconds))s → Transcription: \(String(format: "%.3f", transcriptionDuration))s")

        return latestTranscription
    }

    /// 处理流式事件
    private func handleStreamEvent(
        event: AliyunEvent,
        latestTranscription: inout String,
        taskStarted: inout Bool,
        taskFinished: inout Bool,
        settings: HexSettings?
    ) async {
        TokLogger.log("Received event: \(event.header.event)")

        switch event.header.event {
        case "task-started":
            TokLogger.log("Aliyun task started successfully")
            taskStarted = true

        case "result-generated":
            // 批量模式：只记录中间结果，不输出详细日志，减少资源消耗
            if let payload = event.payload {
                if let output = payload.output {
                    // 首先尝试从sentence.text获取文本（Aliyun实际格式）
                    var resultText: String? = nil
                    if let sentence = output.sentence, let sentenceText = sentence.text {
                        resultText = sentenceText
                    } 
                    // 如果sentence不存在，尝试直接从text字段获取（兼容旧格式）
                    else if let directText = output.text {
                        resultText = directText
                    }
                    
                    if let text = resultText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // 根据设置决定是否输出详细日志
                        latestTranscription = text
                        
                        // 在非批量模式或DEBUG模式下输出中间结果
                        if let settings = settings, !settings.aliyunBatchMode {
                            TokLogger.log("[REALTIME] Intermediate result: \(text)")
                        } else {
                            #if DEBUG
                            TokLogger.log("[BATCH] Intermediate result: \(text.prefix(50))...")
                            #endif
                        }
                    }
                }
            }

        case "task-finished":
            TokLogger.log("Aliyun task finished successfully")
            if !latestTranscription.isEmpty {
                TokLogger.log("[BATCH] Final transcription result: \(latestTranscription)")
            }
            taskFinished = true

        case "task-failed":
            let errorMsg = event.header.error_message ?? "Unknown error"
            TokLogger.log("Task failed: \(errorMsg)", level: .error)
            taskFinished = true

        default:
            TokLogger.log("Received unknown event: \(event.header.event)")
        }
    }

    private func sendRunTaskInstruction(model: TranscriptionModelType, options: DecodingOptions) async throws {
        guard let taskId = currentTaskId else {
            throw TranscriptionError.webSocketError("No task ID available")
        }

        let instruction = AliyunRunTaskInstruction(
            taskId: taskId,
            model: "paraformer-realtime-v2",
            language: options.language
        )

        let data = try JSONEncoder().encode(instruction)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        let message = URLSessionWebSocketTask.Message.string(jsonString)

        TokLogger.log("Sending run-task instruction: \(jsonString)")
        try await webSocket?.send(message)
        TokLogger.log("Aliyun run-task instruction sent with taskId: \(taskId)")
    }
    

    
    private func sendAudioData(audioData: Data, progressCallback: @escaping (Progress) -> Void) async throws {
        guard let taskId = currentTaskId else {
            throw TranscriptionError.webSocketError("No task ID available")
        }

        // Convert WAV to PCM if needed
        let pcmData = try convertToPCM(audioData: audioData)

        let chunkSize = 3200 // 200ms 的音频数据（16000 采样率 * 0.2 秒 * 2 字节）
        let totalChunks = (pcmData.count + chunkSize - 1) / chunkSize

        for i in 0..<totalChunks {
            let startIndex = i * chunkSize
            let endIndex = min(startIndex + chunkSize, pcmData.count)
            let chunk = pcmData[startIndex..<endIndex]

            // 直接发送二进制音频数据，不包装在 JSON 中
            let message = URLSessionWebSocketTask.Message.data(Data(chunk))
            try await webSocket?.send(message)

            // 更新进度
            let progress = Progress(totalUnitCount: 100)
            progress.completedUnitCount = 40 + Int64((Double(i) / Double(totalChunks)) * 30)
            progressCallback(progress)

            // 100ms 间隔（按照官方文档建议）
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        TokLogger.log("Aliyun audio data sent: \(totalChunks) chunks")
    }

    /// 批量模式发送音频数据：保持实时发送以避免超时，但减少日志输出
    private func sendAudioDataStreaming(audioData: Data, settings: HexSettings?, progressCallback: @escaping (Progress) -> Void) async throws {
        // Convert WAV to PCM if needed
        let pcmData = try convertToPCM(audioData: audioData)
        let audioDuration = Double(pcmData.count) / (16000.0 * 2.0)
        
        // 根据设置决定日志输出级别
        if let settings = settings, !settings.aliyunBatchMode {
            TokLogger.log("[REALTIME] Starting audio transmission: \(audioData.count) bytes, duration: \(String(format: "%.3f", audioDuration))s")
        } else {
            TokLogger.log("[BATCH] Starting audio transmission: \(audioData.count) bytes, duration: \(String(format: "%.3f", audioDuration))s")
        }

        // 性能优化：根据音频长度和设置动态调整发送策略
        let chunkSize = 3200 // 100ms的音频数据
        let totalChunks = (pcmData.count + chunkSize - 1) / chunkSize
        let sendStartTime = Date()
        
        // 检查是否启用性能优化
        let performanceMode = settings?.aliyunPerformanceMode ?? true
        
        let sendInterval: UInt64
        let batchSize: Int
        
        if performanceMode {
            // 性能优化模式：动态调整
            if audioDuration < 3.0 {
                sendInterval = 40_000_000  // 40ms 更快
                batchSize = 3  // 三块批量发送
            } else if audioDuration < 8.0 {
                sendInterval = 60_000_000  // 60ms 平衡
                batchSize = 2  // 两块批量发送
            } else {
                sendInterval = 80_000_000  // 80ms 稳定
                batchSize = 1  // 单块发送
            }
        } else {
            // 标准模式：按官方建议
            sendInterval = 100_000_000  // 100ms
            batchSize = 1
        }
        
        var i = 0
        while i < totalChunks {
            let batchEnd = min(i + batchSize, totalChunks)
            
            // 批量发送音频块
            for j in i..<batchEnd {
                let startIndex = j * chunkSize
                let endIndex = min(startIndex + chunkSize, pcmData.count)
                let chunk = pcmData[startIndex..<endIndex]

                let message = URLSessionWebSocketTask.Message.data(Data(chunk))
                try await webSocket?.send(message)
            }

            // 更新进度
            let progress = Progress(totalUnitCount: 100)
            progress.completedUnitCount = 40 + Int64((Double(i) / Double(totalChunks)) * 30)
            progressCallback(progress)

            // 动态间隔等待
            if i + batchSize < totalChunks {
                try await Task.sleep(nanoseconds: sendInterval)
            }
            
            i += batchSize
        }
        
        let sendDuration = Date().timeIntervalSince(sendStartTime)
        let mode = performanceMode ? "PERF" : "STD"
        if let settings = settings, !settings.aliyunBatchMode {
            TokLogger.log("[REALTIME-\(mode)] Audio transmission completed in \(String(format: "%.3f", sendDuration))s, sent \(totalChunks) chunks (batch: \(batchSize))")
        } else {
            TokLogger.log("[BATCH-\(mode)] Audio transmission completed in \(String(format: "%.3f", sendDuration))s, sent \(totalChunks) chunks (batch: \(batchSize))")
        }
    }

    private func sendFinishTaskInstruction() async throws {
        guard let taskId = currentTaskId else {
            throw TranscriptionError.webSocketError("No task ID available")
        }

        let instruction = AliyunFinishTaskInstruction(taskId: taskId)
        let data = try JSONEncoder().encode(instruction)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        let message = URLSessionWebSocketTask.Message.string(jsonString)

        try await webSocket?.send(message)
        TokLogger.log("Aliyun finish-task instruction sent")
    }
    


    // MARK: - Audio Processing

    private func convertToPCM(audioData: Data) throws -> Data {
        // 检查是否是 WAV 文件
        if audioData.count > 44 &&
           audioData[0...3] == Data([0x52, 0x49, 0x46, 0x46]) && // "RIFF"
           audioData[8...11] == Data([0x57, 0x41, 0x56, 0x45]) { // "WAVE"

            TokLogger.log("Detected WAV file format")
            
            // 打印前64字节的十六进制内容用于调试
            let debugBytes = audioData.prefix(64)
            TokLogger.log("WAV header hex dump: \(debugBytes.map { String(format: "%02x", $0) }.joined(separator: " "))")

            // 查找 "fmt " chunk 来获取正确的偏移量
            var fmtChunkOffset: Int? = nil
            for i in 12..<(audioData.count - 8) {
                if audioData[i...i+3] == Data([0x66, 0x6d, 0x74, 0x20]) { // "fmt "
                    fmtChunkOffset = i + 8 // 跳过 "fmt " 和 chunk size (4字节)
                    break
                }
            }
            
            guard let fmtOffset = fmtChunkOffset else {
                TokLogger.log("Could not find fmt chunk in WAV file", level: .error)
                throw TranscriptionError.webSocketError("Invalid WAV file - no fmt chunk found")
            }
            
            TokLogger.log("Found fmt chunk at offset: \(fmtOffset)")

            // 从 fmt chunk 中解析音频格式信息
            let channels = audioData.withUnsafeBytes { bytes in
                bytes.load(fromByteOffset: fmtOffset + 2, as: UInt16.self)
            }
            let sampleRate = audioData.withUnsafeBytes { bytes in
                bytes.load(fromByteOffset: fmtOffset + 4, as: UInt32.self)
            }
            let bitsPerSample = audioData.withUnsafeBytes { bytes in
                bytes.load(fromByteOffset: fmtOffset + 14, as: UInt16.self)
            }

            TokLogger.log("WAV info - Sample rate: \(sampleRate)Hz, Bits per sample: \(bitsPerSample), Channels: \(channels)")

            // 验证关键参数
            if sampleRate == 0 || channels == 0 || bitsPerSample == 0 {
                TokLogger.log("Invalid WAV header detected - may be corrupted or unsupported format", level: .error)
                throw TranscriptionError.webSocketError("Invalid or corrupted WAV header")
            }

            // 检查格式是否符合要求
            if sampleRate != 16000 {
                TokLogger.log("Warning: Sample rate is \(sampleRate)Hz, but we're telling server it's 16000Hz", level: .error)
            }
            if bitsPerSample != 16 {
                TokLogger.log("Warning: Bits per sample is \(bitsPerSample), expected 16", level: .error)
            }
            if channels != 1 {
                TokLogger.log("Warning: Audio has \(channels) channels, but server expects mono (1 channel)", level: .error)
            }

            // 查找 "data" chunk 来获取实际音频数据的开始位置
            var dataChunkOffset: Int? = nil
            for i in 12..<(audioData.count - 8) {
                if audioData[i...i+3] == Data([0x64, 0x61, 0x74, 0x61]) { // "data"
                    dataChunkOffset = i + 8 // 跳过 "data" 和 chunk size (4字节)
                    break
                }
            }
            
            guard let dataOffset = dataChunkOffset else {
                TokLogger.log("Could not find data chunk in WAV file", level: .error)
                throw TranscriptionError.webSocketError("Invalid WAV file - no data chunk found")
            }
            
            TokLogger.log("Found data chunk at offset: \(dataOffset)")

            // 提取 PCM 数据
            let pcmData = audioData.subdata(in: dataOffset..<audioData.count)
            TokLogger.log("Extracted PCM data: \(pcmData.count) bytes")
            return pcmData
        }

        // 否则假设已经是 PCM 数据
        TokLogger.log("Assuming raw PCM data: \(audioData.count) bytes")
        return audioData
    }
}

// MARK: - Aliyun API Message Types

struct AliyunRunTaskInstruction: Codable {
    let header: Header
    let payload: Payload

    struct Header: Codable {
        let action = "run-task"
        let task_id: String
        let streaming = "duplex"
    }

    struct Payload: Codable {
        let task_group = "audio"
        let task = "asr"
        let function = "recognition"
        let model: String
        let parameters: Parameters
        let input: Input
    }

    struct Parameters: Codable {
        let format = "pcm"
        let sample_rate = 16000
        let language_hints: [String]?
    }

    struct Input: Codable {
        // Empty input object
    }

    init(taskId: String, model: String, language: String?) {
        self.header = Header(task_id: taskId)

        var languageHints: [String]? = nil
        if let lang = language {
            languageHints = [lang]
        }

        self.payload = Payload(
            model: model,
            parameters: Parameters(language_hints: languageHints),
            input: Input()
        )
    }
}



struct AliyunFinishTaskInstruction: Codable {
    let header: Header
    let payload: Payload

    struct Header: Codable {
        let action = "finish-task"
        let task_id: String
        let streaming = "duplex"
    }

    struct Payload: Codable {
        let input: Input
    }

    struct Input: Codable {
        // Empty input object
    }

    init(taskId: String) {
        self.header = Header(task_id: taskId)
        self.payload = Payload(input: Input())
    }
}

struct AliyunEvent: Codable {
    let header: Header
    let payload: Payload?

    struct Header: Codable {
        let task_id: String
        let event: String
        let streaming: String?
        let error_code: String?
        let error_message: String?
    }

    struct Payload: Codable {
        let output: Output?
    }

    struct Output: Codable {
        let text: String?        // 保留旧字段以兼容
        let sentence: Sentence?  // Aliyun实际返回的字段
    }
    
    struct Sentence: Codable {
        let text: String?
        let words: [Word]?
    }
    
    struct Word: Codable {
        let text: String?
        let begin_time: Int?
        let end_time: Int?
        let punctuation: String?
    }
}

/// 阿里云转录客户端（非 actor 包装器，用于依赖注入）
struct AliyunTranscriptionClient {
    let apiKey: String
    
    func testAPIKey() async -> Bool {
        let engine = AliyunTranscriptionEngine(apiKey: apiKey)
        return await engine.testAPIKey()
    }
    
    func transcribe(
        audioURL: URL,
        model: TranscriptionModelType,
        options: DecodingOptions,
        settings: HexSettings?,
        progressCallback: @escaping (Progress) -> Void
    ) async throws -> String {
        let engine = AliyunTranscriptionEngine(apiKey: apiKey)
        return try await engine.transcribe(
            audioURL: audioURL,
            model: model,
            options: options,
            settings: settings,
            progressCallback: progressCallback
        )
    }
}