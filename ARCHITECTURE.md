# MPX68K Software Architecture

This document describes the software architecture of MPX68K, a Sharp X68000 emulator for macOS and iOS. The active application targets are `X68000 macOS` and `X68000 iOS`; both use the shared px68k core and c68k CPU library.

## Overall System Architecture

```mermaid
graph TB
    subgraph "User Interface Layer"
        macOS[macOS App]
        iOS[iOS App]
    end
    
    subgraph "Swift Shared Layer"
        GameScene[GameScene.swift<br/>SpriteKit Viewport]
        FileSystem[FileSystem.swift<br/>Document Management]
        AudioStream[AudioStream.swift<br/>Audio Bridge]
        JoyCard[X68JoyCard.swift<br/>Input Controller]
    end
    
    subgraph "C/C++ Emulation Core"
        PX68K[px68k Core<br/>X68000 Hardware]
        M68K[M68000 CPU Wrapper]
        YMFM[ymfm YM2151<br/>FM Sound Engine]
        X68KHW[X68000 Hardware<br/>FDC, SCSI, ADPCF, Graphics]
    end
    
    subgraph "CPU Emulator"
        C68K[C68K Library<br/>M68000 CPU Core]
    end
    
    subgraph "Apple Frameworks"
        SpriteKit[SpriteKit]
        AVFoundation[AVFoundation]
        GameplayKit[GameplayKit]
        CloudKit[CloudKit/iCloud]
        UTI[UniformTypeIdentifiers]
    end
    
    macOS --> GameScene
    iOS --> GameScene
    
    GameScene --> SpriteKit
    GameScene --> JoyCard
    GameScene --> PX68K
    
    FileSystem --> CloudKit
    FileSystem --> UTI
    
    AudioStream --> AVFoundation
    AudioStream --> YMFM
    
    JoyCard --> GameplayKit
    JoyCard --> PX68K
    
    PX68K --> M68K
    PX68K --> YMFM
    PX68K --> X68KHW
    
    M68K --> C68K
    
    style macOS fill:#e8f5e8
    style iOS fill:#e3f2fd
    style GameScene fill:#fff3e0
    style PX68K fill:#fce4ec
    style C68K fill:#f3e5f5
```

## Platform Architecture

```mermaid
graph LR
    subgraph "macOS Platform"
        macOSUI[macOS UI Layer]
        MenuBar[Menu Bar Integration]
        KeyMouse[Keyboard/Mouse Input]
        DragDrop[Drag & Drop]
        WindowMgmt[Window Management]
    end

    subgraph "iOS Platform"
        iOSUI[iOS UI Layer]
        TouchKeyboard[Touch / External Keyboard Input]
        Storyboards[UIKit Storyboards]
    end
    
    subgraph "Shared Core"
        SharedCore[X68000 Shared<br/>Business Logic]
    end
    
    macOSUI --> SharedCore
    MenuBar --> SharedCore
    KeyMouse --> SharedCore
    DragDrop --> SharedCore
    WindowMgmt --> SharedCore
    iOSUI --> SharedCore
    TouchKeyboard --> SharedCore
    Storyboards --> iOSUI
    
    style macOSUI fill:#e8f5e8
    style SharedCore fill:#fff3e0
```

## Data Flow Architecture

```mermaid
sequenceDiagram
    participant User
    participant Swift_UI
    participant GameScene
    participant PX68K_Core
    participant C68K_CPU
    participant Audio_System
    
    User->>Swift_UI: Input (Keyboard/Mouse/Gamepad)
    Swift_UI->>GameScene: Process Input
    GameScene->>PX68K_Core: Emulation Step
    PX68K_Core->>C68K_CPU: Execute CPU Instructions
    C68K_CPU-->>PX68K_Core: CPU State Update
    PX68K_Core->>Audio_System: Generate Audio
    Audio_System-->>Swift_UI: Audio Output
    PX68K_Core-->>GameScene: Screen Update
    GameScene-->>Swift_UI: Render Frame
    Swift_UI-->>User: Display & Audio
```

## File System Architecture

```mermaid
graph TD
    subgraph "File Sources"
        iCloudDocs[iCloud Documents]
        LocalDocs[Local Documents]
        AppBundle[App Bundle ROMs]
        Inbox[App Inbox]
    end
    
    subgraph "File Management"
        FileSystem[FileSystem.swift]
        SecurityScope[Security Scoped Resources]
        UTIHandler[UTI Handler]
    end
    
    subgraph "File Types"
        ROM[ROM Files<br/>CGROM.DAT, IPLROM.DAT]
        Floppy[Floppy Images<br/>.dim, .xdf, .2hd, .d88]
        HDD[Hard Disk Images<br/>.hdf, .hdm]
        SaveData[Save Data<br/>SRAM.DAT]
    end
    
    subgraph "Emulation Core"
        PX68K_FS[px68k File Access]
    end
    
    iCloudDocs --> FileSystem
    LocalDocs --> FileSystem
    AppBundle --> FileSystem
    Inbox --> FileSystem
    
    FileSystem --> SecurityScope
    FileSystem --> UTIHandler
    
    FileSystem --> ROM
    FileSystem --> Floppy
    FileSystem --> HDD
    FileSystem --> SaveData
    
    ROM --> PX68K_FS
    Floppy --> PX68K_FS
    HDD --> PX68K_FS
    SaveData --> PX68K_FS
    
    style iCloudDocs fill:#e3f2fd
    style FileSystem fill:#fff3e0
    style PX68K_FS fill:#fce4ec
```

## Audio System Architecture

```mermaid
graph TB
    subgraph "C++ Audio Generation"
        YMFM[ymfm YM2151<br/>FM Synthesis]
        ADPCM[ADPCM Audio]
        PCM[PCM Audio]
    end
    
    subgraph "Swift Audio Bridge"
        AudioStream[AudioStream.swift]
        AudioBuffer[Audio Buffer Management]
    end
    
    subgraph "Apple Audio Framework"
        AVAudio[AVFoundation]
        AudioOutput[Audio Output]
    end
    
    subgraph "X68000 Hardware"
        OPM[OPM Chip Emulation]
        AudioHW[Audio Hardware]
    end
    
    OPM --> YMFM
    AudioHW --> ADPCM
    AudioHW --> PCM
    
    YMFM --> AudioStream
    ADPCM --> AudioStream
    PCM --> AudioStream
    
    AudioStream --> AudioBuffer
    AudioBuffer --> AVAudio
    AVAudio --> AudioOutput
    
    style YMFM fill:#fce4ec
    style AudioStream fill:#fff3e0
    style AVAudio fill:#e8f5e8
```

## MIDI and Audio Unit Output Architecture

```mermaid
graph LR
    subgraph "X68000 Emulation"
        MIDI[MIDI events]
        EmulatorAudio[Built-in FM/ADPCM audio]
    end

    Router[MIDIController output router]
    CoreMIDI[CoreMIDI OUT-A]
    Serial[Dedicated RS-232C transport OUT-B]
    AUHost[Audio Unit host]
    AUMixer[AU gain mixer]
    BuiltInEffects[4-slot serial Effect/MusicEffect chain]
    AudioOutput[macOS audio output]

    MIDI --> Router
    Router --> CoreMIDI
    Router --> Serial
    Router --> AUHost
    AUHost --> AUMixer
    AUMixer --> AudioOutput
    EmulatorAudio --> BuiltInEffects
    BuiltInEffects --> AudioOutput
```

On macOS, `MIDIController` sends each parsed MIDI event to the selected CoreMIDI destination and, independently, to the selected RS-232C device. The C MIDI bridge records an Apple host-clock timestamp for every emitted byte; the Swift parser carries the first-byte timestamp through to the completed MIDI event. The serial transport uses a dedicated file descriptor and asynchronous transmit queue configured for 31,250 baud, 8-N-1. MIDI IN is intentionally not connected yet.

`System > MIDI Panic` and every X68000 reset path send All Sound Off and All Notes Off on all 16 channels, explicit Note Off messages for all 128 keys on every channel, and the GM System On reset SysEx to the hosted Audio Unit, CoreMIDI OUT-A, and RS-232C OUT-B. Pending delayed serial events are discarded before the panic sequence is sent.

The optional Audio Unit instrument is hosted by a separate `AVAudioEngine`. AUv3 extensions and AUv2 Music Devices are both valid instruments. AUv2 is instantiated out of process; the App Sandbox `audio-unit-host` entitlement lets macOS prompt once to open a non-sandbox-safe plug-in, the same confirmation GarageBand uses. The built-in FM/ADPCM output has a separate `AVAudioSourceNode` graph for four serial slots. Only `kAudioUnitType_Effect` and `kAudioUnitType_MusicEffect` are enumerated there; ordinary effects process audio, while Music Effects also receive the emulator's MIDI events. Effect state is persisted per slot and component, independently of the instrument state. The existing physical MIDI output delay remains applied to OUT-A/OUT-B. RS-232C has no timestamped transport, so OUT-B waits until its host-time deadline before writing the bytes. Instrument settings persist the selected Audio Unit, enabled state, and gain from -60 dB to 0 dB.

The built-in YM2151 is implemented by the `third_party/ymfm` submodule. X68000 hardware uses a 4 MHz YM2151 clock, which produces a native 62,500 Hz stream (`4 MHz / (2 prescale × 32 operators)`). `dswin.c` keeps raw YMFM and ADPCM buses in a fixed SPSC ring, and `AudioStream` converts that stream to the host device rate. Mix parameters are a separate control plane: the settings panel publishes slider values through a static coalescing mailbox, off the emulator and output-object lifecycle; the output callback applies the FM/ADPCM gains with a short ramp, and the ADPCM filter coefficients are prepared off the UI path and ramped by the producer. Neither operation rewrites queued samples or resets the output. Only a change to the output object itself (Direct AudioUnit vs. AudioQueue, device buffer size, or enabling/disabling the effect graph) is allowed to stop and rebuild the path. The default macOS path is a direct HAL AudioUnit with a 64-frame buffer; the settings panel also exposes 16, 32, 128, 256, and 512-frame choices plus an AudioQueue compatibility path. The same panel provides live per-bus FM and ADPCM trims from -24 to +24 dB in 0.5 dB steps, plus a continuous ADPCM low-pass cutoff from 3.3 to 20 kHz (3.3 kHz by default). Audio Unit volume uses the graph-preserving mixer path. The effect graph uses a Float32 source and never advances emulator state from its render callback.

## Input System Architecture

```mermaid
graph TB
    subgraph "Input Sources"
        Keyboard[Keyboard Input<br/>macOS]
        Mouse[Mouse Input<br/>macOS]
        GameController[Game Controller]
    end
    
    subgraph "Swift Input Processing"
        JoyCard[X68JoyCard.swift]
        InputMapper[Input Mapping]
        GameplayKit[GameplayKit Integration]
    end
    
    subgraph "Emulation Core"
        X68KInput[X68000 Input System]
        JoyStick[Joystick Emulation]
        KeyboardEmu[Keyboard Emulation]
        MouseEmu[Mouse Emulation]
    end
    
    Keyboard --> JoyCard
    Mouse --> JoyCard
    GameController --> GameplayKit
    GameplayKit --> JoyCard
    
    JoyCard --> InputMapper
    InputMapper --> X68KInput
    
    X68KInput --> JoyStick
    X68KInput --> KeyboardEmu
    X68KInput --> MouseEmu
    
    style Keyboard fill:#e8f5e8
    style Mouse fill:#e8f5e8
    style JoyCard fill:#fff3e0
    style X68KInput fill:#fce4ec
```

## Build System Architecture

```mermaid
graph TD
    subgraph "Source Code"
        SwiftCode[Swift Source Code]
        CCode[C Source Code]
        CPPCode[C++ Source Code]
        C68KSource[C68K Source Code]
    end
    
    subgraph "Build Process"
        C68KBuild[C68K Static Library Build]
        MainBuild[Main Project Build]
        BridgingHeaders[Bridging Headers]
    end
    
    subgraph "Output"
        C68KLib[libc68k.a]
        macOSApp[macOS App Bundle]
    end
    
    C68KSource --> C68KBuild
    C68KBuild --> C68KLib
    
    SwiftCode --> MainBuild
    CCode --> MainBuild
    CPPCode --> MainBuild
    C68KLib --> MainBuild
    BridgingHeaders --> MainBuild
    
    MainBuild --> macOSApp
    
    style C68KBuild fill:#f3e5f5
    style MainBuild fill:#fff3e0
    style C68KLib fill:#e1f5fe
```

## Key Design Patterns

### 1. Multi-Platform Strategy
- **Shared Core**: Common business logic and emulation engine
- **Platform UI**: macOS and iOS presentation layers kept separate from the shared core
- **Conditional Compilation**: Platform-specific code using `#if os()` directives

### 2. Document-Based Architecture
- **File Type Integration**: Custom UTI declarations for X68000 file formats
- **iCloud Synchronization**: Automatic document sync across devices
- **Sandboxed Access**: Security-scoped resource management

### 3. Bridge Pattern
- **Swift-C Interop**: Bridging headers for C API access from Swift
- **Audio Bridge**: AudioStream class bridges C++ audio to AVFoundation
- **Input Bridge**: Unified input system across different input methods

### 4. Emulation Core Isolation
- **Static Library**: C68K CPU emulator as independent static library
- **C/C++ Core**: px68k emulation engine in separate language layer
- **Minimal Dependencies**: Clean separation between emulation and UI layers

### 5. Machine Monitor Socket (macOS only)

The bottom of `X68000 Shared/px68k/x11/winx68k.cpp` implements a UNIX domain socket server that wraps the existing `X68000_Monitor_*` C API defined in the same file.

```mermaid
graph LR
    subgraph "External Client"
        Client[nc / Python / shell script]
    end
    subgraph "monitor_socket.cpp"
        Thread[POSIX server thread]
        Parser[Line protocol parser]
    end
    subgraph "Machine Monitor API"
        MonitorAPI[X68000_Monitor_*\nwinx68k.cpp]
    end
    subgraph "Emulation Core"
        PX68K[px68k]
    end

    Client -- sandbox HOME/mpx68k_monitor.sock --> Thread
    Thread --> Parser
    Parser --> MonitorAPI
    MonitorAPI --> PX68K
```

The server runs on a dedicated POSIX thread and is lifecycle-managed by `AppDelegate`:
- **Start**: `applicationDidFinishLaunching` calls `MonitorSocket_Start()` when `UserDefaults["monitorSocketEnabled"]` is `true` (default: `false`)
- **Stop**: `applicationWillTerminate` calls `MonitorSocket_Stop()`, which shuts down the listener, removes the socket file, and joins the thread

The socket is placed in the sandbox-writable home directory, restricted to mode `0600`, and can be overridden with `MPX68K_MONITOR_SOCK`. `SO_NOSIGPIPE` is set on each accepted client fd so that a disconnecting client cannot deliver `SIGPIPE` to the main emulator process. Live CPU, memory, and device commands require an acknowledged `PAUSE`. The no-pause `DIAG` command reads a mutex-protected snapshot produced by the emulation thread instead of racing live core state.

This architecture enables MPX68K to provide authentic X68000 emulation while maintaining modern macOS user experience standards.
