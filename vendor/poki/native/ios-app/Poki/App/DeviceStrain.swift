import Foundation
import Observation

/// What the phone asks of the app to spare it: Low Power Mode, and heat. The home page's suggestion
/// rows, its light and the three-dimensional bear all read it here, so they rest together and go on
/// together when the phone is back to normal: the rows and the light stand still, and the bear is
/// its flat picture.
///
/// `-pokiStrain lowPower`, `-pokiStrain hot` or both hold a state on, to see it in the simulator,
/// which never has Low Power Mode and never runs hot. Debug builds only.
@MainActor @Observable
final class DeviceStrain {
    static let shared = DeviceStrain()

    /// Low Power Mode is on.
    var lowPower: Bool
    /// The phone runs hot: its thermal state is serious or critical, when the system itself starts to
    /// slow the phone down.
    var hot: Bool
    /// Either of the two: what moves by itself on the home page rests.
    var resting: Bool { lowPower || hot }

    @ObservationIgnored private let forced: Set<String>
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        #if DEBUG
        forced = Set((UserDefaults.standard.string(forKey: "pokiStrain") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        #else
        forced = []
        #endif
        lowPower = false
        hot = false
        read()
        // Posted on whichever thread changed the state; read on the main one.
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        })
    }

    private func read() {
        let lowPower = forced.contains("lowPower") || ProcessInfo.processInfo.isLowPowerModeEnabled
        if lowPower != self.lowPower { self.lowPower = lowPower }
        let hot = forced.contains("hot") || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if hot != self.hot { self.hot = hot }
    }
}
