//
//  MIDIController.swift
//  Xcode11
//
//  Created by GOROman on 2020/04/06.
//  Copyright © 2020 GOROman. All rights reserved.
//

import Foundation
import CoreMIDI

#if os(macOS)
import AudioToolbox
import Darwin
#endif

/// A UInt8 array, usually 3 bytes long.
public typealias MidiEvent = [UInt8]

/// Selects how the macOS built-in emulator audio is handed to the device.
/// The asynchronous path uses a direct AudioUnit callback and a lock-free
/// native-rate ring; compatibility uses the AudioQueue backend.
public enum MPX68KInternalAudioRenderMode: String, CaseIterable, Identifiable {
    case asynchronous
    case compatibility

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .asynchronous:
            return "Direct AudioUnit (asynchronous)"
        case .compatibility:
            return "AudioQueue (compatibility)"
        }
    }
}

/// Settings for the built-in YM2151/ADPCM output path.
public struct MPX68KInternalAudioSettings: Equatable {
    public static let bufferFrameOptions = [16, 32, 64, 128, 256, 512]

    public var mode: MPX68KInternalAudioRenderMode
    public var bufferFrames: Int

    public init(mode: MPX68KInternalAudioRenderMode = .asynchronous,
                bufferFrames: Int = 64) {
        self.mode = mode
        self.bufferFrames = Self.bufferFrameOptions.contains(bufferFrames)
            ? bufferFrames
            : 64
    }
}

#if os(macOS)

/// A CoreMIDI destination that can be selected as OUT-A.
public struct MPX68KMIDIDestination: Identifiable, Equatable {
    public let id: Int32
    public let name: String

    public init(id: Int32, name: String) {
        self.id = id
        self.name = name
    }
}

/// A host serial device that can be selected as the MIDI OUT-B transport.
public struct MPX68KRS232CDevice: Identifiable, Equatable {
    public let path: String

    public var id: String { path }

    public var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    public init(path: String) {
        self.path = path
    }
}

/// Routing configuration for the two physical MIDI output systems.
public struct MPX68KMIDIOutputSettings: Equatable {
    public var coreMIDIEnabled: Bool
    public var coreMIDIUniqueID: Int32?
    public var rs232cEnabled: Bool
    public var rs232cDevicePath: String?

    public init(coreMIDIEnabled: Bool = true,
                coreMIDIUniqueID: Int32? = nil,
                rs232cEnabled: Bool = false,
                rs232cDevicePath: String? = nil) {
        self.coreMIDIEnabled = coreMIDIEnabled
        self.coreMIDIUniqueID = coreMIDIUniqueID
        self.rs232cEnabled = rs232cEnabled
        self.rs232cDevicePath = rs232cDevicePath
    }
}

/// Audio Unit component identity stored by the settings UI.
///
/// The AudioComponentDescription itself is intentionally not persisted. The
/// three identity fields are resolved again when the app starts, while the
/// display name is refreshed from the system.
public struct MPX68KAudioUnitDescriptor: Identifiable, Hashable {
    public let componentType: UInt32
    public let componentSubType: UInt32
    public let componentManufacturer: UInt32
    public let componentFlags: UInt32
    public let componentFlagsMask: UInt32
    public let name: String

    public var id: String {
        "\(componentType):\(componentSubType):\(componentManufacturer)"
    }

    public init(componentType: UInt32,
                componentSubType: UInt32,
                componentManufacturer: UInt32,
                componentFlags: UInt32 = 0,
                componentFlagsMask: UInt32 = 0,
                name: String) {
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.componentManufacturer = componentManufacturer
        self.componentFlags = componentFlags
        self.componentFlagsMask = componentFlagsMask
        self.name = name
    }
}

/// Settings for the optional Audio Unit sound source.
public struct MPX68KAudioUnitSettings: Equatable {
    public var enabled: Bool
    public var componentID: String?
    public var gainDB: Double

    public init(enabled: Bool = false,
                componentID: String? = nil,
                gainDB: Double = 0.0) {
        self.enabled = enabled
        self.componentID = componentID
        self.gainDB = min(max(gainDB, -60.0), 0.0)
    }
}

private final class MPX68KSerialMIDIOutput {
    private static let allowedDevicePrefixes = ["/dev/cu.", "/dev/tty."]
    private static let maxQueuedBytes = 64 * 1024

    // IOSSIOSPEED is not imported into Swift even when IOKit is imported.
    // _IOW('T', 2, speed_t) on the 64-bit macOS SDK is 0x80085402.
    private static let iossIOSpeedRequest: UInt = 0x80085402

    private let queue = DispatchQueue(label: "MPX68K.MIDI.RS232C", qos: .userInitiated)
    private let stateLock = NSLock()
    private var fileDescriptor: Int32 = -1
    private var queuedBytes = 0

    deinit {
        close()
    }

    func configure(path: String?) -> String? {
        queue.sync {
            closeLocked()

            guard let path = path, !path.isEmpty else {
                return nil
            }
            guard Self.allowedDevicePrefixes.contains(where: { path.hasPrefix($0) }) else {
                return "RS-232C device path is not allowed: \(path)"
            }

            let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard descriptor >= 0 else {
                return "Cannot open RS-232C device \(path): \(String(cString: strerror(errno)))"
            }

            if let error = configurePort(descriptor) {
                Darwin.close(descriptor)
                return error
            }

            fileDescriptor = descriptor
            return nil
        }
    }

    func close() {
        queue.sync {
            closeLocked()
        }
    }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }

        stateLock.lock()
        guard queuedBytes + bytes.count <= Self.maxQueuedBytes else {
            stateLock.unlock()
            warningLog("Dropping RS-232C MIDI bytes because the output queue is full", category: .network)
            return
        }
        queuedBytes += bytes.count
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.stateLock.lock()
                self.queuedBytes = max(0, self.queuedBytes - bytes.count)
                self.stateLock.unlock()
            }
            self.write(bytes)
        }
    }

    private func closeLocked() {
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func configurePort(_ descriptor: Int32) -> String? {
        var options = termios()
        guard tcgetattr(descriptor, &options) == 0 else {
            return "Cannot read RS-232C settings: \(String(cString: strerror(errno)))"
        }

        cfmakeraw(&options)
        options.c_cflag &= ~tcflag_t(CSIZE | CSTOPB | PARENB)
        options.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)

        // Set a conventional speed first so the termios structure is valid,
        // then replace it with the exact MIDI baud using Apple's serial ioctl.
        guard cfsetispeed(&options, speed_t(B9600)) == 0,
              cfsetospeed(&options, speed_t(B9600)) == 0,
              tcsetattr(descriptor, TCSANOW, &options) == 0 else {
            return "Cannot configure RS-232C framing: \(String(cString: strerror(errno)))"
        }

        var midiSpeed = speed_t(31_250)
        guard ioctl(descriptor, Self.iossIOSpeedRequest, &midiSpeed) == 0 else {
            return "Cannot set RS-232C MIDI speed to 31,250 baud: \(String(cString: strerror(errno)))"
        }
        return nil
    }

    private func write(_ bytes: [UInt8]) {
        guard fileDescriptor >= 0 else { return }

        var offset = 0
        var retryCount = 0
        while offset < bytes.count {
            let result = bytes.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(fileDescriptor,
                                    baseAddress.advanced(by: offset),
                                    bytes.count - offset)
            }

            if result > 0 {
                offset += result
                retryCount = 0
                continue
            }

            if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && retryCount < 100 {
                retryCount += 1
                usleep(1_000)
                continue
            }
            if result < 0 {
                errorLog("RS-232C MIDI write failed: \(String(cString: strerror(errno)))", category: .network)
            }
            return
        }
    }
}

#endif

private func withMIDIPacketList(_ events: [MidiEvent],
                                timestamp: MIDITimeStamp,
                                send: (UnsafeMutablePointer<MIDIPacketList>) -> Void) {
    let totalBytes = events.reduce(0) { $0 + $1.count }
    let listSize = MemoryLayout<MIDIPacketList>.size + totalBytes
    let byteBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: listSize)
    byteBuffer.initialize(repeating: 0, count: listSize)
    defer {
        byteBuffer.deinitialize(count: listSize)
        byteBuffer.deallocate()
    }

    byteBuffer.withMemoryRebound(to: MIDIPacketList.self, capacity: 1) { packetList in
        var packet = MIDIPacketListInit(packetList)
        for event in events where !event.isEmpty {
            event.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                packet = MIDIPacketListAdd(packetList,
                                           listSize,
                                           packet,
                                           timestamp,
                                           event.count,
                                           baseAddress)
            }
        }
        send(packetList)
    }
}

final class MIDIController {
    private static let maxSysExBytes = 64 * 1024
    #if os(macOS)
    // MIDI events are drained at the end of an emulation frame. Keep a small
    // look-ahead so CoreMIDI and the Audio Unit can still play them at their
    // original host-time positions instead of collapsing them to the flush.
    private static let midiSchedulingLeadSeconds = 0.025
    private static let midiSchedulingSafetySeconds = 0.002
    #endif

    var clientRef: MIDIClientRef = 0
    var inPortRef: MIDIPortRef = 0
    var outPortRef: MIDIPortRef = 0

    // Kept as compatibility state for older callers. OUT-B is now the
    // dedicated RS-232C transport rather than a second CoreMIDI port.
    var outPortRef2: MIDIPortRef = 0

    var midiSource: MIDIEndpointRef = 0
    var midiDst0: MIDIEndpointRef = 0
    var midiDst1: MIDIEndpointRef = 0
    var midiDst2: MIDIEndpointRef = 0

    #if os(macOS)
    private(set) var availableMIDIDestinations: [MPX68KMIDIDestination] = []
    private(set) var outputSettings = MPX68KMIDIOutputSettings()
    private var selectedCoreMIDIDestination: MIDIEndpointRef = 0
    private let serialMIDIOutput = MPX68KSerialMIDIOutput()
    private var audioUnitSender: (([UInt8], UInt64) -> Void)?
    #else
    private var midiDests: [MIDIEndpointRef] = []
    #endif

    private var outputDelayMs: Double = 0.0

    private struct PendingEvent {
        let data: [UInt8]
        #if os(macOS)
        let dueHostTime: UInt64
        #else
        let dueTime: CFTimeInterval
        #endif
    }
    private var pendingEvents: [PendingEvent] = []
    private var pendingIndex: Int = 0

    private var runningStatus: UInt8? = nil
    private var pendingStatus: UInt8? = nil
    private var pendingExpected: Int = 0
    private var pendingData: [UInt8] = []
    private var pendingHostTime: UInt64 = 0
    private var inSysEx: Bool = false
    private var sysExBuffer: [UInt8] = []
    private var sysExHostTime: UInt64 = 0

    init() {
        connect()
    }

    deinit {
        #if os(macOS)
        serialMIDIOutput.close()
        #endif
        if outPortRef2 != 0 {
            MIDIPortDispose(outPortRef2)
            outPortRef2 = 0
        }
        if outPortRef != 0 {
            MIDIPortDispose(outPortRef)
            outPortRef = 0
        }
        if inPortRef != 0 {
            MIDIPortDispose(inPortRef)
            inPortRef = 0
        }
        if clientRef != 0 {
            MIDIClientDispose(clientRef)
            clientRef = 0
        }
    }

    private func connect() {
        var status = MIDIClientCreateWithBlock("MPX68K" as CFString, &clientRef, midiNotifyBlock)
        if status != noErr {
            errorLog("Cannot create MIDI client", category: .network)
            return
        }

        // MIDI IN is intentionally not created yet. The emulator currently
        // has no useful receive path, and leaving it disconnected avoids
        // consuming external MIDI input unexpectedly.
        status = MIDIOutputPortCreate(clientRef, "MPX68K MIDI Out" as CFString, &outPortRef)
        if status != noErr {
            errorLog("Cannot create MIDI Out", category: .network)
            return
        }

        getDestinations()
    }

    func Send(_ buffer: UnsafeMutablePointer<UInt8>?, _ count: Int) {
        sendStream(buffer, nil, count)
    }

    func sendStream(_ buffer: UnsafePointer<UInt8>?, _ count: Int) {
        sendStream(buffer, nil, count)
    }

    func sendStream(_ buffer: UnsafePointer<UInt8>?,
                    _ hostTimes: UnsafePointer<UInt64>?,
                    _ count: Int) {
        guard let buffer, count > 0 else { return }
        for index in 0..<count {
            handleIncomingByte(buffer[index], hostTime: hostTimes?[index] ?? 0)
        }
    }

    private func handleIncomingByte(_ byte: UInt8, hostTime: UInt64) {
        if inSysEx {
            if byte >= 0xF8 { // Realtime messages may interleave with SysEx.
                sendEvent([byte], hostTime: hostTime)
                return
            }
            guard sysExBuffer.count < Self.maxSysExBytes else {
                warningLog("Dropping oversized MIDI SysEx event", category: .network)
                sysExBuffer.removeAll(keepingCapacity: true)
                inSysEx = false
                sysExHostTime = 0
                return
            }
            sysExBuffer.append(byte)
            if byte == 0xF7 {
                sendEvent(sysExBuffer, hostTime: sysExHostTime)
                sysExBuffer.removeAll(keepingCapacity: true)
                inSysEx = false
                sysExHostTime = 0
            }
            return
        }

        if byte >= 0x80 {
            if byte == 0xF0 {
                inSysEx = true
                sysExBuffer.removeAll(keepingCapacity: true)
                sysExBuffer.append(byte)
                sysExHostTime = hostTime
                pendingStatus = nil
                pendingExpected = 0
                pendingData.removeAll(keepingCapacity: true)
                pendingHostTime = 0
                return
            }
            if byte >= 0xF8 {
                sendEvent([byte], hostTime: hostTime)
                return
            }
            if byte >= 0xF0 {
                runningStatus = nil
                pendingStatus = byte
                pendingExpected = expectedDataLength(for: byte)
                pendingData.removeAll(keepingCapacity: true)
                pendingHostTime = hostTime
                if pendingExpected == 0 {
                    sendEvent([byte], hostTime: pendingHostTime)
                    pendingStatus = nil
                    pendingExpected = 0
                    pendingHostTime = 0
                }
                return
            }
            runningStatus = byte
            pendingStatus = byte
            pendingExpected = expectedDataLength(for: byte)
            pendingData.removeAll(keepingCapacity: true)
            pendingHostTime = hostTime
            return
        }

        if pendingStatus == nil {
            if let running = runningStatus {
                pendingStatus = running
                pendingExpected = expectedDataLength(for: running)
                pendingData.removeAll(keepingCapacity: true)
                pendingHostTime = hostTime
            } else {
                return
            }
        }

        pendingData.append(byte)
        if pendingData.count >= pendingExpected {
            if let status = pendingStatus {
                var event = [status]
                event.append(contentsOf: pendingData.prefix(pendingExpected))
                sendEvent(event, hostTime: pendingHostTime)
                if status >= 0xF0 {
                    runningStatus = nil
                }
            }
            pendingStatus = nil
            pendingExpected = 0
            pendingData.removeAll(keepingCapacity: true)
            pendingHostTime = 0
        }
    }

    private func expectedDataLength(for status: UInt8) -> Int {
        if status >= 0xF0 {
            switch status {
            case 0xF1: return 1
            case 0xF2: return 2
            case 0xF3: return 1
            case 0xF6: return 0
            default: return 0
            }
        }
        let upper = status & 0xF0
        if upper == 0xC0 || upper == 0xD0 {
            return 1
        }
        return 2
    }

    #if os(macOS)

    private func hostTimeTicks(for seconds: Double) -> UInt64 {
        guard seconds > 0.0 else { return 0 }
        let ticks = seconds * AudioGetHostClockFrequency()
        guard ticks.isFinite, ticks < Double(UInt64.max) else { return UInt64.max }
        return UInt64(ticks.rounded())
    }

    private func addingHostTime(_ hostTime: UInt64, ticks: UInt64) -> UInt64 {
        guard UInt64.max - hostTime >= ticks else { return UInt64.max }
        return hostTime + ticks
    }

    private func scheduledHostTime(for sourceHostTime: UInt64) -> UInt64 {
        let now = AudioGetCurrentHostTime()
        let source = sourceHostTime == 0 ? now : sourceHostTime
        let lead = hostTimeTicks(for: Self.midiSchedulingLeadSeconds)
        let safety = hostTimeTicks(for: Self.midiSchedulingSafetySeconds)
        let desired = addingHostTime(source, ticks: lead)
        let earliest = addingHostTime(now, ticks: safety)
        return max(desired, earliest)
    }

    #endif

    private func sendEvent(_ event: [UInt8], hostTime sourceHostTime: UInt64) {
        guard !event.isEmpty else { return }

        #if os(macOS)
        let eventHostTime = scheduledHostTime(for: sourceHostTime)

        // The AU and CoreMIDI paths use the same host-time timeline. The AU
        // remains free of the user-configured hardware compensation delay.
        audioUnitSender?(event, eventHostTime)

        let physicalHostTime = addingHostTime(
            eventHostTime,
            ticks: hostTimeTicks(for: outputDelayMs / 1000.0)
        )
        sendCoreMIDIChunks(event, hostTime: physicalHostTime)

        if outputSettings.rs232cEnabled {
            if physicalHostTime <= AudioGetCurrentHostTime() {
                // A serial port cannot consume CoreMIDI timestamps. Preserve
                // the event order and wait until the requested host time.
                serialMIDIOutput.send(event)
            } else {
                pendingEvents.append(PendingEvent(data: event,
                                                  dueHostTime: physicalHostTime))
            }
        }
        #else
        if outputDelayMs > 0.0 {
            let dueTime = CFAbsoluteTimeGetCurrent() + (outputDelayMs / 1000.0)
            pendingEvents.append(PendingEvent(data: event, dueTime: dueTime))
        } else {
            sendCoreMIDIChunks(event, hostTime: sourceHostTime)
        }
        #endif
    }

    private func sendCoreMIDIChunks(_ event: [UInt8], hostTime: UInt64) {
        if event.count <= 255 {
            sendCoreMIDI(event, hostTime: hostTime)
            return
        }

        var offset = 0
        while offset < event.count {
            let end = min(offset + 255, event.count)
            sendCoreMIDI(Array(event[offset..<end]), hostTime: hostTime)
            offset = end
        }
    }

    private func sendCoreMIDI(_ event: [UInt8], hostTime: UInt64) {
        #if os(macOS)
        guard outputSettings.coreMIDIEnabled,
              outPortRef != 0,
              selectedCoreMIDIDestination != 0 else {
            return
        }
        let timestamp = MIDITimeStamp(hostTime == 0 ? AudioGetCurrentHostTime() : hostTime)
        withMIDIPacketList([event], timestamp: timestamp) { packetList in
            let status = MIDISend(outPortRef, selectedCoreMIDIDestination, packetList)
            if status != noErr {
                errorLog("CoreMIDI send failed: \(status)", category: .network)
            }
        }
        #else
        guard outPortRef != 0 else { return }
        if midiDst0 != 0 {
            withMIDIPacketList([event], timestamp: 0) { packetList in
                _ = MIDISend(outPortRef, midiDst0, packetList)
            }
        }
        #endif
    }

    func setOutputDelayMs(_ ms: Double) {
        outputDelayMs = max(0.0, ms)
    }

    func flushDelayedEvents() {
        #if os(macOS)
        let now = AudioGetCurrentHostTime()
        guard pendingIndex < pendingEvents.count else { return }
        while pendingIndex < pendingEvents.count {
            let item = pendingEvents[pendingIndex]
            if item.dueHostTime > now {
                break
            }
            if outputSettings.rs232cEnabled {
                serialMIDIOutput.send(item.data)
            }
            pendingIndex += 1
        }
        if pendingIndex > 256 {
            pendingEvents.removeFirst(pendingIndex)
            pendingIndex = 0
        }
        #else
        let now = CFAbsoluteTimeGetCurrent()
        guard pendingIndex < pendingEvents.count else { return }
        while pendingIndex < pendingEvents.count {
            let item = pendingEvents[pendingIndex]
            if item.dueTime > now {
                break
            }
            sendCoreMIDIChunks(item.data, hostTime: 0)
            pendingIndex += 1
        }
        if pendingIndex > 256 {
            pendingEvents.removeFirst(pendingIndex)
            pendingIndex = 0
        }
        #endif
    }

    private func midiNotifyBlock(midiNotification: UnsafePointer<MIDINotification>) {
        let messageID = midiNotification.pointee.messageID
        guard messageID == .msgPropertyChanged ||
              messageID == .msgSetupChanged ||
              messageID == .msgObjectAdded ||
              messageID == .msgObjectRemoved else {
            if messageID == .msgIOError {
                errorLog("CoreMIDI I/O error", category: .network)
            }
            return
        }

        // CoreMIDI may call the notification block on its own thread. Keep
        // endpoint discovery serialized with the main-thread settings UI.
        DispatchQueue.main.async { [weak self] in
            self?.getDestinations()
        }
    }

    #if os(macOS)

    func refreshMIDIDestinations() -> [MPX68KMIDIDestination] {
        getDestinations()
        return availableMIDIDestinations
    }

    func configureOutputs(_ settings: MPX68KMIDIOutputSettings) -> String? {
        pendingEvents.removeAll(keepingCapacity: true)
        pendingIndex = 0
        outputSettings = settings
        selectedCoreMIDIDestination = 0
        midiDst0 = 0
        var errors: [String] = []

        if settings.coreMIDIEnabled {
            guard let uniqueID = settings.coreMIDIUniqueID else {
                errors.append("Select a CoreMIDI destination for OUT-A")
                return configureSerialOutput(settings, errors: errors)
            }
            guard let endpoint = endpoint(for: uniqueID) else {
                errors.append("The selected CoreMIDI destination is unavailable")
                return configureSerialOutput(settings, errors: errors)
            }
            selectedCoreMIDIDestination = endpoint
            midiDst0 = endpoint
        }

        return configureSerialOutput(settings, errors: errors)
    }

    private func configureSerialOutput(_ settings: MPX68KMIDIOutputSettings,
                                       errors: [String]) -> String? {
        var errors = errors
        guard settings.rs232cEnabled else {
            _ = serialMIDIOutput.configure(path: nil)
            return errors.isEmpty ? nil : errors.joined(separator: "; ")
        }
        guard let path = settings.rs232cDevicePath, !path.isEmpty else {
            _ = serialMIDIOutput.configure(path: nil)
            errors.append("Select an RS-232C device for OUT-B")
            return errors.joined(separator: "; ")
        }
        if let error = serialMIDIOutput.configure(path: path) {
            errors.append(error)
        }
        return errors.isEmpty ? nil : errors.joined(separator: "; ")
    }

    func setAudioUnitSender(_ sender: (([UInt8], UInt64) -> Void)?) {
        audioUnitSender = sender
    }

    static func availableRS232CDevices() -> [MPX68KRS232CDevice] {
        let paths = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return paths
            .filter { $0.hasPrefix("cu.") || $0.hasPrefix("tty.") }
            .map { MPX68KRS232CDevice(path: "/dev/\($0)") }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    #else

    // Retain a source enumeration entry point for non-macOS builds, but do
    // not connect an input port that is intentionally disabled.
    func getSources() {
        midiSource = 0
    }

    #endif

    private func getDestinations() {
        #if os(macOS)
        let count = MIDIGetNumberOfDestinations()
        var destinations: [MPX68KMIDIDestination] = []
        destinations.reserveCapacity(Int(count))

        for index in 0..<count {
            let endpoint = MIDIGetDestination(index)
            guard endpoint != 0 else { continue }
            let uniqueID = midiUniqueID(for: endpoint)
            let name = midiDisplayName(for: endpoint) ?? "MIDI Destination \(index)"
            destinations.append(MPX68KMIDIDestination(id: uniqueID, name: name))
            debugLog("MIDI destination [\(index)]: \(name)", category: .network)
        }

        availableMIDIDestinations = destinations

        if outputSettings.coreMIDIEnabled {
            if let uniqueID = outputSettings.coreMIDIUniqueID,
               let endpoint = endpoint(for: uniqueID) {
                selectedCoreMIDIDestination = endpoint
            } else if outputSettings.coreMIDIUniqueID == nil,
                      let first = destinations.first,
                      let endpoint = endpoint(for: first.id) {
                // Migration default: preserve the previous first-destination
                // behavior until the user chooses a concrete endpoint.
                outputSettings.coreMIDIUniqueID = first.id
                selectedCoreMIDIDestination = endpoint
            } else {
                selectedCoreMIDIDestination = 0
            }
            midiDst0 = selectedCoreMIDIDestination
        } else {
            selectedCoreMIDIDestination = 0
            midiDst0 = 0
        }

        if destinations.isEmpty {
            warningLog("No MIDI destinations found", category: .network)
        }
        #else
        let count = MIDIGetNumberOfDestinations()
        midiDests.removeAll(keepingCapacity: true)
        for index in 0..<count {
            let endpoint = MIDIGetDestination(index)
            if endpoint != 0 {
                midiDests.append(endpoint)
            }
        }
        midiDst0 = midiDests.first ?? 0
        #endif
    }

    #if os(macOS)

    private func endpoint(for uniqueID: Int32) -> MIDIEndpointRef? {
        let count = MIDIGetNumberOfDestinations()
        for index in 0..<count {
            let endpoint = MIDIGetDestination(index)
            if endpoint != 0 && midiUniqueID(for: endpoint) == uniqueID {
                return endpoint
            }
        }
        return nil
    }

    private func midiUniqueID(for endpoint: MIDIEndpointRef) -> Int32 {
        var uniqueID: MIDIUniqueID = 0
        guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID) == noErr else {
            return Int32(bitPattern: endpoint)
        }
        return uniqueID
    }

    private func midiDisplayName(for endpoint: MIDIEndpointRef) -> String? {
        var unmanagedName: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &unmanagedName) == noErr,
              let unmanagedName = unmanagedName else {
            return nil
        }
        let name = unmanagedName.takeUnretainedValue() as String
        unmanagedName.release()
        return name
    }

    #endif
}
