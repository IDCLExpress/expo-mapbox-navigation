# Fork of @youssefhenna/expo-mapbox-navigation

Forked from **1.5.7** — the exact version pinned in SyncForge (SYNCFORGE-168 §10:
each pin cost a failed build; do not bump casually).

## Why this fork exists

`ExpoMapboxNavigationView.update()` destroyed and rebuilt `MapboxVoiceInstructionsPlayer`
and `MapboxSpeechApi` on EVERY prop change, and twelve prop setters call it. Any prop
changing during navigation tore down the component that was mid-sentence, and the
`requestRoutes()` at the end of `update()` finished the running session.

Measured on device 2026-09-10 22:47 (build 1417099):

    22:47:27.714  routes update - finished
    22:47:27.729  abandonAudioFocus()
    22:47:27.731  routes update - starting        <- second time
    22:47:27.735  setRoutes finish the previous navigation session
    22:47:27.825  requestAudioFocus()
    22:47:27.970  abandonAudioFocus()             <- 145ms later

One defect, four symptoms: voice cut off mid-instruction, sometimes silent entirely,
navigation ending seconds after starting, and the weather band unmounting with it.

Fixing it means MODIFYING existing SDK behaviour. String-anchored patching had already
cost this project twice (SYNCFORGE-233: patches silently discarded before compilation;
SF-204: code inserted 60 lines before the variables it used, which only a compiler could
catch). So the change belongs in source, where it is compiled and reviewed.

## Rules

- Changes go through Pipeline Pro Protocols 1, 2 and 3, like any other code.
- Upstream updates are manual. That is the accepted trade.
- Do not bump the Mapbox SDK versions without a full device test.
