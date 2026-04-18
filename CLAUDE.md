# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

This is a pure Xcode project with **no external dependencies** (no SPM, CocoaPods, or Carthage).

```bash
# Build
xcodebuild -project PalmiAgent.xcodeproj -scheme PalmiAgent -destination 'platform=iOS Simulator,name=iPhone 16' build

# Build for release
xcodebuild -project PalmiAgent.xcodeproj -scheme PalmiAgent -configuration Release build
```

- iOS deployment target: 17.1+
- Swift 5.0, uses modern concurrency (`@Observable`, `Sendable`, `async/await`)
- No test targets exist yet

## Architecture

**Clean Architecture + MVVM** with manual dependency injection via `AppContainer`.

### Entry Point
`PalmiAgentApp.swift` creates `AppContainer` and passes its store to `ContentView`. Single-screen app — no navigation stack. Tool results and media capture use sheets.

### Dependency Graph
```
PalmiAgentApp
  └─ AppContainer (Infrastructure/) — @MainActor DI root
       ├─ ActionExecutor — executes ToolAction commands
       ├─ ActionCatalog  — registry of 48+ tools in 6 categories
       └─ ManualLabStore — ViewModel for the main screen
```

### Key Directories

| Path | Purpose |
|---|---|
| `Core/Actions/` | `ToolAction` model, `ActionCategory` enum, `ToolExecutionOutcome` |
| `Core/Configuration/` | LLM API config store (Keychain for API keys, UserDefaults for metadata) |
| `Core/Sandbox/` | JavaScript runtime (JavaScriptCore) with workspace file API |
| `Features/ManualLab/` | Main screen: `ManualLabScreen` (View) + `ManualLabStore` (ViewModel) |
| `Infrastructure/` | `AppContainer`, `ActionExecutor`, `ActionCatalog` — the glue layer |
| `Integrations/` | 12 system service integrations (Calendar, Contacts, Location, Speech, etc.) |
| `Integrations/Intelligence/` | LLM tool-calling service (OpenAI-compatible API, supports GLM/Zhipu AI) |
| `Intents/` | App Intents for Siri Shortcuts |

### Patterns

- **Command Pattern**: `ToolAction` + `ActionExecutor` — every tool invocation goes through `ActionExecutor.execute(_:parameters:)`
- **Registry Pattern**: `ActionCatalog` defines all 48+ tools with categories and availability levels (`.live`, `.partial`, `.deferred`)
- **Builder Pattern**: `APIProviderDefinition` constructs LLM provider configs
- **Coordinator Pattern**: `MediaCaptureCoordinator` bridges UIKit camera/photo pickers into SwiftUI

### Conventions

- All models are `struct` with `Sendable` conformance
- `@Observable` (not ObservableObject/Combine) for view models
- `@MainActor` on all UI-facing classes
- Comments and UI strings are in Chinese
- Privacy permissions (camera, location, speech, etc.) are declared in project build settings (Info.plist is auto-generated)

## LLM Integration

The `Integrations/Intelligence/` layer calls OpenAI-compatible chat completion APIs with tool calling. Two access modes: Standard API and Coding Plan. Single-turn execution (no multi-step agent loops). API keys stored in Keychain via `APIConfigurationStore`.
