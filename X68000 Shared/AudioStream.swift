#if false

//import Foundation
import AVFoundation


class AudioStream {
    

    var samplingrate = 22050

    init (samplingrate: Int) {
		self.samplingrate = samplingrate
    }


    
    // エンジンの生成
    let audioEngine = AVAudioEngine()
    // ソースノードの生成
    let player = AVAudioPlayerNode()
    
    var buffer :AVAudioPCMBuffer?
    
    

    
    private var sourceNode : AVAudioSourceNode?
	func play(  )
    {
        debugLog("Audio Play", category: .audio)

        // プレイヤーノードからオーディオフォーマットを取得
             let outputNode = audioEngine.outputNode
        let format = outputNode.inputFormat(forBus: 0)
        debugLog("Audio sample rate: \(format.sampleRate)", category: .audio)
        debugLog("Audio format: \(format.commonFormat)", category: .audio)
		let audioFormat :AVAudioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(self.samplingrate), channels: 2, interleaved: true )!// player.outputFormat(forBus: 0)
        let sampleRate = Float(audioFormat.sampleRate)
        debugLog("sampleRate: \(sampleRate)", category: .audio)
            
        
        sourceNode = AVAudioSourceNode(format: audioFormat , renderBlock: { (_, timeStamp, frameCount, audioBufferList) -> OSStatus in

                let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
                let buf: UnsafeMutableBufferPointer<Int16> = UnsafeMutableBufferPointer(ablPointer[0])
                        debugLog("mNumberBuffers: \(audioBufferList.pointee.mNumberBuffers)", category: .audio)
                        debugLog("mDataByteSize: \(audioBufferList.pointee.mBuffers.mDataByteSize)", category: .audio)
                        debugLog("mNumberChannels: \(audioBufferList.pointee.mBuffers.mNumberChannels)", category: .audio)
        debugLog("frameCount: \(frameCount)", category: .audio)
                X68000_AudioCallBack(ablPointer[0].mData, UInt32(frameCount));

            return noErr
        })

        // オーディオエンジンにプレイヤーをアタッチ
        sourceNode?.reset()
        audioEngine.attach(sourceNode!)

        let mixer = audioEngine.mainMixerNode

        audioEngine.connect(sourceNode!, to: mixer, format: audioFormat)
        //        audioEngine.attach(player)
        // プレイヤーノードとミキサーノードを接続
  //      audioEngine.connect(player, to: mixer, format: audioFormat)
        // 再生の開始を設定
//        alloc()
        audioEngine.prepare()
        do {
          // エンジンを開始
          try audioEngine.start()
          // 再生
//          player.play()
        } catch let error {
          errorLog("Audio error", error: error, category: .audio)
        }



    }
    func stop()
    {
        debugLog("Audio Stop", category: .audio)

    }
    func pause()
    {
        debugLog("Audio Pause", category: .audio)

    }
    func close()
    {
        debugLog("Audio Close", category: .audio)
    }
}


 #else

import Foundation
import AudioToolbox
#if os(macOS)
import AVFoundation
import AppKit
import CoreAudioKit
import CoreAudio
#endif

func outputCallback(_ data: UnsafeMutableRawPointer?, queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
    
    let audioData = buffer.pointee.mAudioData
    let size = buffer.pointee.mAudioDataBytesCapacity / 4  // Size in 16-bit stereo frames
    
    // Safety check for reasonable buffer size
    if size > 0 && size <= 8192 {
        let mAudioDataPtr = UnsafeMutablePointer<Int16>(OpaquePointer(audioData))
        
        // Let the X68000 audio core fill the buffer directly
        X68000_AudioCallBack(mAudioDataPtr, UInt32(size))
        X68000_AudioRenderCapture(mAudioDataPtr, UInt32(size))
        
        buffer.pointee.mAudioDataByteSize = buffer.pointee.mAudioDataBytesCapacity
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    } else {
        // Fallback: clear and enqueue if size is invalid
        memset(audioData, 0, Int(buffer.pointee.mAudioDataBytesCapacity))
        buffer.pointee.mAudioDataByteSize = buffer.pointee.mAudioDataBytesCapacity
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
}


class AudioStream {
    private static let recordingTapLock = NSLock()
    private static let recordingPumpQueue = DispatchQueue(label: "MPX68K.AudioStream.recording")
    private static var recordingPumpTimer: DispatchSourceTimer?
    private static var recordingBuffer = [Int16](repeating: 0, count: 2048 * 2)
    static var recordingTapSampleRate = 48_000
    static var recordingTap: ((UnsafeRawPointer, Int, Int) -> Void)? {
        didSet {
            if recordingTap == nil {
                stopRecordingPump()
            } else {
                startRecordingPump()
            }
        }
    }

    #if os(macOS)
    private let audioUnitHost = MPX68KAudioUnitHost()
    private var directAudioUnitOutput: MPX68KDirectAudioUnitOutput?
    #endif

    var dataFormat:     AudioStreamBasicDescription
    var queue:          AudioQueueRef? = nil

    var buffers =       [AudioQueueBufferRef?](repeating: nil, count: 4)

    var bufferByteSize: UInt32
	var samplingrate = 22050
    private var internalAudioSettings: MPX68KInternalAudioSettings
    private var isInternalOutputRunning = false
    private(set) var outputSampleRate = 22050

    init(samplingrate: Int,
         internalAudioSettings: MPX68KInternalAudioSettings = MPX68KInternalAudioSettings()) {
        self.samplingrate = max(8_000, samplingrate)
        self.internalAudioSettings = internalAudioSettings
        self.outputSampleRate = self.samplingrate

        #if os(macOS)
        self.directAudioUnitOutput = nil
        #endif

        dataFormat = AudioStreamBasicDescription(
            mSampleRate:        Float64(self.samplingrate),
            mFormatID:          kAudioFormatLinearPCM,
            mFormatFlags:       kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket:    4,
            mFramesPerPacket:   1,
            mBytesPerFrame:     4,
            mChannelsPerFrame:  2,
            mBitsPerChannel:    16,
            mReserved:          0
        )

        let framesPerBuffer = UInt32(internalAudioSettings.bufferFrames)
        bufferByteSize = framesPerBuffer * dataFormat.mBytesPerFrame

        if let error = configureInternalOutput() {
            errorLog("Built-in audio configuration: \(error)", category: .audio)
        }

    }

    private static func startRecordingPump() {
        recordingTapLock.lock()
        defer { recordingTapLock.unlock() }
        guard recordingPumpTimer == nil else { return }

        X68000_AudioRenderCaptureEnable(1)
        let timer = DispatchSource.makeTimerSource(queue: recordingPumpQueue)
        timer.schedule(deadline: .now(),
                       repeating: .milliseconds(10),
                       leeway: .milliseconds(2))
        timer.setEventHandler {
            drainRecordingAudio()
        }
        recordingPumpTimer = timer
        timer.resume()
    }

    private static func stopRecordingPump() {
        recordingTapLock.lock()
        let timer = recordingPumpTimer
        recordingPumpTimer = nil
        X68000_AudioRenderCaptureEnable(0)
        recordingTapLock.unlock()
        timer?.cancel()
    }

    private static func drainRecordingAudio() {
        while true {
            let frameCount = recordingBuffer.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return UInt32(0) }
                return X68000_AudioRenderCaptureRead(baseAddress, 2048)
            }
            guard frameCount > 0 else { return }

            recordingTapLock.lock()
            let tap = recordingTap
            let sampleRate = recordingTapSampleRate
            recordingTapLock.unlock()
            guard let tap = tap else { return }

            recordingBuffer.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                tap(UnsafeRawPointer(baseAddress), Int(frameCount), sampleRate)
            }
        }
    }

    private func configureInternalOutput() -> String? {
        #if os(macOS)
        applyInternalAudioGains(
            adpcmGainDB: internalAudioSettings.adpcmGainDB,
            opmGainDB: internalAudioSettings.opmGainDB
        )
        applyInternalAudioLowPass(
            cutoffHz: internalAudioSettings.adpcmLowPassCutoffHz
        )
        #endif
        X68000_AudioRenderReset()

        #if os(macOS)
        if internalAudioSettings.mode == .asynchronous {
            let output = MPX68KDirectAudioUnitOutput()
            if let error = output.initialize(bufferFrames: internalAudioSettings.bufferFrames) {
                directAudioUnitOutput = nil
                outputSampleRate = samplingrate
                X68000_AudioRenderSetHostRate(UInt32(samplingrate))
                createAudioQueue()
                return error
            }

            directAudioUnitOutput = output
            outputSampleRate = Int(output.sampleRate.rounded())
            X68000_AudioRenderSetHostRate(UInt32(outputSampleRate))
            return nil
        }
        #endif

        outputSampleRate = samplingrate
        X68000_AudioRenderSetHostRate(UInt32(outputSampleRate))
        createAudioQueue()
        return nil
    }

    private func createAudioQueue() {
        guard queue == nil else { return }

        var createdQueue: AudioQueueRef?
        let result = AudioQueueNewOutput(
            &dataFormat,
            outputCallback,
            unsafeBitCast(self, to: UnsafeMutableRawPointer.self),
            nil,
            nil,
            0,
            &createdQueue)
        guard result == noErr, let createdQueue = createdQueue else {
            errorLog("Failed to create audio queue: \(result)", category: .audio)
            return
        }
        queue = createdQueue

        var enableLevelMetering: UInt32 = 0
        AudioQueueSetProperty(
            createdQueue,
            kAudioQueueProperty_EnableLevelMetering,
            &enableLevelMetering,
            UInt32(MemoryLayout<UInt32>.size)
        )
        load()
    }

    private func disposeAudioQueue() {
        if let queue = self.queue {

            AudioQueueStop(queue, true)
            AudioQueueFlush(queue)
            for buffer in buffers {
                if let buffer = buffer {
                    AudioQueueFreeBuffer(queue, buffer)
                }
            }
            buffers = [AudioQueueBufferRef?](repeating: nil, count: buffers.count)
            AudioQueueDispose(queue, true)
            self.queue = nil
        }
    }

    private func startInternalOutput() {
        #if os(macOS)
        if let directAudioUnitOutput = directAudioUnitOutput {
            if let error = directAudioUnitOutput.start() {
                errorLog("Failed to start direct AudioUnit: \(error)", category: .audio)
                // A device can disappear or reject the requested period after
                // initialization. Keep the emulator audible by falling back
                // to the compatibility queue for this session.
                directAudioUnitOutput.close()
                self.directAudioUnitOutput = nil
                outputSampleRate = samplingrate
                X68000_AudioRenderSetHostRate(UInt32(samplingrate))
                createAudioQueue()
            } else {
                isInternalOutputRunning = true
                return
            }
        }
        #endif

        guard let queue = self.queue else { return }
        let result = AudioQueueStart(queue, nil)
        if result != noErr {
            errorLog("Failed to start audio queue: \(result)", category: .audio)
        } else {
            isInternalOutputRunning = true
        }
    }

    private func stopInternalOutput() {
        #if os(macOS)
        if let directAudioUnitOutput = directAudioUnitOutput {
            directAudioUnitOutput.stop()
            isInternalOutputRunning = false
            return
        }
        #endif

        if let queue = self.queue {
            let result = AudioQueueStop(queue, true)
            if result != noErr {
                errorLog("Failed to stop audio queue: \(result)", category: .audio)
            }
            isInternalOutputRunning = false
        }
    }

    private func pauseInternalOutput() {
        #if os(macOS)
        if let directAudioUnitOutput = directAudioUnitOutput {
            directAudioUnitOutput.pause()
            isInternalOutputRunning = false
            return
        }
        #endif

        if let queue = self.queue {
            let result = AudioQueuePause(queue)
            if result != noErr {
                errorLog("Failed to pause audio queue: \(result)", category: .audio)
            }
            isInternalOutputRunning = false
        }
    }

    func load() {
        guard let queue = self.queue else { return }

        for i in 0..<buffers.count {
            let result = AudioQueueAllocateBuffer(queue, bufferByteSize, &buffers[i])
            guard result == noErr, let buffer = buffers[i] else {
                errorLog("Failed to allocate audio queue buffer: \(result)", category: .audio)
                continue
            }
            memset(buffer.pointee.mAudioData, 0, Int(bufferByteSize))
            buffer.pointee.mAudioDataByteSize = bufferByteSize
            outputCallback(unsafeBitCast(self, to: UnsafeMutableRawPointer.self),
                           queue: queue,
                           buffer: buffer)
        }

        let primeResult = AudioQueuePrime(queue, 0, nil)
        if primeResult != noErr {
            errorLog("Failed to prime audio queue: \(primeResult)", category: .audio)
        }
    }

    func play()
    {
        debugLog("Audio Play", category: .audio)
        startInternalOutput()
        #if os(macOS)
        audioUnitHost.play()
        #endif
    }
    
    func stop()
    {
        debugLog("Audio Stop", category: .audio)
        stopInternalOutput()
        #if os(macOS)
        audioUnitHost.stop()
        #endif
    }
    
    func pause()
    {
        debugLog("Audio Pause", category: .audio)
        pauseInternalOutput()
        #if os(macOS)
        audioUnitHost.pause()
        #endif
    }
    func close()
    {
        debugLog("Audio Close", category: .audio)

        #if os(macOS)
        directAudioUnitOutput?.close()
        directAudioUnitOutput = nil
        #endif
        disposeAudioQueue()
        isInternalOutputRunning = false
        X68000_AudioRenderReset()
        #if os(macOS)
        audioUnitHost.close()
        #endif
    }

    @discardableResult
    func applyInternalAudioSettings(_ settings: MPX68KInternalAudioSettings) -> String? {
        let wasRunning = isInternalOutputRunning
        if wasRunning {
            stopInternalOutput()
        }

        // Always dispose the old queue before rebuilding the selected path.
        // AudioQueueStop flushes its enqueued buffers; retaining that queue
        // would make a later compatibility-mode restart begin with no buffers.
        #if os(macOS)
        directAudioUnitOutput?.stop()
        #endif
        disposeAudioQueue()

        #if os(macOS)
        directAudioUnitOutput?.close()
        directAudioUnitOutput = nil
        #endif

        internalAudioSettings = settings
        bufferByteSize = UInt32(settings.bufferFrames) * dataFormat.mBytesPerFrame
        let error = configureInternalOutput()

        if wasRunning {
            startInternalOutput()
        }
        return error
    }

    #if os(macOS)

    func applyInternalAudioGains(adpcmGainDB: Double, opmGainDB: Double) {
        X68000_AudioRenderSetBusGains(Float(adpcmGainDB), Float(opmGainDB))
    }

    func applyInternalAudioLowPass(cutoffHz: Double) {
        X68000_AudioRenderSetADPCMLowPassCutoff(Float(cutoffHz))
    }

    #endif

    #if os(macOS)

    static func availableAudioUnits() -> [MPX68KAudioUnitDescriptor] {
        MPX68KAudioUnitHost.availableAudioUnits()
    }

    func applyAudioUnitSettings(_ settings: MPX68KAudioUnitSettings,
                                completion: @escaping (String?) -> Void) {
        audioUnitHost.apply(settings, completion: completion)
    }

    func sendAudioUnitMIDI(_ event: [UInt8], hostTime: UInt64) {
        audioUnitHost.sendMIDI(event, hostTime: hostTime)
    }

    func showAudioUnitEditor(completion: @escaping (Result<NSViewController, Error>) -> Void) {
        audioUnitHost.showEditor(completion: completion)
    }

    #endif
}

#if os(macOS)

private final class MPX68KDirectAudioUnitOutput {
    private var audioUnit: AudioUnit?
    private var configuredDevice: AudioDeviceID?
    private var previousDeviceBufferFrames: UInt32?
    private(set) var sampleRate: Double = 48_000.0
    private(set) var isRunning = false

    deinit {
        close()
    }

    func initialize(bufferFrames: Int) -> String? {
        guard audioUnit == nil else { return nil }

        guard let device = Self.defaultOutputDevice() else {
            return "No default macOS audio output device is available"
        }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            return "HAL output AudioUnit is not available"
        }

        var createdUnit: AudioUnit?
        let createStatus = AudioComponentInstanceNew(component, &createdUnit)
        guard createStatus == noErr, let unit = createdUnit else {
            return Self.statusMessage("Cannot create HAL output AudioUnit", status: createStatus)
        }

        var keepUnit = false
        defer {
            if !keepUnit {
                AudioComponentInstanceDispose(unit)
            }
        }

        var enableOutput: UInt32 = 1
        var status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &enableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            return Self.statusMessage("Cannot enable HAL output", status: status)
        }

        var disableInput: UInt32 = 0
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &disableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            return Self.statusMessage("Cannot disable HAL input", status: status)
        }

        var selectedDevice = device
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDevice,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            return Self.statusMessage("Cannot select the default audio device", status: status)
        }

        configuredDevice = device
        previousDeviceBufferFrames = Self.deviceBufferSize(device)
        let bufferStatus = Self.setDeviceBufferSize(UInt32(bufferFrames), device: device)
        guard bufferStatus == noErr else {
            return Self.statusMessage("Cannot set audio device buffer size", status: bufferStatus)
        }

        sampleRate = Self.deviceSampleRate(device) ?? 48_000.0
        let format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeEndian
                | kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var clientFormat = format
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &clientFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            return Self.statusMessage("Cannot configure HAL output format", status: status)
        }

        var maximumFrames = max(UInt32(bufferFrames),
                                Self.deviceBufferSize(device) ?? UInt32(bufferFrames))
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maximumFrames,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            return Self.statusMessage("Cannot configure AudioUnit buffer size", status: status)
        }

        var callback = AURenderCallbackStruct(
            inputProc: mpx68kDirectAudioRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            return Self.statusMessage("Cannot install AudioUnit render callback", status: status)
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            return Self.statusMessage("Cannot initialize HAL output AudioUnit", status: status)
        }

        audioUnit = unit
        keepUnit = true
        X68000_AudioRenderSetHostRate(UInt32(sampleRate.rounded()))
        return nil
    }

    func start() -> String? {
        guard let audioUnit = audioUnit else {
            return "HAL output AudioUnit is not initialized"
        }
        guard !isRunning else { return nil }

        let status = AudioOutputUnitStart(audioUnit)
        guard status == noErr else {
            return Self.statusMessage("Cannot start HAL output AudioUnit", status: status)
        }
        isRunning = true
        return nil
    }

    func stop() {
        guard let audioUnit = audioUnit, isRunning else { return }
        AudioOutputUnitStop(audioUnit)
        isRunning = false
    }

    func pause() {
        stop()
    }

    func close() {
        if let audioUnit = audioUnit {
            stop()
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            self.audioUnit = nil
        }
        if let device = configuredDevice,
           let previousDeviceBufferFrames = previousDeviceBufferFrames {
            _ = Self.setDeviceBufferSize(previousDeviceBufferFrames, device: device)
        }
        configuredDevice = nil
        previousDeviceBufferFrames = nil
    }

    fileprivate func render(frameCount: UInt32,
                             audioBufferList: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let audioBufferList = audioBufferList else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard !buffers.isEmpty else { return noErr }

        // The client format above is interleaved signed 16-bit stereo, so the
        // HAL normally supplies one buffer. Keep a safe fallback for a device
        // that reports a deinterleaved list rather than writing past it.
        guard buffers.count == 1,
              let audioData = buffers[0].mData else {
            for index in 0..<buffers.count {
                if let audioData = buffers[index].mData {
                    memset(audioData, 0, Int(buffers[index].mDataByteSize))
                }
            }
            return noErr
        }

        let samples = audioData.assumingMemoryBound(to: Int16.self)
        X68000_AudioRenderConsumeInt16(samples, frameCount)
        X68000_AudioRenderCapture(samples, frameCount)
        return noErr
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }
        return device
    }

    private static func deviceSampleRate(_ device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            &sampleRate
        )
        guard status == noErr, sampleRate >= 8_000.0, sampleRate <= 192_000.0 else {
            return nil
        }
        return sampleRate
    }

    private static func deviceBufferSize(_ device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }

        var frames = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            &frames
        )
        return status == noErr ? frames : nil
    }

    private static func setDeviceBufferSize(_ frames: UInt32,
                                            device: AudioDeviceID) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return noErr }

        var requestedFrames = frames
        return AudioObjectSetPropertyData(
            device,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &requestedFrames
        )
    }

    private static func statusMessage(_ action: String, status: OSStatus) -> String {
        "\(action) (status \(status))"
    }
}

private let mpx68kDirectAudioRenderCallback: AURenderCallback = {
    inRefCon, _, _, _, frameCount, audioBufferList in
    let output = Unmanaged<MPX68KDirectAudioUnitOutput>
        .fromOpaque(inRefCon)
        .takeUnretainedValue()
    return output.render(frameCount: frameCount, audioBufferList: audioBufferList)
}

private final class MPX68KAudioUnitHost {
    private let engine = AVAudioEngine()
    private let audioUnitMixer = AVAudioMixerNode()
    private var audioUnit: AVAudioUnit?
    private var midiScheduler: AUScheduleMIDIEventBlock?
    private var currentDescriptor: MPX68KAudioUnitDescriptor?
    private var loadingComponentID: String?
    private var loadGeneration: UInt = 0
    private var isEnabled = false
    private var gainDB: Double = 0.0
    private var isClosed = false

    init() {
        // Keep the AU path separate from the emulator's AudioQueue. The
        // dedicated mixer gives the AU its own gain control while both paths
        // remain audible through macOS's normal audio-device mixer.
        engine.attach(audioUnitMixer)
        engine.connect(audioUnitMixer, to: engine.mainMixerNode, format: nil)
    }

    deinit {
        close()
    }

    static func availableAudioUnits() -> [MPX68KAudioUnitDescriptor] {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let manager = AVAudioUnitComponentManager.shared()
        return manager.components(matching: description)
            .filter { $0.hasMIDIInput }
            .map { component in
                let componentDescription = component.audioComponentDescription
                let manufacturer = component.manufacturerName.isEmpty
                    ? ""
                    : " (\(component.manufacturerName))"
                return MPX68KAudioUnitDescriptor(
                    componentType: componentDescription.componentType,
                    componentSubType: componentDescription.componentSubType,
                    componentManufacturer: componentDescription.componentManufacturer,
                    componentFlags: componentDescription.componentFlags,
                    componentFlagsMask: componentDescription.componentFlagsMask,
                    name: "\(component.name)\(manufacturer)"
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func apply(_ settings: MPX68KAudioUnitSettings,
               completion: @escaping (String?) -> Void) {
        guard !isClosed else {
            completion("Audio Unit host is closed")
            return
        }

        if !settings.enabled || currentDescriptor?.id != settings.componentID {
            sendPanicToCurrentAudioUnit()
        }
        gainDB = min(max(settings.gainDB, -60.0), 0.0)
        isEnabled = settings.enabled

        guard settings.enabled else {
            loadGeneration &+= 1
            loadingComponentID = nil
            stop()
            completion(nil)
            return
        }

        guard let componentID = settings.componentID,
              let descriptor = Self.availableAudioUnits().first(where: { $0.id == componentID }) else {
            loadGeneration &+= 1
            loadingComponentID = nil
            isEnabled = false
            stop()
            completion("Select an Audio Unit instrument before enabling Audio Unit output")
            return
        }

        if currentDescriptor?.id == descriptor.id, audioUnit != nil {
            audioUnitMixer.outputVolume = Self.linearGain(for: gainDB)
            start(completion: completion)
            return
        }

        if loadingComponentID == descriptor.id {
            // A slider update or repeated toggle can arrive while the AU is
            // being instantiated. The pending load observes the latest gain.
            return
        }

        load(descriptor: descriptor, completion: completion)
    }

    func play() {
        guard isEnabled, audioUnit != nil else { return }
        start { error in
            if let error = error {
                errorLog(error, category: .audio)
            }
        }
    }

    func pause() {
        guard engine.isRunning else { return }
        engine.pause()
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        loadGeneration &+= 1
        loadingComponentID = nil
        engine.stop()
        if let audioUnit = audioUnit {
            engine.disconnectNodeInput(audioUnit)
            engine.detach(audioUnit)
        }
        audioUnit = nil
        midiScheduler = nil
        currentDescriptor = nil
    }

    func sendMIDI(_ event: [UInt8], hostTime: UInt64) {
        guard isEnabled,
              !event.isEmpty,
              let midiScheduler,
              audioUnit != nil else {
            return
        }

        scheduleMIDI(event, atHostTime: hostTime, using: midiScheduler)
    }

    private func sendPanicToCurrentAudioUnit() {
        guard let midiScheduler, audioUnit != nil else { return }
        for channel in 0..<16 {
            let status = 0xB0 | UInt8(channel)
            scheduleMIDI([status, 123, 0], atHostTime: 0, using: midiScheduler)
            scheduleMIDI([status, 120, 0], atHostTime: 0, using: midiScheduler)
        }
    }

    private func scheduleMIDI(_ event: [UInt8],
                              atHostTime hostTime: UInt64,
                              using scheduler: AUScheduleMIDIEventBlock) {
        let eventSampleTime = sampleTime(forHostTime: hostTime)
        event.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            scheduler(eventSampleTime, 0, event.count, baseAddress)
        }
    }

    private func sampleTime(forHostTime hostTime: UInt64) -> AUEventSampleTime {
        guard let renderTime = engine.outputNode.lastRenderTime,
              renderTime.isHostTimeValid,
              renderTime.isSampleTimeValid,
              renderTime.sampleRate > 0.0 else {
            // The engine may not have rendered its first cycle yet. Immediate
            // is the only valid fallback until an audio time anchor exists.
            return AUEventSampleTimeImmediate
        }

        let anchorHostTime = renderTime.hostTime
        let hostClockFrequency = AudioGetHostClockFrequency()
        guard hostClockFrequency > 0.0 else {
            return AUEventSampleTimeImmediate
        }
        let deltaTicks: Double
        if hostTime >= anchorHostTime {
            deltaTicks = Double(hostTime - anchorHostTime)
        } else {
            deltaTicks = -Double(anchorHostTime - hostTime)
        }
        let deltaFrames = AVAudioFramePosition(
            (deltaTicks / hostClockFrequency * renderTime.sampleRate).rounded()
        )
        let targetSampleTime = renderTime.sampleTime + deltaFrames
        guard targetSampleTime > renderTime.sampleTime else {
            return AUEventSampleTimeImmediate
        }
        return AUEventSampleTime(targetSampleTime)
    }

    func showEditor(completion: @escaping (Result<NSViewController, Error>) -> Void) {
        guard let audioUnit = audioUnit else {
            completion(.failure(Self.hostError("No Audio Unit is loaded")))
            return
        }

        audioUnit.auAudioUnit.requestViewController { viewController in
            DispatchQueue.main.async {
                guard let viewController = viewController else {
                    completion(.failure(Self.hostError("This Audio Unit does not provide a custom UI")))
                    return
                }
                completion(.success(viewController))
            }
        }
    }

    private func load(descriptor: MPX68KAudioUnitDescriptor,
                      completion: @escaping (String?) -> Void) {
        loadGeneration &+= 1
        let generation = loadGeneration
        loadingComponentID = descriptor.id
        stop()
        if let oldAudioUnit = audioUnit {
            engine.disconnectNodeInput(oldAudioUnit)
            engine.detach(oldAudioUnit)
        }
        audioUnit = nil
        midiScheduler = nil
        currentDescriptor = nil

        let description = AudioComponentDescription(
            componentType: descriptor.componentType,
            componentSubType: descriptor.componentSubType,
            componentManufacturer: descriptor.componentManufacturer,
            componentFlags: descriptor.componentFlags,
            componentFlagsMask: descriptor.componentFlagsMask
        )

        AVAudioUnit.instantiate(with: description, options: []) { [weak self] unit, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.loadGeneration == generation else { return }
                self.loadingComponentID = nil
                if let error = error {
                    self.isEnabled = false
                    completion("Cannot load Audio Unit: \(error.localizedDescription)")
                    return
                }
                guard let unit = unit else {
                    self.isEnabled = false
                    completion("Audio Unit returned no instance")
                    return
                }

                guard let midiScheduler = unit.auAudioUnit.scheduleMIDIEventBlock else {
                    self.isEnabled = false
                    completion("This Audio Unit does not accept MIDI input")
                    return
                }

                self.engine.attach(unit)
                self.engine.connect(unit, to: self.audioUnitMixer, format: nil)

                self.audioUnit = unit
                self.currentDescriptor = descriptor
                self.midiScheduler = midiScheduler
                self.audioUnitMixer.outputVolume = Self.linearGain(for: self.gainDB)
                self.start(completion: completion)
            }
        }
    }

    private func start(completion: @escaping (String?) -> Void) {
        guard isEnabled, audioUnit != nil else {
            completion(nil)
            return
        }
        guard !engine.isRunning else {
            completion(nil)
            return
        }

        engine.prepare()
        do {
            try engine.start()
            completion(nil)
        } catch {
            isEnabled = false
            completion("Cannot start Audio Unit engine: \(error.localizedDescription)")
        }
    }

    private static func linearGain(for decibels: Double) -> Float {
        Float(pow(10.0, decibels / 20.0))
    }

    private static func hostError(_ message: String) -> NSError {
        NSError(domain: "MPX68K.AudioUnitHost",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

#endif

#endif
