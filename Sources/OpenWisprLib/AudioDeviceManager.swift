import CoreAudio
import Foundation

struct AudioInputDevice {
    let id: AudioDeviceID
    let uid: String?
    let name: String
    let isDefault: Bool
}

class AudioDeviceManager {
    static func listInputDevices() -> [AudioInputDevice] {
        let defaultID = getDefaultInputDeviceID()

        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &propertySize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &propertySize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            guard hasInputStreams(deviceID: deviceID),
                  !isVirtualDevice(deviceID: deviceID),
                  let name = getDeviceName(deviceID: deviceID) else { continue }
            result.append(AudioInputDevice(
                id: deviceID,
                uid: getDeviceUID(deviceID: deviceID),
                name: name,
                isDefault: deviceID == defaultID
            ))
        }
        return result
    }

    static func getDefaultInputDeviceID() -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )
        return deviceID
    }

    /// Resolve the configured input device to a current AudioDeviceID.
    /// A stored UID wins over the numeric ID, because AudioDeviceIDs are not
    /// stable across reboots or device replugs while UIDs are. If a UID is
    /// set but no longer present, returns nil (system default) rather than
    /// trusting the possibly-reassigned numeric ID.
    static func resolveConfiguredDeviceID(uid: String?, legacyID: AudioDeviceID?) -> AudioDeviceID? {
        guard let uid = uid else { return legacyID }
        return listInputDevices().first(where: { $0.uid == uid })?.id
    }

    private static var deviceChangeHandler: (() -> Void)?
    private static var deviceChangeDebounce: DispatchWorkItem?
    private static var deviceChangeListener: AudioObjectPropertyListenerBlock?

    /// Invoke `onChange` (on the main queue) whenever the set of audio
    /// devices or the default input device changes. Bursts of change events
    /// (a Bluetooth headset connecting fires several) are coalesced.
    static func startDeviceChangeMonitoring(onChange: @escaping () -> Void) {
        guard deviceChangeListener == nil else {
            deviceChangeHandler = onChange
            return
        }
        deviceChangeHandler = onChange

        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            deviceChangeDebounce?.cancel()
            let work = DispatchWorkItem { deviceChangeHandler?() }
            deviceChangeDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        deviceChangeListener = listener

        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener
            )
        }
    }

    static func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let cfUID = uid?.takeRetainedValue() else { return nil }
        return cfUID as String
    }

    private static func isVirtualDevice(deviceID: AudioDeviceID) -> Bool {
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        guard status == noErr else { return false }
        return transportType == kAudioDeviceTransportTypeAggregate
            || transportType == kAudioDeviceTransportTypeVirtual
    }

    private static func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    private static func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let cfName = name?.takeRetainedValue() else { return nil }
        return cfName as String
    }
}
