import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String
    var description: String { "\(context) failed (OSStatus \(status))" }
}

@inline(__always)
func check(_ status: OSStatus, _ context: String) throws {
    if status != noErr { throw CoreAudioError(status: status, context: context) }
}

func propertyAddress(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

extension AudioObjectID {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func readValue<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, initial: T,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = propertyAddress(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    func readString(_ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>? = nil
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard status == noErr, let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    func readObjectList(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = propertyAddress(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &list) == noErr else { return [] }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    // MARK: Convenience

    static var defaultOutputDevice: AudioDeviceID? {
        let id = AudioObjectID.systemObject.readValue(kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))
        return (id == nil || id == 0) ? nil : id
    }

    var deviceUID: String? { readString(kAudioDevicePropertyDeviceUID) }
    var objectName: String? { readString(kAudioObjectPropertyName) }

    var processPID: pid_t? { readValue(kAudioProcessPropertyPID, initial: pid_t(-1)) }
    var processBundleID: String? { readString(kAudioProcessPropertyBundleID) }
    var processIsRunningOutput: Bool { (readValue(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0 }
}

/// Wraps a property listener block so it can be removed later.
final class PropertyListener {
    let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private let queue: DispatchQueue

    init?(objectID: AudioObjectID, selector: AudioObjectPropertySelector,
          queue: DispatchQueue = .main, handler: @escaping () -> Void) {
        self.objectID = objectID
        self.address = propertyAddress(selector)
        self.queue = queue
        self.block = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block) != noErr { return nil }
    }

    func remove() {
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }
}
