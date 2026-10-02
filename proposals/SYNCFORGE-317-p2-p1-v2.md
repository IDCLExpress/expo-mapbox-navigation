# SYNCFORGE-317 Part 2 — Protocol 1 (Design) — v2

Repo: `expo-mapbox-navigation` (fork) — branch `syncforge-317` @ `5008cf7`
File under design: `android/src/main/java/expo/modules/mapboxnavigation/ExpoMapboxNavigationView.kt`
Plus: app manifest (one new permission — see §6)
Status: design only. No code written.

Supersedes v1 (task `35b1a27b`, verdict CONDITIONAL / CONDITIONAL).
Every v1 finding is answered in §8. Two were answered by owner ruling, one by
new measurement, the rest by specification.

---

## 1. Requirement

Primary user: motorcycle riders, helmet-mounted Bluetooth earpieces, listening to
calls, music and navigation through the same device. Owner's words:

> "This GPS should have to play anywhere that the listener is listening in,
> whether it's Bluetooth, speaker, or regular phone."

**AC1.** A navigation voice instruction must be audible on whichever output the
user is listening through — Bluetooth, phone speaker, earpiece, wired — at the
moment it is due.

**AC2.** AC1 holds during a telephony call. Launch order is irrelevant.

**AC3.** AC2 holds when the headset's audio link is owned by Bluetooth SCO.

**AC4 (REVISED — owner ruling 2026-10-01).** Audibility to the rider takes
precedence over the remote party not overhearing. v1 treated possible uplink
bleed as a blocking gate; the owner ruled **"Speak anyway"** — a rider missing a
turn at speed is the real hazard, a caller hearing "turn right in 500 feet" is
an annoyance. AC4 is therefore **measure and document, do not block**.

**AC5 (NEW).** The rider fleet is mixed and uncontrolled (owner ruling: "Mixed,
and I can't control what riders use" — Sena, Cardo, generic earbuds). The design
must work on the worst case and exploit the better case when present. No
device allow/block lists. No per-device user toggle (the owner declined the
"let the rider choose" option).

---

## 2. Measured evidence

Device: Galaxy S22 Ultra `R5CT81CKMHJ`, `com.idclexpress.saferoute`,
`versionCode=1445773`, `minSdk=24 targetSdk=36`.
Log: one `logcat -d`, 270,472 lines, 2026-10-01 19:01:51 → 20:23:51.
Call window isolated: 19:02:26.910 → 19:03:30.115.

- Call active, holding focus:
  `CallAudioModeStateMachine$SimCallFocusState: AudioManager#requestAudioFocus(CALL)`
  `AudioManager#setMode(MODE_IN_CALL)`; `AS.AudioService: setMode(mode=2, caller=com.android.server.telecom)`
  `SamsungCallStateAudioParam: CALL_STATUS_VOLTE_CP_VOICE_CALL_ON`
- Routed to Bluetooth SCO throughout:
  `SamsungBluetoothDeviceAdapter: getConnectedDevices - hfp : <addr>`
  `calculateBaselineRoute - audio routing to AudioRoute[Type=TYPE_BLUETOOTH_SCO, ...]`
  `Event: AUDIO_ROUTE_TO, dest=AudioRoute[Type=TYPE_BLUETOOTH_SCO, ...], reason=ACTIVE_FOCUS`
  333 Bluetooth lines in window; route reverts to `EARPIECE` only at teardown (19:03:29).
- App voice path initialised during the call:
  `Connected successfully to TTS engine: com.google.android.tts` (19:02:39);
  `MARsPolicyManager: setTTSPkgInfo : 10669` — uid 10669 is SafeRoute (`u0a669`);
  unbound 19:02:59.
- Owner report: visual directions produced, no voice heard.
- `setMode` fires **14 times** in this single 64-second call. Relevant to §5.4.

### NEW MEASUREMENT since v1 — closes v1 finding 1.5

Merged manifest extracted from the shipped APK (`SafeRoute-1445773.apk`,
`AndroidManifest.xml` decoded from binary AXML). 16 permissions declared. Probed:

```
MODIFY_AUDIO_SETTINGS -> no
BLUETOOTH_CONNECT     -> no
READ_PHONE_STATE      -> no
```

Consequences, all three load-bearing:

1. `MODIFY_AUDIO_SETTINGS` is **not** held, and is **not** inherited from the
   Mapbox AARs via manifest merge. It must be added. It is a **normal**
   permission — install-time, no runtime prompt, no rider-visible change.
2. `BLUETOOTH_CONNECT` is **not** held. It is a **runtime** permission on API
   31+. Therefore the design must not call anything requiring it. Output
   *types* from `AudioManager.getDevices()` are available without it; device
   *names* are not. The design uses types only. This answers v1 finding 1.3 /
   summary 5: the wider routing APIs are usable, but only the
   permission-free subset.
3. `READ_PHONE_STATE` is **not** held, and the design does not need it —
   confirming the `AudioManager`-mode approach over `TelephonyManager` /
   `PhoneStateListener`.

### Instrument limitation (unchanged, still binding)

App-level audio focus is not logged by default on this device: across all
270,472 lines, `MediaFocusControl` = 0, `AudioFocusInfo` = 0, `AUDIOFOCUS_` = 0.
The only 4 `requestAudioFocus` hits are Telecom's own. `getOutputForAttrInt`
appears twice, both outside the call window.

**Therefore "the player never requested focus" is NOT an established fact.**
Whether focus was requested, what was granted, and which output the TTS opened
remain UNMEASURED and must not be asserted.

Mitigation in place: `log.tag.MediaFocusControl`, `AudioManager`,
`AS.AudioService`, `APM_AudioPolicyManager`, `AudioTrack`, `TextToSpeech`,
`ReactNativeJS` and Mapbox tags set to `V` on the device; live `logcat` capture
writing to disk (ring buffer is capped at 5 MiB and rolls in ~80 min, so the
ring alone is insufficient for a long test).

---

## 3. Measured SDK constraints

From `javap` on `voice-ndk27-3.11.0.aar` — bytecode, not documentation. The
documentation was wrong twice on this already.

- `MapboxVoiceInstructionsPlayer(Context, String, VoiceInstructionsPlayerOptions)`
- `VoiceInstructionsPlayerOptions.Builder` defaults from `<init>` bytecode:
  `focusGain=3` (AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK), `streamType=3`,
  `ttsStreamType=3` (STREAM_MUSIC), `usage=12`
  (USAGE_ASSISTANCE_NAVIGATION_GUIDANCE — already correct, never a defect),
  `contentType=2` (MUSIC; Part 1 set this to CONTENT_TYPE_SPEECH),
  `useLegacyApi` unset→false, `abandonFocusDelay` unset→0.
- `ttsStreamType` is fixed at construction. **No setter exists.**
- `AudioFocusDelegate` exposes only `requestFocus()` / `abandonFocus()`. It
  cannot influence stream type or routing, and cannot implement this fix.
- `voiceInstructionsPlayer` in `ExpoMapboxNavigationView.kt` is `private var`,
  so reassignment is available.

Part 1 changed `contentType` only. `contentType` is a routing *hint*; it does not
move output off `STREAM_MUSIC`. Consistent with Part 1 having no observable
effect, which is what the owner reported.

---

## 4. Root cause

While a telephony call is active, two independent mechanisms each suffice to
produce silence in the rider's ear:

1. **Focus.** Telecom holds `AUDIOFOCUS_GAIN` for the call. A player requesting
   `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK` is, on Samsung One UI, commonly refused
   outright rather than granted with ducking.
2. **Routing.** SCO owns the headset link. On classic Bluetooth, A2DP is
   suspended while SCO is active on the same device, so there is no media path
   to the headset at all; `STREAM_MUSIC` renders to the phone's own speaker.

Mechanism 2 is the more damaging for this product: the app can be behaving
"correctly" by its own lights — speaking to a speaker in a tank bag while the
rider's ear is on SCO. The rider experiences silence.

Which is operative is what the instrumented log must settle. The design below
addresses both, and does not depend on knowing which.

---

## 5. Design

### 5.1 Output selection (revised for AC5 — mixed fleet)

Rather than always forcing the voice-call stream during a call, select at
instruction time:

```
if (no call active)                  -> media player   (STREAM_MUSIC)   [today's behaviour]
else if (a media output path exists) -> media player   (STREAM_MUSIC)
else                                 -> in-call player (STREAM_VOICE_CALL)
```

"A media output path exists" is evaluated from
`AudioManager.getDevices(GET_DEVICES_OUTPUTS)` by **device type only** —
`TYPE_BLUETOOTH_A2DP`, `TYPE_WIRED_HEADSET`, `TYPE_WIRED_HEADPHONES` — never by
name, because `BLUETOOTH_CONNECT` is not held (§2).

Why this ordering matters, and it is a direct consequence of the owner's mixed-fleet
answer: Sena and Cardo intercoms are frequently multipoint and keep A2DP alive
alongside an active call. For those riders the existing media path still works,
so the voice goes out the normal route, nothing is reconstructed, and the uplink
is never touched — which also minimises AC4 exposure without relying on a device
list. Only when no media path survives (the generic HFP case, which §1 AC5
makes the baseline) does the design fall back to the voice-call stream.

### 5.2 Player reconstruction

`ttsStreamType` is construction-fixed (§3), so "switching stream" means holding
up to two player instances and reassigning `voiceInstructionsPlayer`:

- media instance: as today, plus Part 1's `CONTENT_TYPE_SPEECH`
- in-call instance: `ttsStreamType = STREAM_VOICE_CALL`, usage and content type
  matched to speech on the communication path

Construct lazily — the in-call instance is only built the first time it is
needed, so riders who never take calls pay nothing. The outgoing instance must
be `shutdown()` whenever it is dropped; the measured log already shows TTS
bind/unbind churn on this engine, so a leak here is a real risk, not theoretical.

### 5.3 Mid-utterance swap — SPECIFIED (closes v1 finding 1.2)

v1 left this open. Decision:

- On a swap while an utterance is in flight: **stop** the outgoing utterance and
  **re-speak the current instruction on the incoming player**, provided the
  maneuver it refers to has not already been passed.
- If the maneuver has been passed, drop it; the SDK will issue the next one.
- Never queue across instances. The outgoing instance is shut down; anything
  still queued on it is abandoned deliberately, not silently.

Rationale: a half-spoken instruction is worse than a repeated one for a rider in
a helmet, and re-speaking costs one synthesis.

### 5.4 Debounce — SPECIFIED (closes v1 finding 1.4)

v1 said "must be debounced" without saying how. The measured log shows 14
`setMode` calls in one 64-second call, so this is required, not defensive.

- Collapse mode to one boolean: call-active (`MODE_IN_CALL` or
  `MODE_IN_COMMUNICATION`) vs not.
- Act only on a change to that boolean, not on `setMode` events.
- Require the new value to hold for a settling interval (**750 ms** proposed —
  reviewers should challenge the number) before reconstructing.
- At most one reconstruction per settled transition.

`MODE_IN_COMMUNICATION` is included deliberately: riders use WhatsApp and
Messenger calls, not only cellular.

### 5.5 Call-state detection and API-level fallback — SPECIFIED (closes v1 finding 1.9)

- API 31+: `AudioManager.OnModeChangedListener`.
- API 24–30: no listener. Read `AudioManager.getMode()` **at instruction
  dispatch time**. This is sufficient because the only moment the correct player
  matters is the moment an instruction is about to be spoken. No polling loop.

Neither path needs `READ_PHONE_STATE` (§2).

### 5.6 Degradation (AC1, AC5)

If no call is active, behaviour is exactly today's. If a call is active and
neither a media path nor the voice-call path yields audible output, fall back to
the phone speaker rather than silence. Silence is the defect; a speaker a rider
may not hear is still strictly better than nothing.

### 5.7 iOS parity seam (closes v1 finding 1.6)

iOS is a separate ticket and must not be assumed to follow from this. To keep
parity cheap, the decision in §5.1 — *given call state and available outputs,
which audio configuration* — is implemented as one pure function with no Android
types in its signature, so the iOS side (`AVAudioSession` category/mode,
`.allowBluetooth`, `.duckOthers`) can mirror the same rule rather than
re-deriving it.

---

## 6. Permission change

Add `MODIFY_AUDIO_SETTINGS` to the app manifest. Measured absent (§2), not
inherited from Mapbox. Normal permission: install-time grant, no runtime prompt,
no rider-visible change, no interaction with the SAFEROUTE-309 permission work.

Explicitly NOT added: `BLUETOOTH_CONNECT` (would prompt riders — §5.1 is designed
around not needing it) and `READ_PHONE_STATE` (not needed — §5.5).

---

## 7. Accepted risk — AC4 (owner ruling)

On some hardware, audio on the voice-call stream may be mixed into the call
uplink, so the remote party hears navigation instructions. The owner has ruled
that the app speaks anyway.

Recorded consequences, which the ruling accepts:

- This can only occur in the §5.1 fallback branch — a call active AND no media
  output path. Multipoint intercom riders are unaffected.
- No device allow/block list and no user toggle (owner declined both).
- **Recommendation, not a blocker:** disclose it in plain language somewhere a
  rider will see it once — release notes or a first-run note — so the first
  person whose wife hears "turn right in 500 feet" understands it is the app and
  not the phone misbehaving. Cheap, and it protects the support queue.
- Still measure it in P3 (§9) and record the result per device. Accepted is not
  the same as unknown.

---

## 8. Disposition of every v1 finding

| v1 finding | Disposition |
|---|---|
| 1.1 AC4 uplink bleed not mitigated; make it a gate | **Owner ruling: speak anyway.** AC4 revised to measure-and-document (§1 AC4, §7). Exposure additionally narrowed by §5.1 so it only applies when no media path exists. |
| 1.2 Mid-utterance swap undefined | **Specified** — §5.3. Stop and re-speak if the maneuver is still ahead; otherwise drop. |
| 1.3 Wider OS routing APIs unexplored | **Adopted, within a measured limit** — §5.1 uses `getDevices()` by type. Device names are unavailable because `BLUETOOTH_CONNECT` is not held (§2). |
| 1.4 Debounce unspecified | **Specified** — §5.4. Boolean collapse, 750 ms settle, one swap per transition. |
| 1.5 `MODIFY_AUDIO_SETTINGS` unverified | **Measured: absent**, and not inherited from Mapbox (§2). Added in §6. |
| 1.6 No iOS parity strategy | **Addressed** — §5.7 names the seam. iOS remains a separate ticket. |
| 1.7 No user override / fallback | **Owner declined the toggle** (chose "speak anyway" over "let the rider choose"). Fallback-to-speaker retained — §5.6. |
| 1.8 Multipoint headsets assumed away | **Fixed, and now load-bearing** — §5.1 prefers the surviving media path, which is the common multipoint case. Driven by the owner's mixed-fleet answer. |
| 1.9 API 24–30 fallback undecided | **Decided** — §5.5. Listener on 31+, dispatch-time `getMode()` below. |
| 8 Logs may capture sensitive activity | **Accepted.** Device logs stay on the Mac Studio, are not committed to any repo and are not shipped. Telecom already masks the dialled number (`handle=tel:**********`); the Bluetooth MAC is masked in this document. |

---

## 9. Verification plan

Protocol 2 passing is **not** sufficient — this changes runtime audio behaviour
on a device. Standing rule: a device log must confirm behaviour before it reaches
the owner's phone.

1. P3 on the changed range.
2. Instrumented device run with the verbose tags already enabled. Must show,
   inside the call window: the focus request and what was granted; the
   `getOutputForAttrInt` attributes and the selected output device; the stream
   actually used.
3. Rider-realistic test, generic HFP headset (the §5.1 fallback branch): active
   call, navigation running, instruction due. Instruction must be heard.
4. Multipoint test (Sena or Cardo if available): confirm the media path is used
   and **no reconstruction occurs** — this branch should be a no-op.
5. AC4 measurement (record, do not block): ask the remote party whether they
   heard the instruction. Record per device.
6. Regression: voice with no call, on A2DP, on speaker, on earpiece, wired.
7. Confirm mute still works — see §10.
8. Confirm no TTS engine leak across several call start/stop cycles
   (`setTTSPkgInfo` / bind-unbind churn in logcat).

---

## 10. Out of scope / do not touch

- The `soundButton` `if (isMuted) 1.0f else 0.0f` polarity. The owner has ruled
  on this three times; flipping it breaks mute. Not in scope.
- `apk_download_url` being unused — by design, owner confirmed, not a defect.
- Branch base: `syncforge-317` is branched from the shipped pin `6471b8f2`, NOT
  from `main`/`dc71895`, which lacks SAFEROUTE-288. Do not rebase onto main.

---

## 11. Questions to reviewers

1. §5.1 — is preferring a surviving media path over the voice-call stream
   correct, or are there devices where A2DP reports as an available output during
   a call but renders nothing? That would turn the preferred branch into silence
   and invert the ordering.
2. §5.4 — is 750 ms the right settle interval given 14 `setMode` events per
   call, or does it risk missing an instruction due during call setup?
3. §5.2 — any supported path to in-call audibility on a SCO-owned headset that
   does NOT require replacing the player instance, which I have missed in the
   measured API surface in §3?
