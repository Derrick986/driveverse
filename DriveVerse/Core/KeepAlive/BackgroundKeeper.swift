import Foundation

#if os(iOS)
import CoreLocation
import os

enum KeepAliveError: Error {
    case locationDenied
}

/// Keeps DriveVerse actively executing while Drive Mode is enabled.
///
/// We use Core Location because Drive Mode genuinely needs timely background
/// execution for its Live Activity. Location values themselves are discarded.
final class BackgroundKeeper: NSObject, CLLocationManagerDelegate {

    private static let log = Logger(
        subsystem: "com.derrick986.driveverse2",
        category: "keepalive"
    )

    private let manager = CLLocationManager()

    /// Explicit iOS background activity session.
    /// Keeping a strong reference is important — invalidating or releasing it
    /// ends the background activity session.
    private var backgroundSession: CLBackgroundActivitySession?

    private var wantsRunning = false
    private(set) var isRunning = false

    /// Surfaced on the Home screen when a permission problem blocks Drive Mode.
    var onIssue: ((String) -> Void)?

    override init() {
        super.init()

        manager.delegate = self

        // We don't need GPS-level precision, but 3 km + 1000 m filtering was
        // too aggressive and could leave the process without timely location
        // activity for many seconds while driving.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters

        // At driving speed this produces much more regular Core Location
        // activity without requesting every tiny GPS movement.
        manager.distanceFilter = 25

        // Drive Mode must not allow Core Location to automatically pause.
        manager.pausesLocationUpdatesAutomatically = false

        // Tell Core Location that this session represents vehicle travel.
        manager.activityType = .automotiveNavigation
    }

    func start() throws {
        guard !isRunning else {
            return
        }

        wantsRunning = true

        switch manager.authorizationStatus {

        case .notDetermined:
            manager.requestWhenInUseAuthorization()

        case .denied, .restricted:
            wantsRunning = false
            throw KeepAliveError.locationDenied

        case .authorizedWhenInUse,
             .authorizedAlways:

            activate()

        @unknown default:
            activate()
        }
    }

    func stop() {
        wantsRunning = false

        guard isRunning || backgroundSession != nil else {
            return
        }

        Self.log.info("Stopping Drive Mode background session")

        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false

        backgroundSession?.invalidate()
        backgroundSession = nil

        isRunning = false
    }

    private func activate() {
        guard wantsRunning, !isRunning else {
            return
        }

        Self.log.info("Starting Drive Mode background session")

        // Explicitly tell iOS that DriveVerse needs timely Core Location
        // activity while backgrounded.
        if backgroundSession == nil {
            backgroundSession = CLBackgroundActivitySession()
        }

        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation

        manager.startUpdatingLocation()

        isRunning = true

        // Always authorization makes CarPlay-triggered Drive Mode more
        // reliable when the app starts from the background.
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        guard wantsRunning else {
            return
        }

        switch manager.authorizationStatus {

        case .authorizedWhenInUse,
             .authorizedAlways:

            activate()

        case .denied,
             .restricted:

            wantsRunning = false

            backgroundSession?.invalidate()
            backgroundSession = nil

            isRunning = false

            onIssue?(
                """
                Drive Mode needs location access to keep lyrics updating \
                while the phone is locked. Allow location access for \
                DriveVerse in Settings → Privacy & Security → \
                Location Services.
                """
            )

        default:
            break
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        Self.log.warning(
            "Location error: \(error.localizedDescription, privacy: .public)"
        )
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        // Intentionally discard location information.
        //
        // Receiving these callbacks keeps the background location session
        // active. DriveVerse does not store or use the user's position.
    }

    deinit {
        manager.stopUpdatingLocation()
        backgroundSession?.invalidate()
    }
}
#endif