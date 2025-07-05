# OpenAI 转录客户端技术文档

## 概述

OpenAI 转录客户端是 Hex 应用中负责与 OpenAI Speech-to-Text API 集成的核心组件。它提供了安全、高效的音频转录服务，支持多种音频格式和配置选项。

## 架构设计

该模块采用 Actor 模式和依赖注入设计，包含两个主要组件：

### 1. OpenAITranscriptionEngine (Actor)
- **类型**: `actor`
- **作用**: 核心转录引擎，处理并发安全的 API 调用
- **特点**: 使用 Swift 并发模型确保线程安全

### 2. OpenAITranscriptionClient (Struct)
- **类型**: `struct`
- **作用**: 客户端包装器，用于依赖注入和外部接口
- **特点**: 轻量级包装，便于测试和模块化

## 主要功能

### 1. API 密钥验证
```swift
func testAPIKey() async -> Bool
```
- 验证 OpenAI API 密钥的有效性
- 通过调用 `/models` 端点检查认证状态
- 设置 10 秒超时，快速失败机制

### 2. 音频转录
```swift
func transcribe(
    audioURL: URL,
    model: TranscriptionModelType,
    options: DecodingOptions,
    settings: HexSettings?,
    progressCallback: @escaping (Progress) -> Void
) async throws -> String
```

#### 参数说明：
- `audioURL`: 音频文件的本地路径
- `model`: 转录模型类型（必须是 OpenAI 提供商）
- `options`: 解码选项（语言、时间戳等）
- `settings`: 应用设置（如禁用自动大写）
- `progressCallback`: 进度回调函数

#### 转录流程：
1. **模型验证**: 确认使用的是 OpenAI 模型
2. **文件大小检查**: 限制 25MB（OpenAI API 限制）
3. **构建请求**: 创建 multipart/form-data 请求
4. **发送请求**: 调用 OpenAI API
5. **解析响应**: 提取转录文本
6. **应用设置**: 根据用户设置处理文本

## 技术实现细节

### 1. 文件大小限制
- 最大文件大小：25MB
- 超出限制时抛出 `TranscriptionError.fileTooLarge`

### 2. 支持的音频格式
- MP3 (audio/mpeg)
- WAV (audio/wav)
- M4A (audio/m4a)
- FLAC (audio/flac)
- MP4 (audio/mp4)
- MPEG (audio/mpeg)
- MPGA (audio/mpeg)
- WebM (audio/webm)

### 3. HTTP 请求配置
- 基础 URL: `https://api.openai.com/v1`
- 认证方式: Bearer Token
- 超时设置: 5 分钟（300 秒）
- 请求格式: multipart/form-data

### 4. 进度跟踪
进度回调分为以下阶段：
- 0%: 开始转录
- 10%: 文件大小检查完成
- 30%: 请求准备完成
- 80%: API 响应接收完成
- 100%: 转录完成

### 5. 错误处理
自定义错误类型处理：
- `TranscriptionError.invalidModel`: 模型不匹配
- `TranscriptionError.fileTooLarge`: 文件过大
- `TranscriptionError.invalidResponse`: 响应格式错误
- `TranscriptionError.apiError`: API 错误

## API 集成详解

### 1. 认证
```swift
request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
```

### 2. 请求体构建
使用 multipart/form-data 格式，包含以下字段：
- `file`: 音频文件数据
- `model`: 转录模型名称
- `language`: 语言代码（可选）
- `response_format`: 响应格式（固定为 "json"）
- `timestamp_granularities[]`: 时间戳粒度（可选）

### 3. 响应解析
```swift
struct OpenAITranscriptionResponse: Codable {
    let text: String
}
```

## 配置选项

### 1. 语言设置
- 支持自动检测（"auto"）
- 支持指定语言代码
- 使用 ISO 639-1 标准

### 2. 时间戳设置
- 可通过 `options.withoutTimestamps` 控制
- 支持段落级别的时间戳

### 3. 文本处理
- 支持禁用自动大写（`settings.disableAutoCapitalization`）
- 保持原始转录结果的格式

## 日志记录

集成了 TokLogger 系统，记录关键操作：
- 转录开始：记录模型和文件大小
- 转录完成：记录结果预览
- 错误情况：记录错误详情和状态码

## 使用示例

```swift
// 创建客户端
let client = OpenAITranscriptionClient(apiKey: "your-api-key")

// 测试 API 密钥
let isValid = await client.testAPIKey()

// 执行转录
let result = try await client.transcribe(
    audioURL: audioFileURL,
    model: .whisper1,
    options: DecodingOptions(language: "zh", withoutTimestamps: false),
    settings: settings,
    progressCallback: { progress in
        print("转录进度: \(progress.fractionCompleted)")
    }
)
```

## 性能优化

1. **并发安全**: 使用 Actor 模式确保线程安全
2. **超时控制**: 设置合理的超时时间防止长时间等待
3. **错误快速失败**: API 密钥验证快速返回结果
4. **内存管理**: 及时释放音频数据避免内存泄漏

## 限制和注意事项

### 1. 文件大小限制
- OpenAI API 限制单个文件最大 25MB
- 超出限制需要考虑文件分割或压缩

### 2. 网络依赖
- 需要稳定的网络连接
- 建议在网络状况良好时使用

### 3. API 成本
- 基于音频时长计费
- 需要合理控制使用频率

### 4. 支持的模型
- 目前仅支持 OpenAI 提供商的模型
- 需要确保模型类型匹配

## 依赖项

- `Foundation`: 基础网络和数据处理
- `Dependencies`: 依赖注入框架
- `WhisperKit`: 转录相关类型定义

## 未来扩展

1. **批量转录**: 支持多文件同时转录
2. **断点续传**: 大文件转录中断后继续
3. **缓存机制**: 相同文件避免重复转录
4. **模型切换**: 动态选择最优模型
5. **本地备份**: 转录结果本地存储

## 维护说明

1. 定期检查 OpenAI API 更新
2. 监控错误率和性能指标
3. 更新支持的音频格式
4. 优化错误处理机制 