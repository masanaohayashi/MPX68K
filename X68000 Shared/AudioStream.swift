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
#endif

func bridge<T : AnyObject>(_ obj : T) -> UnsafeRawPointer {
    return UnsafeRawPointer(Unmanaged.passUnretained(obj).toOpaque())
    // return unsafeAddressOf(obj) // ***
}

func bridge<T : AnyObject>(_ ptr : UnsafeRawPointer) -> T {
    return Unmanaged<T>.fromOpaque(ptr).takeUnretainedValue()
    // return unsafeBitCast(ptr, T.self) // ***
}

func outputCallback(_ data: UnsafeMutableRawPointer?, queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
    
    let audioData = buffer.pointee.mAudioData
    let size = buffer.pointee.mAudioDataBytesCapacity / 4  // Size in 16-bit stereo frames
    let stream: AudioStream? = data.map { bridge($0) }
    
    // Safety check for reasonable buffer size
    if size > 0 && size <= 8192 {
        let mAudioDataPtr = UnsafeMutablePointer<Int16>(OpaquePointer(audioData))
        
        // Let the X68000 audio core fill the buffer directly
        X68000_AudioCallBack(mAudioDataPtr, UInt32(size))
        stream?.tapRenderedAudio(audioData, frameCount: Int(size))
        
        buffer.pointee.mAudioDataByteSize = buffer.pointee.mAudioDataBytesCapacity
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    } else {
        // Fallback: clear and enqueue if size is invalid
        memset(audioData, 0, Int(buffer.pointee.mAudioDataBytesCapacity))
        stream?.tapRenderedAudio(audioData, frameCount: Int(size))
        buffer.pointee.mAudioDataByteSize = buffer.pointee.mAudioDataBytesCapacity
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
}


class AudioStream {
    static var recordingTap: ((UnsafeRawPointer, Int, Int) -> Void)?

    #if os(macOS)
    private let audioUnitHost = MPX68KAudioUnitHost()
    #endif

    var dataFormat:     AudioStreamBasicDescription
    var queue:          AudioQueueRef? = nil

    var buffers =       [AudioQueueBufferRef?](repeating: nil, count: 4)  // Increased buffer count for stability

    var bufferByteSize: UInt32
    
	var samplingrate = 22050
	
	init (samplingrate: Int) {
		self.samplingrate = samplingrate

        dataFormat = AudioStreamBasicDescription(
            mSampleRate:        Float64(samplingrate),
            mFormatID:          kAudioFormatLinearPCM,
            mFormatFlags:       kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket:    4,
            mFramesPerPacket:   1,
            mBytesPerFrame:     4,
            mChannelsPerFrame:  2,
            mBitsPerChannel:    16,
            mReserved:          0
        )

        // Calculate buffer size based on sample rate to provide ~100ms of audio buffer for stability
        let bufferDurationSeconds: Float64 = 0.1  // 100ms for better stability and reduced stuttering
        let framesPerBuffer = UInt32(Float64(samplingrate) * bufferDurationSeconds)
        bufferByteSize = framesPerBuffer * dataFormat.mBytesPerFrame
        
        debugLog("Audio buffer: \(framesPerBuffer) frames, \(bufferByteSize) bytes", category: .audio)
//return;
        AudioQueueNewOutput(
            &dataFormat,
            outputCallback,
            unsafeBitCast(self, to: UnsafeMutableRawPointer.self),
            nil,  // Use internal thread for better performance
            nil,  // Use internal thread for better performance
            0,
            &queue)
        
        // Set audio queue properties for better performance and stability
        if let queue = queue {
            // Disable level metering for better performance
            var enableLevelMetering: UInt32 = 0
            AudioQueueSetProperty(queue, kAudioQueueProperty_EnableLevelMetering, &enableLevelMetering, UInt32(MemoryLayout<UInt32>.size))
        }
        
        load()
    
    }

    func tapRenderedAudio(_ audioData: UnsafeMutableRawPointer?, frameCount: Int) {
        guard frameCount > 0,
              let audioData = audioData,
              let recordingTap = AudioStream.recordingTap else {
            return
        }

        recordingTap(UnsafeRawPointer(audioData), frameCount, samplingrate)
    }

    func load()
    {
        if let queue = self.queue {
            
            // Allocate and pre-fill all buffers
            for i in 0..<buffers.count {
                AudioQueueAllocateBuffer(queue, bufferByteSize, &buffers[i])
                if let buffer = buffers[i] {
                    // Pre-fill buffer with silence to ensure smooth startup
                    memset(buffer.pointee.mAudioData, 0, Int(bufferByteSize))
                    buffer.pointee.mAudioDataByteSize = bufferByteSize
                    outputCallback(unsafeBitCast(self, to: UnsafeMutableRawPointer.self), queue: queue, buffer: buffer)
                }
            }
            
            // Flush any previous state and prime the queue
            AudioQueueFlush(queue)
            let primeResult = AudioQueuePrime(queue, 0, nil)
            if primeResult != noErr {
                errorLog("Failed to prime audio queue: \(primeResult)", category: .audio)
            }
        }
    }

    func play()
    {
        debugLog("Audio Play", category: .audio)
        if let queue = self.queue {
            let result = AudioQueueStart(queue, nil)
            if result != noErr {
                errorLog("Failed to start audio queue: \(result)", category: .audio)
            }
        }
        #if os(macOS)
        audioUnitHost.play()
        #endif
    }
    
    func stop()
    {
        debugLog("Audio Stop", category: .audio)
        if let queue = self.queue {
            let result = AudioQueueStop(queue, true)  // immediate stop
            if result != noErr {
                errorLog("Failed to stop audio queue: \(result)", category: .audio)
            }
        }
        #if os(macOS)
        audioUnitHost.stop()
        #endif
    }
    
    func pause()
    {
        debugLog("Audio Pause", category: .audio)
        if let queue = self.queue {
            let result = AudioQueuePause(queue)
            if result != noErr {
                errorLog("Failed to pause audio queue: \(result)", category: .audio)
            }
        }
        #if os(macOS)
        audioUnitHost.pause()
        #endif
    }
    func close()
    {
        debugLog("Audio Close", category: .audio)

        if let queue = self.queue {
            // Stop audio queue first
            AudioQueueStop(queue, true)
            
            // Flush any remaining buffers
            AudioQueueFlush(queue)
            
            // Free all buffers
            for buffer in buffers {
                if let buffer = buffer {
                    AudioQueueFreeBuffer(queue, buffer)
                }
            }
            
            // Dispose of the queue
            let result = AudioQueueDispose(queue, true)
            if result != noErr {
                errorLog("Failed to dispose audio queue: \(result)", category: .audio)
            }
            
            self.queue = nil
        }
        #if os(macOS)
        audioUnitHost.close()
        #endif
    }

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
