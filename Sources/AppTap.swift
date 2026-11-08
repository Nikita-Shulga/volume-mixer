import CoreAudio
import Foundation

/// Controls the volume of one app (a group of Core Audio process objects).
///
/// How it works:
/// * A process tap with `muteBehavior = .muted` silences the app's direct path to the speakers.
/// * When the app is muted, that is all we need: no audio thread runs at all.
/// * When the app is at a reduced volume (and actually playing), a private aggregate device
///   reads the tap, multiplies by the gain and writes it to the current output device.
/// * When the app goes idle, the IO proc is stopped, so nothing runs in the background.
final class AppTap {
    let processObjects: [AudioObjectID]
    private let tapID: AudioObjectID
    private let tapUID: String

    private var aggregateID: AudioObjectID = 0
    private var aggregateDeviceUID: String?
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var isRunning = false

    /// [0] = target gain (written by UI), [1] = current gain (owned by IO thread),
    /// [2]/[3] = peak input/output level of the last buffer (diagnostics).
    private let gainState: UnsafeMutablePointer<Float>

    init(processObjects: [AudioObjectID], name: String) throws {
        self.processObjects = processObjects
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.name = "Volume Mixer – \(name)"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .muted
        var newTap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &newTap), "AudioHardwareCreateProcessTap")
        tapID = newTap
        tapUID = description.uuid.uuidString
        gainState = .allocate(capacity: 4)
        gainState.initialize(repeating: 1, count: 2)
        (gainState + 2).initialize(repeating: 0, count: 2)
    }

    var gain: Float {
        get { gainState[0] }
        set { gainState[0] = max(0, min(1, newValue)) }
    }

    var debugPeaks: (input: Float, output: Float) { (gainState[2], gainState[3]) }

    /// Start routing the tapped audio (with gain) to `outputDeviceUID`.
    func start(outputDeviceUID: String) throws {
        if aggregateID != 0, aggregateDeviceUID != outputDeviceUID {
            destroyAggregate()
        }
        if aggregateID == 0 {
            try createAggregate(outputDeviceUID: outputDeviceUID)
        }
        guard !isRunning, let ioProcID else { return }
        gainState[1] = gainState[0]
        try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
        isRunning = true
    }

    /// Stop the audio thread (keeps the aggregate device around for a quick restart).
    func stop() {
        guard isRunning, let ioProcID else { return }
        AudioDeviceStop(aggregateID, ioProcID)
        isRunning = false
    }

    func destroyAggregate() {
        stop()
        if let ioProcID, aggregateID != 0 {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        aggregateID = 0
        aggregateDeviceUID = nil
    }

    func invalidate() {
        destroyAggregate()
        AudioHardwareDestroyProcessTap(tapID)
    }

    deinit {
        gainState.deallocate()
    }

    // MARK: - Private

    private func createAggregate(outputDeviceUID: String) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Volume Mixer Output",
            kAudioAggregateDeviceUIDKey: "VolumeMixer-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]
            ],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregate),
                  "AudioHardwareCreateAggregateDevice")
        aggregateID = newAggregate
        aggregateDeviceUID = outputDeviceUID

        let state = gainState
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, newAggregate, nil) { _, inInput, _, outOutput, _ in
            AppTap.render(input: inInput, output: outOutput, state: state)
        }
        if status != noErr {
            AudioHardwareDestroyAggregateDevice(newAggregate)
            aggregateID = 0
            aggregateDeviceUID = nil
            throw CoreAudioError(status: status, context: "AudioDeviceCreateIOProcIDWithBlock")
        }
        ioProcID = procID
    }

    /// Real-time audio callback. No allocations, no locks.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               state: UnsafeMutablePointer<Float>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        // The tap's stereo stream is appended after any input streams of the output device,
        // so take the last buffer(s) of the input list.
        var leftPtr: UnsafePointer<Float>? = nil, leftStride = 1
        var rightPtr: UnsafePointer<Float>? = nil, rightStride = 1
        var inFrames = Int.max
        let inCount = inList.count
        if inCount > 0 {
            let last = inList[inCount - 1]
            let channels = Int(last.mNumberChannels)
            if let data = last.mData, channels > 0 {
                let p = UnsafePointer(data.assumingMemoryBound(to: Float.self))
                inFrames = Int(last.mDataByteSize) / (4 * channels)
                if channels >= 2 {
                    leftPtr = p; rightPtr = p + 1; leftStride = channels; rightStride = channels
                } else {
                    rightPtr = p; rightStride = 1
                    if inCount > 1, let prevData = inList[inCount - 2].mData, inList[inCount - 2].mNumberChannels == 1 {
                        leftPtr = UnsafePointer(prevData.assumingMemoryBound(to: Float.self))
                        inFrames = min(inFrames, Int(inList[inCount - 2].mDataByteSize) / 4)
                    } else {
                        leftPtr = p
                    }
                }
            }
        }

        let target = state[0]
        let start = state[1]

        var totalOutChannels = 0
        for buffer in outList { totalOutChannels += Int(buffer.mNumberChannels) }

        var peakIn: Float = 0, peakOut: Float = 0
        var channelBase = 0
        for buffer in outList {
            let channels = Int(buffer.mNumberChannels)
            guard let data = buffer.mData, channels > 0 else { channelBase += channels; continue }
            let out = data.assumingMemoryBound(to: Float.self)
            let outFrames = Int(buffer.mDataByteSize) / (4 * channels)
            guard let l = leftPtr, let r = rightPtr, inFrames != Int.max else {
                memset(data, 0, Int(buffer.mDataByteSize))
                channelBase += channels
                continue
            }
            let frames = min(outFrames, inFrames)
            let step = frames > 0 ? (target - start) / Float(frames) : 0
            for ch in 0..<channels {
                let global = channelBase + ch
                for i in 0..<outFrames {
                    var sample: Float = 0
                    if i < frames {
                        let g = start + step * Float(i)
                        if totalOutChannels == 1 {
                            sample = 0.5 * (l[i * leftStride] + r[i * rightStride]) * g
                        } else if global == 0 {
                            sample = l[i * leftStride] * g
                        } else if global == 1 {
                            sample = r[i * rightStride] * g
                        }
                    }
                    out[i * channels + ch] = sample
                    if global == 0 {
                        peakOut = max(peakOut, abs(sample))
                        if i < frames { peakIn = max(peakIn, abs(l[i * leftStride])) }
                    }
                }
            }
            channelBase += channels
        }
        state[1] = target
        state[2] = peakIn
        state[3] = peakOut
    }
}
