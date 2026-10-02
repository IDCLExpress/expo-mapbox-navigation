# SYNCFORGE-317 Part 2 — Protocol 1 (Design)

Repo: `expo-mapbox-navigation` (fork) — branch `syncforge-317` @ `5008cf7`
File under design: `android/src/main/java/expo/modules/mapboxnavigation/ExpoMapboxNavigationView.kt`
Status: design only. No code written. Part 1 shipped and did NOT fix the defect.

---

## 1. Requirement (owner, verbatim intent)

> "most of these people are going to be motorcycle riders. They're going to be
> wearing helmets, and they're going to be wearing their actual earpieces,
> Bluetooth earpieces, and that's how they're going to be listening to the phone,
> music, as far as and GPS. This GPS should have to play anywhere that the
> listener is listening in, whether it's Bluetooth, speaker, or regular phone."

Restated as an acceptance criterion:

**AC1.** A navigation voice instruction must be audible on whichever output the
user is actually listening through — Bluetooth headset, phone speaker, earpiece,
or wired — at the moment the instruction is due.

**AC2.** AC1 holds while a telephony call is in progress. Launch order is
irrelevant: whether navigation started before or during the call, the
instruction must be heard.

**AC3.** AC2 holds for the primary scenario: a helmet-mounted Bluetooth earpiece
with an active call, i.e. the headset's audio link is owned by Bluetooth SCO.

**AC4.** The instruction must NOT be transmitted to the remote party on the call.

AC2 is currently failing on both platforms. AC4 is a new constraint introduced by
the design below and must be verified on device, not assumed.

---

## 2. Measured evidence

Device: Galaxy S22 Ultra `R5CT81CKMHJ`, `com.idclexpress.saferoute`,
`versionCode=1445773` (confirmed on device), `minSdk=24 targetSdk=36`.
Log: single `logcat -d` dump, 270,472 lines, 2026-10-01 19:01:51 → 20:23:51.
Call window isolated to 19:02:26.910 → 19:03:30.115.

Established facts from that window:

- Telephony call active and holding focus:
  `CallAudioModeStateMachine$SimCallFocusState: AudioManager#requestAudioFocus(CALL)`
  `AudioManager#setMode(MODE_IN_CALL)`, `AS.AudioService: setMode(mode=2, caller=com.android.server.telecom)`
  `SamsungCallStateAudioParam: CALL_STATUS_VOLTE_CP_VOICE_CALL_ON`
- Audio routed to Bluetooth SCO for the duration:
  `SamsungBluetoothDeviceAdapter: getConnectedDevices - hfp : 88:B9:45:19:AF:D5`
  `calculateBaselineRoute - audio routing to AudioRoute[Type=TYPE_BLUETOOTH_SCO, Address=88:B9:45:19:AF:D5]`
  `Event: AUDIO_ROUTE_TO, dest=AudioRoute[Type=TYPE_BLUETOOTH_SCO, ...], reason=ACTIVE_FOCUS`
  333 Bluetooth-related lines in the window; route reverts to `EARPIECE` only at
  19:03:29 on teardown.
- The app's voice path initialised during the call:
  `TextToSpeechManagerPerUserService: Connected successfully to TTS engine: com.google.android.tts` (19:02:39)
  `MARsPolicyManager: setTTSPkgInfo : 10669` (19:02:48) — uid 10669 is SafeRoute (`u0a669`)
  TTS unbound 19:02:59 "client disconnection request"
- Owner report for this run: visual directions were produced; no voice was heard.

### Instrument limitation — read before weighing the above

App-level audio focus is **not logged** on this device by default. Across all
270,472 lines: `MediaFocusControl` = 0, `AudioFocusInfo` = 0, `AUDIOFOCUS_` = 0.
The only four `requestAudioFocus` hits are Telecom's own. `getOutputForAttrInt`
appears twice in the whole log, both outside the call window.

Therefore **"the player never requested focus" is NOT an established fact** and
must not be treated as one. Whether focus was requested, what was granted, and
which output the TTS opened are all currently UNMEASURED.

Mitigation applied: `log.tag.MediaFocusControl`, `AudioManager`, `AS.AudioService`,
`APM_AudioPolicyManager`, `AudioTrack`, `TextToSpeech`, `ReactNativeJS` and the
Mapbox tags are now set to `V` on the device, and a live `logcat` capture is
writing to disk (ring buffer is capped at 5 MiB and rolls in ~80 minutes, so the
ring alone is not sufficient for a long test).

---

## 3. Measured constraints on the SDK

From `javap` on `voice-ndk27-3.11.0.aar` (bytecode, not documentation — the
documentation was wrong twice on this already):

- Constructor exists: `MapboxVoiceInstructionsPlayer(Context, String, VoiceInstructionsPlayerOptions)`
- `VoiceInstructionsPlayerOptions.Builder` defaults, read from `<init>` bytecode:
  `focusGain=3` (AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK), `streamType=3`,
  `ttsStreamType=3` (STREAM_MUSIC), `usage=12` (USAGE_ASSISTANCE_NAVIGATION_GUIDANCE
  — already correct, not a defect), `contentType=2` (MUSIC; Part 1 changed this to
  `CONTENT_TYPE_SPEECH`), `useLegacyApi` unset→false, `abandonFocusDelay` unset→0.
- `ttsStreamType` is fixed at construction. There is no setter.
- `AudioFocusDelegate` exposes only `requestFocus()` and `abandonFocus()`. It has
  no influence over stream type or output routing. It cannot implement this fix.
- In `ExpoMapboxNavigationView.kt`, `voiceInstructionsPlayer` is declared
  `private var` — reassignment is therefore available.

Part 1 changed `contentType` only. `contentType` is a hint for attribute-based
routing; it does not move the output off `STREAM_MUSIC`. This is consistent with
Part 1 having no observable effect, which is what the owner reported.

---

## 4. Root-cause hypothesis

While a telephony call is active:

1. Telecom holds `AUDIOFOCUS_GAIN` for the call. A player requesting
   `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK` against an active call is, on Samsung One
   UI, commonly refused outright rather than granted with ducking.
2. Independently of focus, the headset's audio link is owned by SCO. On classic
   Bluetooth, A2DP is suspended while SCO is active on the same device, so there
   is **no media path to the headset at all**. Audio on `STREAM_MUSIC` is
   rendered to the phone's own speaker.

Either mechanism alone produces the reported symptom. Mechanism 2 is the more
damaging one for this product, because the app may be behaving "correctly" from
the code's point of view — speaking to a speaker in a tank bag or jacket pocket
while the rider's ear is on SCO. The rider experiences silence.

Which mechanism is operative is the open question the instrumented log must
settle. The design below is chosen because it addresses both.

---

## 5. Design options

### Option A — call-state-aware player reconstruction (recommended)

Observe audio mode. While a call is active, hold a player built with
`ttsStreamType = AudioManager.STREAM_VOICE_CALL` (with matching usage and
content type). When the call ends, return to the normal media player.

`ttsStreamType` is immutable per instance, so this is a reconstruction, not a
mutation. `voiceInstructionsPlayer` being `private var` makes it possible. The
outgoing instance must be `shutdown()` on swap or the TTS engine binding leaks —
the log already shows bind/unbind churn on this engine, so this is a real risk,
not a theoretical one.

Audio on the voice-call stream rides the SCO path and is therefore audible in the
headset during a call, which is precisely AC3.

**Call-state detection:** `AudioManager.getMode()` plus
`AudioManager.OnModeChangedListener`. This covers `MODE_IN_CALL` (cellular) and
`MODE_IN_COMMUNICATION` (VoIP — WhatsApp, Messenger, which riders also use) and
requires **no** `READ_PHONE_STATE` permission. Worth stating explicitly: the
wrapper's permission surface is already a sore point (SAFEROUTE-309), and
`TelephonyManager`/`PhoneStateListener` would add a sensitive permission for no
benefit. `OnModeChangedListener` is API 31+; `minSdk` is 24, so a fallback is
required for 24–30 — reviewers should weigh polling `getMode()` on instruction
dispatch against a legacy listener.

### Option B — app-owned TTS for the in-call case

Bypass the Mapbox player while a call is active and speak instructions through an
app-owned `TextToSpeech` configured for the voice-call stream.

More control, more surface: duplicate voice logic, two engines to keep in sync,
instruction text must be intercepted before the SDK consumes it. Keep as the
fallback if reviewers judge mid-session reconstruction of the Mapbox player
unsafe.

### Option C — raise the focus gain only

Request `AUDIOFOCUS_GAIN` or `..._TRANSIENT_EXCLUSIVE` instead of
`MAY_DUCK`. **Rejected as a standalone fix.** It may change whether focus is
granted, but it does not move output off `STREAM_MUSIC` and therefore cannot
address mechanism 2. It may be worth combining with Option A; reviewers should
say whether it helps or whether raising gain against an active call is
counterproductive.

**Recommendation: Option A**, with C considered as an adjunct, and B held as
fallback.

---

## 6. Risks requiring reviewer attention

1. **AC4 — uplink bleed.** Does output on `STREAM_VOICE_CALL` mix into the call's
   uplink, so the remote party hears navigation instructions? On most devices
   this is downlink-only, but it is device- and OEM-dependent and I have not
   measured it. **If it bleeds into uplink, Option A is wrong and must not
   ship.** This is the single most important thing to verify on device.
2. **Swap during an in-flight utterance.** What happens to a queued or
   mid-sentence instruction when the player is replaced. Needs a defined
   behaviour: drop, or re-speak on the new player.
3. **TTS engine leak** if the outgoing player is not shut down.
4. **`MODIFY_AUDIO_SETTINGS`** — confirm it is already held by the wrapper; if
   not, this is a new permission and the owner should know before it ships.
5. **Mode flapping.** `setMode` fires several times per call setup (14 occurrences
   in a single 64-second call in the measured log). Reconstruction must be
   debounced or it will thrash the TTS engine.
6. **Device with no SCO/A2DP at all** — must degrade to speaker, not silence.
7. **iOS parity.** The owner's requirement is both platforms. This P1 covers
   Android only; the iOS equivalent (`AVAudioSession` category/mode and
   `.allowBluetooth`/`.duckOthers`) is a separate design and must not be assumed
   to follow from this one.

---

## 7. Out of scope / do not touch

- The `soundButton` `if (isMuted) 1.0f else 0.0f` polarity. Owner has ruled on
  this three times; flipping it breaks mute. Not in scope here.
- `apk_download_url` being unused — by design, owner confirmed, not a defect.
- Branch base: `syncforge-317` is branched from the shipped pin `6471b8f2`, NOT
  from `main`/`dc71895`, which lacks SAFEROUTE-288. Do not rebase onto main.

---

## 8. Verification plan

Protocol 2 passing is not sufficient — this changes runtime audio behaviour on a
device, so per standing rule a device log must confirm it before it reaches the
owner's phone.

1. P3 on the changed range.
2. Instrumented device run with the verbose tags now enabled. Must show, inside
   the call window: the focus request and what was granted; the
   `getOutputForAttrInt` attributes and selected device for the TTS output; the
   stream actually used.
3. Rider-realistic test: helmet Bluetooth earpiece, active call, navigation
   running, instruction due. Confirm the instruction is heard in the earpiece.
4. **AC4 check:** confirm with the remote party that they did not hear the
   instruction.
5. Regression: navigation voice with no call, on BT A2DP, on speaker, and on
   earpiece — all must still work.
6. Confirm mute still works (see §7).

---

## 9. Question to reviewers

Is Option A's call-state-driven reconstruction of `MapboxVoiceInstructionsPlayer`
sound, given `ttsStreamType` is construction-fixed and the field is `private var`?
Specifically: is there a supported path to in-call audibility on a SCO-owned
Bluetooth headset that does NOT require replacing the player instance, and which
I have missed in the measured API surface in §3?
