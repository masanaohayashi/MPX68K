# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MPX68K is a Sharp X68000 computer emulator for macOS and iOS, based on the px68k emulator core. The project bridges low-level C emulation code with modern Swift UI frameworks using SpriteKit. This is a document-based application with deep integration into Apple's ecosystem. The shared core is built by both the `X68000 macOS` and `X68000 iOS` application targets.

## Build Commands

### Building the Project
```bash
# Open in Xcode (primary build method)
open X68000.xcodeproj

# List available schemes and targets
xcodebuild -list -project X68000.xcodeproj

# Build macOS version
xcodebuild -project X68000.xcodeproj -scheme "X68000 macOS" -configuration Debug
xcodebuild -project X68000.xcodeproj -scheme "X68000 macOS" -configuration Release

# Build iOS Simulator version
xcodebuild -project X68000.xcodeproj -scheme "X68000 iOS" -configuration Debug \
  -destination 'generic/platform=iOS Simulator'
xcodebuild -project X68000.xcodeproj -scheme "X68000 iOS" -configuration Release \
  -destination 'generic/platform=iOS Simulator'

# Clean build artifacts
xcodebuild clean -project X68000.xcodeproj -scheme "X68000 macOS"
```

### Running Tests
Host-side unit tests for the C emulation core live in `tests/core/` and run
on any platform with a C compiler (no Xcode required). CI runs them on Linux:
```bash
make -C tests/core
```

### Dependencies
The project has a critical dependency on the c68k CPU emulator. Each application
target declares its matching c68k target as an Xcode target dependency, so Xcode
builds it automatically. To build the dependency by itself:
```bash
# Build C68K static library (required dependency)
# The macOS app links against libc68k_mac_DEBUG.a / libc68k_mac.a,
# which are produced by the "c68k mac" scheme (the plain "c68k" scheme is legacy)
xcodebuild -project c68k/c68k.xcodeproj -scheme "c68k mac" -configuration Debug
```

## Architecture

### Design Pattern
The project keeps a shared core separated from the platform presentation layers:
- **X68000 Shared/**: Business logic and emulation core
- **X68000 macOS/**: macOS-specific UI, menu integration, and window management
- **X68000 iOS/**: iOS app lifecycle, SpriteKit view controller, and storyboards
- **c68k/**: Independent M68000 CPU emulator built as static library

### Core Components
- **GameScene.swift**: Main SpriteKit-based emulation viewport and input handling
- **FileSystem.swift**: Document-based file management with iCloud integration
- **AudioStream.swift**: AVFoundation bridge for C++ audio output
- **X68JoyCard.swift**: Virtual joycard with cross-platform input support
- **px68k/**: Complete X68000 hardware emulation written in C/C++
  - `x68k/`: Hardware components (FDC, SCSI, ADPCM, graphics, CRTC)
  - `m68000/`: M68000 CPU wrapper using C68K static library
  - `fmgen/`: FM sound synthesis engine (C++)
  - `x11/`: Platform abstraction and main emulation loop

### Language Stack and Interoperability
- **Swift**: UI frameworks, file system, audio bridge, input management
- **C**: Core emulation engine (CPU, hardware peripherals, timing)
- **C++**: FM sound synthesis (fmgen), some emulation components
- **Bridging**: Platform-specific bridging headers expose C APIs to Swift
- **Static Linking**: C68K CPU emulator built as separate static library

### Key Frameworks
- **SpriteKit**: Hardware-accelerated rendering and scene management
- **GameplayKit**: GameController integration for external controllers
- **AVFoundation**: Audio processing and output via AudioStream
- **UniformTypeIdentifiers**: Custom UTI declarations for X68000 file formats
- **CloudKit**: iCloud document synchronization (`iCloud.GOROman.X68000.1`)

### Document Architecture
- **File Format Support**: .dim, .xdf, .2hd, .d88 (floppy), .hdf, .hdm (hard disk)
- **Multi-Location Search**: Documents, Inbox, legacy paths for ROM discovery
- **Security-Scoped Resources**: Proper sandboxed file access on macOS
- **ROM Management**: Flexible loading from embedded or external ROM files

## Platform Implementation

### macOS Platform
- **Native Menu Integration**: File menu with FDD/HDD loading/ejecting shortcuts
- **Window Management**: Standard macOS document-based app architecture
- **Keyboard/Mouse Input**: Full support for traditional input methods
- **Drag & Drop**: Multi-file support with automatic drive assignment
- **Screen Rotation**: 90-degree rotation support for vertical games (tate mode)

### iOS Platform
- **Native iOS Target**: `X68000 iOS` builds for iPhone and iPad from the shared emulation core
- **SpriteKit Presentation**: iOS-specific app delegate, view controller, and storyboards
- **Touch / External Keyboard Input**: UIKit lifecycle and HID keyboard integration

## Development Guidelines

### Swift-C Interoperability
- Bridging headers expose C emulation APIs to Swift code
- When modifying C code, ensure function signatures remain Swift-compatible
- Use `@objc` annotations for Swift functions called from C
- Memory management across Swift-C boundary requires careful attention

### Build Dependencies
- **Critical**: The application target must keep its matching c68k target dependency
- Xcode builds the required `libc68k` variant automatically when building an app scheme
- The standalone c68k schemes can be used when inspecting or rebuilding the dependency directly

### File System Architecture
- **ROM Loading**: Multi-path search strategy for CGROM.DAT/IPLROM.DAT
- **Document Model**: All disk images managed through document-based architecture
- **Security**: Sandboxed file access with security-scoped resources on macOS
- **iCloud**: Ubiquitous container integration with automatic downloading

### Audio System
- **AudioStream Class**: Bridges C++ fmgen sound synthesis to AVFoundation
- **Real-time Audio**: Low-latency audio processing for accurate emulation

### Input Handling
- **Unified Input**: Single input system supports keyboard, mouse, and gamepad
- **Joycard Emulation**: Virtual joycard provides a consistent controller interface
