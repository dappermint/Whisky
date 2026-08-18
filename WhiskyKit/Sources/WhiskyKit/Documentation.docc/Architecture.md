# Architecture Overview

Understand how WhiskyKit components work together to manage Wine bottles and Windows applications.

## Overview

WhiskyKit is organized into several logical layers, each responsible for a specific aspect of Wine management on macOS.

```
┌─────────────────────────────────────────────────────────────┐
│                    Application Layer                         │
│                 (Whisky.app, WhiskyCmd)                      │
├─────────────────────────────────────────────────────────────┤
│                      WhiskyKit                               │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │   Bottle    │  │    Wine      │  │ WhiskyWineInstaller│  │
│  │  Management │  │  Execution   │  │                   │  │
│  └─────────────┘  └──────────────┘  └───────────────────┘  │
│  ┌─────────────┐  ┌──────────────┐                         │
│  │   Program   │  │   PE File    │                         │
│  │  Discovery  │  │   Parsing    │                         │
│  └─────────────┘  └──────────────┘                         │
├─────────────────────────────────────────────────────────────┤
│                     Wine Runtime                             │
│              (WhiskyWine / Wine64 Binary)                   │
└─────────────────────────────────────────────────────────────┘
```

## Core Components

### Bottle Management

The bottle management layer handles the lifecycle of Wine prefixes:

| Component | Responsibility |
|-----------|----------------|
| ``Bottle`` | Represents an isolated Wine environment |
| ``BottleSettings`` | Stores configuration for a bottle |
| ``BottleWineConfig`` | Wine-specific settings (Windows version, sync mode) |
| ``BottleMetalConfig`` | Metal and graphics settings |
| ``BottleDXVKConfig`` | DXVK configuration for DirectX translation |
| ``BottlePerformanceConfig`` | Performance optimization settings |

Each bottle is stored as a directory containing:

```
MyBottle/
├── Metadata.plist          # BottleSettings serialized
├── drive_c/                # Windows C: drive
│   ├── windows/
│   ├── Program Files/
│   └── users/
├── Program Settings/       # Per-program plist files
│   ├── game.exe.plist      # Settings for game.exe
│   └── launcher.exe.plist  # Settings for launcher.exe
└── ...                     # Wine registry and other files
```

### Wine Execution

The ``Wine`` class provides the interface to the Wine runtime:

- **Process Management**: Start and monitor Wine processes
- **Environment Setup**: A layered ``EnvironmentBuilder`` resolves settings into environment variables, recording per-key provenance
- **Logging**: Capture output and errors from Wine processes into per-run logs

Every entry point launches through the same door, so the full stack applies no matter where the click happened:

```
Program.launchWithUserMode(useTerminal:)
       │
       ▼
┌────────────────────┐
│ LauncherFixes      │  detect the launcher, apply compatibility settings
└────────┬───────────┘
         ▼
┌────────────────────┐
│ LaunchResolver     │  GameDB profile fills what the user left unset
└────────┬───────────┘
         ▼
┌────────────────────┐
│ syncAudioRegistry  │  wine reg, only when audio settings changed
└────────┬───────────┘
         ▼
┌────────────────────┐
│ EnvironmentBuilder │  layered resolve, per-key provenance
└────────┬───────────┘
         ▼
┌────────────────────┐
│ Execute wine64     │
│ start /unix        │
└────────┬───────────┘
         ▼
  run log, then crash classification
  (immediate check + wineserver-idle watcher)
```

### Program Discovery

Programs are Windows executables found within a bottle:

- ``Program`` represents an executable (.exe) file
- ``ProgramSettings`` stores per-program configuration
- Programs can be pinned for quick access via ``PinnedProgram``

### PE File Parsing

WhiskyKit includes a complete Windows PE (Portable Executable) file parser:

- ``PEFile`` - Main parser for .exe and .dll files
- ``COFFFileHeader`` - COFF header parsing
- ``OptionalHeader`` - PE optional header with magic number
- ``Section`` - PE section table parsing
- Resource parsing for icon extraction

This enables:
- Detecting 32-bit vs 64-bit executables
- Extracting application icons
- Reading executable metadata

## Thread Safety

WhiskyKit uses Swift's actor isolation for thread safety:

- ``Bottle`` and ``Program`` are `@MainActor` isolated
- Cross-thread access is provided via `nonisolated` properties like `id`
- Wine execution methods require `@MainActor` context

```swift
// Must be called from MainActor
@MainActor
func runGame() async throws {
    try await Wine.runProgram(at: gameURL, bottle: bottle)
}
```

## Data Flow

### Settings Persistence

Settings are automatically persisted when modified:

```
bottle.settings.dxvk = true
       │
       ▼
┌──────────────────┐
│ didSet observer  │
│ triggers save    │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│ Encode to        │
│ PropertyList     │
└────────┬─────────┘
         │
         ▼
  Metadata.plist
```

### Environment Construction

When running a program, WhiskyKit builds a complete environment:

1. Base Wine environment (WINEPREFIX, PATH)
2. Bottle-level settings (DXVK, Metal, sync mode)
3. Program-level settings (locale, custom variables)
4. User-provided overrides

## Extension Points

WhiskyKit is extended through several mechanisms:

- **Extensions**: Additional functionality on core types in `Extensions/`
- **Configuration Types**: Modular settings in separate config structs
- **Wine Registry**: Direct registry manipulation via methods on ``Wine`` (e.g., `retinaMode`, `changeDpiResolution`, `changeWinVersion`)

## See Also

- <doc:GettingStarted>
- ``Bottle``
- ``Wine``
- ``WhiskyWineInstaller``
