import AVFoundation
import CoreAudio
import Foundation

/// The microphone a new recording would capture from: macOS's default input.
///
/// A room recording only works with the Mac's own microphone. A Bluetooth headset that
/// woke up in a bag and grabbed the default input records silence for the whole meeting,
/// and nothing about the recording itself looks wrong. Showing the device in the menu and
/// warning when a room recording starts on something else catches that before it costs
/// a meeting.
struct MicrophoneDevice: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case builtIn
        case bluetooth
        case other
    }

    let name: String
    let kind: Kind

    var isBuiltIn: Bool { kind == .builtIn }

    /// The line shown at the top of the menu.
    var menuLabel: String {
        switch kind {
        case .builtIn: "マイク：\(name)"
        case .bluetooth: "マイク：\(name)（Bluetooth）"
        case .other: "マイク：\(name)（外部）"
        }
    }

    static func current() -> MicrophoneDevice? {
        guard let device = AVCaptureDevice.default(for: .audio) else { return nil }
        return MicrophoneDevice(name: device.localizedName, kind: kind(ofTransport: device.transportType))
    }

    static func kind(ofTransport transport: Int32) -> Kind {
        switch UInt32(bitPattern: transport) {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        default: .other
        }
    }
}

/// Calls back whenever the default input device may have changed: a headset connecting
/// or disconnecting, or the user picking another input in System Settings.
final class MicrophoneDeviceWatcher: @unchecked Sendable {
    private let onChange: @MainActor @Sendable () -> Void
    private var observers: [NSObjectProtocol] = []
    private var listener: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
    }

    func start() {
        let notify: @Sendable () -> Void = { [onChange] in
            Task { @MainActor in onChange() }
        }
        let block: AudioObjectPropertyListenerBlock = { _, _ in notify() }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in notify() })
        }
    }

    deinit {
        if let listener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
