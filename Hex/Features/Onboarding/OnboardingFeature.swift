import ComposableArchitecture
import Dependencies
import Foundation
import SwiftUI
import AVFoundation
import ApplicationServices
import Clocks

@Reducer
struct OnboardingFeature {
  @ObservableState
  struct State {
    @Shared(.hexSettings) var hexSettings: HexSettings
    
    var currentStep: OnboardingStep = .modelSelection
    var microphonePermission: PermissionStatus = .notDetermined
    var accessibilityPermission: PermissionStatus = .notDetermined
    var screenCapturePermission: PermissionStatus = .notDetermined
    var isComplete: Bool = false
    var hasCompletedOnboarding: Bool = false
    var testTranscription: String = ""
    var availableInputDevices: [AudioInputDevice] = []
    // Child state: model selection & download
    var modelDownload: ModelDownloadFeature.State = .init()
    
    enum OnboardingStep: Int, CaseIterable {
      case modelSelection = 0
      case microphone = 1
      case accessibility = 2
      case screenCapture = 3
      case hotkey = 4
      case test = 5
      
      var title: String {
        switch self {
        case .modelSelection: return "Select a Model"
        case .microphone: return "Microphone Access"
        case .accessibility: return "Accessibility Permissions"
        case .screenCapture: return "Screen Capture"
        case .hotkey: return "Set Up Your Hotkey"
        case .test: return "Test It Out"
        }
      }
      
      var description: String {
        switch self {
        case .modelSelection:
          return "Choose a speech-to-text model to download and warm up so transcription is ready when you need it."
        case .microphone:
          return "Tok needs access to your microphone to record and transcribe your speech."
        case .accessibility:
          return "Accessibility permissions allow Tok to monitor your hotkey presses so you can quickly start recording."
        case .screenCapture:
          return "Screen capture helps provide context for better transcription accuracy by analyzing what you're working on."
        case .hotkey:
          return "Set up a convenient hotkey combination to quickly start and stop recording."
        case .test:
          return "Test It Out"
        }
      }
      
      var systemImage: String {
        switch self {
        case .modelSelection: return "square.and.arrow.down"
        case .microphone: return "mic"
        case .accessibility: return "key"
        case .screenCapture: return "camera"
        case .hotkey: return "keyboard"
        case .test: return "play.circle"
        }
      }
    }
  }
  
  @Dependency(\.recording) var recording
  @Dependency(\.screenCapture) var screenCapture
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.continuousClock) var clock
  
  @CasePathable
  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case nextStep
    case previousStep
    case skipStep
    case requestMicrophonePermission
    case requestAccessibilityPermission
    case requestScreenCapturePermission
    case microphonePermissionUpdated(PermissionStatus)
    case accessibilityPermissionUpdated(PermissionStatus)
    case screenCapturePermissionUpdated(PermissionStatus)
    case checkAllPermissions
    case completeOnboarding
    case updateTestTranscription(String)
    case loadAvailableInputDevices
    case availableInputDevicesLoaded([AudioInputDevice])
    case hotkeySet(HotKey)
    // Child action
    case modelDownload(ModelDownloadFeature.Action)
  }
  
  var body: some ReducerOf<Self> {
    BindingReducer()
    
    Scope(state: \.modelDownload, action: \.modelDownload) {
      ModelDownloadFeature()
    }
    
    Reduce { state, action -> Effect<Action> in
      switch action {
      case .binding, .modelDownload:
        return .none
        
      case .nextStep:
        let allSteps = OnboardingFeature.State.OnboardingStep.allCases
        if let currentIndex = allSteps.firstIndex(of: state.currentStep),
           currentIndex < allSteps.count - 1 {
          state.currentStep = allSteps[currentIndex + 1]
          
          // Check permissions when entering relevant steps
          switch state.currentStep {
          case .microphone:
            return .send(.loadAvailableInputDevices)
          case .accessibility, .screenCapture:
            return .send(.checkAllPermissions)
          default:
            return .none
          }
        }
        return .none
        
      case .previousStep:
        let allSteps = OnboardingFeature.State.OnboardingStep.allCases
        if let currentIndex = allSteps.firstIndex(of: state.currentStep),
           currentIndex > 0 {
          state.currentStep = allSteps[currentIndex - 1]
        }
        return .none
        
      case .skipStep:
        return .send(.nextStep)
        
      case .requestMicrophonePermission:
        return .run { send in
          let granted = await recording.requestMicrophoneAccess()
          await send(.microphonePermissionUpdated(granted ? .granted : .denied))
        }
        
      case .requestAccessibilityPermission:
        return .run { send in
          // First, prompt the user with the system dialog
          let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
          _ = AXIsProcessTrustedWithOptions(options)

          // Open System Settings
          if #available(macOS 13.0, *) {
            // For macOS 13+ (System Settings)
            NSWorkspace.shared.open(
              URL(string: "x-apple.systempreferences:com.apple.SystemPreferences.Extensions?Privacy_Accessibility")!
            )
          } else {
            // For macOS 12 and earlier (System Preferences)
            NSWorkspace.shared.open(
              URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
          }

          // Poll for changes with state stability checking
          var grantedCount = 0
          var deniedCount = 0
          let requiredConsistentChecks = 3
          
          for await _ in self.clock.timer(interval: .seconds(0.5)) {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            let currentStatus: PermissionStatus = trusted ? .granted : .denied
            
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
              await send(.accessibilityPermissionUpdated(.granted))
              break
            } else if deniedCount >= requiredConsistentChecks {
              // Permission is stable and denied, continue polling
              await send(.accessibilityPermissionUpdated(.denied))
            }
            
            // Safety timeout after 2 minutes
            if deniedCount + grantedCount > 240 { // 240 * 0.5s = 2 minutes
              break
            }
          }
        }
        
      case .requestScreenCapturePermission:
        return .run { send in
          do {
            // Try to capture screen to trigger permission prompt
            _ = try await screenCapture.captureScreen()
            await send(.screenCapturePermissionUpdated(.granted))
          } catch {
            await send(.screenCapturePermissionUpdated(.denied))
          }
        }
        
      case let .microphonePermissionUpdated(status):
        state.microphonePermission = status
        if status == .granted {
          // Auto advance after short delay
          return .run { send in
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            await send(.nextStep)
          }
        }
        return .none
        
      case let .accessibilityPermissionUpdated(status):
        state.accessibilityPermission = status
        if status == .granted {
          return .run { send in
            // Add delay to allow system permission state to fully propagate
            try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 second delay
            await send(.nextStep)
          }
        }
        return .none
        
      case let .screenCapturePermissionUpdated(status):
        state.screenCapturePermission = status
        if status == .granted {
          state.$hexSettings.withLock { $0.enableScreenCapture = true }
          return .run { send in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            await send(.nextStep)
          }
        }
        return .none
        
      case .checkAllPermissions:
        return .run { send in
          // Check microphone
          let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
          let micPermission: PermissionStatus = switch micAuthStatus {
          case .authorized: .granted
          case .denied: .denied
          case .restricted: .denied
          case .notDetermined: .notDetermined
          @unknown default: .notDetermined
          }
          await send(.microphonePermissionUpdated(micPermission))
          
          // Check accessibility - use consistent method with SettingsFeature
          let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
          let trusted = AXIsProcessTrustedWithOptions(options)
          let accPermission: PermissionStatus = trusted ? .granted : .denied
          await send(.accessibilityPermissionUpdated(accPermission))
          
          // Check screen capture by attempting capture
          do {
            _ = try await screenCapture.captureScreen()
            await send(.screenCapturePermissionUpdated(.granted))
          } catch {
            await send(.screenCapturePermissionUpdated(.denied))
          }
        }
        
      case .completeOnboarding:
        state.hasCompletedOnboarding = true
        state.isComplete = true
        state.$hexSettings.withLock { $0.hasCompletedOnboarding = true }
        return .none
        
      case let .updateTestTranscription(text):
        state.testTranscription = text
        return .none
        
      case .loadAvailableInputDevices:
        return .run { send in
          let devices = await recording.getAvailableInputDevices()
          await send(.availableInputDevicesLoaded(devices))
        }
        
      case let .availableInputDevicesLoaded(devices):
        state.availableInputDevices = devices
        return .none
        
      case let .hotkeySet(hotkey):
        state.$hexSettings.withLock { $0.hotkey = hotkey }
        return .send(.nextStep)
      }
    }
  }
}

 