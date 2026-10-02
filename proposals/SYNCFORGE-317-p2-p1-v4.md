# SYNCFORGE-317 Part 2 — Protocol 1 (Design) — v4

Repo: `expo-mapbox-navigation` (fork) — branch `syncforge-317` @ `5008cf7`
File under design: `android/src/main/java/expo/modules/mapboxnavigation/ExpoMapboxNavigationView.kt` (1491 lines)
Status: design only. No code written.

History: v1 `35b1a27b` CONDITIONAL/CONDITIONAL → v2 `aab8af73` APPROVED/**REJECTED**
→ v3 `a6f6480c` APPROVED/CONDITIONAL. v4 closes v3's three findings, two of them
with new measurements from the file. **One correction to my own design: the new
permission is dropped (§7).**

---

## 1. Requirement

Primary user: motorcycle riders, helmet Bluetooth earpieces, same device carrying
calls, music and navigation. Owner's words:

> "This GPS should have to play anywhere that the listener is listening in,
> whether it's Bluetooth, speaker, or regular phone."

**AC1.** A navigation voice instruction must be audible on whichever output the
user is listening through — Bluetooth, speaker, earpiece, wired — when it is due.

**AC2.** AC1 holds during a telephony call. Launch order is irrelevant.

**AC3.** AC2 holds when the headset's audio link is owned by Bluetooth SCO.

**AC4 (owner ruling 2026-10-01: "Speak anyway").** Rider audibility outranks the
remote party not overhearing. Possible uplink bleed is **measured and documented,
not blocking**. A rider missing a turn at speed is the hazard; a caller hearing
"turn right in 500 feet" is an annoyance.

**AC5 (owner ruling 2026-10-01: "Mixed, and I can't control what riders use").**
Sena, Cardo, generic earbuds. Build against the worst case, exploit the better
case when present. No device allow/block lists. No per-rider toggle.

**AC6.** Must not reintroduce SYNCFORGE-239 (§3). The voice player instance must
never be destroyed while the view is alive.

---

## 2. Measured evidence

Device: Galaxy S22 Ultra `R5CT81CKMHJ`, `com.idclexpress.saferoute`,
`versionCode=1445773`, `minSdk=24 targetSdk=36`.
Log: one `logcat -d`, 270,472 lines, 2026-10-01 19:01:51 → 20:23:51. Call window
isolated: 19:02:26.910 → 19:03:30.115.

- Call active, holding focus: `CallAudioModeStateMachine$SimCallFocusState:
  AudioManager#requestAudioFocus(CALL)`; `AudioManager#setMode(MODE_IN_CALL)`;
  `AS.AudioService: setMode(mode=2, caller=com.android.server.telecom)`;
  `SamsungCallStateAudioParam: CALL_STATUS_VOLTE_CP_VOICE_CALL_ON`
- Routed to Bluetooth SCO throughout: `getConnectedDevices - hfp : <addr>`;
  `calculateBaselineRoute - audio routing to AudioRoute[Type=TYPE_BLUETOOTH_SCO, ...]`;
  `Event: AUDIO_ROUTE_TO, dest=AudioRoute[Type=TYPE_BLUETOOTH_SCO, ...], reason=ACTIVE_FOCUS`.
  333 Bluetooth lines; reverts to `EARPIECE` only at teardown 19:03:29.
- App voice path initialised during the call: `Connected successfully to TTS
  engine: com.google.android.tts` (19:02:39); `MARsPolicyManager: setTTSPkgInfo :
  10669` — uid 10669 is SafeRoute (`u0a669`); unbound 19:02:59.
- Owner report: visual directions produced, no voice heard.
- `setMode` fires **14 times** in this one 64-second call.

### Merged-manifest measurement (shipped `SafeRoute-1445773.apk`, AXML decoded)

16 permissions declared. Probed: `MODIFY_AUDIO_SETTINGS -> no`,
`BLUETOOTH_CONNECT -> no`, `READ_PHONE_STATE -> no`. See §7 — v4 concludes none
of the three is required.

### Instrument limitation (still binding)

App-level focus is not logged by default on this device: across 270,472 lines
`MediaFocusControl` = 0, `AudioFocusInfo` = 0, `AUDIOFOCUS_` = 0; the only 4
`requestAudioFocus` hits are Telecom's own. `getOutputForAttrInt` appears twice,
both outside the call window.

**"The player never requested focus" is NOT an established fact** and must not be
asserted. Verbose tags are now set on the device (`MediaFocusControl`,
`AudioManager`, `AS.AudioService`, `APM_AudioPolicyManager`, `AudioTrack`,
`TextToSpeech`, `ReactNativeJS`, Mapbox) and a live `logcat` writes to disk — the
ring buffer is capped at 5 MiB and rolls in ~80 min, so the ring alone is
insufficient.

---

## 3. SYNCFORGE-239 — the binding prior constraint

`ExpoMapboxNavigationView.kt` line ~1356, in `update()`:

```
// [SYNCFORGE-239] NEVER replace the voice player. Retune it in place.
//
// This block previously rebuilt voiceInstructionsPlayer and speechApi on every
// update(), and twelve prop setters call update(). Any prop changing during
// navigation destroyed the component that was speaking. Measured on device
// 2026-09-10 22:47 (build 1417099): audio focus taken at .825 and abandoned at
// .970 - 145ms, far too short to say a word. That is the voice cutting out.
//
// ... One player for the life of the view means there is no moment when it does
// not exist, and no audio focus to strand.
```

v2's design reconstructed the player on call-state change and therefore
contradicted this. Narrower than the reconstruction SYNCFORGE-239 removed, but
the same failure class: destroying a player that may be speaking, stranding
focus. The v2 REJECTED halt was correct. §5.1 complies instead of working around.

Also recorded: the v2 primary critique claimed to have "scanned the relevant
Kotlin" for a submission stating "design only. No code written." **Its APPROVED
is discounted accordingly** — it reviewed an artifact that was not submitted. The
second critic caught this, which is why the halt mattered.

---

## 4. Measured SDK constraints

From `javap` on `voice-ndk27-3.11.0.aar` — bytecode, not documentation, which was
wrong twice on this already.

- `MapboxVoiceInstructionsPlayer(Context, String, VoiceInstructionsPlayerOptions)`
- Builder defaults from `<init>`: `focusGain=3` (AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK),
  `streamType=3`, `ttsStreamType=3` (STREAM_MUSIC), `usage=12`
  (USAGE_ASSISTANCE_NAVIGATION_GUIDANCE — already correct, never a defect),
  `contentType=2` (MUSIC; Part 1 set CONTENT_TYPE_SPEECH), `useLegacyApi`
  unset→false, `abandonFocusDelay` unset→0.
- `ttsStreamType` is fixed at construction. **No setter.** This is why the stream
  cannot be retuned the way `updateLanguage()` and `volume()` can.
- `updateLanguage(String)` and `volume(SpeechVolume)` exist and mutate in place —
  what SYNCFORGE-239 means by "retune it in place".
- `AudioFocusDelegate` is only `requestFocus()`/`abandonFocus()`; no influence on
  stream or routing. It cannot implement this fix.
- `voiceInstructionsPlayer` is `private var` (line 175); reassignment is possible
  but AC6 forbids destroying an instance.
- From the existing comment at lines 170–174 (written during Part 1):
  `STREAM_VOICE_CALL` while **no** call is active routes guidance to the earpiece
  instead of the speaker. So a single always-voice-call player is also wrong; the
  choice is genuinely call-state dependent.

Part 1 changed `contentType` only, a routing *hint* that does not move output off
`STREAM_MUSIC` — consistent with Part 1 having no effect, as reported.

---

## 5. Design

### 5.1 Two long-lived players, selected per announcement

Construct **both** at view creation; keep both alive for the life of the view;
never destroy either mid-life. Choose which to `play()` on per announcement.

- `mediaVoicePlayer` — `ttsStreamType = STREAM_MUSIC` plus Part 1's
  `CONTENT_TYPE_SPEECH`. Identical to today's single player.
- `inCallVoicePlayer` — `ttsStreamType = STREAM_VOICE_CALL`, usage and content
  type matched to speech on the communication path.

Satisfies AC6 on its own terms: SYNCFORGE-239 requires that there is never a
moment when the speaking component does not exist and no focus stranded by a
destroyed instance. Two permanent instances satisfy that more easily than one —
nothing is torn down, so nothing can strand.

It also removes v2's complexity: no reconstruction means no thrash, so v2's
750 ms debounce and its open question are gone. The 14 `setMode` events per call
become harmless — read, never acted on.

**Selection rule, evaluated at announcement enqueue:**

```
if (no call active)                  -> mediaVoicePlayer    [exactly today's behaviour]
else if (a media output path exists) -> mediaVoicePlayer
else                                 -> inCallVoicePlayer
```

"A media output path exists" comes from
`AudioManager.getDevices(GET_DEVICES_OUTPUTS)` by **device type only** —
`TYPE_BLUETOOTH_A2DP`, `TYPE_WIRED_HEADSET`, `TYPE_WIRED_HEADPHONES` — never by
name (§7).

Why this ordering, from AC5: Sena and Cardo intercoms are frequently multipoint
and keep A2DP alive during a call. Those riders keep the normal path, nothing
changes for them, and the uplink is never touched — minimising AC4 exposure
without a device list. Only when no media path survives (generic HFP, the AC5
baseline) does selection fall to the voice-call player.

**`getDevices()` failure handling:** on exception, empty list, or ambiguity
*while a call is active*, treat as "no media path" → `inCallVoicePlayer`. AC1 and
"speak anyway" both say audibility wins, and that is the branch that works in the
hard case. With no call active, always `mediaVoicePlayer` — never guess into the
earpiece (§4).

### 5.2 Call-state detection and API fallback

- API 31+: `AudioManager.OnModeChangedListener`, cached to a boolean.
- API 24–30: no listener. Read `AudioManager.getMode()` at announcement enqueue.
  Sufficient: the only moment the choice matters is the moment an announcement is
  about to be spoken. No polling loop.

Call-active means `MODE_IN_CALL` **or** `MODE_IN_COMMUNICATION` — riders use
WhatsApp and Messenger calls, not only cellular.

**Residual race (closes v3 finding 3).** Between the `getMode()` read and
`play()` the mode can change, so an announcement can be spoken on the
player that was correct microseconds earlier. Accepted, not mitigated:
the window is sub-millisecond on the main thread (§5.6); the cost is one
announcement on the wrong stream, which under AC4 is at worst audible to the
remote party and at best inaudible to the rider for one instruction; and the
alternative — re-checking inside the SDK's playback path — is not reachable
through the measured API surface (§4). Reviewers should say if they disagree that
this is acceptable.

### 5.3 Mute must be applied to BOTH players

Measured: mute is **per-instance player volume state**, not a global.

- line 118: `private var isMuted = false`
- line 220 (sound button): `voiceInstructionsPlayer.volume(SpeechVolume(if (isMuted) 1.0f else 0.0f))`
- line 1245 (`setIsMuted` prop): `volume(SpeechVolume(if (isMuted) 0.0f else 1.0f))`
- line 1382 (`update()`, every call): `volume(SpeechVolume(if (isMuted) 0.0f else 1.0f))`

**Requirement:** all three sites must set volume on **both** players. One missed
site is an unmuted announcement, and under AC4 that announcement may reach the
person on the call — the highest-severity detail in this design.

Partly mitigated by existing behaviour that must be preserved: SAFEROUTE-283
(line ~390) drops muted announcements **before synthesis**, so a muted
announcement never reaches either player. Volume is the second line of defence,
not the only one. Both must hold.

#### The line-220 polarity is CORRECT — do not "fix" it

Line 220 reads `if (isMuted) 1.0f else 0.0f`, which looks inverted against 1245
and 1382. It is not. Line 220 is in the sound button's click handler and runs
**before** line 225, `isMuted = !isMuted`; at line 220 `isMuted` still holds the
**pre-toggle** value. Muted rider taps to unmute → line 220 correctly sets 1.0f.
Lines 1245 and 1382 run after `isMuted` holds its final value, so they spell the
same meaning the opposite way.

The pipeline has demanded this flip three times and the owner has ruled against
it three times. **Flipping it breaks mute.** Recorded here with the reasoning so
it can be closed rather than re-raised a fourth time. Out of scope.

### 5.4 Lifecycle, `clear()` and `shutdown()` — both sites measured

Two existing call sites operate on the single player and both must become
both-player operations:

1. **`flushSpeechForRouteChange()`, line ~369** — `voiceInstructionsPlayer.clear()`,
   alongside `pendingSpeech.clear()`, `speechApi.cancel()`, `speechInFlight = false`
   and the `speechEpoch++` guard (SAFEROUTE-282). **Decision, answering v3
   reviewer Q4: `clear()` applies to BOTH players unconditionally.** Reasoning:
   the flush exists so that a route change cannot leave a stale announcement
   about the old route queued. An announcement queued on the player that is not
   currently selected is exactly as stale, and would survive a conditional
   clear and then speak after the reroute. Unconditional is also cheaper to
   reason about than tracking which instance holds what.
2. **Teardown, line ~1096** — `speechApi.cancel()` then
   `voiceInstructionsPlayer.shutdown()`. Must shut down **both**, or the second
   instance leaks its TTS binding. The measured log already shows TTS
   bind/unbind churn, so this is a real leak path, not theoretical.

No per-call-transition construction or destruction anywhere, so that churn is not
amplified.

**Construction timing (answering v3 reviewer Q2).** Decision: construct both
eagerly at view creation. Reasoning: lazy construction of `inCallVoicePlayer` on
the first call would defer cost for riders who never take calls, but it moves a
TTS engine bind onto the moment a call starts — the worst possible moment, when
Telecom is already churning `setMode` 14 times and competing for focus. Eager
construction pays a known cost at a quiet moment instead of an unknown cost at a
busy one. Reviewers may overrule this on low-memory grounds; if so, lazy
construction must still never destroy the instance once built (AC6).

**Instantiation failure (closes v3 finding 2).** If `inCallVoicePlayer` fails to
construct, log it and fall back to `mediaVoicePlayer` for all announcements —
i.e. exactly today's behaviour, which is the defect but not a regression. If
`mediaVoicePlayer` fails to construct, that is today's existing failure mode and
is not changed by this design. A `play()` throwing on the selected player is
handled as today; this design adds no new catch semantics.

### 5.5 Degradation

No call active: exactly today's behaviour. Call active and neither path audible:
fall back to the phone speaker rather than silence. Silence is the defect.

### 5.6 Threading — contract already enforced in code (closes v3 finding 1)

v3's primary critic asserted "current code is single-threaded"; the second critic
correctly flagged that as unverified by the submission. Measured, it is verified
by the code. `enqueueSpeech()` at line ~377:

```
// [SF-244 P2] The no-locking design rests on this being main-thread only. A
// comment saying so is not enforcement: if a future SDK change or refactor
// calls this from a background thread, the queue corrupts silently and the
// symptom would be intermittent lost speech ...
if (android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
    android.util.Log.e("SyncForge", "[SF-244] enqueueSpeech called off the main thread - the queue is not thread-safe")
}
```

So the queue is main-thread by contract, with a loud guard. **Player selection
(§5.1) is performed inside `enqueueSpeech`, so it inherits that contract and
introduces no new locking requirement.** The `isMuted` writes at lines 225 and
1244 are UI/prop callbacks and also main-thread. The one piece of state crossing
threads is the cached call-state boolean written by `OnModeChangedListener`; it
must be `@Volatile` (or equivalent), since the listener is not guaranteed to be
on the main thread. That is the only concurrency obligation this design adds.

### 5.7 iOS parity seam

iOS is a separate ticket and must not be assumed to follow from this. The §5.1
selection rule — *given call state and available outputs, which configuration* —
is implemented as one pure function with no Android types in its signature, so
the iOS side (`AVAudioSession` category/mode, `.allowBluetooth`, `.duckOthers`)
mirrors the same rule rather than re-deriving it.

---

## 6. Root cause

While a telephony call is active, two independent mechanisms each suffice:

1. **Focus.** Telecom holds `AUDIOFOCUS_GAIN`. A player requesting
   `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK` is, on Samsung One UI, commonly refused
   outright rather than granted with ducking.
2. **Routing.** SCO owns the headset link. On classic Bluetooth, A2DP is
   suspended while SCO is active on the same device, so `STREAM_MUSIC` renders to
   the phone's own speaker — the app speaks to a speaker in a tank bag while the
   rider's ear is on SCO.

Mechanism 2 is the more damaging. §5.1 addresses both and does not depend on
knowing which is operative.

---

## 7. Permissions — CORRECTION to v2/v3

**v2 and v3 said `MODIFY_AUDIO_SETTINGS` "must be added". That was wrong and v4
withdraws it.** v3's second critic challenged the necessity and was right to: the
claim was never justified against a specific API call.

Walking the design's actual calls: `AudioManager.getMode()`,
`AudioManager.addOnModeChangedListener()`,
`AudioManager.getDevices(GET_DEVICES_OUTPUTS)`, and constructing
`VoiceInstructionsPlayerOptions` with a `ttsStreamType`/`AudioAttributes`. None of
these require `MODIFY_AUDIO_SETTINGS`, which gates *mutating* global audio state
— `setMode()`, `setSpeakerphoneOn()`, `setStreamVolume()`,
`startBluetoothSco()`. **This design reads audio state and never mutates it.**

So: **no new permission is declared.** If a measured call fails at P2 without it,
it is added then, with the failing call named as the justification. Adding a
permission on speculation is exactly the kind of unforced change SAFEROUTE-309
made expensive.

Also not added, and not needed: `BLUETOOTH_CONNECT` — a runtime permission on API
31+ that would prompt riders. §5.1 reads device *types*, which does not require
it; device *names* would, so names are never read. And `READ_PHONE_STATE` —
avoided by using `AudioManager` mode rather than `TelephonyManager`/
`PhoneStateListener` (§5.2).

---

## 8. Accepted risk — AC4

Voice-call-stream output may mix into the call uplink on some hardware, so the
remote party hears instructions. Owner ruling: speak anyway.

- Can only occur in the §5.1 fallback branch (call active AND no media path).
  Multipoint intercom riders are unaffected.
- No device list, no rider toggle (owner declined both).
- **Recommendation, not a blocker:** disclose it once in release notes or a
  first-run note, so the first rider whose wife hears "turn right in 500 feet"
  knows it is the app. Cheap; protects the support queue.
- Still measured in P3 (§9) and recorded per device. Accepted is not unknown.

---

## 9. Verification plan

Protocol 2 passing is **not** sufficient — this changes runtime audio behaviour
on a device. A device log must confirm behaviour before it reaches the owner's
phone.

1. P3 on the changed range.
2. Instrumented device run with the verbose tags already enabled. Must show,
   inside the call window: the focus request and what was granted; the
   `getOutputForAttrInt` attributes and selected output device; the stream used.
3. Generic HFP headset (the §5.1 fallback branch): active call, navigation
   running, instruction due. Must be heard.
4. Multipoint test (Sena/Cardo if available): media path used, fallback branch
   **not** taken — should be a no-op.
5. **AC6 regression — the SYNCFORGE-239 check.** Change props during active
   navigation while speaking (the twelve prop setters calling `update()`) and
   confirm no audio-focus window shorter than a spoken word — no repeat of the
   measured 145 ms take/abandon from build 1417099. Mandatory.
6. **Mute across both players (§5.3).** Mute, start a call, confirm silence on
   both branches; unmute mid-call and confirm audibility; confirm the sound
   button still toggles correctly (the line-220 path).
7. **Route-change flush with two players (§5.4).** Trigger a reroute while an
   announcement is queued, and confirm nothing from the old route speaks
   afterwards on either instance.
8. AC4 measurement (record, do not block): ask the remote party whether they
   heard it. Record per device.
9. Regression: voice with no call, on A2DP, on speaker, on earpiece, wired.
10. No TTS leak across several call start/stop cycles and a view teardown — both
    instances shut down (`setTTSPkgInfo` / bind-unbind churn in logcat).
11. Confirm no `[SF-244] enqueueSpeech called off the main thread` appears (§5.6).

---

## 10. Questions to reviewers

1. §5.1 — is preferring a surviving media path over the voice-call stream
   correct, or are there devices where A2DP reports as an available output during
   a call but renders nothing? That would invert the ordering.
2. §5.4 — eager construction of both players is chosen over lazy. Is that right
   on low-memory devices, given lazy moves a TTS bind onto call start?
3. §4/§5.1 — given `ttsStreamType` is construction-fixed and AC6 forbids
   destroying an instance, is holding two instances the correct resolution, or is
   there a supported in-place path missed in the measured API surface (§4)?
4. §5.2 — is the sub-millisecond mode-change race acceptable as argued?
5. §7 — confirm no new permission is needed for the calls listed. If any does
   require one, name the call.

---

## 11. Out of scope / do not touch

- The line-220 `soundButton` polarity (§5.3). Owner has ruled three times;
  flipping it breaks mute.
- `apk_download_url` being unused — by design, owner confirmed, not a defect.
- Branch base: `syncforge-317` is branched from the shipped pin `6471b8f2`, NOT
  from `main`/`dc71895`, which lacks SAFEROUTE-288. Do not rebase onto main.
- SYNCFORGE-239's "retune in place" principle is not revisited or weakened; §5.1
  is designed to comply with it (§3, AC6).
- SAFEROUTE-282's `speechEpoch` flush guard and SAFEROUTE-283's drop-before-
  synthesis behaviour are preserved, not altered — only extended to two players.
