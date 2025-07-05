import AVFoundation
import ComposableArchitecture
import Dependencies
import IdentifiedCollections
import Sauce
import ServiceManagement
import SwiftUI

extension SharedReaderKey
  where Self == InMemoryKey<Bool>.Default
{
  static var isSettingHotKey: Self {
    Self[.inMemory("isSettingHotKey"), default: false]
  }
}

// MARK: - Settings Feature

@Reducer
struct SettingsFeature {
  @ObservableState
  struct State {
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isSettingHotKey) var isSettingHotKey: Bool = false

    var languages: IdentifiedArrayOf<Language> = []
    var currentModifiers: Modifiers = .init(modifiers: [])
    
    // Available microphones
    var availableInputDevices: [AudioInputDevice] = []

    // Permissions
    var microphonePermission: PermissionStatus = .notDetermined
    var accessibilityPermission: PermissionStatus = .notDetermined

    // Model Management
    var modelDownload = ModelDownloadFeature.State()
    
    // AI Enhancement
    var aiEnhancement = AIEnhancementFeature.State()
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)

    // Existing
    case task
    case startSettingHotKey
    case keyEvent(KeyEvent)
    case toggleOpenOnLogin(Bool)
    case togglePreventSystemSleep(Bool)
    case togglePauseMediaOnRecord(Bool)
    case checkPermissions
    case setMicrophonePermission(PermissionStatus)
    case setAccessibilityPermission(PermissionStatus)
    case requestMicrophonePermission
    case requestAccessibilityPermission
    case accessibilityStatusDidChange
    
    // Microphone selection
    case loadAvailableInputDevices
    case availableInputDevicesLoaded([AudioInputDevice])

    // Model Management
    case modelDownload(ModelDownloadFeature.Action)
    
    // AI Enhancement
    case aiEnhancement(AIEnhancementFeature.Action)
    
    // OpenAI API Key Testing
    case testOpenAIAPIKey
    case openAIAPIKeyTestResult(Bool)

    // Navigation
    case openHistory
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.continuousClock) var clock
  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.modelDownload, action: \.modelDownload) {
      ModelDownloadFeature()
    }
    
    Scope(state: \.aiEnhancement, action: \.aiEnhancement) {
      AIEnhancementFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .run { _ in
          await MainActor.run {
            NotificationCenter.default.post(name: NSNotification.Name("UpdateAppMode"), object: nil)
          }
        }

      case .task:
        print("🚀 [SETTINGS] SettingsFeature.task started")
        print("🔐 [PERMISSION] Current permission states - mic: \(state.microphonePermission), accessibility: \(state.accessibilityPermission)")
        
        if let url = Bundle.main.url(forResource: "languages", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let languages = try? JSONDecoder().decode([Language].self, from: data)
        {
          state.languages = IdentifiedArray(uniqueElements: languages)
        } else {
          print("Failed to load languages")
        }

        // Listen for key events and load microphones (existing + new)
        let shouldCheckPermissions = state.microphonePermission == .notDetermined || state.accessibilityPermission == .notDetermined
        print("🔐 [PERMISSION] shouldCheckPermissions: \(shouldCheckPermissions)")
        return .run { send in
          // Only check permissions if they haven't been determined yet
          if shouldCheckPermissions {
            await send(.checkPermissions)
          }
          await send(.modelDownload(.fetchModels))
          await send(.loadAvailableInputDevices)
          
          // Set up periodic refresh of available devices (every 180 seconds = 3 minutes)
          // Using an even longer interval to further reduce resource usage
          let deviceRefreshTask = Task { @MainActor in
            for await _ in clock.timer(interval: .seconds(180)) {
              // Only refresh when the app is active AND the settings panel is visible
              let isActive = NSApplication.shared.isActive
              let areSettingsVisible = NSApp.windows.contains { 
                $0.isVisible && ($0.title.contains("Settings") || $0.title.contains("Preferences")) 
              }
              
              if isActive && areSettingsVisible {
                send(.loadAvailableInputDevices)
              }
            }
          }
          
          // Listen for device connection/disconnection notifications
          // Using a simpler debounced approach with a single task
          var deviceUpdateTask: Task<Void, Never>?
          
          // Helper function to debounce device updates
          func debounceDeviceUpdate() {
            deviceUpdateTask?.cancel()
            deviceUpdateTask = Task {
              try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
              if !Task.isCancelled {
                await send(.loadAvailableInputDevices)
              }
            }
          }
          
          let deviceConnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasConnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }
          
          let deviceDisconnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasDisconnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }
          
          // Be sure to clean up resources when the task is finished
          defer {
            deviceUpdateTask?.cancel()
            NotificationCenter.default.removeObserver(deviceConnectionObserver)
            NotificationCenter.default.removeObserver(deviceDisconnectionObserver)
          }

          for try await keyEvent in await keyEventMonitor.listenForKeyPress() {
            await send(.keyEvent(keyEvent))
          }
          
          deviceRefreshTask.cancel()
        }

      case .startSettingHotKey:
        state.$isSettingHotKey.withLock { $0 = true }
        return .none

      case let .keyEvent(keyEvent):
        guard state.isSettingHotKey else { return .none }

        if keyEvent.key == .escape {
          state.$isSettingHotKey.withLock { $0 = false }
          state.currentModifiers = []
          return .none
        }

        state.currentModifiers = keyEvent.modifiers.union(state.currentModifiers)
        let currentModifiers = state.currentModifiers
        if let key = keyEvent.key {
          state.$hexSettings.withLock {
            $0.hotkey.key = key
            $0.hotkey.modifiers = currentModifiers
          }
          state.$isSettingHotKey.withLock { $0 = false }
          state.currentModifiers = []
        } else if keyEvent.modifiers.isEmpty {
          state.$hexSettings.withLock {
            $0.hotkey.key = nil
            $0.hotkey.modifiers = currentModifiers
          }
          state.$isSettingHotKey.withLock { $0 = false }
          state.currentModifiers = []
        }
        return .none

      case let .toggleOpenOnLogin(enabled):
        state.$hexSettings.withLock { $0.openOnLogin = enabled }
        return .run { _ in
          if enabled {
            try? SMAppService.mainApp.register()
          } else {
            try? SMAppService.mainApp.unregister()
          }
        }

      case let .togglePreventSystemSleep(enabled):
        state.$hexSettings.withLock { $0.preventSystemSleep = enabled }
        return .none

      case let .togglePauseMediaOnRecord(enabled):
        state.$hexSettings.withLock { $0.pauseMediaOnRecord = enabled }
        return .none

      // Permissions
      case .checkPermissions:
        print("🔐 [PERMISSION] checkPermissions called")
        // Check microphone
        return .merge(
          .run { send in
            let currentStatus = await checkMicrophonePermission()
            print("🔐 [PERMISSION] Initial microphone check: \(currentStatus)")
            await send(.setMicrophonePermission(currentStatus))
          },
          .run { send in
            let currentStatus = checkAccessibilityPermission()
            print("🔐 [PERMISSION] Initial accessibility check: \(currentStatus)")
            await send(.setAccessibilityPermission(currentStatus))
          }
        )

      case let .setMicrophonePermission(status):
        state.microphonePermission = status
        return .none

      case let .setAccessibilityPermission(status):
        print("🔐 [PERMISSION] setAccessibilityPermission: \(state.accessibilityPermission) -> \(status)")
        state.accessibilityPermission = status
        if status == .granted {
          return .run { _ in
            print("🔐 [PERMISSION] Starting keyEventMonitor after 1s delay...")
            // Add a delay to allow system permission state to fully propagate
            // before attempting to create CGEvent tap
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
            print("🔐 [PERMISSION] Calling keyEventMonitor.startMonitoring()")
            await keyEventMonitor.startMonitoring()
          }
        } else {
          print("🔐 [PERMISSION] Permission denied, not starting keyEventMonitor")
          return .none
        }

      case .requestMicrophonePermission:
        return .run { send in
          let granted = await requestMicrophonePermissionImpl()
          let status: PermissionStatus = granted ? .granted : .denied
          await send(.setMicrophonePermission(status))
        }

      case .requestAccessibilityPermission:
        return .run { send in
          print("🔐 [PERMISSION] requestAccessibilityPermission started")
          
          // First, prompt the user with the system dialog
          let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
          _ = AXIsProcessTrustedWithOptions(options)
          print("🔐 [PERMISSION] System permission dialog triggered")

          // Open System Settings
          if #available(macOS 13.0, *) {
            // For macOS 13+ (System Settings)
            NSWorkspace.shared.open(
              URL(string: "x-apple.systempreferences:com.apple.SystemPreferences.Extensions?Privacy_Accessibility")!
            )
            print("🔐 [PERMISSION] Opened System Settings (macOS 13+)")
          } else {
            // For macOS 12 and earlier (System Preferences)
            NSWorkspace.shared.open(
              URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
            print("🔐 [PERMISSION] Opened System Preferences (macOS 12-)")
          }

          // Poll for changes with state stability checking
          var grantedCount = 0
          var deniedCount = 0
          let requiredConsistentChecks = 3
          var totalChecks = 0
          
          print("🔐 [PERMISSION] Starting polling loop...")
          
          for await _ in self.clock.timer(interval: .seconds(0.5)) {
            totalChecks += 1
            let currentStatus = checkAccessibilityPermission()
            
            print("🔐 [PERMISSION] Poll #\(totalChecks): \(currentStatus) (granted: \(grantedCount), denied: \(deniedCount))")
            
            // Count consecutive status results to ensure stability
            if currentStatus == .granted {
              grantedCount += 1
              deniedCount = 0
            } else {
              deniedCount += 1
              grantedCount = 0
            }
            
            // Only update state if we have consistent results
            if grantedCount >= requiredConsistentChecks {
              // Permission is stable and granted
              print("🔐 [PERMISSION] Permission STABLE and GRANTED after \(grantedCount) consecutive checks")
              await send(.setAccessibilityPermission(.granted))
              break
            } else if deniedCount >= requiredConsistentChecks {
              // Permission is stable and denied, continue polling
              print("🔐 [PERMISSION] Permission STABLE and DENIED after \(deniedCount) consecutive checks")
              await send(.setAccessibilityPermission(.denied))
            }
            
            // Safety timeout after 2 minutes
            if deniedCount + grantedCount > 240 { // 240 * 0.5s = 2 minutes
              print("🔐 [PERMISSION] Polling timeout reached after 2 minutes")
              break
            }
          }
          
          print("🔐 [PERMISSION] Polling loop ended")
        }

      case .accessibilityStatusDidChange:
        // Add state validation to ensure the permission change is stable
        return .run { send in
          print("🔐 [PERMISSION] accessibilityStatusDidChange triggered")
          
          // Check permission status multiple times with delays to ensure stability
          var stableStatus: PermissionStatus?
          let checkCount = 3
          
          for i in 0..<checkCount {
            let currentStatus = checkAccessibilityPermission()
            print("🔐 [PERMISSION] accessibilityStatusDidChange check \(i+1)/\(checkCount): \(currentStatus)")
            
            if i == 0 {
              stableStatus = currentStatus
            } else if stableStatus != currentStatus {
              // Status changed between checks, reset and start over
              print("🔐 [PERMISSION] Status changed between checks, resetting")
              stableStatus = nil
              break
            }
            
            // Wait between checks to allow system state to stabilize
            if i < checkCount - 1 {
              try? await Task.sleep(nanoseconds: 150_000_000) // 150ms delay
            }
          }
          
          // Only update if we have a stable status
          if let finalStatus = stableStatus {
            print("🔐 [PERMISSION] accessibilityStatusDidChange sending stable status: \(finalStatus)")
            await send(.setAccessibilityPermission(finalStatus))
          } else {
            print("🔐 [PERMISSION] accessibilityStatusDidChange - no stable status found")
          }
        }

      // Model Management
      case let .modelDownload(.selectModel(newModel)):
        // Also store it in hexSettings:
        state.$hexSettings.withLock {
          $0.selectedModel = newModel
        }
        // Then continue with the child's normal logic:
        return .none

      case .modelDownload:
        return .none
        
      // AI Enhancement
      case .aiEnhancement:
        return .none
      
      // Microphone device selection
      case .loadAvailableInputDevices:
        return .run { send in
          let devices = await recording.getAvailableInputDevices()
          await send(.availableInputDevicesLoaded(devices))
        }
        
      case let .availableInputDevicesLoaded(devices):
        state.availableInputDevices = devices
        return .none

      // OpenAI API Key Testing
      case .testOpenAIAPIKey:
        guard !state.hexSettings.openaiAPIKey.isEmpty else {
          return .none
        }
        
        return .run { [apiKey = state.hexSettings.openaiAPIKey] send in
          let isValid = await transcription.testOpenAIConnection(apiKey)
          await send(.openAIAPIKeyTestResult(isValid))
        }
        
      case let .openAIAPIKeyTestResult(isValid):
        state.$hexSettings.withLock {
          $0.openaiAPIKeyIsValid = isValid
          $0.openaiAPIKeyLastTested = Date()
        }
        
        if isValid {
          TokLogger.log("OpenAI API key validation successful")
        } else {
          TokLogger.log("OpenAI API key validation failed", level: .warn)
        }
        
        return .none

      // Navigation
      case .openHistory:
        return .none
      }
    }
  }
}

// MARK: - Permissions Helpers

/// Check current microphone permission
private func checkMicrophonePermission() async -> PermissionStatus {
  switch AVCaptureDevice.authorizationStatus(for: .audio) {
  case .authorized:
    return .granted
  case .denied, .restricted:
    return .denied
  case .notDetermined:
    return .notDetermined
  @unknown default:
    return .denied
  }
}

/// Request microphone permission
private func requestMicrophonePermissionImpl() async -> Bool {
  await withCheckedContinuation { continuation in
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      continuation.resume(returning: granted)
    }
  }
}

/// Check Accessibility permission on macOS
/// This implementation checks the actual trust status without showing a prompt
private func checkAccessibilityPermission() -> PermissionStatus {
  let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
  let trusted = AXIsProcessTrustedWithOptions(options)
  let status: PermissionStatus = trusted ? .granted : .denied
  
  print("🔐 [PERMISSION] checkAccessibilityPermission() -> \(status) (trusted: \(trusted))")
  
  return status
}


// MARK: - Permission Status
// PermissionStatus is now defined in Models/PermissionStatus.swift
