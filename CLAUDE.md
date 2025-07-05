# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Development Commands

**Build the project:**
```bash
xcodebuild -scheme Tok -configuration Debug build
```

**List available schemes:**
```bash
xcodebuild -list
```

**Run linting and type checking:**
The project requires running linting and typechecking after code changes. Check for specific commands in the codebase or ask the user if not immediately apparent.

## Architecture Overview

### Core Framework Stack
- **Swift Composable Architecture (TCA)**: State management and feature composition
- **SwiftUI**: UI layer with @Bindable stores and reactive updates  
- **WhisperKit**: Local speech-to-text transcription
- **Dependencies framework**: Dependency injection and testing
- **Swift 6 with async/await**: Modern concurrency patterns

### Application Structure

**Main App Features (TCA Reducers):**
- `AppFeature`: Root coordinator managing tabs and global state
- `TranscriptionFeature`: Core voice recording and transcription logic
- `SettingsFeature`: Configuration management with provider-specific settings
- `HistoryFeature`: Transcription history management
- `OnboardingFeature`: First-run user experience
- `ModelDownloadFeature`: Local model management for WhisperKit

**Transcription Architecture:**
The app supports three transcription providers through a unified interface:
- **WhisperKit (Local)**: On-device processing with downloadable models
- **OpenAI Whisper API**: Remote HTTP-based transcription 
- **Aliyun DashScope**: Real-time WebSocket streaming transcription

Provider routing is handled in `TranscriptionClient.swift` with provider-specific implementations:
- `OpenAITranscriptionClient.swift`: HTTP multipart uploads
- `AliyunTranscriptionClient.swift`: WebSocket-based streaming with actor concurrency

**Settings and State Management:**
- `HexSettings`: Centralized configuration struct with provider-specific API keys
- Uses `@Shared(.hexSettings)` for cross-feature state synchronization
- Settings include transcription provider selection, model configuration, and API key management

### Key Patterns

**TCA Navigation:**
Uses tree-based navigation with `@Presents` macro and `PresentationAction`:
```swift
@Presents var destination: Destination.State?
case destination(PresentationAction<Destination.Action>)
```

**Dependency Injection:**
All external dependencies (clients, effects) are injected via `@Dependency`:
```swift
@Dependency(\.transcription) var transcription
@Dependency(\.recording) var recording
```

**Actor-Based Concurrency:**
WebSocket connections and audio processing use Swift actors for thread safety:
```swift
actor AliyunTranscriptionEngine {
    private var webSocket: URLSessionWebSocketTask?
    private var currentTaskId: String?
}
```

### Provider Integration Patterns

When adding new transcription providers:
1. Define provider enum in `TranscriptionModels.swift`
2. Add API key fields to `HexSettings.swift` 
3. Create provider-specific client (e.g., `[Provider]TranscriptionClient.swift`)
4. Add routing logic in `TranscriptionClient.swift`
5. Update UI in `SettingsView.swift` with provider-specific configuration

### Audio Processing
- Uses `RecordingClient` for cross-platform audio capture
- Audio data flows: Recording → Provider Client → Transcription Result → UI
- WebSocket providers require PCM format conversion from WAV headers

### Logging and Debugging
- `TokLogger.log()` for structured logging with levels (info, warn, error)
- Extensive logging in WebSocket implementations for debugging connection issues
- Use logging to trace audio data flow and API interactions

## Development Notes

**Model Management:**
- Local models stored in Application Support directory
- Model warm status tracking (cold/warming/warm) for performance optimization
- Curated model list in `models.json` with metadata

**API Key Security:**
- All API keys stored in user defaults, never committed to repository
- API key validation with connection testing
- Provider-specific error handling and validation

**Hotkey System:**
- Global hotkey capture using `KeyEventMonitorClient`
- Accessibility permissions required for system-wide key monitoring
- Press-and-hold paradigm for voice activation