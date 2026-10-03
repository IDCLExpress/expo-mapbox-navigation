# SYNCFORGE-318 — iOS: navigation voice must be audible during a phone call

Protocol 1 (Design). Repo: `expo-mapbox-navigation` (fork), branch `syncforge-317` @ `ad490a7`
File under design: `ios/ExpoMapboxNavigationView.swift` (509 lines)
Status: design only. No code written.

Companion to SYNCFORGE-317, which fixed this on Android in three parts and is
confirmed working on device (build 1448711, live on the "SafeRoute Test" closed
track). **This is a fresh design, not a port** — the mechanism that broke Android
does not exist on iOS, and the lever that fixed it does not either.

---

## 1. Requirement

Same as 317, restated for iOS. Owner's words, on the rider fleet:

> "most of these people are going to be motorcycle riders... wearing their actual
> earpieces, Bluetooth earpieces... This GPS should have to play anywhere that the
> listener is listening in, whether it's Bluetooth, speaker, or regular phone."

**AC1.** A navigation voice instruction must be audible on whichever output the
user is listening through at the moment it is due.

**AC2.** AC1 holds while a telephony call is in progress, regardless of whether
navigation started before or during the call.

**AC3.** AC2 holds when the headset's audio link is owned by the call.

**AC4.** Rider audibility outranks the remote party not overhearing. Owner ruling
2026-10-01: "Speak anyway." Measure and document, do not block.

**AC5.** The rider fleet is mixed and uncontrolled — Sena, Cardo, generic earbuds.
No device allow/block lists, no per-rider toggle.

---

## 2. STATE THIS FIRST: the iOS defect is UNMEASURED

On Android every claim in 317 rested on a device log. **For iOS there is none.**

What is actually known:
- The owner asked, before any of this work, whether the problem was fixed "on both
  mediums, iOS and Android." That expresses an expectation, not a measurement.
- No iOS build has been tested for this defect. No iOS device log exists.
- The Android cause — Samsung's `requestAudioFocus failed while call`, a blanket
  OEM refusal of app audio focus during a call — **has no iOS analogue.** iOS has
  no audio-focus system at all. It uses `AVAudioSession` categories, options and
  interruptions. So the Android diagnosis transfers nothing.

Therefore §6 verification step 1 is to **confirm the defect and capture its
failure mode before any code is written**, and this document's design is
provisional on that. Parts 1 and 2 of SYNCFORGE-317 each shipped a build that
changed the wrong thing because the mechanism had not been measured; that cost two
builds and two owner test cycles. Not repeating it.

A measurement hook exists on iOS that Android lacked — see §3, `SpeechFailureAction`.

---

## 3. Measured API surface

From `MapboxNavigationCore.xcframework/ios-arm64/.../arm64-apple-ios.swiftinterface`
(2,535 lines) — the shipped interface, not documentation.

```swift
@MainActor public protocol SpeechSynthesizing : AnyObject, Sendable {
  var voiceInstructions: AnyPublisher<any VoiceInstructionEvent, Never> { get }
  var muted: Bool { get set }
  var volume: VolumeMode { get set }
  var isSpeaking: Bool { get }
  var locale: Locale? { get set }
  var managesAudioSession: Bool { get set }          // <- the lever
  func prepareIncomingSpokenInstructions(_:locale:)
  func speak(_:during:locale:)
  func stopSpeaking()
  func interruptSpeaking()
}
```

`managesAudioSession` is a settable `Bool` on the protocol and on both concrete
synthesizers (`MapboxSpeechSynthesizer` line 2336, `MultiplexedSpeechSynthesizer`
line 2363). When true — the default — the SDK configures and activates
`AVAudioSession` itself. Setting it false hands that responsibility to the app.

```swift
public enum SpeechFailureAction : String, Sendable { case mix, duck, unduck, play }
```

The SDK names the audio-session operation that failed. This is the diagnostic hook
(§6 step 1): if the defect is the SDK failing to mix or duck during a call, the
error identifies which, which is more than the Android side ever volunteered.

```swift
@available(*, deprecated, message: "This extension is no longer supported.")
extension AVAudioSession {
  public func tryDuckAudio() -> (any Error)?
  public func tryUnduckAudio() -> (any Error)?
}
```

**Deprecated and unsupported.** The old ducking helpers are not the route; session
configuration is now either the SDK's internal business or the app's, decided by
`managesAudioSession`.

```swift
@MainActor final public class RouteVoiceController {
  final public var speechSynthesizer: any SpeechSynthesizing { get }     // GET ONLY
  final public var playsRerouteSound: Bool
  public init(routeProgressing:…, rerouteStarted:…, fasterRouteSet:…,
              speechSynthesizer: any SpeechSynthesizing)
}
public enum VolumeMode : Equatable, Sendable { case system, case override(Float) }
```

`speechSynthesizer` cannot be replaced on an existing controller, but the
controller has a public initialiser that accepts one. Relevant only if §4 needs a
different synthesizer; it does not.

### What the wrapper does today

`ios/ExpoMapboxNavigationView.swift` is 509 lines and contains **no
`AVAudioSession` code at all**. Its only audio line is:

```swift
ExpoMapboxNavigationViewController.navigationProvider.routeVoiceController
    .speechSynthesizer.muted = isMuted!
```

So iOS audio behaviour today is entirely the SDK's defaults. Nothing in SafeRoute
has ever configured it. That is consistent with the defect existing, and it also
means there is no existing app-side configuration to conflict with.

---

## 4. Design (provisional on §6 step 1)

### 4.1 Take ownership of the audio session

Set `managesAudioSession = false` on the synthesizer, then configure
`AVAudioSession` in the wrapper.

Why this is the lever: while the SDK manages the session it will choose a category
and activate it on its own terms, and the app cannot add the one option that
decides whether audio coexists with a call.

### 4.2 The configuration, and why each part

- **`.mixWithOthers`** — the load-bearing option. On iOS, audio from an app whose
  session does not mix is silenced or refused while another session (the call)
  is active. Without it nothing else in this design matters.
- **`.duckOthers`** — lowers the call audio under the instruction rather than
  talking over it at full level. This is strictly better than Android, where
  ducking was impossible because ducking is what audio focus buys and focus was
  refused. iOS can do what Android could not.
- **Category `.playback`** — navigation guidance is playback, and `.playback`
  honours mixing. `.playAndRecord` is the alternative and is discussed in §4.3.
- **Mode `.voicePrompt`** — tells iOS this is spoken guidance, which is what
  drives correct routing and ducking behaviour for navigation.
- **Reactivate rather than assume.** The session must be activated at
  instruction time, not once at startup, because a call interruption deactivates
  it (§4.4).

### 4.3 The Bluetooth question — the direct analogue of the Android SCO finding

On Android the decisive measurement was that during a call the headset link was
owned by Bluetooth SCO, A2DP was reported present but carried nothing, and
guidance had to go onto the call stream to be heard.

iOS has the same physical constraint and different controls:
`.allowBluetooth` routes to HFP (the call profile), `.allowBluetoothA2DP` to the
media profile. During a call the headset is on HFP, so `.allowBluetoothA2DP` alone
may put guidance on a profile that is not currently rendering — exactly the Android
failure. But `.allowBluetooth` requires the `.playAndRecord` category, which
engages the microphone and has its own consequences on a live call.

**This is the main open question and §6 step 1 must settle it empirically.** Two
candidate configurations to measure, not to choose from a document:

| | category | options | mode |
|---|---|---|---|
| A | `.playback` | `[.mixWithOthers, .duckOthers]` | `.voicePrompt` |
| B | `.playAndRecord` | `[.mixWithOthers, .duckOthers, .allowBluetooth]` | `.voicePrompt` |

A is less invasive and is the right default if it is audible on a headset during a
call. B is the fallback if A proves to be the iOS version of "rendered to a profile
nobody is listening to." Reviewers should say whether B's microphone engagement
during a live call is acceptable, since it may affect the call itself.

### 4.4 Interruption handling

A call raises `AVAudioSession.interruptionNotification`. With `.mixWithOthers` the
app may not be interrupted at all; if it is, `.ended` must trigger reactivation, or
guidance stays silent for the rest of the drive even after the call ends. That
"silent until relaunch" failure mode is worse than the defect being fixed, so it is
a required test (§6 step 5) rather than a nicety.

### 4.5 Scope containment, mirroring the Android fix

On Android the focus bypass was attached to one player used only during a call, so
no-call behaviour was byte-identical. The iOS equivalent: the mixing configuration
must not change behaviour when no call is active. Navigation voice on iOS works
today; if this design alters the no-call path and regresses it, that is a net loss
even if the call case improves. Reviewers should say whether the session should be
reconfigured per call state or set once with options that are harmless when no call
is present.

### 4.6 Mute parity

`muted: Bool` and `volume: VolumeMode` (`.system` / `.override(Float)`). Unlike
Android there is one synthesizer, so there is no two-instance mute-sync problem —
the Android bug where three volume sites each had to set both players has no iOS
analogue. The existing `setIsMuted` line is sufficient and must keep working; mute
must still mean silence during a call.

---

## 5. What this does NOT do

- Does not touch Android. SYNCFORGE-317 is confirmed working and is not reopened.
- Does not port the Android mechanism. There is no audio focus on iOS and no
  `AudioFocusDelegate` equivalent; `managesAudioSession` is a different lever
  solving a different problem.
- Does not assume the defect exists. §6 step 1 confirms it first.

---

## 6. Verification plan

Protocol 2 passing is not sufficient — this changes runtime audio behaviour on a
device. Standing rule: a device log must confirm behaviour before it reaches the
owner's phone.

1. **FIRST, BEFORE CODE: confirm the defect and capture the mechanism.** Install
   the current iOS build on an iPhone, navigate with a Bluetooth earpiece, take a
   call, and capture the device log. Specifically look for a `SpeechError` carrying
   a `SpeechFailureAction` (`.mix`, `.duck`, `.unduck`, `.play`) and for
   `AVAudioSession` interruption and route-change notifications. If the defect does
   not reproduce on iOS, this ticket closes here and the design is discarded.
2. P3 on the changed range once code exists.
3. Device run with the fix: guidance audible on a Bluetooth earpiece during a call.
4. Configuration A vs B (§4.3) decided by measurement, with the chosen one recorded
   along with what the other did.
5. **Post-call recovery**: after the call ends, guidance must still work for the
   rest of the session. This is the interruption-handling test and it is mandatory.
6. **No-call regression**: guidance on A2DP, speaker, earpiece and wired with no
   call active — all must behave exactly as they do today (§4.5).
7. Mute, including mid-call, and the mute prop from JS.
8. AC4: ask the remote party whether they heard the instruction. Record per device.
9. Call types: cellular and VoIP both. On Android these took different paths —
   the confirmed Android fix was measured on `MODE_IN_COMMUNICATION` and the
   cellular case is still outstanding there. Do not repeat that gap on iOS.

---

## 7. Out of scope / do not touch

- Android: `ExpoMapboxNavigationView.kt` and everything in SYNCFORGE-317.
- The iOS build link rule: the install link must go to TestFlight, never an `.ipa`
  download. Not in scope here, but not to be regressed.
- Branch base: `syncforge-317` descends from the shipped pin `6471b8f2`. Do not
  rebase onto `main`/`dc71895`, which lacks SAFEROUTE-288.
- The pre-existing findings tabled in `docs/decisions/SYNCFORGE-317-P2-override.md`
  remain open and out of scope here, including `maneuverApi`/`tripProgressApi`
  being rebuilt on every `update()`.

---

## 8. Questions to reviewers

1. §4.3 — configuration A or B? Is engaging the microphone via `.playAndRecord`
   during a live call acceptable to get `.allowBluetooth` HFP routing, or is that
   too invasive and A must be made to work?
2. §4.5 — configure the session once with call-safe options, or reconfigure per
   call state? Once is simpler; per-state protects the no-call path that currently
   works.
3. §4.1 — does setting `managesAudioSession = false` oblige the app to handle
   anything else the SDK was doing (route changes, secondary audio hints), and is
   there a documented contract for what the app must then take on?
4. §4.4 — is `.mixWithOthers` sufficient to avoid interruption entirely on a
   cellular call, or must the app always handle `.began`/`.ended`?
5. §2 — is designing before the iOS defect is measured the right call at all, or
   should this document be held until step 1 reports?
