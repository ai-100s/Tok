import ComposableArchitecture
import SwiftUI

struct SettingsView: View {
	@Bindable var store: StoreOf<SettingsFeature>
	
	var body: some View {
		Form {
			// --- Permissions Section ---
			Section {
				// Microphone
				HStack {
					Label("Microphone", systemImage: "mic.fill")
					Spacer()
					switch store.microphonePermission {
					case .granted:
						Label("Granted", systemImage: "checkmark.circle.fill")
							.foregroundColor(.green)
							.labelStyle(.iconOnly)
					case .denied:
						Button("Request Permission") {
							store.send(.requestMicrophonePermission)
						}
						.buttonStyle(.borderedProminent)
						.tint(.blue)
					case .notDetermined:
						Button("Request Permission") {
							store.send(.requestMicrophonePermission)
						}
						.buttonStyle(.bordered)
					}
				}

				// Accessibility
				HStack {
					Label("Accessibility", systemImage: "accessibility")
					Spacer()
					switch store.accessibilityPermission {
					case .granted:
						Label("Granted", systemImage: "checkmark.circle.fill")
							.foregroundColor(.green)
							.labelStyle(.iconOnly)
					case .denied:
						Button("Request Permission") {
							print("🔘 [UI] User clicked Request Accessibility Permission (denied state)")
							store.send(.requestAccessibilityPermission)
						}
						.buttonStyle(.borderedProminent)
						.tint(.blue)
					case .notDetermined:
						Button("Request Permission") {
							print("🔘 [UI] User clicked Request Accessibility Permission (notDetermined state)")
							store.send(.requestAccessibilityPermission)
						}
						.buttonStyle(.bordered)
					}
				}

			} header: {
				Text("Permissions")
			}
      
			// --- Input Device Selection Section ---
			if store.microphonePermission == .granted && !store.availableInputDevices.isEmpty {
				Section {
					// Input device picker
					HStack {
						Label {
							Picker("Input Device", selection: $store.hexSettings.selectedMicrophoneID) {
								Text("System Default").tag(nil as String?)
								ForEach(store.availableInputDevices) { device in
									Text(device.name).tag(device.id as String?)
								}
							}
							.pickerStyle(.menu)
							.id(UUID()) // Force refresh when devices change
						} icon: {
							Image(systemName: "mic.circle")
						}
						
						Button(action: {
							store.send(.loadAvailableInputDevices)
						}) {
							Image(systemName: "arrow.clockwise")
						}
						.buttonStyle(.borderless)
						.help("Refresh available input devices")
					}
					
					// Show fallback note for selected device not connected
					if let selectedID = store.hexSettings.selectedMicrophoneID, 
					   !store.availableInputDevices.contains(where: { $0.id == selectedID }) {
						Text("Selected device not connected. System default will be used.")
							.font(.caption)
							.foregroundColor(.secondary)
					}
				} header: {
					Text("Microphone Selection")
				}
			}

			// --- Transcription Provider Section ---
			Section("Transcription Provider") {
				TranscriptionProviderPicker(store: store)
			}

			// --- Provider Configuration Section ---
			switch store.hexSettings.selectedTranscriptionProvider {
			case .openai:
				// OpenAI remote provider: API configuration and model selection
				Section("OpenAI Configuration") {
					OpenAIAPIConfigurationView(store: store)
				}

				Section("Model Selection") {
					TranscriptionModelPicker(store: store)
				}
				
			case .aliyun:
				// Aliyun remote provider: API configuration and model selection
				Section("Aliyun Configuration") {
					AliyunAPIConfigurationView(store: store)
				}

				Section("Model Selection") {
					TranscriptionModelPicker(store: store)
				}
				
			case .whisperKit:
				// Local provider: show model download section and model selection
				Section("Local Model Download") {
					ModelDownloadView(store: store.scope(state: \.modelDownload, action: \.modelDownload))
				}

				Section("Model Selection") {
					TranscriptionModelPicker(store: store)
				}
			}

			Label {
				Picker("Output Language", selection: $store.hexSettings.outputLanguage) {
					ForEach(store.languages, id: \.id) { language in
						Text(language.name).tag(language.code)
					}
				}
				.pickerStyle(.menu)
			} icon: {
				Image(systemName: "globe")
			}

			// --- Hot Key Section ---
			Section("Hot Key") {
				let hotKey = store.hexSettings.hotkey
				let key = store.isSettingHotKey ? nil : hotKey.key
				let modifiers = store.isSettingHotKey ? store.currentModifiers : hotKey.modifiers
				
				VStack(spacing: 12) {
					// Info text for full keyboard shortcut support
					if hotKey.key != nil {
						Text("You're using a full keyboard shortcut. Double-tap is recommended.")
							.font(.caption)
							.foregroundColor(.secondary)
							.frame(maxWidth: .infinity, alignment: .center)
					}
					
					// Hot key view
					HStack {
						Spacer()
						HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingHotKey)
							.animation(.spring(), value: key)
							.animation(.spring(), value: modifiers)
						Spacer()
					}
					.contentShape(Rectangle())
					.onTapGesture {
						store.send(.startSettingHotKey)
					}
				}
				
				// Double-tap toggle (for key+modifier combinations)
				if hotKey.key != nil {
					Label {
						Toggle("Use double-tap only", isOn: $store.hexSettings.useDoubleTapOnly)
						Text("Recommended for custom hotkeys to avoid interfering with normal usage")
							.font(.caption)
							.foregroundColor(.secondary)
					} icon: {
						Image(systemName: "hand.tap")
					}
				}
				
				// Minimum key time (for modifier-only shortcuts)
                if store.hexSettings.hotkey.key == nil {
                    Label {
                        Slider(value: $store.hexSettings.minimumKeyTime, in: 0.0...2.0, step: 0.1) {
                            Text("Ignore below \(store.hexSettings.minimumKeyTime, specifier: "%.1f")s")
                        }
                    } icon: {
                        Image(systemName: "clock")
                    }
                }
			}

			// --- Sound Section ---
			Section {
				Label {
					Toggle("Sound Effects", isOn: $store.hexSettings.soundEffectsEnabled)
				} icon: {
					Image(systemName: "speaker.wave.2.fill")
				}
			} header: {
				Text("Sound")
			}

			// --- General Section ---
			Section {
				Label {
					Toggle("Open on Login",
					       isOn: Binding(
					       	get: { store.hexSettings.openOnLogin },
					       	set: { store.send(.toggleOpenOnLogin($0)) }
					       ))
				} icon: {
					Image(systemName: "arrow.right.circle")
				}

				Label {
					Toggle("Show Dock Icon", isOn: $store.hexSettings.showDockIcon)
				} icon: {
					Image(systemName: "dock.rectangle")
				}

				Label {
					Toggle("Use clipboard to insert", isOn: $store.hexSettings.useClipboardPaste)
					Text("Use clipboard to insert text. Fast but may not restore all clipboard content.\nTurn off to use simulated keypresses. Slower, but doesn't need to restore clipboard")
				} icon: {
					Image(systemName: "doc.on.doc.fill")
				}
				
				Label {
					Toggle("Copy to clipboard", isOn: $store.hexSettings.copyToClipboard)
					Text("Copy transcription text to clipboard in addition to pasting it")
				} icon: {
					Image(systemName: "doc.on.clipboard")
				}
                
                Label {
                    Toggle("Disable auto-capitalization", isOn: $store.hexSettings.disableAutoCapitalization)
                    Text("Disable automatic capitalization in transcriptions")
                } icon: {
                    Image(systemName: "textformat.abc")
                }

				Label {
					Toggle(
						"Prevent System Sleep while Recording",
						isOn: Binding(
							get: { store.hexSettings.preventSystemSleep },
							set: { store.send(.togglePreventSystemSleep($0)) }
						))
				} icon: {
					Image(systemName: "zzz")
				}
                
                Label {
                    Toggle(
                        "Pause Media while Recording",
                        isOn: Binding(
                            get: { store.hexSettings.pauseMediaOnRecord },
                            set: { store.send(.togglePauseMediaOnRecord($0)) }
                        ))
                } icon: {
                    Image(systemName: "pause")
                }
			} header: {
				Text("General")
			}
		}
		.formStyle(.grouped)
		.task {
			await store.send(.task).finish()
		}
	}
}

// MARK: - Transcription Model Selection

struct TranscriptionModelPicker: View {
    @Bindable var store: StoreOf<SettingsFeature>
    @State private var showingAPIKeyAlert = false

    // Get available models for the current provider
    private var availableModels: [TranscriptionModelType] {
        TranscriptionModelType.modelsForProvider(store.hexSettings.selectedTranscriptionProvider)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Model Selection (filtered by current provider)
            Picker("Model", selection: $store.hexSettings.selectedTranscriptionModel) {
                ForEach(availableModels, id: \.self) { model in
                    ModelRow(model: model, settings: store.hexSettings)
                        .tag(model)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: store.hexSettings.selectedTranscriptionModel) { oldValue, newValue in
                // Update the legacy selectedModel field for compatibility
                store.send(.binding(.set(\.hexSettings.selectedModel, newValue.rawValue)))

                if newValue.requiresAPIKey {
                    let needsAPIKey = switch newValue.provider {
                    case .openai:
                        store.hexSettings.openaiAPIKey.isEmpty
                    case .aliyun:
                        store.hexSettings.aliyunAPIKey.isEmpty
                    case .whisperKit:
                        false
                    }
                    
                    if needsAPIKey {
                        showingAPIKeyAlert = true
                    }
                }
            }

            // Model description
            let selectedModel = store.hexSettings.selectedTranscriptionModel
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedModel.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if selectedModel.estimatedCostPerMinute > 0 {
                    Text("Estimated cost: $\(selectedModel.estimatedCostPerMinute, specifier: "%.3f")/minute")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("API Key Required", isPresented: $showingAPIKeyAlert) {
            Button("Cancel") {
                // Revert to a local model
                store.send(.binding(.set(\.hexSettings.selectedTranscriptionModel, .whisperLarge)))
            }
            Button("Configure") {
                // Keep the selection, user needs to configure API key
            }
        } message: {
            let providerName = store.hexSettings.selectedTranscriptionModel.provider.displayName
            Text("The selected model requires an API key for \(providerName). Please configure your API key or choose a local model.")
        }
    }
}

// MARK: - Model Row View

struct ModelRow: View {
    let model: TranscriptionModelType
    let settings: HexSettings
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .fontWeight(.medium)
                
                HStack(spacing: 8) {
                    // Provider label
                    Label(model.isLocal ? "Local" : "Remote", systemImage: model.iconName)
                        .font(.caption)
                        .foregroundColor(model.iconColor)
                    
                    // Cost label
                    if model.estimatedCostPerMinute > 0 {
                        Label("$\(model.estimatedCostPerMinute, specifier: "%.3f")/min", systemImage: "dollarsign.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Label("Free", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }
            
            Spacer()
            
            // Status indicator
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
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
    }
}

// MARK: - API Key Configuration View

struct APIKeyConfigurationView: View {
    @Bindable var store: StoreOf<SettingsFeature>
    @State private var showAPIKey = false
    @State private var testingConnection = false
    
    var body: some View {
        VStack(spacing: 12) {
            // API Key Input
            HStack {
                if showAPIKey {
                    TextField("OpenAI API Key", text: $store.hexSettings.openaiAPIKey)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("OpenAI API Key", text: $store.hexSettings.openaiAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
                
                Button(action: { showAPIKey.toggle() }) {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            // Test Connection and Status
            HStack {
                Button("Test Connection") {
                    store.send(.testOpenAIAPIKey)
                }
                .disabled(store.hexSettings.openaiAPIKey.isEmpty)
                

                
                Spacer()
                
                // Connection status
                if store.hexSettings.openaiAPIKeyLastTested != nil {
                    HStack(spacing: 4) {
                        Image(systemName: store.hexSettings.openaiAPIKeyIsValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(store.hexSettings.openaiAPIKeyIsValid ? .green : .red)

                        Text(store.hexSettings.openaiAPIKeyIsValid ? "Valid" : "Invalid")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Help text
            Text("Get your API key from platform.openai.com")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - OpenAI API Configuration View

struct OpenAIAPIConfigurationView: View {
    @Bindable var store: StoreOf<SettingsFeature>
    @State private var showingAPIKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // API Key Input
            HStack {
                Label {
                    HStack {
                        if showingAPIKey {
                            TextField("Enter your OpenAI API key", text: $store.hexSettings.openaiAPIKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Enter your OpenAI API key", text: $store.hexSettings.openaiAPIKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button(action: { showingAPIKey.toggle() }) {
                            Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                } icon: {
                    Image(systemName: "key")
                }
            }

            // Test Connection Button
            HStack {
                Button("Test Connection") {
                    store.send(.testOpenAIAPIKey)
                }
                .disabled(store.hexSettings.openaiAPIKey.isEmpty)

                Spacer()

                // Connection Status
                if store.hexSettings.openaiAPIKeyIsValid {
                    Label("Valid", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                } else if !store.hexSettings.openaiAPIKey.isEmpty {
                    Label("Invalid", systemImage: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            // Help Text
            Text("Get your API key from platform.openai.com")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Aliyun API Configuration View

struct AliyunAPIConfigurationView: View {
    @Bindable var store: StoreOf<SettingsFeature>
    @State private var showingAPIKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // API Key Input
            HStack {
                Label {
                    HStack {
                        if showingAPIKey {
                            TextField("Enter your Aliyun API key", text: $store.hexSettings.aliyunAPIKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Enter your Aliyun API key", text: $store.hexSettings.aliyunAPIKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button(action: { showingAPIKey.toggle() }) {
                            Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                } icon: {
                    Image(systemName: "key")
                }
            }

            // Test Connection Button
            HStack {
                Button("Test Connection") {
                    store.send(.testAliyunAPIKey)
                }
                .disabled(store.hexSettings.aliyunAPIKey.isEmpty)

                Spacer()

                // Connection Status
                if store.hexSettings.aliyunAPIKeyIsValid {
                    Label("Valid", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                } else if !store.hexSettings.aliyunAPIKey.isEmpty {
                    Label("Invalid", systemImage: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            // Help Text
            Text("Get your API key from Aliyun Model Studio console")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Transcription Provider Picker

struct TranscriptionProviderPicker: View {
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Transcription Provider", selection: $store.hexSettings.selectedTranscriptionProvider) {
                ForEach(TranscriptionProvider.allCases, id: \.self) { provider in
                    VStack(alignment: .leading) {
                        Text(provider.displayName)
                        Text(provider.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .tag(provider)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: store.hexSettings.selectedTranscriptionProvider) { oldValue, newValue in
                // When provider changes, update the selected model to the first available model for that provider
                let availableModels = TranscriptionModelType.modelsForProvider(newValue)
                if let firstModel = availableModels.first {
                    store.send(.binding(.set(\.hexSettings.selectedTranscriptionModel, firstModel)))
                    // Also update the legacy selectedModel field for compatibility
                    store.send(.binding(.set(\.hexSettings.selectedModel, firstModel.rawValue)))
                }
            }
        }
    }
}
