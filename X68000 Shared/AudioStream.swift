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
    // Audio controls are delivered from SwiftUI's main thread, while the
    // emulator and platform callback have their own timing requirements. Do
    // the small amount of gain/filter preparation off the main thread and
    // coalesce slider events so an old drag position cannot be applied after
    // the newest one.
    private static let audioParameterQueue = DispatchQueue(
        label: "MPX68K.AudioStream.parameters",
        qos: .userInitiated
    )
    private static let audioParameterLock = NSLock()
    private struct PendingAudioParameters {
        var adpcmGainDB: Float?
        var opmGainDB: Float?
        var lowPassCutoffHz: Float?
    }
    private static var pendingAudioParameters = PendingAudioParameters(
        adpcmGainDB: nil,
        opmGainDB: nil,
        lowPassCutoffHz: nil
    )
    private static var requestedAdpcmGainDB: Float = 0.0
    private static var requestedOpmGainDB: Float = 0.0
    private static var audioParameterUpdateScheduled = false

    private static func enqueueAudioParameters(adpcmGainDB: Float? = nil,
                                                opmGainDB: Float? = nil,
                                                lowPassCutoffHz: Float? = nil) {
        var shouldStartDrain = false
        audioParameterLock.lock()
        if let adpcmGainDB {
            pendingAudioParameters.adpcmGainDB = adpcmGainDB
            requestedAdpcmGainDB = adpcmGainDB
        }
        if let opmGainDB {
            pendingAudioParameters.opmGainDB = opmGainDB
            requestedOpmGainDB = opmGainDB
        }
        if let lowPassCutoffHz {
            pendingAudioParameters.lowPassCutoffHz = lowPassCutoffHz
        }
        if !audioParameterUpdateScheduled {
            audioParameterUpdateScheduled = true
            shouldStartDrain = true
        }
        audioParameterLock.unlock()

        guard shouldStartDrain else { return }
        audioParameterQueue.async {
            Self.drainAudioParameters()
        }
    }

    // These entry points are intentionally independent of an AudioStream
    // instance. SwiftUI can call them for every slider movement without
    // touching GameScene state or any output object's lifecycle.
    static func publishInternalAudioGains(adpcmGainDB: Double,
                                          opmGainDB: Double) {
        enqueueAudioParameters(
            adpcmGainDB: Float(adpcmGainDB),
            opmGainDB: Float(opmGainDB)
        )
    }

    static func publishInternalAudioLowPass(cutoffHz: Double) {
        enqueueAudioParameters(lowPassCutoffHz: Float(cutoffHz))
    }

    private static func drainAudioParameters() {
        while true {
            audioParameterLock.lock()
            let pending = pendingAudioParameters
            pendingAudioParameters = PendingAudioParameters(
                adpcmGainDB: nil,
                opmGainDB: nil,
                lowPassCutoffHz: nil
            )
            audioParameterLock.unlock()

            if pending.adpcmGainDB != nil || pending.opmGainDB != nil {
                // Both values are retained under the same lock so a caller
                // that updates one bus cannot accidentally reset the other.
                audioParameterLock.lock()
                let adpcmGainDB = requestedAdpcmGainDB
                let opmGainDB = requestedOpmGainDB
                audioParameterLock.unlock()
                X68000_AudioRenderSetBusGains(adpcmGainDB, opmGainDB)
            }
            if let lowPassCutoffHz = pending.lowPassCutoffHz {
                X68000_AudioRenderSetADPCMLowPassCutoff(lowPassCutoffHz)
            }

            audioParameterLock.lock()
            let hasPendingParameters = pendingAudioParameters.adpcmGainDB != nil
                || pendingAudioParameters.opmGainDB != nil
                || pendingAudioParameters.lowPassCutoffHz != nil
            if !hasPendingParameters {
                audioParameterUpdateScheduled = false
                audioParameterLock.unlock()
                return
            }
            audioParameterLock.unlock()
        }
    }
    #endif

    #if os(macOS)
    private let audioUnitHost = MPX68KAudioUnitHost()
    private var directAudioUnitOutput: MPX68KDirectAudioUnitOutput?
    private var audioEffectHost: MPX68KAudioEffectHost?
    #endif

    var dataFormat:     AudioStreamBasicDescription
    var queue:          AudioQueueRef? = nil

    var buffers =       [AudioQueueBufferRef?](repeating: nil, count: 4)

    var bufferByteSize: UInt32
	var samplingrate = 22050
    private var internalAudioSettings: MPX68KInternalAudioSettings
    private var isInternalOutputRunning = false
    private var shouldRunInternalOutput = false
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
        if let audioEffectHost = audioEffectHost {
            if let error = audioEffectHost.play() {
                errorLog("Failed to start Audio Unit effect chain: \(error)", category: .audio)
                audioEffectHost.close()
                self.audioEffectHost = nil
                X68000_AudioRenderReset()
                if let fallbackError = configureInternalOutput() {
                    errorLog("Built-in audio fallback failed: \(fallbackError)", category: .audio)
                }
                startInternalOutput()
            } else {
                isInternalOutputRunning = audioEffectHost.isRunning
            }
            return
        }

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
        if let audioEffectHost = audioEffectHost {
            audioEffectHost.stop()
            isInternalOutputRunning = false
            return
        }

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
        if let audioEffectHost = audioEffectHost {
            audioEffectHost.pause()
            isInternalOutputRunning = false
            return
        }

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
        shouldRunInternalOutput = true
        startInternalOutput()
        #if os(macOS)
        audioUnitHost.play()
        #endif
    }
    
    func stop()
    {
        debugLog("Audio Stop", category: .audio)
        shouldRunInternalOutput = false
        stopInternalOutput()
        #if os(macOS)
        audioUnitHost.stop()
        #endif
    }
    
    func pause()
    {
        debugLog("Audio Pause", category: .audio)
        shouldRunInternalOutput = false
        pauseInternalOutput()
        #if os(macOS)
        audioUnitHost.pause()
        #endif
    }
    func close()
    {
        debugLog("Audio Close", category: .audio)

        #if os(macOS)
        shouldRunInternalOutput = false
        saveAudioUnitState()
        audioEffectHost?.close()
        audioEffectHost = nil
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
    func applyInternalAudioOutputSettings(
        mode: MPX68KInternalAudioRenderMode,
        bufferFrames: Int
    ) -> String? {
        // This method is deliberately limited to the two settings that define
        // the output object. Runtime mix/filter parameters never enter this
        // path, so a slider cannot accidentally stop or rebuild audio.
        let settings = MPX68KInternalAudioSettings(
            mode: mode,
            bufferFrames: bufferFrames,
            adpcmGainDB: internalAudioSettings.adpcmGainDB,
            opmGainDB: internalAudioSettings.opmGainDB,
            adpcmLowPassCutoffHz: internalAudioSettings.adpcmLowPassCutoffHz
        )
        let outputPathChanged = settings.mode != internalAudioSettings.mode
            || settings.bufferFrames != internalAudioSettings.bufferFrames
        guard outputPathChanged else { return nil }

        #if os(macOS)
        if let audioEffectHost = audioEffectHost {
            internalAudioSettings = settings
            return audioEffectHost.applyBufferFrames(settings.bufferFrames)
        }
        #endif

        let wasRunning = shouldRunInternalOutput
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
        let settings = MPX68KInternalAudioSettings(
            mode: internalAudioSettings.mode,
            bufferFrames: internalAudioSettings.bufferFrames,
            adpcmGainDB: adpcmGainDB,
            opmGainDB: opmGainDB,
            adpcmLowPassCutoffHz: internalAudioSettings.adpcmLowPassCutoffHz
        )
        internalAudioSettings = settings
        Self.publishInternalAudioGains(
            adpcmGainDB: settings.adpcmGainDB,
            opmGainDB: settings.opmGainDB
        )
    }

    func applyInternalAudioLowPass(cutoffHz: Double) {
        let settings = MPX68KInternalAudioSettings(
            mode: internalAudioSettings.mode,
            bufferFrames: internalAudioSettings.bufferFrames,
            adpcmGainDB: internalAudioSettings.adpcmGainDB,
            opmGainDB: internalAudioSettings.opmGainDB,
            adpcmLowPassCutoffHz: cutoffHz
        )
        internalAudioSettings = settings
        Self.publishInternalAudioLowPass(cutoffHz: settings.adpcmLowPassCutoffHz)
    }

    #endif

    #if os(macOS)

    static func availableAudioUnits() -> [MPX68KAudioUnitDescriptor] {
        MPX68KAudioUnitHost.availableAudioUnits()
    }

    static func availableAudioEffects() -> [MPX68KAudioUnitDescriptor] {
        MPX68KAudioEffectHost.availableAudioEffects()
    }

    func applyAudioUnitSettings(_ settings: MPX68KAudioUnitSettings,
                                completion: @escaping (String?) -> Void) {
        audioUnitHost.apply(settings, completion: completion)
    }

    func applyAudioUnitVolume(_ gainDB: Double) {
        audioUnitHost.setGainOnly(gainDB)
    }

    func sendAudioUnitMIDI(_ event: [UInt8], hostTime: UInt64) {
        audioUnitHost.sendMIDI(event, hostTime: hostTime)
        audioEffectHost?.sendMIDI(event, hostTime: hostTime)
    }

    func showAudioUnitEditor(completion: @escaping (Result<NSViewController, Error>) -> Void) {
        audioUnitHost.showEditor(completion: completion)
    }

    func saveAudioUnitState() {
        audioUnitHost.saveState()
        audioEffectHost?.saveStates()
    }

    func applyAudioEffectSettings(
        _ settings: MPX68KAudioEffectSettings,
        completion: @escaping (String?) -> Void
    ) {
        let normalizedSettings = MPX68KAudioEffectSettings(
            componentIDs: settings.componentIDs
        )
        let hasSelectedEffect = normalizedSettings.hasSelectedEffect

        guard hasSelectedEffect else {
            guard let oldHost = audioEffectHost else {
                completion(nil)
                return
            }

            let wasRunning = shouldRunInternalOutput
            oldHost.close()
            audioEffectHost = nil
            X68000_AudioRenderReset()
            let error = configureInternalOutput()
            if wasRunning {
                startInternalOutput()
            }
            completion(error)
            return
        }

        let wasRunning = shouldRunInternalOutput
        let hadEffectHost = audioEffectHost != nil
        if !hadEffectHost {
            // The direct/queue output and an AVAudioEngine output cannot both
            // own the built-in stream. Stop and release the former before the
            // asynchronous effect instances are attached.
            stopInternalOutput()
            directAudioUnitOutput?.close()
            directAudioUnitOutput = nil
            disposeAudioQueue()
            X68000_AudioRenderReset()
            audioEffectHost = MPX68KAudioEffectHost()
        }

        guard let effectHost = audioEffectHost else {
            completion("Audio effect host is not available")
            return
        }
        let preferredSampleRate = Double(outputSampleRate)
        effectHost.apply(
            normalizedSettings,
            preferredSampleRate: preferredSampleRate,
            bufferFrames: internalAudioSettings.bufferFrames
        ) { [weak self, weak effectHost] error in
            guard let self = self, let effectHost = effectHost,
                  self.audioEffectHost === effectHost else {
                completion(nil)
                return
            }

            if let error = error {
                // If a component disappears or rejects instantiation, return
                // to the normal built-in path so a bad optional effect never
                // leaves the emulator silent.
                effectHost.close()
                self.audioEffectHost = nil
                X68000_AudioRenderReset()
                let fallbackError = self.configureInternalOutput()
                if wasRunning {
                    self.startInternalOutput()
                }
                if let fallbackError {
                    completion("\(error); fallback failed: \(fallbackError)")
                } else {
                    completion(error)
                }
                return
            }

            self.outputSampleRate = Int(effectHost.sampleRate.rounded())
            if wasRunning {
                _ = effectHost.play()
                self.isInternalOutputRunning = effectHost.isRunning
            }
            completion(nil)
        }
    }

    func showAudioEffectEditor(
        slot: Int,
        completion: @escaping (Result<NSViewController, Error>) -> Void
    ) {
        guard let audioEffectHost else {
            completion(.failure(NSError(
                domain: "MPX68K.AudioEffectHost",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No Audio Unit effect chain is loaded"]
            )))
            return
        }
        audioEffectHost.showEditor(slot: slot, completion: completion)
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

    fileprivate static func defaultOutputDevice() -> AudioDeviceID? {
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

    fileprivate static func deviceSampleRate(_ device: AudioDeviceID) -> Double? {
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

    fileprivate static func deviceBufferSize(_ device: AudioDeviceID) -> UInt32? {
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

    fileprivate static func setDeviceBufferSize(_ frames: UInt32,
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
    private static let audioUnitStateDefaultsPrefix = "MPX68K.AudioUnitState."
    private static let audioUnitLoadQueue = DispatchQueue(
        label: "MPX68K.AudioUnitHost.load",
        qos: .userInitiated
    )
    private let engine = AVAudioEngine()
    private let audioUnitMixer = AVAudioMixerNode()
    private var audioUnit: AVAudioUnit?
    private var midiScheduler: AUScheduleMIDIEventBlock?
    private var legacyAudioUnit: AudioUnit?
    private var currentDescriptor: MPX68KAudioUnitDescriptor?
    private var loadingComponentID: String?
    private var loadGeneration: UInt = 0
    private var isEnabled = false
    private var shouldRun = false
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

        let normalizedGainDB = min(max(settings.gainDB, -60.0), 0.0)

        // A gain-only change must stay on the running graph. In particular,
        // do not enumerate components, stop the engine, or reconnect the AU
        // while a slider is being dragged. AVAudioMixerNode exposes this as a
        // realtime-safe per-node gain control.
        if settings.enabled,
           currentDescriptor?.id == settings.componentID,
           audioUnit != nil {
            gainDB = normalizedGainDB
            isEnabled = true
            audioUnitMixer.outputVolume = Self.linearGain(for: gainDB)
            // This is a parameter-only update. The graph is already running;
            // do not call prepare/start here, because even a graph-preserving
            // start attempt can make the engine negotiate or interrupt the
            // current render cycle. Explicit play/resume owns engine start.
            if shouldRun && !engine.isRunning {
                start(completion: completion)
            } else {
                completion(nil)
            }
            return
        }

        if !settings.enabled || currentDescriptor?.id != settings.componentID {
            sendPanicToCurrentAudioUnit()
        }
        gainDB = normalizedGainDB
        isEnabled = settings.enabled

        guard settings.enabled else {
            loadGeneration &+= 1
            loadingComponentID = nil
            // Disable only the AU engine. Preserve the application's desired
            // playback state so re-enabling the same instrument can start it
            // without rebuilding the graph.
            stopEngine()
            completion(nil)
            return
        }

        guard let componentID = settings.componentID,
              let descriptor = Self.availableAudioUnits().first(where: { $0.id == componentID }) else {
            loadGeneration &+= 1
            loadingComponentID = nil
            isEnabled = false
            stopEngine()
            completion("Select an Audio Unit instrument before enabling Audio Unit output")
            return
        }

        if loadingComponentID == descriptor.id {
            // A slider update or repeated toggle can arrive while the AU is
            // being instantiated. The pending load observes the latest gain.
            completion(nil)
            return
        }

        load(descriptor: descriptor, completion: completion)
    }

    func setGainOnly(_ gainDB: Double) {
        guard !isClosed else { return }
        self.gainDB = min(max(gainDB, -60.0), 0.0)
        guard audioUnit != nil else { return }
        // AVAudioMixerNode's outputVolume is a graph parameter. Updating it
        // does not stop/prepare/reconnect the engine and must not call start,
        // even if a previous device interruption left the engine stopped.
        audioUnitMixer.outputVolume = Self.linearGain(for: self.gainDB)
    }

    func play() {
        shouldRun = true
        guard isEnabled, audioUnit != nil else { return }
        start { error in
            if let error = error {
                errorLog(error, category: .audio)
            }
        }
    }

    func pause() {
        shouldRun = false
        guard engine.isRunning else { return }
        engine.pause()
    }

    func stop() {
        shouldRun = false
        stopEngine()
    }

    private func stopEngine() {
        if engine.isRunning {
            engine.stop()
        }
    }

    func close() {
        guard !isClosed else { return }
        saveState()
        isClosed = true
        shouldRun = false
        loadGeneration &+= 1
        loadingComponentID = nil
        engine.stop()
        if let audioUnit = audioUnit {
            engine.disconnectNodeInput(audioUnit)
            engine.detach(audioUnit)
        }
        audioUnit = nil
        midiScheduler = nil
        legacyAudioUnit = nil
        currentDescriptor = nil
    }

    func saveState() {
        guard !isClosed,
              let audioUnit,
              let descriptor = currentDescriptor else {
            return
        }

        guard let state = audioUnit.auAudioUnit.fullState else {
            warningLog(
                "Audio Unit \(descriptor.name) does not provide a persistable state",
                category: .audio
            )
            return
        }

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: state,
                format: .binary,
                options: 0
            )
            UserDefaults.standard.set(data, forKey: Self.stateDefaultsKey(for: descriptor))
            debugLog("Saved Audio Unit state: \(descriptor.name)", category: .audio)
        } catch {
            warningLog(
                "Cannot serialize Audio Unit state for \(descriptor.name): \(error.localizedDescription)",
                category: .audio
            )
        }
    }

    func sendMIDI(_ event: [UInt8], hostTime: UInt64) {
        guard isEnabled,
              !event.isEmpty,
              audioUnit != nil else {
            return
        }

        if let midiScheduler {
            scheduleMIDI(event, atHostTime: hostTime, using: midiScheduler)
        } else if let legacyAudioUnit {
            sendLegacyMIDI(event, atHostTime: hostTime, using: legacyAudioUnit)
        }
    }

    private func sendPanicToCurrentAudioUnit() {
        guard audioUnit != nil else { return }
        for channel in 0..<16 {
            let status = 0xB0 | UInt8(channel)
            let allNotesOff = [status, 123, 0]
            let allSoundOff = [status, 120, 0]
            if let midiScheduler {
                scheduleMIDI(allNotesOff, atHostTime: 0, using: midiScheduler)
                scheduleMIDI(allSoundOff, atHostTime: 0, using: midiScheduler)
            } else if let legacyAudioUnit {
                sendLegacyMIDI(allNotesOff, atHostTime: 0, using: legacyAudioUnit)
                sendLegacyMIDI(allSoundOff, atHostTime: 0, using: legacyAudioUnit)
            }
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

    private func sendLegacyMIDI(_ event: [UInt8],
                                atHostTime hostTime: UInt64,
                                using audioUnit: AudioUnit) {
        guard let status = event.first else { return }
        let data1 = event.count > 1 ? event[1] : 0
        let data2 = event.count > 2 ? event[2] : 0
        let offset = sampleOffset(forHostTime: hostTime)
        _ = MusicDeviceMIDIEvent(
            audioUnit,
            UInt32(status),
            UInt32(data1),
            UInt32(data2),
            offset
        )
    }

    private func sampleOffset(forHostTime hostTime: UInt64) -> UInt32 {
        guard let renderTime = engine.outputNode.lastRenderTime,
              renderTime.isHostTimeValid,
              renderTime.isSampleTimeValid,
              renderTime.sampleRate > 0.0 else {
            return 0
        }

        let hostClockFrequency = AudioGetHostClockFrequency()
        guard hostClockFrequency > 0.0 else { return 0 }
        let deltaTicks: Double
        if hostTime >= renderTime.hostTime {
            deltaTicks = Double(hostTime - renderTime.hostTime)
        } else {
            deltaTicks = -Double(renderTime.hostTime - hostTime)
        }
        let deltaFrames = deltaTicks / hostClockFrequency * renderTime.sampleRate
        guard deltaFrames > 0.0 else { return 0 }
        return UInt32(min(deltaFrames.rounded(), Double(UInt32.max)))
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
        // Keep the previous instrument's latest state before its instance is
        // detached. Loading is asynchronous, so the app can otherwise quit
        // while the old instance has already been cleared from the host.
        saveState()
        loadGeneration &+= 1
        let generation = loadGeneration
        loadingComponentID = descriptor.id
        stopEngine()
        if let oldAudioUnit = audioUnit {
            engine.disconnectNodeInput(oldAudioUnit)
            engine.detach(oldAudioUnit)
        }
        audioUnit = nil
        midiScheduler = nil
        legacyAudioUnit = nil
        currentDescriptor = nil

        let description = AudioComponentDescription(
            componentType: descriptor.componentType,
            componentSubType: descriptor.componentSubType,
            componentManufacturer: descriptor.componentManufacturer,
            // The type/subtype/manufacturer identify the component. Passing
            // enumeration-time flags back into instantiation can make a valid
            // AUv2 lookup fail when the manager supplied a flag mask.
            componentFlags: 0,
            componentFlagsMask: 0
        )

        // Do not use AVAudioUnitMIDIInstrument's synchronous initializer here.
        // Some valid AUv2 music devices throw an Objective-C NSException
        // ("error -1") from that initializer. Swift Error handling cannot
        // catch an NSException, so the process would terminate before
        // `finishLoad` could report the failure. The asynchronous factory is
        // the safe path for both AUv2 and AUv3 components and reports failures
        // through its Error? completion value.
        //
        // AUv2 Music Devices are almost never sandbox-safe. Instantiate them
        // out of process first so the host does not dlopen the component
        // in-process under the hardened runtime. macOS may then show its
        // standard "Lower Security Settings" confirmation for this app only.
        // Fall back to the system default only if that request is rejected.
        Self.audioUnitLoadQueue.async { [weak self] in
            Self.instantiateMusicDevice(description: description) { unit, error in
                self?.finishLoad(
                    unit: unit,
                    error: error,
                    descriptor: descriptor,
                    generation: generation,
                    completion: completion
                )
            }
        }
    }

    private static func instantiateMusicDevice(
        description: AudioComponentDescription,
        completion: @escaping (AVAudioUnit?, Error?) -> Void
    ) {
        AVAudioUnit.instantiate(with: description, options: .loadOutOfProcess) { unit, error in
            if unit != nil {
                completion(unit, nil)
                return
            }
            AVAudioUnit.instantiate(with: description, options: []) { fallbackUnit, fallbackError in
                completion(fallbackUnit, fallbackError ?? error)
            }
        }
    }

    private func finishLoad(unit: AVAudioUnit?,
                            error: Error?,
                            descriptor: MPX68KAudioUnitDescriptor,
                            generation: UInt,
                            completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.loadGeneration == generation else {
                // The caller has already requested another state. Do not
                // leave its UI waiting for a completion from an obsolete
                // instance.
                completion(nil)
                return
            }
            self.loadingComponentID = nil
            if let error = error {
                self.isEnabled = false
                errorLog(
                    "Cannot load Audio Unit \(descriptor.name): \(error.localizedDescription)",
                    category: .audio
                )
                completion("Cannot load Audio Unit: \(error.localizedDescription)")
                return
            }
            guard let unit = unit else {
                self.isEnabled = false
                completion("Audio Unit returned no instance")
                return
            }

            self.engine.attach(unit)
            self.engine.connect(unit, to: self.audioUnitMixer, format: nil)

            self.audioUnit = unit
            self.currentDescriptor = descriptor
            self.restoreSavedState(for: descriptor, in: unit)
            self.audioUnitMixer.outputVolume = Self.linearGain(for: self.gainDB)
            if self.shouldRun {
                self.start { error in
                    if let error = error {
                        completion(error)
                        return
                    }
                    self.bindMIDI(from: unit, completion: completion)
                }
            } else {
                self.bindMIDI(from: unit, completion: completion)
            }
        }
    }

    private func bindMIDI(from unit: AVAudioUnit,
                          completion: @escaping (String?) -> Void) {
        var midiScheduler = unit.auAudioUnit.scheduleMIDIEventBlock
        var legacyAudioUnit = midiScheduler == nil ? unit.audioUnit : nil
        if midiScheduler == nil && legacyAudioUnit == nil {
            // AUv2 wrappers often expose the MIDI schedule block only after
            // render resources exist. Try an explicit allocate before giving up.
            do {
                try unit.auAudioUnit.allocateRenderResources()
                midiScheduler = unit.auAudioUnit.scheduleMIDIEventBlock
                legacyAudioUnit = midiScheduler == nil ? unit.audioUnit : nil
            } catch {
                errorLog(
                    "Audio Unit MIDI resource allocation: \(error.localizedDescription)",
                    category: .audio
                )
            }
        }
        guard midiScheduler != nil || legacyAudioUnit != nil else {
            isEnabled = false
            stopEngine()
            if let audioUnit = audioUnit {
                engine.disconnectNodeInput(audioUnit)
                engine.detach(audioUnit)
            }
            audioUnit = nil
            currentDescriptor = nil
            completion("This Audio Unit does not accept MIDI input")
            return
        }

        self.midiScheduler = midiScheduler
        self.legacyAudioUnit = legacyAudioUnit
        completion(nil)
    }

    private func restoreSavedState(for descriptor: MPX68KAudioUnitDescriptor,
                                   in unit: AVAudioUnit) {
        guard let data = UserDefaults.standard.data(forKey: Self.stateDefaultsKey(for: descriptor)) else {
            return
        }

        do {
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard let state = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
            ) as? [String: Any] else {
                warningLog(
                    "Saved Audio Unit state has an invalid format: \(descriptor.name)",
                    category: .audio
                )
                return
            }

            // AUAudioUnit.fullState is bridged to kAudioUnitProperty_ClassInfo,
            // so this restores both AUv3 and AUv2 music devices through the
            // same API. It is applied before the engine is started.
            unit.auAudioUnit.fullState = state
            guard unit.auAudioUnit.fullState != nil else {
                warningLog(
                    "Audio Unit rejected its saved state: \(descriptor.name)",
                    category: .audio
                )
                return
            }
            notifyParameterListeners(for: unit)
            debugLog("Restored Audio Unit state: \(descriptor.name)", category: .audio)
        } catch {
            warningLog(
                "Cannot deserialize Audio Unit state for \(descriptor.name): \(error.localizedDescription)",
                category: .audio
            )
        }
    }

    private func notifyParameterListeners(for unit: AVAudioUnit) {
        let underlyingAudioUnit: AudioUnit? = unit.audioUnit
        guard let underlyingAudioUnit else { return }

        var changedUnit = AudioUnitParameter(
            mAudioUnit: underlyingAudioUnit,
            mParameterID: kAUParameterListener_AnyParameter,
            mScope: kAudioUnitScope_Global,
            mElement: 0
        )
        _ = AUParameterListenerNotify(nil, nil, &changedUnit)
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
            if let audioUnit = audioUnit {
                engine.disconnectNodeInput(audioUnit)
                engine.detach(audioUnit)
            }
            audioUnit = nil
            midiScheduler = nil
            legacyAudioUnit = nil
            currentDescriptor = nil
            completion("Cannot start Audio Unit engine: \(error.localizedDescription)")
        }
    }

    private static func linearGain(for decibels: Double) -> Float {
        Float(pow(10.0, decibels / 20.0))
    }

    private static func stateDefaultsKey(for descriptor: MPX68KAudioUnitDescriptor) -> String {
        "\(audioUnitStateDefaultsPrefix)\(descriptor.id)"
    }

    private static func hostError(_ message: String) -> NSError {
        NSError(domain: "MPX68K.AudioUnitHost",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class MPX68KAudioEffectHost {
    private static let stateDefaultsPrefix = "MPX68K.AudioEffectState."
    private static let loadQueue = DispatchQueue(
        label: "MPX68K.AudioEffectHost.load",
        qos: .userInitiated
    )
    private static let maximumPendingMIDIEvents = 2048

    private struct EffectInstance {
        let slot: Int
        let descriptor: MPX68KAudioUnitDescriptor
        let unit: AVAudioUnit
    }

    private struct PendingMIDIEvent {
        let data: [UInt8]
        let hostTime: UInt64
    }

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var effects = [AVAudioUnit?](
        repeating: nil,
        count: MPX68KAudioEffectSettings.slotCount
    )
    private var descriptors = [MPX68KAudioUnitDescriptor?](
        repeating: nil,
        count: MPX68KAudioEffectSettings.slotCount
    )
    private var midiSchedulers = [AUScheduleMIDIEventBlock?](
        repeating: nil,
        count: MPX68KAudioEffectSettings.slotCount
    )
    private var legacyAudioUnits = [AudioUnit?](
        repeating: nil,
        count: MPX68KAudioEffectSettings.slotCount
    )
    private var pendingMIDIEvents: [PendingMIDIEvent] = []
    private let midiLock = NSLock()
    private var currentSettings = MPX68KAudioEffectSettings()
    private var loadGeneration: UInt = 0
    private var shouldRun = false
    private(set) var isRunning = false
    private(set) var isReady = false
    private(set) var sampleRate: Double = 48_000.0
    private var configuredDevice: AudioDeviceID?
    private var previousDeviceBufferFrames: UInt32?
    private var bufferFrames = 64
    private var isClosed = false

    deinit {
        close()
    }

    static func availableAudioEffects() -> [MPX68KAudioUnitDescriptor] {
        let manager = AVAudioUnitComponentManager.shared()
        let componentTypes: [UInt32] = [
            kAudioUnitType_Effect,
            kAudioUnitType_MusicEffect
        ]
        var descriptorsByID: [String: MPX68KAudioUnitDescriptor] = [:]

        for componentType in componentTypes {
            let description = AudioComponentDescription(
                componentType: componentType,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            for component in manager.components(matching: description) {
                let componentDescription = component.audioComponentDescription
                let manufacturer = component.manufacturerName.isEmpty
                    ? ""
                    : " (\(component.manufacturerName))"
                let descriptor = MPX68KAudioUnitDescriptor(
                    componentType: componentDescription.componentType,
                    componentSubType: componentDescription.componentSubType,
                    componentManufacturer: componentDescription.componentManufacturer,
                    componentFlags: componentDescription.componentFlags,
                    componentFlagsMask: componentDescription.componentFlagsMask,
                    name: "\(component.name)\(manufacturer)"
                )
                descriptorsByID[descriptor.id] = descriptor
            }
        }

        return descriptorsByID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func apply(
        _ settings: MPX68KAudioEffectSettings,
        preferredSampleRate: Double,
        bufferFrames: Int,
        completion: @escaping (String?) -> Void
    ) {
        guard !isClosed else {
            completion("Audio effect host is closed")
            return
        }

        let normalizedSettings = MPX68KAudioEffectSettings(
            componentIDs: settings.componentIDs
        )
        if isReady, normalizedSettings == currentSettings {
            completion(applyBufferFrames(bufferFrames))
            return
        }
        let availableEffects = Dictionary(
            uniqueKeysWithValues: Self.availableAudioEffects().map { ($0.id, $0) }
        )
        var requestedEffects: [(slot: Int, descriptor: MPX68KAudioUnitDescriptor)] = []
        for (slot, componentID) in normalizedSettings.componentIDs.enumerated() {
            guard let componentID else { continue }
            guard let descriptor = availableEffects[componentID] else {
                completion("Audio Unit effect is no longer available: \(componentID)")
                return
            }
            requestedEffects.append((slot: slot, descriptor: descriptor))
        }

        saveStates()
        loadGeneration &+= 1
        let generation = loadGeneration
        self.bufferFrames = bufferFrames

        Self.loadQueue.async { [weak self] in
            Self.loadEffects(
                requestedEffects,
                index: 0,
                loaded: []
            ) { [weak self] loaded, error in
                guard let self = self else {
                    completion(nil)
                    return
                }
                DispatchQueue.main.async {
                    self.finishApply(
                        loaded: loaded,
                        error: error,
                        settings: normalizedSettings,
                        preferredSampleRate: preferredSampleRate,
                        generation: generation,
                        completion: completion
                    )
                }
            }
        }
    }

    func applyBufferFrames(_ frames: Int) -> String? {
        bufferFrames = frames
        guard let device = Self.defaultOutputDevice() else {
            return "No default macOS audio output device is available"
        }
        if configuredDevice != device {
            if let configuredDevice,
               let previousDeviceBufferFrames = previousDeviceBufferFrames {
                _ = Self.setDeviceBufferSize(
                    previousDeviceBufferFrames,
                    device: configuredDevice
                )
            }
            configuredDevice = device
            previousDeviceBufferFrames = Self.deviceBufferSize(device)
        }
        let status = Self.setDeviceBufferSize(UInt32(frames), device: device)
        guard status == noErr else {
            return Self.statusMessage("Cannot set audio device buffer size", status: status)
        }
        sampleRate = Self.deviceSampleRate(device) ?? sampleRate
        X68000_AudioRenderSetHostRate(UInt32(sampleRate.rounded()))
        return nil
    }

    func play() -> String? {
        shouldRun = true
        guard isReady else { return nil }
        return startEngine()
    }

    func pause() {
        shouldRun = false
        stopEngine()
    }

    func stop() {
        shouldRun = false
        stopEngine()
    }

    func close() {
        guard !isClosed else { return }
        saveStates()
        isClosed = true
        shouldRun = false
        loadGeneration &+= 1
        sendPanicToCurrentEffects()
        stopEngine()
        detachGraph()
        restoreDeviceBuffer()
        pendingMIDIEvents.removeAll(keepingCapacity: false)
    }

    func saveStates() {
        guard !isClosed else { return }
        for slot in 0..<MPX68KAudioEffectSettings.slotCount {
            guard let unit = effects[slot],
                  let descriptor = descriptors[slot] else {
                continue
            }
            guard let state = unit.auAudioUnit.fullState else {
                warningLog(
                    "Audio Unit effect \(descriptor.name) does not provide a persistable state",
                    category: .audio
                )
                continue
            }

            do {
                let data = try PropertyListSerialization.data(
                    fromPropertyList: state,
                    format: .binary,
                    options: 0
                )
                UserDefaults.standard.set(
                    data,
                    forKey: Self.stateDefaultsKey(slot: slot, descriptor: descriptor)
                )
                debugLog(
                    "Saved Audio Unit effect state: slot \(slot + 1), \(descriptor.name)",
                    category: .audio
                )
            } catch {
                warningLog(
                    "Cannot serialize Audio Unit effect state for \(descriptor.name): "
                        + error.localizedDescription,
                    category: .audio
                )
            }
        }
    }

    func sendMIDI(_ event: [UInt8], hostTime: UInt64) {
        guard !event.isEmpty else { return }

        midiLock.lock()
        defer { midiLock.unlock() }
        let hasMIDIEffect = midiSchedulers.contains { $0 != nil }
            || legacyAudioUnits.contains { $0 != nil }
        guard hasMIDIEffect else { return }

        if !engine.isRunning || engine.outputNode.lastRenderTime == nil {
            if pendingMIDIEvents.count >= Self.maximumPendingMIDIEvents {
                pendingMIDIEvents.removeFirst()
            }
            pendingMIDIEvents.append(PendingMIDIEvent(data: event, hostTime: hostTime))
            return
        }

        sendMIDIImmediately(event, hostTime: hostTime)
        flushPendingMIDIImmediately()
    }

    func showEditor(
        slot: Int,
        completion: @escaping (Result<NSViewController, Error>) -> Void
    ) {
        guard slot >= 0,
              slot < MPX68KAudioEffectSettings.slotCount,
              let unit = effects[slot] else {
            completion(.failure(Self.hostError("No Audio Unit effect is loaded in this slot")))
            return
        }

        unit.auAudioUnit.requestViewController { viewController in
            DispatchQueue.main.async {
                guard let viewController else {
                    completion(.failure(Self.hostError(
                        "This Audio Unit effect does not provide a custom UI"
                    )))
                    return
                }
                completion(.success(viewController))
            }
        }
    }

    private func finishApply(
        loaded: [EffectInstance]?,
        error: Error?,
        settings: MPX68KAudioEffectSettings,
        preferredSampleRate: Double,
        generation: UInt,
        completion: @escaping (String?) -> Void
    ) {
        guard !isClosed, loadGeneration == generation else {
            completion(nil)
            return
        }
        if let error {
            errorLog(
                "Cannot load Audio Unit effect chain: \(error.localizedDescription)",
                category: .audio
            )
            completion("Cannot load Audio Unit effect: \(error.localizedDescription)")
            return
        }
        guard let loaded else {
            completion("Audio Unit effect returned no instances")
            return
        }

        if let error = install(
            loaded: loaded,
            settings: settings,
            preferredSampleRate: preferredSampleRate,
            bufferFrames: self.bufferFrames
        ) {
            completion(error)
            return
        }
        completion(nil)
    }

    private func install(
        loaded: [EffectInstance],
        settings: MPX68KAudioEffectSettings,
        preferredSampleRate: Double,
        bufferFrames: Int
    ) -> String? {
        guard let device = Self.defaultOutputDevice() else {
            return "No default macOS audio output device is available"
        }

        if configuredDevice != device {
            if let configuredDevice,
               let previousDeviceBufferFrames = previousDeviceBufferFrames {
                _ = Self.setDeviceBufferSize(
                    previousDeviceBufferFrames,
                    device: configuredDevice
                )
            }
            configuredDevice = device
            previousDeviceBufferFrames = Self.deviceBufferSize(device)
        }
        let bufferStatus = Self.setDeviceBufferSize(UInt32(bufferFrames), device: device)
        guard bufferStatus == noErr else {
            return Self.statusMessage("Cannot set audio device buffer size", status: bufferStatus)
        }

        let deviceRate = Self.deviceSampleRate(device) ?? preferredSampleRate
        guard deviceRate >= 8_000.0, deviceRate <= 192_000.0 else {
            return "The audio output device reported an invalid sample rate"
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: deviceRate,
            channels: 2,
            interleaved: true
        ) else {
            return "Cannot create the built-in effect audio format"
        }

        stopEngine()
        sendPanicToCurrentEffects()
        detachGraph()

        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            Self.renderBuiltInAudio(
                frameCount: frameCount,
                audioBufferList: audioBufferList
            )
        }
        engine.attach(source)

        var previousNode: AVAudioNode = source
        for instance in loaded.sorted(by: { $0.slot < $1.slot }) {
            engine.attach(instance.unit)
            engine.connect(previousNode, to: instance.unit, format: format)
            previousNode = instance.unit
        }
        engine.connect(previousNode, to: engine.mainMixerNode, format: format)

        self.sourceNode = source
        self.effects = [AVAudioUnit?](
            repeating: nil,
            count: MPX68KAudioEffectSettings.slotCount
        )
        self.descriptors = [MPX68KAudioUnitDescriptor?](
            repeating: nil,
            count: MPX68KAudioEffectSettings.slotCount
        )
        midiLock.lock()
        midiSchedulers = [AUScheduleMIDIEventBlock?](
            repeating: nil,
            count: MPX68KAudioEffectSettings.slotCount
        )
        legacyAudioUnits = [AudioUnit?](
            repeating: nil,
            count: MPX68KAudioEffectSettings.slotCount
        )
        midiLock.unlock()

        for instance in loaded {
            effects[instance.slot] = instance.unit
            descriptors[instance.slot] = instance.descriptor
            restoreSavedState(for: instance.slot,
                              descriptor: instance.descriptor,
                              in: instance.unit)
            bindMIDIIfNeeded(
                slot: instance.slot,
                descriptor: instance.descriptor,
                unit: instance.unit
            )
        }

        currentSettings = settings
        sampleRate = deviceRate
        self.bufferFrames = bufferFrames
        X68000_AudioRenderSetHostRate(UInt32(deviceRate.rounded()))
        isReady = true

        if shouldRun, let error = startEngine() {
            isReady = false
            detachGraph()
            return error
        }
        return nil
    }

    private func bindMIDIIfNeeded(
        slot: Int,
        descriptor: MPX68KAudioUnitDescriptor,
        unit: AVAudioUnit
    ) {
        guard descriptor.componentType == kAudioUnitType_MusicEffect else {
            return
        }

        var scheduler = unit.auAudioUnit.scheduleMIDIEventBlock
        var legacyAudioUnit: AudioUnit? = scheduler == nil ? unit.audioUnit : nil
        if scheduler == nil, legacyAudioUnit == nil {
            do {
                try unit.auAudioUnit.allocateRenderResources()
                scheduler = unit.auAudioUnit.scheduleMIDIEventBlock
                legacyAudioUnit = scheduler == nil ? unit.audioUnit : nil
            } catch {
                warningLog(
                    "Audio Unit MusicEffect resource allocation: \(error.localizedDescription)",
                    category: .audio
                )
            }
        }
        midiLock.lock()
        midiSchedulers[slot] = scheduler
        legacyAudioUnits[slot] = legacyAudioUnit
        midiLock.unlock()

        if scheduler == nil, legacyAudioUnit == nil {
            warningLog(
                "Audio Unit MusicEffect does not expose a MIDI input: \(descriptor.name)",
                category: .audio
            )
        }
    }

    private func restoreSavedState(
        for slot: Int,
        descriptor: MPX68KAudioUnitDescriptor,
        in unit: AVAudioUnit
    ) {
        guard let data = UserDefaults.standard.data(
            forKey: Self.stateDefaultsKey(slot: slot, descriptor: descriptor)
        ) else {
            return
        }

        do {
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard let state = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
            ) as? [String: Any] else {
                warningLog(
                    "Saved Audio Unit effect state has an invalid format: \(descriptor.name)",
                    category: .audio
                )
                return
            }

            unit.auAudioUnit.fullState = state
            guard unit.auAudioUnit.fullState != nil else {
                warningLog(
                    "Audio Unit rejected its saved effect state: \(descriptor.name)",
                    category: .audio
                )
                return
            }
            notifyParameterListeners(for: unit)
            debugLog(
                "Restored Audio Unit effect state: slot \(slot + 1), \(descriptor.name)",
                category: .audio
            )
        } catch {
            warningLog(
                "Cannot deserialize Audio Unit effect state for \(descriptor.name): "
                    + error.localizedDescription,
                category: .audio
            )
        }
    }

    private func notifyParameterListeners(for unit: AVAudioUnit) {
        let underlyingAudioUnit: AudioUnit? = unit.audioUnit
        guard let underlyingAudioUnit else { return }

        var changedUnit = AudioUnitParameter(
            mAudioUnit: underlyingAudioUnit,
            mParameterID: kAUParameterListener_AnyParameter,
            mScope: kAudioUnitScope_Global,
            mElement: 0
        )
        _ = AUParameterListenerNotify(nil, nil, &changedUnit)
    }

    private func startEngine() -> String? {
        guard isReady else { return nil }
        guard !engine.isRunning else {
            isRunning = true
            return nil
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            midiLock.lock()
            flushPendingMIDIImmediately()
            midiLock.unlock()
            return nil
        } catch {
            isRunning = false
            return "Cannot start Audio Unit effect engine: \(error.localizedDescription)"
        }
    }

    private func stopEngine() {
        if engine.isRunning {
            engine.stop()
        }
        isRunning = false
    }

    private func detachGraph() {
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
        }
        for effect in effects.compactMap({ $0 }) {
            engine.disconnectNodeInput(effect)
            engine.disconnectNodeOutput(effect)
            engine.detach(effect)
        }
        sourceNode = nil
        effects = [AVAudioUnit?](
            repeating: nil,
            count: MPX68KAudioEffectSettings.slotCount
        )
        descriptors = [MPX68KAudioUnitDescriptor?](
            repeating: nil,
            count: MPX68KAudioEffectSettings.slotCount
        )
        midiLock.lock()
        midiSchedulers = [AUScheduleMIDIEventBlock?](
            repeating: nil,
            count: MPX68KAudioEffectSettings.slotCount
        )
        legacyAudioUnits = [AudioUnit?](
            repeating: nil,
            count: MPX68KAudioEffectSettings.slotCount
        )
        midiLock.unlock()
        isReady = false
        isRunning = false
    }

    private func sendPanicToCurrentEffects() {
        midiLock.lock()
        defer { midiLock.unlock() }
        guard midiSchedulers.contains(where: { $0 != nil })
                || legacyAudioUnits.contains(where: { $0 != nil }) else {
            return
        }
        for channel in 0..<16 {
            let status = 0xB0 | UInt8(channel)
            sendMIDIImmediately([status, 123, 0], hostTime: 0)
            sendMIDIImmediately([status, 120, 0], hostTime: 0)
        }
        pendingMIDIEvents.removeAll(keepingCapacity: true)
    }

    private func sendMIDIImmediately(_ event: [UInt8], hostTime: UInt64) {
        for scheduler in midiSchedulers.compactMap({ $0 }) {
            scheduleMIDI(event, atHostTime: hostTime, using: scheduler)
        }
        for audioUnit in legacyAudioUnits.compactMap({ $0 }) {
            sendLegacyMIDI(event, atHostTime: hostTime, using: audioUnit)
        }
    }

    private func flushPendingMIDIImmediately() {
        guard !pendingMIDIEvents.isEmpty,
              engine.isRunning,
              engine.outputNode.lastRenderTime != nil else {
            return
        }
        let pending = pendingMIDIEvents
        pendingMIDIEvents.removeAll(keepingCapacity: true)
        for event in pending {
            sendMIDIImmediately(event.data, hostTime: event.hostTime)
        }
    }

    private func scheduleMIDI(
        _ event: [UInt8],
        atHostTime hostTime: UInt64,
        using scheduler: AUScheduleMIDIEventBlock
    ) {
        let eventSampleTime = sampleTime(forHostTime: hostTime)
        event.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            scheduler(eventSampleTime, 0, event.count, baseAddress)
        }
    }

    private func sendLegacyMIDI(
        _ event: [UInt8],
        atHostTime hostTime: UInt64,
        using audioUnit: AudioUnit
    ) {
        guard let status = event.first else { return }
        let data1 = event.count > 1 ? event[1] : 0
        let data2 = event.count > 2 ? event[2] : 0
        _ = MusicDeviceMIDIEvent(
            audioUnit,
            UInt32(status),
            UInt32(data1),
            UInt32(data2),
            sampleOffset(forHostTime: hostTime)
        )
    }

    private func sampleOffset(forHostTime hostTime: UInt64) -> UInt32 {
        guard let renderTime = engine.outputNode.lastRenderTime,
              renderTime.isHostTimeValid,
              renderTime.isSampleTimeValid,
              renderTime.sampleRate > 0.0 else {
            return 0
        }

        let hostClockFrequency = AudioGetHostClockFrequency()
        guard hostClockFrequency > 0.0 else { return 0 }
        let deltaTicks: Double
        if hostTime >= renderTime.hostTime {
            deltaTicks = Double(hostTime - renderTime.hostTime)
        } else {
            deltaTicks = -Double(renderTime.hostTime - hostTime)
        }
        let deltaFrames = deltaTicks / hostClockFrequency * renderTime.sampleRate
        guard deltaFrames > 0.0 else { return 0 }
        return UInt32(min(deltaFrames.rounded(), Double(UInt32.max)))
    }

    private func sampleTime(forHostTime hostTime: UInt64) -> AUEventSampleTime {
        guard let renderTime = engine.outputNode.lastRenderTime,
              renderTime.isHostTimeValid,
              renderTime.isSampleTimeValid,
              renderTime.sampleRate > 0.0 else {
            return AUEventSampleTimeImmediate
        }

        let hostClockFrequency = AudioGetHostClockFrequency()
        guard hostClockFrequency > 0.0 else {
            return AUEventSampleTimeImmediate
        }
        let deltaTicks: Double
        if hostTime >= renderTime.hostTime {
            deltaTicks = Double(hostTime - renderTime.hostTime)
        } else {
            deltaTicks = -Double(renderTime.hostTime - hostTime)
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

    private static func loadEffects(
        _ requested: [(slot: Int, descriptor: MPX68KAudioUnitDescriptor)],
        index: Int,
        loaded: [EffectInstance],
        completion: @escaping ([EffectInstance]?, Error?) -> Void
    ) {
        guard index < requested.count else {
            completion(loaded, nil)
            return
        }
        let request = requested[index]
        let description = AudioComponentDescription(
            componentType: request.descriptor.componentType,
            componentSubType: request.descriptor.componentSubType,
            componentManufacturer: request.descriptor.componentManufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        instantiateEffect(description: description) { unit, error in
            guard let unit else {
                completion(nil, error ?? Self.hostError(
                    "Audio Unit effect returned no instance: \(request.descriptor.name)"
                ))
                return
            }
            let next = loaded + [EffectInstance(
                slot: request.slot,
                descriptor: request.descriptor,
                unit: unit
            )]
            Self.loadEffects(
                requested,
                index: index + 1,
                loaded: next,
                completion: completion
            )
        }
    }

    private static func instantiateEffect(
        description: AudioComponentDescription,
        completion: @escaping (AVAudioUnit?, Error?) -> Void
    ) {
        AVAudioUnit.instantiate(
            with: description,
            options: .loadOutOfProcess
        ) { unit, error in
            if unit != nil {
                completion(unit, nil)
                return
            }
            AVAudioUnit.instantiate(with: description, options: []) { fallbackUnit, fallbackError in
                completion(fallbackUnit, fallbackError ?? error)
            }
        }
    }

    private static func renderBuiltInAudio(
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard !buffers.isEmpty else { return noErr }

        let requiredInterleavedBytes = Int(frameCount)
            * 2
            * MemoryLayout<Float>.size
        if buffers.count == 1,
           buffers[0].mNumberChannels >= 2,
           Int(buffers[0].mDataByteSize) >= requiredInterleavedBytes,
           let audioData = buffers[0].mData {
            let samples = audioData.assumingMemoryBound(to: Float.self)
            X68000_AudioRenderConsumeInterleavedFloat32(samples, frameCount)
            X68000_AudioRenderCaptureFloat32(samples, frameCount)
            return noErr
        }

        guard buffers.count >= 2,
              let leftData = buffers[0].mData,
              let rightData = buffers[1].mData else {
            for index in 0..<buffers.count {
                if let audioData = buffers[index].mData {
                    memset(audioData, 0, Int(buffers[index].mDataByteSize))
                }
            }
            return noErr
        }
        X68000_AudioRenderConsumeFloat32(
            leftData.assumingMemoryBound(to: Float.self),
            rightData.assumingMemoryBound(to: Float.self),
            frameCount
        )
        return noErr
    }

    private func restoreDeviceBuffer() {
        if let device = configuredDevice,
           let previousDeviceBufferFrames = previousDeviceBufferFrames {
            _ = Self.setDeviceBufferSize(previousDeviceBufferFrames, device: device)
        }
        configuredDevice = nil
        previousDeviceBufferFrames = nil
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        MPX68KDirectAudioUnitOutput.defaultOutputDevice()
    }

    private static func deviceSampleRate(_ device: AudioDeviceID) -> Double? {
        MPX68KDirectAudioUnitOutput.deviceSampleRate(device)
    }

    private static func deviceBufferSize(_ device: AudioDeviceID) -> UInt32? {
        MPX68KDirectAudioUnitOutput.deviceBufferSize(device)
    }

    private static func setDeviceBufferSize(
        _ frames: UInt32,
        device: AudioDeviceID
    ) -> OSStatus {
        MPX68KDirectAudioUnitOutput.setDeviceBufferSize(frames, device: device)
    }

    private static func stateDefaultsKey(
        slot: Int,
        descriptor: MPX68KAudioUnitDescriptor
    ) -> String {
        "\(stateDefaultsPrefix)slot\(slot).\(descriptor.id)"
    }

    private static func statusMessage(_ action: String, status: OSStatus) -> String {
        "\(action) (status \(status))"
    }

    private static func hostError(_ message: String) -> NSError {
        NSError(
            domain: "MPX68K.AudioEffectHost",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

#endif

#endif
