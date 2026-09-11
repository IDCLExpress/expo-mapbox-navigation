package expo.modules.mapboxnavigation

import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import com.mapbox.geojson.Point
import com.mapbox.navigation.base.options.NavigationOptions
import com.mapbox.navigation.core.lifecycle.MapboxNavigationApp
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class ExpoMapboxNavigationModule : Module() {
  /**
   * [SYNCFORGE-242] Held only to keep the warmed TTS connection alive.
   * Never used to speak. Shut down in OnDestroy.
   */
  private var ttsWarmup: android.speech.tts.TextToSpeech? = null

  private val activity
    get() = requireNotNull(appContext.activityProvider?.currentActivity)

  @com.mapbox.navigation.base.ExperimentalPreviewMapboxNavigationAPI
  override fun definition() = ModuleDefinition {
    Name("ExpoMapboxNavigation")

    // [SYNCFORGE-242] Warm Android's text-to-speech engine at app launch.
    //
    // The engine connection is established asynchronously and took 1.079s on the test
    // device. The navigation view is built the instant the driver presses Navigate, so
    // if the app was opened moments earlier the first turn instruction is spoken into
    // an engine that is not ready and dies mid-phrase. Measured 2026-09-11 01:30:
    //   TextToSpeech: isSpeaking failed: TTS engine connection not fully set up
    //   ... requestAudioFocus -> abandonAudioFocus 880ms later
    // A warm session 90 seconds earlier held focus for 7.8 seconds.
    //
    // MODULE scope, not View scope: OnCreate here runs when the module loads at app
    // launch - minutes before Navigate. Inside View(...) it would fire when the view is
    // built, which is exactly the moment that is already too late.
    //
    // Nothing is ever spoken through this instance; it exists to open the connection.
    // Failures are swallowed deliberately - a warm-up that cannot run must never stop
    // the app from starting.
    OnCreate {
      try {
        // Application context, not the React context: this instance lives for the whole
        // process, and holding a context that can be torn down underneath it leaks and
        // can misbehave on some TTS implementations.
        val ctx = appContext.reactContext?.applicationContext
        if (ctx != null) {
          ttsWarmup = android.speech.tts.TextToSpeech(ctx) { status ->
            android.util.Log.i(
                    "SyncForge",
                    "[SF-242] TTS warm-up finished, status=" + status +
                            (if (status == android.speech.tts.TextToSpeech.SUCCESS) " (ready)" else " (unavailable)")
            )
          }
        }
      } catch (e: Exception) {
        android.util.Log.w("SyncForge", "[SF-242] TTS warm-up could not start", e)
      }
    }

    // A TextToSpeech holds a service connection for the life of the process if it is
    // never shut down.
    OnDestroy {
      try {
        ttsWarmup?.shutdown()
        ttsWarmup = null
      } catch (e: Exception) {
        android.util.Log.w("SyncForge", "[SF-242] TTS warm-up shutdown failed", e)
      }
    }

    OnActivityEntersForeground {
      (activity as LifecycleOwner).lifecycleScope.launch(Dispatchers.Main) {
        if (!MapboxNavigationApp.isSetup()) {
          MapboxNavigationApp.setup {
            NavigationOptions.Builder(activity.applicationContext).build()
          }
        }
        MapboxNavigationApp.attach(activity as LifecycleOwner)
      }
    }

    View(ExpoMapboxNavigationView::class) {
      Events(
              "onRouteProgressChanged",
              "onCancelNavigation",
              "onWaypointArrival",
              "onFinalDestinationArrival",
              "onRouteChanged",
              "onUserOffRoute",
              "onRoutesLoaded",
              "onRouteFailedToLoad"
      )

      Prop("coordinates") { view: ExpoMapboxNavigationView, coordinates: List<Map<String, Any>> ->
        val points = mutableListOf<Point>()
        for (coordinate in coordinates) {
          val longValue = coordinate.get("longitude")
          val latValue = coordinate.get("latitude")
          if (longValue is Double && latValue is Double) {
            points.add(Point.fromLngLat(longValue, latValue))
          }
        }
        view.setCoordinates(points)
      }

      Prop("vehicleMaxHeight") { view: ExpoMapboxNavigationView, maxHeight: Double? ->
        view.setVehicleMaxHeight(maxHeight)
      }

      Prop("vehicleMaxWidth") { view: ExpoMapboxNavigationView, maxWidth: Double? ->
        view.setVehicleMaxWidth(maxWidth)
      }

      Prop("waypointIndices") { view: ExpoMapboxNavigationView, indices: List<Int>? ->
        view.setWaypointIndices(indices)
      }

      Prop("locale") { view: ExpoMapboxNavigationView, localeStr: String? ->
        view.setLocale(localeStr)
      }

      Prop("useRouteMatchingApi") { view: ExpoMapboxNavigationView, useRouteMatchingApi: Boolean? ->
        view.setIsUsingRouteMatchingApi(useRouteMatchingApi)
      }

      Prop("routeProfile") { view: ExpoMapboxNavigationView, profile: String? ->
        view.setRouteProfile(profile)
      }

      Prop("routeExcludeList") { view: ExpoMapboxNavigationView, excludeList: List<String>? ->
        view.setRouteExcludeList(excludeList)
      }

      Prop("mapStyle") { view: ExpoMapboxNavigationView, style: String? -> view.setMapStyle(style) }

      Prop("mute") { view: ExpoMapboxNavigationView, isMuted: Boolean? -> view.setIsMuted(isMuted) }

      Prop("initialLocation") { view: ExpoMapboxNavigationView, initialLocation: Map<String, Any>?
        ->
        val longValue = initialLocation?.get("longitude")
        val latValue = initialLocation?.get("latitude")
        val zoomValue = initialLocation?.get("zoom")

        if (longValue is Double && latValue is Double && zoomValue is Double?) {
          view.setInitialLocation(Point.fromLngLat(longValue, latValue), zoomValue)
        }
      }

      Prop("customRasterSourceUrl") { view: ExpoMapboxNavigationView, url: String? ->
        view.setCustomRasterSourceUrl(url)
      }

      Prop("placeCustomRasterLayerAbove") { view: ExpoMapboxNavigationView, layerId: String? ->
        view.setPlaceCustomRasterLayerAbove(layerId)
      }

      Prop("disableAlternativeRoutes") {
              view: ExpoMapboxNavigationView,
              disableAlternativeRoutes: Boolean? ->
        view.setDisableAlternativeRoutes(disableAlternativeRoutes)
      }

      Prop("followingZoom") { view: ExpoMapboxNavigationView, followingZoom: Double? ->
        view.setFollowingZoom(followingZoom)
      }

      AsyncFunction("recenterMap") { view: ExpoMapboxNavigationView -> view.recenterMap() }
    }
  }
}
