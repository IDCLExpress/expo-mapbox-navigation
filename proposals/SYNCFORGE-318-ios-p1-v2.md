# SYNCFORGE-318 — iOS: navigation voice must be audible during a phone call — v2

Protocol 1 (Design). Repo: `expo-mapbox-navigation` (fork), branch `syncforge-317` @ `ad490a7`
File under design: `ios/ExpoMapboxNavigationView.swift` (509 lines)
Status: design only. No code written.

Supersedes v1 (task `c87e99a5`, APPROVED / CONDITIONAL). The second critic's
challenge was accepted, not argued: v1 deferred too many decisions to reviewers and
to future measurement. **v2 answers four of its five questions from new
measurements of the shipped framework** rather than inventing answers. The fifth is
answered by stating a sequencing rule.

---

## 1. Requirement (unchanged from v1)

Primary user: motorcycle riders, helmet Bluetooth earpieces, same device carrying
calls, music and navigation.

**AC1.** A navigation voice instruction must be audible on whichever output the
user is listening through when it is due.
**AC2.** AC1 holds during a telephony call, whatever the launch order.
**AC3.** AC2 holds when the headset's audio link is owned by the call.
**AC4.** Rider audibility outranks the remote party not overhearing — owner ruling
2026-10-01, "Speak anyway". Measure and document, do not block.
**AC5.** Mixed, uncontrolled fleet (Sena, Cardo, generic earbuds). No device lists,
no per-rider toggle.

---

## 2. The iOS defect is still UNMEASURED — and that now sets the order of work

No iOS device log exists. No iOS build has been tested for this defect. The Android
cause (Samsung's blanket `requestAudioFocus failed while call`) has **no iOS
analogue** — iOS has no audio-focus system; it has `AVAudioSession` categories,
options and interruptions.

**Answering v1 reviewer question 5 — "is designing before measuring right at all?"**
Both, in this order, and the order is the answer: this document is the *measured
API design*, which is exactly what could be determined without a device, and §7
step 1 is the *device measurement*, which decides between the two configurations in
§4.3 and confirms the defect exists at all. What was wrong in v1 was not designing
early — it was presenting open questions as a finished design. v2 narrows the
design to what the framework can prove and names the single empirical fork.

If step 1 shows no defect on iOS, this ticket closes and nothing is built.

---

## 3. Measured API surface

From the shipped `MapboxNavigationCore.xcframework` — public `.swiftinterface`
(2,535 lines), `.private.swiftinterface` (2,676 lines), and `nm`/`strings` on the
4.8 MB arm64 binary. Bytecode and interface, not documentation.

### 3.1 The lever

```swift
@MainActor var managesAudioSession: Bool { get set }   // SpeechSynthesizing protocol
```

Present and settable on **all three** synthesizers, confirmed by symbol:

```
_$s20MapboxNavigationCore0A17SpeechSynthesizerC19managesAudioSessionSbvs   (MapboxSpeechSynthesizer, setter)
_$s20MapboxNavigationCore23SystemSpeechSynthesizerC19managesAudioSessionSbvs (SystemSpeechSynthesizer, setter)
_$s20MapboxNavigationCore18SpeechSynthesizingP19managesAudioSessionSbvsTj  (protocol witness, setter)
```

### 3.2 What the SDK does while it manages the session — answers v1 Q3

v1 asked what the app inherits when `managesAudioSession = false`, and flagged it as
an undocumented integration trap. Measured from the binary's Objective-C selector
references:

```
setCategory:mode:options:error:
setActive:withOptions:error:
```

plus type references to `AVAudioSessionCategory`, `AVAudioSessionCategoryOptions`,
`AVAudioSessionMode`.

**So the SDK's audio-session responsibility is exactly two calls: configure
(category + mode + options) and activate.** Nothing in the public or private
interface, and no symbol in the binary, indicates it handles route changes,
secondary-audio hints, or interruption recovery on the app's behalf. The inherited
obligation is therefore bounded and small: set the category and activate the
session. That is a real answer to Q3 and it makes the design materially less risky
than v1 presented it.

The old helpers are explicitly dead and must not be used:

```swift
@available(*, deprecated, message: "This extension is no longer supported.")
extension AVAudioSession {
  public func tryDuckAudio() -> (any Error)?
  public func tryUnduckAudio() -> (any Error)?
}
```

### 3.3 The diagnostic — sharper than anything Android offered

```swift
public enum SpeechError : LocalizedError {
  case unableToControlAudio(instruction: SpokenInstruction?,
                            action: SpeechFailureAction,
                            underlying: (any Error)?)
  …
}
public enum SpeechFailureAction : String, Sendable { case mix, duck, unduck, play }
```

The SDK reports **which audio-session operation failed, by name**. On Android the
equivalent evidence had to be reconstructed from OEM log lines that were not even
enabled by default. Here the SDK volunteers it. §7 step 1 greps for
`unableToControlAudio` and reads its `action`.

### 3.4 Which synthesizer SafeRoute actually gets, and where the flag must be set

The wrapper builds one shared provider:

```swift
static let navigationProvider: MapboxNavigationProvider = MapboxNavigationProvider(
    coreConfig: CoreConfig(
        routingConfig: RoutingConfig(fasterRouteDetectionConfig: .none),
        locationSource: .live))
```

`static let` — one instance for the app's lifetime. The voice path is reached as
`navigationProvider.routeVoiceController.speechSynthesizer`, typed
`any SpeechSynthesizing`, and `RouteVoiceController.speechSynthesizer` is
**get-only**, so the synthesizer cannot be replaced on it.

In practice that synthesizer is a `MultiplexedSpeechSynthesizer`, which wraps
children and exposes them:

```swift
@MainActor final public class MultiplexedSpeechSynthesizer : SpeechSynthesizing {
  final public var managesAudioSession: Bool { get set }
  final public var speechSynthesizers: [any SpeechSynthesizing] { get set }   // readable AND settable
  …
}
```

**This changes the design from v1.** Setting `managesAudioSession` on the wrapper
may or may not propagate to its children — the interface does not say, and guessing
is what cost two Android builds. But there is direct evidence that wrapper→child
propagation works for at least one property: the wrapper's `muted` is the only
audio line in the shipped app today and mute demonstrably works, so the wrapper
does forward `muted` to the children that actually speak.

Design consequence (§4.1): set it on the wrapper **and** iterate
`speechSynthesizers` setting it on each child. `speechSynthesizers` is readable, so
this costs one loop and removes the propagation question entirely rather than
betting on it.

---

## 4. Design

### 4.1 Take ownership of the audio session

```
synth.managesAudioSession = false
for child in (synth as? MultiplexedSpeechSynthesizer)?.speechSynthesizers ?? [] {
    child.managesAudioSession = false
}
```

Belt and braces per §3.4. All three concrete synthesizers expose the setter, so no
child can refuse it.

### 4.2 Configure the session ourselves

Per §3.2 the inherited duty is `setCategory(_:mode:options:)` and `setActive(_:)`.

- **`.mixWithOthers`** — load-bearing. On iOS an app whose session does not mix is
  silenced or refused activation while the call's session is active. Nothing else in
  this design matters without it.
- **`.duckOthers`** — lowers call audio under the instruction instead of competing
  with it. **This is strictly better than the Android outcome**, where ducking was
  impossible because ducking is what audio focus buys and focus was refused
  outright. iOS can do what Android could not.
- **Mode `.voicePrompt`** — the mode iOS provides for spoken guidance; drives
  routing and ducking behaviour appropriately.
- **Activate at instruction time, not once at startup**, because an interruption
  deactivates the session (§4.4).

### 4.3 The one empirical fork — Bluetooth routing during a call

The direct analogue of the Android SCO finding, where A2DP was reported present,
carried nothing, and guidance had to move to the call's own path to be heard.

iOS controls differ: `.allowBluetooth` routes to HFP (the call profile),
`.allowBluetoothA2DP` to the media profile. During a call the headset is on HFP, so
A2DP-only may render to a profile nobody is listening to — the same failure. But
`.allowBluetooth` requires `.playAndRecord`, which engages the microphone during a
live call.

| | category | options | mode |
|---|---|---|---|
| **A** | `.playback` | `[.mixWithOthers, .duckOthers]` | `.voicePrompt` |
| **B** | `.playAndRecord` | `[.mixWithOthers, .duckOthers, .allowBluetooth]` | `.voicePrompt` |

**A is the default and B the fallback**, decided by §7 step 3, not by this document.
A is less invasive; B is needed only if A proves inaudible on a headset mid-call.

**Answering v1 reviewer question 1** (is B's microphone engagement acceptable):
reviewers should rule, but the design position is that B is not adopted unless A is
measured as failing, because engaging the microphone on a live call risks affecting
the call itself — a regression the rider would notice more than a missed
instruction.

### 4.4 Interruption handling — answers v1 Q4

v1 asked whether `.mixWithOthers` avoids interruption entirely or whether
`.began`/`.ended` must always be handled. **Design decision: always handle them.**

Reasoning rather than deferral: whether a given iOS version and call type
interrupts a mixing session is not something this design can guarantee across the
fleet, and the cost of being wrong is asymmetric. If we assume no interruption and
one arrives, the session stays inactive and **guidance is silent for the remainder
of the drive, even after the call ends** — far worse than the defect being fixed.
Handling `.ended` by reactivating is a few lines and is correct whether or not the
interruption ever fires. §7 step 5 tests it explicitly.

### 4.5 Session lifetime — answers v1 Q2

v1 left "configure once" versus "reconfigure per call state" to reviewers.
**Design decision: configure once, with options that are harmless when no call is
present.**

Reasoning: `.mixWithOthers` and `.duckOthers` describe how to coexist with other
audio, and they are correct behaviour with or without a call — a navigation app
should duck the rider's music rather than stop it. There is no state-dependent
value to switch between, unlike Android where `STREAM_VOICE_CALL` with no call
active would have routed guidance to the earpiece and so had to be call-gated.

This matters for the regression risk v1 identified: navigation voice on iOS works
today, and a per-call-state reconfiguration would put that working path behind new
conditional logic for no benefit. If step 3 selects configuration B, this decision
must be revisited, because `.playAndRecord` is **not** harmless with no call active
and would then need call-state gating.

### 4.6 Mute parity — answers v1 Q (F)

`muted: Bool` and `volume: VolumeMode` (`.system` / `.override(Float)`). There is
one synthesizer facade, so Android's two-instance mute-sync bug — three volume
sites each needing to set both players — has no iOS analogue. The existing line
stands:

```swift
navigationProvider.routeVoiceController.speechSynthesizer.muted = isMuted!
```

The interaction v1 left underspecified: mute must survive session reactivation
after an interruption. `muted` is synthesizer state and session activation is
independent of it, so reactivating must not touch `muted` — and §7 step 7 tests
mute across a call boundary to confirm that separation holds in practice.

### 4.7 Debuggability — answers v1 Q (G)

v1 was silent on surfacing state, which the critic flagged given how much the
Android work depended on logs. Minimum: log the chosen category/mode/options, every
`SpeechError.unableToControlAudio` with its `action`, and each interruption
`.began`/`.ended` with whether reactivation succeeded. Those four facts are what
§7's steps actually read, and without them an iOS failure is as blind as Android
was before `MediaFocusControl` was turned up.

---

## 5. Scope containment

No-call behaviour must not regress. Navigation voice on iOS works today; a fix that
gains the call case and loses the ordinary case is a net loss. §4.5 is chosen
partly to keep the no-call path free of new conditionals, and §7 step 6 is the gate.

---

## 6. What this does NOT do

- Does not touch Android. SYNCFORGE-317 is confirmed working (build 1448711, live
  on the "SafeRoute Test" closed track) and is not reopened.
- Does not port the Android mechanism — no audio focus exists on iOS and no
  `AudioFocusDelegate` equivalent.
- Does not assume the defect exists. §7 step 1 confirms it first.

---

## 7. Verification plan

Protocol 2 passing is not sufficient. A device log must confirm behaviour before
this reaches the owner's phone.

1. **FIRST, BEFORE CODE — confirm the defect and capture the mechanism.** iPhone
   connected to the **Mac Mini** (it has Xcode and `devicectl`; the Mac Studio has
   neither). Navigate with a Bluetooth earpiece on the build already installed,
   take a call, capture the device log. Read:
   `SpeechError.unableToControlAudio` and its `SpeechFailureAction` (`.mix`,
   `.duck`, `.unduck`, `.play`); `AVAudioSession` interruption notifications; route
   changes. **If the defect does not reproduce, close the ticket.**
2. P3 on the changed range once code exists.
3. **Configuration A vs B (§4.3)** decided on device: is guidance audible on a
   Bluetooth earpiece mid-call under A? Record what the other did.
4. Device run with the fix: guidance audible on the earpiece during a call.
5. **Post-call recovery (§4.4)** — after the call ends, guidance must still work
   for the rest of the session. Mandatory.
6. **No-call regression (§5)** — A2DP, speaker, earpiece, wired, no call active:
   all exactly as today.
7. **Mute across a call boundary (§4.6)** — mute, start a call, confirm silence;
   unmute mid-call; confirm the JS prop still works after reactivation.
8. AC4 — ask the remote party whether they heard it. Record per device.
9. **Both call types: cellular and VoIP.** On Android these took different paths
   and the confirmed fix was measured on `MODE_IN_COMMUNICATION` with the cellular
   case still outstanding. Do not repeat that gap.

---

## 8. Out of scope / do not touch

- Android: `ExpoMapboxNavigationView.kt` and all of SYNCFORGE-317.
- The iOS install-link rule: the link must go to TestFlight, never an `.ipa`
  download. Not in scope, not to be regressed.
- Branch base: `syncforge-317` descends from the shipped pin `6471b8f2`. Do not
  rebase onto `main`/`dc71895`, which lacks SAFEROUTE-288.
- Pre-existing findings in `docs/decisions/SYNCFORGE-317-P2-override.md`, including
  `maneuverApi`/`tripProgressApi` rebuilt on every `update()`.

---

## 9. Remaining questions to reviewers

1. §4.3 — ratify A-default/B-fallback, and rule on whether `.playAndRecord`
   engaging the microphone on a live call is acceptable at all if A fails.
2. §3.4 — is setting `managesAudioSession` on both the multiplexed wrapper and each
   child the right belt-and-braces, or does writing to children risk fighting the
   wrapper's own propagation?
3. §4.5 — if step 3 selects B, confirm that call-state gating then becomes
   required, since `.playAndRecord` is not harmless with no call active.
4. Is there a `CoreConfig` path to inject a pre-configured synthesizer at provider
   construction, which would be cleaner than mutating a `static let` provider's
   synthesizer after the fact?
