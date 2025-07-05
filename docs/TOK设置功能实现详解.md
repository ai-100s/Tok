# TOK 设置功能实现详解

## 1. 概述

TOK 的设置功能是一个基于 **The Composable Architecture (TCA)** 构建的复杂系统，它展示了现代 SwiftUI 应用中状态管理、模块化设计和依赖注入的最佳实践。本文档将深入分析其实现细节，包括架构设计、数据流、UI 组件以及各个子模块的具体实现。

## 2. 核心架构设计

### 2.1 整体架构图

```mermaid
graph TB
    subgraph "应用层 (App Layer)"
        AppFeature[AppFeature<br/>顶级聚合器]
        AppView[AppView<br/>导航容器]
    end
    
    subgraph "设置模块 (Settings Module)"
        SettingsFeature[SettingsFeature<br/>主设置逻辑]
        SettingsView[SettingsView<br/>主设置界面]
    end
    
    subgraph "子功能模块 (Sub-Features)"
        ModelDownloadFeature[ModelDownloadFeature<br/>模型管理]
        AIEnhancementFeature[AIEnhancementFeature<br/>AI增强]
        ModelDownloadView[ModelDownloadView<br/>模型下载界面]
        AIEnhancementView[AIEnhancementView<br/>AI增强界面]
    end
    
    subgraph "数据层 (Data Layer)"
        HexSettings[HexSettings<br/>配置数据模型]
        SharedState[@Shared状态共享]
        FileStorage[文件持久化<br/>hex_settings.json]
    end
    
    subgraph "系统集成 (System Integration)"
        Permissions[权限管理<br/>麦克风/辅助功能]
        HotKeyMonitor[热键监听<br/>键盘事件]
        AudioDevices[音频设备<br/>麦克风选择]
        ModelManagement[模型管理<br/>下载/删除]
    end
    
    AppFeature --> SettingsFeature
    AppView --> AppFeature
    SettingsFeature --> ModelDownloadFeature
    SettingsFeature --> AIEnhancementFeature
    SettingsView --> SettingsFeature
    ModelDownloadView --> ModelDownloadFeature
    AIEnhancementView --> AIEnhancementFeature
    
    SettingsFeature --> HexSettings
    ModelDownloadFeature --> HexSettings
    AIEnhancementFeature --> HexSettings
    HexSettings --> SharedState
    SharedState --> FileStorage
    
    SettingsFeature --> Permissions
    SettingsFeature --> HotKeyMonitor
    SettingsFeature --> AudioDevices
    ModelDownloadFeature --> ModelManagement
```

### 2.2 TCA 架构模式

TOK 严格遵循 TCA 的 **State-Action-Reducer** 模式：

- **State**: 不可变的数据结构，描述应用的当前状态
- **Action**: 描述可能发生的事件或用户交互
- **Reducer**: 纯函数，根据当前状态和动作计算新状态
- **Effect**: 处理副作用，如网络请求、文件操作等

## 3. 数据模型与状态管理

### 3.1 HexSettings - 核心数据模型

`HexSettings` 是整个应用配置的单一数据源，包含 50+ 个配置项：

```swift
struct HexSettings: Codable, Equatable {
    // 基础设置
    var soundEffectsEnabled: Bool = true
    var hotkey: HotKey = .init(key: nil, modifiers: [.option])
    var openOnLogin: Bool = false
    var showDockIcon: Bool = true
    
    // 转录设置
    var selectedModel: String = "openai_whisper-large-v3-v20240930"
    var selectedTranscriptionModel: TranscriptionModelType = .whisperLarge
    var outputLanguage: String? = nil
    var selectedMicrophoneID: String? = nil
    var disableAutoCapitalization: Bool = false
    
    // AI 增强设置
    var useAIEnhancement: Bool = false
    var selectedAIModel: String = "gemma3"
    var aiEnhancementPrompt: String = EnhancementOptions.defaultPrompt
    var aiEnhancementTemperature: Double = 0.3
    var aiProviderType: AIProviderType = .ollama
    
    // OpenAI API 配置
    var openaiAPIKey: String = ""
    var openaiAPIKeyLastTested: Date? = nil
    var openaiAPIKeyIsValid: Bool = false
    
    // 屏幕捕获和图像分析
    var enableScreenCapture: Bool = false
    var selectedImageModel: String = "llava:latest"
    var imageAnalysisPrompt: String = defaultImageAnalysisPrompt
    
    // 开发者选项
    var developerModeEnabled: Bool = false
    
    // ... 更多配置项
}
```

#### 3.1.1 向后兼容性设计

为了确保应用升级时不会因为新增配置项而崩溃，`HexSettings` 实现了自定义的 `Codable` 解码器：

```swift
init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    
    // 使用 decodeIfPresent 为每个字段提供默认值
    soundEffectsEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEffectsEnabled) ?? true
    hotkey = try container.decodeIfPresent(HotKey.self, forKey: .hotkey) ?? .init(key: nil, modifiers: [.option])
    openOnLogin = try container.decodeIfPresent(Bool.self, forKey: .openOnLogin) ?? false
    // ... 其他字段
}
```

这种设计确保了：
- 老版本用户升级后不会因缺少新字段而解析失败
- 新字段自动使用合理的默认值
- 保持数据结构的演进能力

#### 3.1.2 全局状态共享机制

TOK 使用 TCA 的 `@Shared` 属性包装器实现全局状态共享：

```swift
extension SharedReaderKey where Self == FileStorageKey<HexSettings>.Default {
    static var hexSettings: Self {
        Self[
            .fileStorage(URL.documentsDirectory.appending(component: "hex_settings.json")),
            default: getCachedSettings()
        ]
    }
}
```

**工作原理**：
1. **文件存储**: 配置自动持久化到 `~/Documents/hex_settings.json`
2. **内存缓存**: 使用 `getCachedSettings()` 减少磁盘 I/O
3. **响应式更新**: 任何 Feature 修改配置后，所有订阅的 UI 自动更新

### 3.2 热键系统设计

#### 3.2.1 热键数据结构

```swift
public struct HotKey: Codable, Equatable {
    public var key: Key?           // 可选的具体按键
    public var modifiers: Modifiers // 修饰键组合
}

public struct Modifiers: Codable, Equatable {
    var modifiers: Set<Modifier>
    
    // 特殊的超级键检测
    public var isHyperkey: Bool {
        return modifiers.contains(.command) && 
               modifiers.contains(.option) && 
               modifiers.contains(.shift) && 
               modifiers.contains(.control)
    }
}
```

#### 3.2.2 热键录制机制

热键录制通过一个内存中的共享状态来协调：

```swift
extension SharedReaderKey where Self == InMemoryKey<Bool>.Default {
    static var isSettingHotKey: Self {
        Self[.inMemory("isSettingHotKey"), default: false]
    }
}
```

**录制流程**：
1. 用户点击热键视图 → 发送 `startSettingHotKey` 动作
2. `isSettingHotKey` 设为 `true`，UI 进入录制状态
3. `keyEventMonitor` 开始捕获键盘事件
4. 每个键盘事件触发 `keyEvent` 动作
5. Reducer 处理事件，更新 `currentModifiers` 或完成录制
6. 完成后 `isSettingHotKey` 设为 `false`

```swift
case let .keyEvent(keyEvent):
    guard state.isSettingHotKey else { return .none }
    
    // ESC 键取消录制
    if keyEvent.key == .escape {
        state.$isSettingHotKey.withLock { $0 = false }
        state.currentModifiers = []
        return .none
    }
    
    // 累积修饰键
    state.currentModifiers = keyEvent.modifiers.union(state.currentModifiers)
    let currentModifiers = state.currentModifiers
    
    // 检测到具体按键，完成录制
    if let key = keyEvent.key {
        state.$hexSettings.withLock {
            $0.hotkey.key = key
            $0.hotkey.modifiers = currentModifiers
        }
        state.$isSettingHotKey.withLock { $0 = false }
        state.currentModifiers = []
    }
    // 只有修饰键的组合（如纯 Option 键）
    else if keyEvent.modifiers.isEmpty {
        state.$hexSettings.withLock {
            $0.hotkey.key = nil
            $0.hotkey.modifiers = currentModifiers
        }
        state.$isSettingHotKey.withLock { $0 = false }
        state.currentModifiers = []
    }
    return .none
```

## 4. 主要功能模块实现

### 4.1 SettingsFeature - 主设置模块

#### 4.1.1 状态结构

```swift
@ObservableState
struct State {
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isSettingHotKey) var isSettingHotKey: Bool = false
    
    // 语言列表
    var languages: IdentifiedArrayOf<Language> = []
    
    // 热键录制状态
    var currentModifiers: Modifiers = .init(modifiers: [])
    
    // 音频设备
    var availableInputDevices: [AudioInputDevice] = []
    
    // 权限状态
    var microphonePermission: PermissionStatus = .notDetermined
    var accessibilityPermission: PermissionStatus = .notDetermined
    
    // 子功能模块
    var modelDownload = ModelDownloadFeature.State()
    var aiEnhancement = AIEnhancementFeature.State()
}
```

#### 4.1.2 权限管理实现

**权限检查**：
```swift
private func checkMicrophonePermission() async -> PermissionStatus {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return .granted
    case .denied, .restricted: return .denied
    case .notDetermined: return .notDetermined
    @unknown default: return .denied
    }
}

private func checkAccessibilityPermission() -> PermissionStatus {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(options)
    return trusted ? .granted : .denied
}
```

**权限请求流程**：
1. **麦克风权限**: 使用 `AVCaptureDevice.requestAccess(for: .audio)` 异步请求
2. **辅助功能权限**: 
   - 显示系统提示对话框
   - 自动打开系统设置页面
   - 每 0.5 秒轮询检查权限状态
   - 获得权限后自动停止轮询

#### 4.1.3 音频设备管理

**设备列表管理**：
```swift
case .task:
    return .run { send in
        // 初始加载设备列表
        await send(.loadAvailableInputDevices)
        
        // 定期刷新（每3分钟）
        let deviceRefreshTask = Task { @MainActor in
            for await _ in clock.timer(interval: .seconds(180)) {
                let isActive = NSApplication.shared.isActive
                let areSettingsVisible = NSApp.windows.contains { 
                    $0.isVisible && ($0.title.contains("Settings") || $0.title.contains("Preferences")) 
                }
                
                if isActive && areSettingsVisible {
                    send(.loadAvailableInputDevices)
                }
            }
        }
        
        // 监听设备连接/断开事件
        let deviceConnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasConnected"),
            object: nil,
            queue: .main
        ) { _ in
            debounceDeviceUpdate()
        }
        // ... 设备断开监听
    }
```

**优化策略**：
- 只在应用活跃且设置窗口可见时刷新设备列表
- 使用防抖动机制避免频繁更新
- 自动清理通知监听器防止内存泄漏

### 4.2 ModelDownloadFeature - 模型管理模块

#### 4.2.1 数据模型

```swift
public struct ModelInfo: Equatable, Identifiable {
    public let name: String
    public var isDownloaded: Bool
    public var id: String { name }
}

public struct CuratedModelInfo: Equatable, Identifiable, Codable {
    public let displayName: String      // 显示名称
    public let internalName: String     // 内部标识
    public let size: String            // 模型大小描述
    public let accuracyStars: Int      // 准确度评级（1-5星）
    public let speedStars: Int         // 速度评级（1-5星）
    public let storageSize: String     // 存储空间需求
    public var isDownloaded: Bool      // 运行时设置
}
```

#### 4.2.2 模型下载流程

```swift
case .downloadSelectedModel:
    guard !state.selectedModel.isEmpty else { return .none }
    state.downloadError = nil
    state.isDownloading = true
    state.downloadingModelName = state.selectedModel
    
    return .run { [state] send in
        do {
            try await transcription.downloadModel(state.selectedModel) { progress in
                Task { await send(.downloadProgress(progress.fractionCompleted)) }
            }
            await send(.downloadCompleted(.success(state.selectedModel)))
        } catch {
            await send(.downloadCompleted(.failure(error)))
        }
    }
    .cancellable(id: CancelID.download)
```

**关键特性**：
- 实时进度更新
- 可取消的下载任务
- 下载完成后自动预热模型
- 错误处理和用户反馈

#### 4.2.3 模型预热机制

```swift
case let .prewarmModel(model):
    state.$hexSettings.withLock { $0.transcriptionModelWarmStatus = .warming }
    
    return .run { send in
        do {
            try await transcription.prewarmModel(model) { progress in
                Task { @MainActor in
                    send(.prewarmProgress(progress.fractionCompleted))
                }
            }
            await send(.prewarmCompleted(.success(model)))
        } catch {
            await send(.prewarmCompleted(.failure(error)))
        }
    }
    .cancellable(id: CancelID.prewarm)
```

**模型状态追踪**：
- `cold`: 模型未加载
- `warming`: 模型正在预热
- `warm`: 模型已就绪

### 4.3 AIEnhancementFeature - AI增强模块

#### 4.3.1 多提供商支持

```swift
enum AIProviderType: String, Codable, CaseIterable {
    case ollama = "ollama"    // 本地 Ollama
    case groq = "groq"        // 远程 Groq API
    
    var displayName: String {
        switch self {
        case .ollama: return "Ollama (Local)"
        case .groq: return "Groq (Remote)"
        }
    }
}
```

#### 4.3.2 动态模型加载

```swift
case .setProviderType(let providerType):
    state.$hexSettings.withLock { $0.aiProviderType = providerType }
    state.errorMessage = nil
    state.connectionStatus = nil
    
    // 根据提供商类型加载对应模型
    switch providerType {
    case .ollama:
        if state.isOllamaAvailable {
            return .merge(
                .send(.loadAvailableModels),
                .send(.loadAvailableImageModels)
            )
        }
    case .groq:
        if !state.currentAPIKey.isEmpty {
            return .merge(
                .send(.loadRemoteModels),
                .send(.loadRemoteImageModels)
            )
        }
    }
    return .none
```

#### 4.3.3 连接测试机制

```swift
case .testConnection:
    state.isTestingConnection = true
    state.connectionStatus = nil
    
    return .run { [provider = state.currentProvider, apiKey = state.currentAPIKey] send in
        let isConnected = await aiEnhancement.testRemoteConnection(provider, apiKey)
        let status = isConnected ? "Connection successful" : "Connection failed"
        await send(.connectionTestResult(isConnected, status))
    }
```

## 5. UI 组件实现

### 5.1 导航结构

#### 5.1.1 AppFeature - 顶级导航控制器

```swift
enum ActiveTab: Equatable {
    case settings
    case history
    case about
    case aiEnhancement
    case developer    // 隐藏的开发者模式
}
```

#### 5.1.2 NavigationSplitView 布局

```swift
NavigationSplitView(columnVisibility: $columnVisibility) {
    List(selection: $store.activeTab) {
        Button { store.send(.setActiveTab(.settings)) } label: {
            Label("Settings", systemImage: "gearshape")
        }
        // ... 其他导航项
        
        // 开发者模式条件显示
        if store.settings.hexSettings.developerModeEnabled {
            Button { store.send(.setActiveTab(.developer)) } label: {
                Label("Developer", systemImage: "hammer")
            }
        }
    }
} detail: {
    switch store.state.activeTab {
    case .settings:
        SettingsView(store: store.scope(state: \.settings, action: \.settings))
    case .aiEnhancement:
        AIEnhancementView(store: store.scope(state: \.settings.aiEnhancement, action: \.settings.aiEnhancement))
    // ... 其他视图
    }
}
```

### 5.2 热键视图组件

#### 5.2.1 HotKeyView 实现

```swift
struct HotKeyView: View {
    var modifiers: Modifiers
    var key: Key?
    var isActive: Bool
    
    var body: some View {
        HStack(spacing: 6) {
            if modifiers.isHyperkey {
                // 超级键显示特殊符号
                KeyView(text: "✦")
            } else {
                ForEach(modifiers.sorted) { modifier in
                    KeyView(text: modifier.stringValue)
                }
            }
            
            if let key {
                KeyView(text: key.toString)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.blue.opacity(isActive ? 0.1 : 0))
                .stroke(Color.blue.opacity(isActive ? 0.2 : 0), lineWidth: 1)
        )
        .animation(.bouncy(duration: 0.3), value: key)
        .animation(.bouncy(duration: 0.3), value: modifiers)
    }
}
```

#### 5.2.2 KeyView 样式设计

```swift
struct KeyView: View {
    var text: String
    
    var body: some View {
        Text(text)
            .font(.title.weight(.bold))
            .foregroundColor(.white)
            .frame(width: 48, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        .black.mix(with: .primary, by: 0.2)
                            .shadow(.inner(color: .white.opacity(0.3), radius: 1, y: 1))
                            .shadow(.inner(color: .black.opacity(0.3), radius: 1, y: -3))
                    )
            )
            .shadow(radius: 4, y: 2)
    }
}
```

### 5.3 模型选择界面

#### 5.3.1 TranscriptionModelPicker

```swift
struct TranscriptionModelPicker: View {
    @Bindable var store: StoreOf<SettingsFeature>
    @State private var showingAPIKeyAlert = false
    
    var body: some View {
        VStack(spacing: 12) {
            // 模型类型选择
            Picker("Transcription Provider", selection: $store.hexSettings.selectedTranscriptionModel) {
                ForEach(TranscriptionModelType.allCases, id: \.self) { model in
                    ModelRow(model: model, settings: store.hexSettings)
                }
            }
            .onChange(of: store.hexSettings.selectedTranscriptionModel) { oldValue, newValue in
                if newValue.requiresAPIKey && store.hexSettings.openaiAPIKey.isEmpty {
                    showingAPIKeyAlert = true
                }
            }
            
            // API Key 配置（远程模型）
            if store.hexSettings.selectedTranscriptionModel.requiresAPIKey {
                APIKeyConfigurationView(store: store)
            }
        }
    }
}
```

#### 5.3.2 ModelRow 状态指示器

```swift
struct ModelRow: View {
    let model: TranscriptionModelType
    let settings: HexSettings
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .fontWeight(.medium)
                
                HStack(spacing: 8) {
                    Label(model.isLocal ? "Local" : "Remote", systemImage: model.iconName)
                        .foregroundColor(model.iconColor)
                    
                    if model.estimatedCostPerMinute > 0 {
                        Label("$\(model.estimatedCostPerMinute, specifier: "%.3f")/min", systemImage: "dollarsign.circle")
                            .foregroundColor(.secondary)
                    } else {
                        Label("Free", systemImage: "checkmark.circle")
                            .foregroundColor(.green)
                    }
                }
            }
            
            Spacer()
            
            // 状态指示器
            if model.requiresAPIKey {
                if settings.openaiAPIKey.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                } else if settings.openaiAPIKeyIsValid {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
```

### 5.4 模型下载界面

#### 5.4.1 CuratedList - 策划模型列表

```swift
private struct CuratedList: View {
    @Bindable var store: StoreOf<ModelDownloadFeature>
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 表头
            HStack(alignment: .bottom) {
                Text("Model").frame(minWidth: 80, alignment: .leading)
                Spacer()
                Text("Accuracy").frame(minWidth: 80, alignment: .leading)
                Spacer()
                Text("Speed").frame(minWidth: 80, alignment: .leading)
                Spacer()
                Text("Size").frame(minWidth: 70, alignment: .leading)
            }
            .font(.caption.bold())
            
            ForEach(store.curatedModels) { model in
                CuratedRow(store: store, model: model)
            }
        }
    }
}
```

#### 5.4.2 星级评价组件

```swift
private struct StarRatingView: View {
    let filled: Int
    let max: Int
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max, id: \.self) { i in
                Image(systemName: i < filled ? "circle.fill" : "circle")
                    .font(.system(size: 7))
                    .foregroundColor(i < filled ? .blue : .gray.opacity(0.5))
            }
        }
    }
}
```

#### 5.4.3 模型状态指示器

```swift
private struct ModelWarmStatusIndicator: View {
    let status: ModelWarmStatus
    
    var body: some View {
        Group {
            switch status {
            case .cold:
                Image(systemName: "snowflake")
                    .foregroundColor(.gray)
                    .help("Model is cold (not loaded)")
            case .warming:
                Image(systemName: "thermometer.medium")
                    .foregroundColor(.orange)
                    .help("Model is warming up...")
            case .warm:
                Image(systemName: "flame.fill")
                    .foregroundColor(.red)
                    .help("Model is warm (ready)")
            }
        }
        .font(.caption)
    }
}
```

## 6. 特殊功能实现

### 6.1 开发者模式激活

#### 6.1.1 隐藏触发机制

```swift
struct AboutView: View {
    @State private var versionTapCount = 0
    
    var body: some View {
        Form {
            Section {
                HStack {
                    Label("Version", systemImage: "info.circle")
                        .onTapGesture {
                            versionTapCount += 1
                            if versionTapCount >= 8 {
                                // 连续点击8次启用开发者模式
                                store.send(.binding(.set(\.hexSettings.developerModeEnabled, true)))
                                versionTapCount = 0
                            }
                        }
                    // ... 版本信息显示
                }
            }
        }
    }
}
```

### 6.2 自动更新集成

#### 6.2.1 Sparkle 框架集成

```swift
@State var viewModel = CheckForUpdatesViewModel.shared

Button("Check for Updates") {
    viewModel.checkForUpdates()
}
```

### 6.3 屏幕捕获功能

#### 6.3.1 屏幕捕获开关

```swift
Toggle(isOn: Binding(
    get: { store.hexSettings.enableScreenCapture },
    set: { newValue in 
        store.$hexSettings.withLock { $0.enableScreenCapture = newValue }
    }
)) {
    Label {
        VStack(alignment: .leading, spacing: 4) {
            Text("Enable Screen Capture")
            Text("Allow capturing screenshots for AI image analysis")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    } icon: {
        Image(systemName: "camera.viewfinder")
    }
}
```

## 7. 性能优化策略

### 7.1 缓存机制

#### 7.1.1 设置缓存

```swift
private var cachedSettings: HexSettings? = nil
private var lastSettingsLoadTime: Date = .distantPast

func getCachedSettings() -> HexSettings {
    if let cached = cachedSettings, 
       Date().timeIntervalSince(lastSettingsLoadTime) < 5.0 {
        return cached
    }
    
    // 从磁盘读取并更新缓存
    // ...
}
```

### 7.2 设备列表优化

#### 7.2.1 智能刷新策略

```swift
// 只在应用活跃且设置窗口可见时刷新
let isActive = NSApplication.shared.isActive
let areSettingsVisible = NSApp.windows.contains { 
    $0.isVisible && ($0.title.contains("Settings") || $0.title.contains("Preferences")) 
}

if isActive && areSettingsVisible {
    send(.loadAvailableInputDevices)
}
```

#### 7.2.2 防抖动机制

```swift
func debounceDeviceUpdate() {
    deviceUpdateTask?.cancel()
    deviceUpdateTask = Task {
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        if !Task.isCancelled {
            await send(.loadAvailableInputDevices)
        }
    }
}
```

### 7.3 内存管理

#### 7.3.1 自动清理机制

```swift
defer {
    deviceUpdateTask?.cancel()
    NotificationCenter.default.removeObserver(deviceConnectionObserver)
    NotificationCenter.default.removeObserver(deviceDisconnectionObserver)
}
```

## 8. 错误处理与用户体验

### 8.1 权限请求流程

#### 8.1.1 渐进式权限请求

```swift
// 麦克风权限状态显示
switch store.microphonePermission {
case .granted:
    Label("Granted", systemImage: "checkmark.circle.fill")
        .foregroundColor(.green)
case .denied:
    Button("Request Permission") {
        store.send(.requestMicrophonePermission)
    }
    .buttonStyle(.borderedProminent)
case .notDetermined:
    Button("Request Permission") {
        store.send(.requestMicrophonePermission)
    }
    .buttonStyle(.bordered)
}
```

### 8.2 API Key 验证

#### 8.2.1 实时验证反馈

```swift
struct APIKeyConfigurationView: View {
    @State private var testingConnection = false
    
    var body: some View {
        VStack(spacing: 12) {
            // API Key 输入框
            HStack {
                if showAPIKey {
                    TextField("OpenAI API Key", text: $store.hexSettings.openaiAPIKey)
                } else {
                    SecureField("OpenAI API Key", text: $store.hexSettings.openaiAPIKey)
                }
                
                Button(action: { showAPIKey.toggle() }) {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                }
            }
            
            // 测试连接状态
            HStack {
                Button("Test Connection") {
                    testConnection()
                }
                .disabled(store.hexSettings.openaiAPIKey.isEmpty || testingConnection)
                
                if testingConnection {
                    ProgressView().scaleEffect(0.8)
                }
                
                Spacer()
                
                if let status = store.connectionStatus {
                    Text(status)
                        .foregroundColor(status.contains("successful") ? .green : .red)
                }
            }
        }
    }
}
```

### 8.3 模型下载错误处理

#### 8.3.1 下载状态管理

```swift
if store.isDownloading, store.downloadingModelName == store.hexSettings.selectedModel {
    VStack(alignment: .leading) {
        Text("Downloading model...")
            .font(.caption)
        ProgressView(value: store.downloadProgress)
            .tint(.blue)
    }
}

if let err = store.downloadError {
    Text("Download Error: \(err)")
        .foregroundColor(.red)
        .font(.caption)
}
```

## 9. 测试与调试

### 9.1 TCA 测试优势

TCA 架构使得单元测试变得非常简单：

```swift
func testHotKeyRecording() {
    let store = TestStore(initialState: SettingsFeature.State()) {
        SettingsFeature()
    }
    
    // 测试开始录制
    store.send(.startSettingHotKey) {
        $0.isSettingHotKey = true
    }
    
    // 测试键盘事件处理
    store.send(.keyEvent(KeyEvent(key: .a, modifiers: [.command]))) {
        $0.hexSettings.hotkey = HotKey(key: .a, modifiers: [.command])
        $0.isSettingHotKey = false
    }
}
```

### 9.2 状态调试

通过 TCA 的状态快照，可以轻松调试状态变化：

```swift
print("Current state: \(store.state)")
print("Settings: \(store.state.hexSettings)")
print("Permissions: microphone=\(store.state.microphonePermission), accessibility=\(store.state.accessibilityPermission)")
```

## 10. 总结

TOK 的设置功能展示了现代 SwiftUI 应用的最佳实践：

### 10.1 架构优势

1. **单向数据流**: TCA 确保数据流向清晰，状态变化可预测
2. **模块化设计**: 每个功能都是独立的 Feature，易于开发和测试
3. **状态共享**: `@Shared` 机制实现了高效的全局状态管理
4. **副作用隔离**: Effect 系统将副作用与纯函数逻辑分离

### 10.2 用户体验

1. **响应式界面**: 状态变化自动触发 UI 更新
2. **渐进式交互**: 权限请求、API 验证等都有清晰的状态反馈
3. **智能优化**: 设备列表刷新、缓存机制等提升性能
4. **错误处理**: 全面的错误处理和用户反馈机制

### 10.3 可维护性

1. **类型安全**: Swift 的类型系统和 TCA 的约束确保代码安全
2. **可测试性**: 纯函数和状态管理使得单元测试变得简单
3. **可扩展性**: 新功能可以作为独立的 Feature 添加
4. **向后兼容**: 配置数据结构的演进不会破坏现有用户数据

这个设置系统是一个完整的、生产就绪的实现，展示了如何在复杂的 macOS 应用中实现高质量的用户配置管理。 