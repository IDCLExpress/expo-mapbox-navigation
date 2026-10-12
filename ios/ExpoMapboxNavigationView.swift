import ExpoModulesCore
import MapboxNavigationCore
import MapboxMaps
import MapboxNavigationUIKit
import MapboxDirections
import Combine
import AVFoundation


class ExpoMapboxNavigationView: ExpoView {
    private let onRouteProgressChanged = EventDispatcher()
    private let onCancelNavigation = EventDispatcher()
    private let onWaypointArrival = EventDispatcher()
    private let onFinalDestinationArrival = EventDispatcher()
    private let onRouteChanged = EventDispatcher()
    private let onUserOffRoute = EventDispatcher()
    private let onRoutesLoaded = EventDispatcher()
    private let onRouteFailedToLoad = EventDispatcher()

    let controller = ExpoMapboxNavigationViewController()

    required init(appContext: AppContext? = nil) {
        super.init(appContext: appContext)
        clipsToBounds = true
        addSubview(controller.view)

        controller.onRouteProgressChanged = onRouteProgressChanged
        controller.onCancelNavigation = onCancelNavigation
        controller.onWaypointArrival = onWaypointArrival
        controller.onFinalDestinationArrival = onFinalDestinationArrival
        controller.onRouteChanged = onRouteChanged
        controller.onUserOffRoute = onUserOffRoute
        controller.onRoutesLoaded = onRoutesLoaded
        controller.onRouteFailedToLoad = onRouteFailedToLoad
    }

    override func layoutSubviews() {
        controller.view.frame = bounds
    }
}


class ExpoMapboxNavigationViewController: UIViewController {
    static let navigationProvider: MapboxNavigationProvider = MapboxNavigationProvider(coreConfig: CoreConfig(routingConfig: RoutingConfig(fasterRouteDetectionConfig: Optional<FasterRouteDetectionConfig>.none),locationSource: .live ))
    // ── [SYNCFORGE-318] Navigation voice during a phone call ─────────────────
    //
    // Owner ruling 2026-10-12: build the most likely fix now and test it rather
    // than measure first, with the understanding that it may be wrong and is
    // revertible. This overrides step 1 of the approved design, which required
    // reproducing the defect on a device before writing code. Recorded as an
    // override, not as a measurement.
    //
    // WHAT CARRIES OVER FROM THE ANDROID FIX, AND WHAT CANNOT
    //
    // The Android fix (SYNCFORGE-317) injected an AudioFocusDelegate that
    // reports focus granted, because One UI blanket-refuses app audio focus for
    // the duration of a call. iOS HAS NO AUDIO FOCUS, so there is nothing to
    // bypass and that mechanism cannot be ported. Two things do carry:
    //
    //  1. THE MEASUREMENT. On Android the decisive finding was that during a
    //     call the headset is owned by the call profile (Bluetooth SCO), and
    //     audio sent to the media path is reported as routed but is not heard.
    //     The iOS equivalent of that profile is bluetoothHFP, and reaching it
    //     requires the .playAndRecord category plus .allowBluetooth. That is
    //     why this uses configuration B from the design rather than A: A
    //     (.playback) is less invasive but routes to the media profile, which
    //     is precisely what Android proved is inaudible mid-call.
    //
    //  2. SCOPE CONTAINMENT, which matters more. The Android fix attached its
    //     bypass to ONE player selected only while a call was active, leaving
    //     no-call behaviour byte-identical. iOS navigation voice WORKS today, so
    //     the same discipline applies here: with no call active this touches
    //     nothing at all. If it regresses ordinary navigation to fix the call
    //     case, that is a net loss even if the call case improves.
    //
    // CALL DETECTION - and the obvious signal is a trap.
    //
    // AVAudioSession.isOtherAudioPlaying is true for MUSIC as well as calls, so
    // using it would switch the microphone on via .playAndRecord whenever the
    // rider is playing anything. Instead this reads the current ROUTE: a
    // bluetoothHFP or builtInReceiver output means call-type audio owns the
    // path, because media never routes to the receiver and HFP is the call
    // profile. That is specific to the case we want and encodes the Android
    // finding directly.
    //
    // UNVERIFIED, plainly: nothing here has been measured on an iPhone. The log
    // lines exist so ONE device run either confirms this or names what is
    // actually happening. If it fails, set inCallAudioEnabled to false for an
    // exact revert to stock behaviour, and the captured log tells us whether to
    // move to configuration A.

    /// [SYNCFORGE-318] Single kill switch. false restores stock behaviour exactly.
    static let inCallAudioEnabled = true

    private static var inCallAudioStarted = false
    /// Tracks whether WE took the session over, so it is only ever handed back
    /// if we were the ones holding it.
    private static var weConfiguredSession = false

    /// Registers once for the app's lifetime. No removal: the observers are
    /// tied to a static and must outlive any individual view controller, since
    /// a call can start while navigation is already running.
    @MainActor
    static func startInCallAudioManagement() {
        guard inCallAudioEnabled, !inCallAudioStarted else { return }
        inCallAudioStarted = true

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in applyInCallAudioIfNeeded(reason: "routeChange") }
        }

        // With .mixWithOthers we may not be interrupted at all, but if we are,
        // failing to reactivate would leave guidance silent for the rest of the
        // drive even after the call ends - worse than the defect being fixed.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.ended.rawValue {
                Task { @MainActor in applyInCallAudioIfNeeded(reason: "interruptionEnded") }
            }
        }

        applyInCallAudioIfNeeded(reason: "start")
    }

    /// A call-type output owns the route. See the note above on why
    /// isOtherAudioPlaying is NOT used.
    private static func callLikelyActive(_ session: AVAudioSession) -> Bool {
        for output in session.currentRoute.outputs {
            if output.portType == .bluetoothHFP || output.portType == .builtInReceiver {
                return true
            }
        }
        return false
    }

    @MainActor
    static func applyInCallAudioIfNeeded(reason: String) {
        guard inCallAudioEnabled else { return }
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let active = callLikelyActive(session)

        // Logged unconditionally: one device run must be enough to confirm this
        // or to say what is really happening, which is what Android took three
        // builds to establish.
        NSLog("[SYNCFORGE-318] %@: outputs=[%@] callLikely=%@ category=%@ mode=%@",
              reason, outputs, active ? "YES" : "no",
              session.category.rawValue, session.mode.rawValue)

        let synthesizer = navigationProvider.routeVoiceController.speechSynthesizer

        if active {
            // Take the session over. While the SDK manages it, it chooses a
            // category and activates on its own terms, and the app cannot add
            // the option that decides whether audio coexists with a call.
            synthesizer.managesAudioSession = false
            do {
                try session.setCategory(
                    .playAndRecord,
                    mode: .voicePrompt,
                    options: [.mixWithOthers, .duckOthers, .allowBluetooth]
                )
                try session.setActive(true, options: [])
                weConfiguredSession = true
                NSLog("[SYNCFORGE-318] in-call audio configured (playAndRecord/voicePrompt/mix+duck+allowBluetooth)")
            } catch {
                // Hand the session back rather than leaving it orphaned with
                // nobody managing it - that would be worse than not trying.
                synthesizer.managesAudioSession = true
                weConfiguredSession = false
                NSLog("[SYNCFORGE-318] configure FAILED: %@ - handed session back to the SDK",
                      error.localizedDescription)
            }
        } else if weConfiguredSession {
            synthesizer.managesAudioSession = true
            weConfiguredSession = false
            NSLog("[SYNCFORGE-318] call-type route gone; session handed back to the SDK")
        }
        // No call and we never configured anything: deliberately does nothing.
        // This is the scope containment described above.
    }

    var mapboxNavigation: MapboxNavigation? = nil
    var routingProvider: RoutingProvider? = nil
    var navigation: NavigationController? = nil
    var tripSession: SessionController? = nil
    var navigationViewController: NavigationViewController? = nil
    
    var currentCoordinates: Array<CLLocationCoordinate2D>? = nil
    var initialLocation: CLLocationCoordinate2D? = nil
    var initialLocationZoom: Double? = nil
    var currentWaypointIndices: Array<Int>? = nil
    var currentLocale: Locale = Locale.current
    var currentRouteProfile: String? = nil
    var currentRouteExcludeList: Array<String>? = nil
    var currentMapStyle: String? = nil
    var currentCustomRasterSourceUrl: String? = nil
    var currentPlaceCustomRasterLayerAbove: String? = nil
    var currentDisableAlternativeRoutes: Bool? = nil
    var currentFollowingZoom: Double? = nil
    var isUsingRouteMatchingApi: Bool = false
    var vehicleMaxHeight: Double? = nil
    var vehicleMaxWidth: Double? = nil

    var onRouteProgressChanged: EventDispatcher? = nil
    var onCancelNavigation: EventDispatcher? = nil
    var onWaypointArrival: EventDispatcher? = nil
    var onFinalDestinationArrival: EventDispatcher? = nil
    var onRouteChanged: EventDispatcher? = nil
    var onUserOffRoute: EventDispatcher? = nil
    var onRoutesLoaded: EventDispatcher? = nil
    var onRouteFailedToLoad: EventDispatcher? = nil

    var calculateRoutesTask: Task<Void, Error>? = nil
    private var routeProgressCancellable: AnyCancellable? = nil
    private var waypointArrivalCancellable: AnyCancellable? = nil
    private var reroutingCancellable: AnyCancellable? = nil
    private var sessionCancellable: AnyCancellable? = nil

    init() {
        super.init(nibName: nil, bundle: nil)
        mapboxNavigation = ExpoMapboxNavigationViewController.navigationProvider.mapboxNavigation
        routingProvider = mapboxNavigation!.routingProvider()
        navigation = mapboxNavigation!.navigation()
        tripSession = mapboxNavigation!.tripSession()

        // [SYNCFORGE-318] Registers once; evaluates the route immediately so a
        // call already in progress when navigation starts is handled. The owner
        // established on Android that launch order must not matter: "whether I
        // make the call first or make the call after I start the app, it
        // shouldn't matter. The app should always give me directions."
        ExpoMapboxNavigationViewController.startInCallAudioManagement()

        routeProgressCancellable = navigation!.routeProgress.sink { progressState in
            if(progressState != nil){


                // For some reason the maneuver arrows sometimes (not consistently) show up the same color as the route line making them invisible.
                // This is a hack to always ensure the arrows are visible.
                try? self.navigationViewController?.navigationMapView?.mapView.mapboxMap.setLayerProperty(
                    for: "com.mapbox.navigation.arrow.next",
                    property: "line-color",
                    value: "#FFFFFF" 
                )
                try? self.navigationViewController?.navigationMapView?.mapView.mapboxMap.setLayerProperty(
                    for: "com.mapbox.navigation.arrow.next.stroke",
                    property: "line-color",
                    value: "#FFFFFF" 
                )
                try? self.navigationViewController?.navigationMapView?.mapView.mapboxMap.setLayerProperty(
                    for: "com.mapbox.navigation.arrow.next.symbol",
                    property: "icon-color",
                    value: "#FFFFFF" 
                )
                try? self.navigationViewController?.navigationMapView?.mapView.mapboxMap.setLayerProperty(
                    for: "com.mapbox.navigation.arrow.next.symbol.casing",
                    property: "icon-color",
                    value: "#FFFFFF" 
                )
                
               self.onRouteProgressChanged?([
                    "distanceRemaining": progressState!.routeProgress.distanceRemaining,
                    "distanceTraveled": progressState!.routeProgress.distanceTraveled,
                    "durationRemaining": progressState!.routeProgress.durationRemaining,
                    "fractionTraveled": progressState!.routeProgress.fractionTraveled,
                ])
            }
        }

        waypointArrivalCancellable = navigation!.waypointsArrival.sink { arrivalStatus in
            let event = arrivalStatus.event
            if event is WaypointArrivalStatus.Events.ToFinalDestination {
                self.onFinalDestinationArrival?()
            } else if event is WaypointArrivalStatus.Events.ToWaypoint {
                self.onWaypointArrival?()
            }
        }

        reroutingCancellable = navigation!.rerouting.sink { rerouteStatus in
            self.onRouteChanged?()            
        }

        sessionCancellable = tripSession!.session.sink { session in 
            let state = session.state
            switch state {
                case .activeGuidance(let activeGuidanceState):
                    switch(activeGuidanceState){
                        case .offRoute:
                            self.onUserOffRoute?()
                        default: break
                    }
                default: break
            }
        }

    }

    deinit {
        routeProgressCancellable?.cancel()
        waypointArrivalCancellable?.cancel()
        reroutingCancellable?.cancel()
        sessionCancellable?.cancel()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        Task { @MainActor in tripSession?.setToIdle() } // Stops navigation
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        fatalError("This controller should not be loaded through a story board")
    }

    func addCustomRasterLayer() {
        let navigationMapView = navigationViewController?.navigationMapView
        let sourceId = "raster-source"
        let layerId = "raster-layer"

        if(currentCustomRasterSourceUrl == nil){
            if let mapView = navigationMapView?.mapView.mapboxMap {
                if mapView.layerExists(withId: layerId) {
                    try? mapView.removeLayer(withId: layerId)
                }
                if mapView.sourceExists(withId: sourceId) {
                    try? mapView.removeSource(withId: sourceId)
                }
            }
            return
        }

        let sourceUrl = currentCustomRasterSourceUrl! 

        var rasterSource = RasterSource(id: sourceId)

        rasterSource.tiles = [sourceUrl]
        rasterSource.tileSize = 256

        let rasterLayer = RasterLayer(id: layerId, source: sourceId)


        if let mapView = navigationMapView?.mapView.mapboxMap {
            if mapView.layerExists(withId: layerId) {
                try? mapView.removeLayer(withId: layerId)
            }
            if mapView.sourceExists(withId: sourceId) {
                try? mapView.removeSource(withId: sourceId)
            }

            try? mapView.addSource(rasterSource)
            try? mapView.addLayer(rasterLayer, layerPosition: .above(currentPlaceCustomRasterLayerAbove ?? "water"))    
        }
    }


    func setCoordinates(coordinates: Array<CLLocationCoordinate2D>) {
        currentCoordinates = coordinates
        update()
    }

    func setVehicleMaxHeight(maxHeight: Double?) {
        vehicleMaxHeight = maxHeight
        update()
    }

    func setVehicleMaxWidth(maxWidth: Double?) {
        vehicleMaxWidth = maxWidth
        update()
    }

    func setLocale(locale: String?) {
        if(locale != nil){
            currentLocale = Locale(identifier: locale!)
        } else {
            currentLocale = Locale.current
        }
        update()
    }

    func setIsUsingRouteMatchingApi(useRouteMatchingApi: Bool?){
        isUsingRouteMatchingApi = useRouteMatchingApi ?? false
        update()
    }

    func setWaypointIndices(waypointIndices: Array<Int>?){
        currentWaypointIndices = waypointIndices
        update()
    }

    func setRouteProfile(profile: String?){
        currentRouteProfile = profile
        update()
    }

    func setRouteExcludeList(excludeList: Array<String>?){
        currentRouteExcludeList = excludeList
        update()
    }

    func setMapStyle(style: String?){
        currentMapStyle = style
        update()
    }

    func setCustomRasterSourceUrl(url: String?){
        currentCustomRasterSourceUrl = url
        update()
    }

    func setPlaceCustomRasterLayerAbove(layerId: String?){
        currentPlaceCustomRasterLayerAbove = layerId
        update()
    }

    func setDisableAlternativeRoutes(disableAlternativeRoutes: Bool?){
        currentDisableAlternativeRoutes = disableAlternativeRoutes
        update()
    }

    func recenterMap(){
        let navigationMapView = navigationViewController?.navigationMapView
        navigationMapView?.navigationCamera.update(cameraState: .following)
    }

    func setIsMuted(isMuted: Bool?){
        if(isMuted != nil){
            ExpoMapboxNavigationViewController.navigationProvider.routeVoiceController.speechSynthesizer.muted = isMuted!
        }
    }

    func setInitialLocation(location: CLLocationCoordinate2D, zoom: Double?){
        initialLocation = location
        initialLocationZoom = zoom
        let navigationMapView = navigationViewController?.navigationMapView
        if(initialLocation != nil && navigationMapView != nil){
            navigationMapView!.mapView.mapboxMap.setCamera(to: CameraOptions(center: initialLocation!, zoom: initialLocationZoom ?? 15))
        }
    }

    func setFollowingZoom(followingZoom: Double?){
        let navigationMapView = navigationViewController?.navigationMapView
        currentFollowingZoom = followingZoom
        if(navigationMapView != nil && followingZoom != nil){
            let newDataSource = MobileViewportDataSource(navigationMapView!.mapView)
            newDataSource.options.followingCameraOptions.zoomRange = followingZoom!...followingZoom!
            navigationMapView?.navigationCamera.viewportDataSource = newDataSource
        }
    }

    func update(){
        calculateRoutesTask?.cancel()

        if(currentCoordinates != nil){
            let waypoints = currentCoordinates!.enumerated().map {
                let index = $0
                let coordinate = $1
                var waypoint = Waypoint(coordinate: coordinate) 
                waypoint.separatesLegs = currentWaypointIndices == nil ? true : currentWaypointIndices!.contains(index)
                return waypoint
            }

            if(isUsingRouteMatchingApi){
                calculateMapMatchingRoutes(waypoints: waypoints)
            } else {
                calculateRoutes(waypoints: waypoints)
            }
        }
    }

    func calculateRoutes(waypoints: Array<Waypoint>){
        let routeOptions = NavigationRouteOptions(
            waypoints: waypoints, 
            profileIdentifier: currentRouteProfile != nil ? ProfileIdentifier(rawValue: currentRouteProfile!) : nil,
            queryItems: [
                URLQueryItem(name: "exclude", value: currentRouteExcludeList?.joined(separator: ",")),
                URLQueryItem(name: "max_height", value: String(format: "%.1f", vehicleMaxHeight ?? 0.0)),
                URLQueryItem(name: "max_width", value: String(format: "%.1f", vehicleMaxWidth ?? 0.0))
            ],
            locale: currentLocale, 
            distanceUnit: currentLocale.usesMetricSystem ? LengthFormatter.Unit.meter : LengthFormatter.Unit.mile
        )

        calculateRoutesTask = Task {
            switch await self.routingProvider!.calculateRoutes(options: routeOptions).result {
            case .failure(let error):
                onRouteFailedToLoad?([
                    "errorMessage": error.localizedDescription
                ])
                print(error.localizedDescription)
            case .success(let navigationRoutes):
                onRoutesCalculated(navigationRoutes: navigationRoutes)
            }
        }
    }

    func calculateMapMatchingRoutes(waypoints: Array<Waypoint>){
        let matchOptions = NavigationMatchOptions(
            waypoints: waypoints, 
            profileIdentifier: currentRouteProfile != nil ? ProfileIdentifier(rawValue: currentRouteProfile!) : nil,
            queryItems: [URLQueryItem(name: "exclude", value: currentRouteExcludeList?.joined(separator: ","))],
            distanceUnit: currentLocale.usesMetricSystem ? LengthFormatter.Unit.meter : LengthFormatter.Unit.mile
        )
        matchOptions.locale = currentLocale


        calculateRoutesTask = Task {
            switch await self.routingProvider!.calculateRoutes(options: matchOptions).result {
            case .failure(let error):
                onRouteFailedToLoad?([
                    "errorMessage": error.localizedDescription
                ])
                print(error.localizedDescription)
            case .success(let navigationRoutes):
                onRoutesCalculated(navigationRoutes: navigationRoutes)
            }
        }
    }

    @objc func cancelButtonClicked(_ sender: AnyObject?) {
        onCancelNavigation?()
    }

    func convertRoute(route: Route) -> Any {
        return [
            "distance": route.distance,
            "expectedTravelTime": route.expectedTravelTime,
            "legs": route.legs.map { leg in
                return [
                    "source": leg.source != nil ? [
                        "latitude": leg.source!.coordinate.latitude,
                        "longitude": leg.source!.coordinate.longitude
                    ] : nil,
                    "destination": leg.destination != nil ? [
                        "latitude": leg.destination!.coordinate.latitude,
                        "longitude": leg.destination!.coordinate.longitude
                    ] : nil,
                    "steps": leg.steps.map { step in
                        return [
                            "shape": step.shape != nil ? [
                                "coordinates": step.shape!.coordinates.map { coordinate in
                                    return [
                                        "latitude": coordinate.latitude,
                                        "longitude": coordinate.longitude,
                                    ]
                                }
                            ] : nil
                        ]
                    }
                ]
            }
        ]
    }

    func onRoutesCalculated(navigationRoutes: NavigationRoutes){
        onRoutesLoaded?([
            "routes": [
                "mainRoute": convertRoute(route: navigationRoutes.mainRoute.route),
                "alternativeRoutes": navigationRoutes.alternativeRoutes.map { convertRoute(route: $0.route) }
            ]
        ])

        let topBanner = TopBannerViewController()
        topBanner.instructionsBannerView.distanceFormatter.locale = currentLocale
        let bottomBanner = BottomBannerViewController()
        bottomBanner.distanceFormatter.locale = currentLocale
        bottomBanner.dateFormatter.locale = currentLocale

        let navigationOptions = NavigationOptions(
            mapboxNavigation: self.mapboxNavigation!,
            voiceController: ExpoMapboxNavigationViewController.navigationProvider.routeVoiceController,
            eventsManager: ExpoMapboxNavigationViewController.navigationProvider.eventsManager(),
            styles: [DayStyle()],
            topBanner: topBanner,
            bottomBanner: bottomBanner
        )

        let newNavigationControllerRequired = navigationViewController == nil

        if(newNavigationControllerRequired){
            navigationViewController = NavigationViewController(
                navigationRoutes: navigationRoutes,
                navigationOptions: navigationOptions
            )
        } else {
            navigationViewController!.prepareViewLoading(
                navigationRoutes: navigationRoutes,
                navigationOptions: navigationOptions
            )
        }
        
        let navigationViewController = navigationViewController!

        navigationViewController.showsContinuousAlternatives = currentDisableAlternativeRoutes != true
        navigationViewController.usesNightStyleWhileInTunnel = false
        navigationViewController.automaticallyAdjustsStyleForTimeOfDay = false

        let navigationMapView = navigationViewController.navigationMapView
        navigationMapView!.puckType = .puck2D(.navigationDefault)

        if(initialLocation != nil && newNavigationControllerRequired){
            navigationMapView!.mapView.mapboxMap.setCamera(to: CameraOptions(center: initialLocation!, zoom: initialLocationZoom ?? 15))
        }

        let style = currentMapStyle != nil ? StyleURI(rawValue: currentMapStyle!) : StyleURI.streets
        navigationMapView!.mapView.mapboxMap.loadStyle(style!, completion: { _ in
            navigationMapView!.localizeLabels(locale: self.currentLocale)
            do{
                try navigationMapView!.mapView.mapboxMap.localizeLabels(into: self.currentLocale)
            } catch {}
            self.addCustomRasterLayer()
        })
        

        let cancelButton = navigationViewController.navigationView.bottomBannerContainerView.findViews(subclassOf: CancelButton.self)[0]
        cancelButton.addTarget(self, action: #selector(cancelButtonClicked), for: .touchUpInside)

        navigationViewController.delegate = self
        addChild(navigationViewController)
        view.addSubview(navigationViewController.view)
        navigationViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            navigationViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
            navigationViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0),
            navigationViewController.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 0),
            navigationViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0),
        ])
        didMove(toParent: self)
        mapboxNavigation!.tripSession().startActiveGuidance(with: navigationRoutes, startLegIndex: 0)
    }
}
extension ExpoMapboxNavigationViewController: NavigationViewControllerDelegate {
    func navigationViewController(_ navigationViewController: NavigationViewController, didRerouteAlong route: Route) {
        onRoutesLoaded?([
            "routes": [
                "mainRoute": convertRoute(route: route),
                "alternativeRoutes": []
            ]
        ])
    }

    func navigationViewControllerDidDismiss(
        _ navigationViewController: NavigationViewController,
        byCanceling canceled: Bool
    ) { }
}

extension UIView {
    func findViews<T: UIView>(subclassOf: T.Type) -> [T] {
        return recursiveSubviews.compactMap { $0 as? T }
    }

    var recursiveSubviews: [UIView] {
        return subviews + subviews.flatMap { $0.recursiveSubviews }
    }
}
