# SYNCFORGE-317 Part 2 — Protocol 1 (Design) — v3

Repo: `expo-mapbox-navigation` (fork) — branch `syncforge-317` @ `5008cf7`
File under design: `android/src/main/java/expo/modules/mapboxnavigation/ExpoMapboxNavigationView.kt` (1491 lines)
Plus: app manifest (one normal permission — §7)
Status: design only. No code written.

History: v1 `35b1a27b` CONDITIONAL/CONDITIONAL → v2 `aab8af73` APPROVED/**REJECTED**.
The v2 halt was correct and v3 changes the core mechanism as a result. See §3.

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
case when present. No device allow/block lists. No per-rider toggle (the owner
declined "let the rider choose").

**AC6 (NEW — see §3).** The fix must not reintroduce the SYNCFORGE-239 defect.
The voice player instance must never be destroyed while the view is alive.

---

## 2. Measured evidence

Device: Galaxy S22 Ultra `R5CT81CKMHJ`, `com.idclexpress.saferoute`,
`versionCode=1445773`, `minSdk=24 targetSdk=36`.
Log: one `logcat -d`, 270,472 lines, 2026-10-01 19:01:51 → 20:23:51.
Call window isolated: 19:02:26.910 → 19:03:30.115.

- Call active, holding focus: `CallAudioModeStateMachine$SimCallFocusState:
  AudioManager#requestAudioFocus(CALL)`; `AudioManager#setMode(MODE_IN_CALL)`;
  `AS.AudioService: setMode(mode=2, caller=com.android.server.telecom)`;
  `SamsungCallStateAudioParam: CALL_STATUS_VOLTE_CP_VOICE_CALL_ON`
- Routed to Bluetooth SCO throughout: `getConnectedDevices - hfp : <addr>`;
  `calculateBaselineRoute - audio routing to AudioRoute[Type=TYPE_BLUETOOTH_SCO, ...]`;
  `Event: AUDIO_ROUTE_TO, dest=AudioRoute[Type=TYPE_BLUETOOTH_SCO, ...], reason=ACTIVE_FOCUS`.
  333 Bluetooth lines in window; reverts to `EARPIECE` only at teardown 19:03:29.
- App voice path initialised during the call: `Connected successfully to TTS
  engine: com.google.android.tts` (19:02:39); `MARsPolicyManager: setTTSPkgInfo :
  10669` — uid 10669 is SafeRoute (`u0a669`); unbound 19:02:59.
- Owner report: visual directions produced, no voice heard.
- `setMode` fires **14 times** in this one 64-second call.

### Merged-manifest measurement (from shipped `SafeRoute-1445773.apk`, AXML decoded)

16 permissions declared. Probed:

```
MODIFY_AUDIO_SETTINGS -> no
BLUETOOTH_CONNECT     -> no
READ_PHONE_STATE      -> no
```

1. `MODIFY_AUDIO_SETTINGS` not held and **not** inherited from the Mapbox AARs.
   Must be added. **Normal** permission — install-time, no prompt, nothing a
   rider sees, no interaction with SAFEROUTE-309.
2. `BLUETOOTH_CONNECT` not held; it is a **runtime** permission on API 31+. The
   design must not need it. Output *types* from `AudioManager.getDevices()` are
   available without it; device *names* are not. Types only.
3. `READ_PHONE_STATE` not held and not needed — confirms using `AudioManager`
   mode over `TelephonyManager`/`PhoneStateListener`.

### Instrument limitation (still binding)

App-level focus is not logged by default on this device: across 270,472 lines
`MediaFocusControl` = 0, `AudioFocusInfo` = 0, `AUDIOFOCUS_` = 0; the only 4
`requestAudioFocus` hits are Telecom's own. `getOutputForAttrInt` appears twice,
both outside the call window.

**"The player never requested focus" is therefore NOT an established fact** and
must not be asserted. Verbose tags are now set on the device
(`MediaFocusControl`, `AudioManager`, `AS.AudioService`, `APM_AudioPolicyManager`,
`AudioTrack`, `TextToSpeech`, `ReactNativeJS`, Mapbox) and a live `logcat` is
writing to disk — the ring buffer is capped at 5 MiB and rolls in ~80 minutes, so
the ring alone is insufficient.

---

## 3. Why v2 was rejected, and what changed

The v2 second-critic REJECTED was aimed at the **primary critique**, not the
design: the primary claimed to have scanned "the relevant Kotlin" and asserted
facts about current code, for a submission that states "design only. No code
written." The second critic was right to flag that. **Consequence: v2's primary
APPROVED is discounted — it reviewed an artifact that was not submitted.**

The second critic also raised three findings against the design. Investigating
the first of them against the actual file surfaced something neither critic knew,
and it invalidates v2's core mechanism.

### SYNCFORGE-239 — a prior, device-measured ruling in this same file

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

**v2's Option A — reconstructing the player on call-state change — directly
contradicts this.** It is a narrower reconstruction than the one SYNCFORGE-239
removed (call transitions only, debounced, rather than all twelve prop setters),
but the failure mode is the same class: destroying a player that may be speaking,
and stranding audio focus. Shipping v2 would have risked re-breaking a defect
already fixed with device measurements. This is now AC6.

v3 therefore **abandons reconstruction entirely** in favour of §5.1.

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
  cannot simply be retuned the way `updateLanguage()` and `volume()` can.
- `updateLanguage(String)` and `volume(SpeechVolume)` DO exist and mutate in
  place — that is what SYNCFORGE-239 means by "retune it in place".
- `AudioFocusDelegate` is only `requestFocus()`/`abandonFocus()`; no influence on
  stream or routing. It cannot implement this fix.
- `voiceInstructionsPlayer` is `private var` (line 175) — reassignment is
  *possible*, but AC6/§3 forbids destroying an instance.

Also measured, from the existing comment at lines 170–174 (written during Part 1):
`STREAM_VOICE_CALL` while **no** call is active routes guidance to the earpiece
instead of the speaker. So a single always-voice-call player is not an option
either; the choice is genuinely call-state dependent.

Part 1 changed `contentType` only, which is a routing *hint* and does not move
output off `STREAM_MUSIC` — consistent with Part 1 having no effect, as reported.

---

## 5. Design

### 5.1 Two long-lived players, selected per announcement (replaces v2 Option A)

Construct **both** players once, at view creation, and keep both alive for the
life of the view. Neither is ever destroyed mid-life. Select which one to
`play()` on at announcement time.

- `mediaVoicePlayer` — `ttsStreamType = STREAM_MUSIC`, plus Part 1's
  `CONTENT_TYPE_SPEECH`. Identical to today's single player.
- `inCallVoicePlayer` — `ttsStreamType = STREAM_VOICE_CALL`, usage and content
  type matched to speech on the communication path.

This satisfies AC6 on its own terms. SYNCFORGE-239's requirement is that there is
never a moment when the speaking component does not exist, and no audio focus
left stranded by a destroyed instance. Two instances that both live for the full
view lifetime satisfy that strictly more easily than one — nothing is ever torn
down, so there is nothing to strand.

It also dissolves most of v2's complexity: with no reconstruction there is no
thrash, so v2's 750 ms debounce (and the open question about its value) is no
longer needed. The 14 `setMode` events per call become harmless — they are read,
not acted upon.

**Selection rule, evaluated when an announcement is enqueued:**

```
if (no call active)                  -> mediaVoicePlayer    [exactly today's behaviour]
else if (a media output path exists) -> mediaVoicePlayer
else                                 -> inCallVoicePlayer
```

"A media output path exists" is read from
`AudioManager.getDevices(GET_DEVICES_OUTPUTS)` by **device type only** —
`TYPE_BLUETOOTH_A2DP`, `TYPE_WIRED_HEADSET`, `TYPE_WIRED_HEADPHONES` — never by
name, because `BLUETOOTH_CONNECT` is not held (§2).

Why this ordering, and it follows directly from AC5: Sena and Cardo intercoms are
frequently multipoint and keep A2DP alive during a call. Those riders keep the
normal path, nothing changes for them, and the uplink is never touched — which
also minimises AC4 exposure without a device list. Only when no media path
survives (generic HFP, the AC5 baseline) does selection fall to the voice-call
player.

**`getDevices()` error handling (closes v2 second-critic finding 3):** on an
exception, an empty list, or any ambiguous result *while a call is active*, treat
it as "no media path" and select `inCallVoicePlayer`. Rationale: AC1 and the
owner's "speak anyway" both say audibility wins, and the voice-call player is the
branch that works in the hard case. When no call is active, always
`mediaVoicePlayer` — never guess into the earpiece (§4).

### 5.2 Call-state detection and API fallback

- API 31+: `AudioManager.OnModeChangedListener`, cached into a boolean.
- API 24–30: no listener. Read `AudioManager.getMode()` **at announcement enqueue
  time**. Sufficient, because the only moment the choice matters is the moment an
  announcement is about to be spoken. No polling loop.

Call-active means `MODE_IN_CALL` **or** `MODE_IN_COMMUNICATION` — riders use
WhatsApp and Messenger calls, not only cellular. Neither path needs
`READ_PHONE_STATE` (§2).

### 5.3 Mute must be applied to BOTH players (closes v2 second-critic finding 1)

This was a real gap in v2 and the second critic was right to raise it. Measured
from the file, mute is **per-instance player volume state**, not a global:

- line 118: `private var isMuted = false`
- line 220 (sound button): `voiceInstructionsPlayer.volume(SpeechVolume(if (isMuted) 1.0f else 0.0f))`
- line 1245 (`setIsMuted` prop): `volume(SpeechVolume(if (isMuted) 0.0f else 1.0f))`
- line 1382 (`update()`, every call): `volume(SpeechVolume(if (isMuted) 0.0f else 1.0f))`

**Requirement:** every site that currently sets volume on the single player must
set it on **both** players, so a rider who mutes navigation stays muted whichever
player is selected. A single missed site is an unmuted announcement, and under
AC4 that announcement may now reach the person on the call — so this is the
highest-severity detail in the design.

Severity is partly mitigated by existing behaviour, which must be preserved:
SAFEROUTE-283 (line ~402) drops muted announcements **before synthesis**, so a
muted announcement never reaches either player at all. Volume is the second line
of defence, not the only one. Both must hold.

#### The line-220 polarity is CORRECT — do not "fix" it

Recording the reasoning, because the pipeline has demanded this flip three times
and the owner has ruled against it three times. Now that the code is in front of
us, here is why the reviewers are wrong:

Line 220 reads `if (isMuted) 1.0f else 0.0f`, which looks inverted against lines
1245 and 1382. It is not. Line 220 is inside the sound button's click handler and
runs **before** line 225, which is `isMuted = !isMuted`. At line 220 `isMuted`
still holds the **pre-toggle** value. If the rider was muted and taps to unmute,
line 220 correctly sets volume to 1.0f. Lines 1245 and 1382 run **after**
`isMuted` already holds its final value, so they use the opposite spelling for
the same meaning.

Reviewers reading line 220 in isolation see an inversion. Reading it with line
225 shows it is right. **Flipping it breaks mute.** Out of scope here; this note
exists so the finding can be closed with reasoning rather than re-raised a
fourth time.

### 5.4 Lifecycle and resource cost (closes v2 second-critic finding 2)

- Both players constructed at view creation; neither destroyed until view
  teardown.
- Line 1096 currently calls `voiceInstructionsPlayer.shutdown()` on teardown.
  That must become a shutdown of **both**, or the second instance leaks its TTS
  binding.
- No per-call-transition construction or destruction at all, so the TTS
  bind/unbind churn visible in the measured log is not amplified.
- Accepted cost: two TTS engine bindings for the life of the view instead of one.
  Reviewers should say whether that is acceptable on low-memory devices, and
  whether `inCallVoicePlayer` should instead be constructed lazily on the first
  call and then kept forever (never destroyed, preserving AC6, but deferring the
  cost for riders who never take calls). **Open question — see §10.**
- `voiceInstructionsPlayer.clear()` (line 368) and the SAFEROUTE-282 behaviour
  (line ~552) must be audited against two instances; `clear()` on the wrong
  instance would leave a queue on the other.

### 5.5 Degradation

No call active: exactly today's behaviour. Call active and neither path audible:
fall back to the phone speaker rather than silence. Silence is the defect.

### 5.6 iOS parity seam

iOS is a separate ticket and must not be assumed to follow from this. To keep
parity cheap, the §5.1 selection rule — *given call state and available outputs,
which audio configuration* — is implemented as one pure function with no Android
types in its signature, so the iOS side (`AVAudioSession` category/mode,
`.allowBluetooth`, `.duckOthers`) mirrors the same rule rather than re-deriving it.

---

## 6. Root cause (unchanged)

While a telephony call is active, two independent mechanisms each suffice to
produce silence in the rider's ear:

1. **Focus.** Telecom holds `AUDIOFOCUS_GAIN`. A player requesting
   `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK` is, on Samsung One UI, commonly refused
   outright rather than granted with ducking.
2. **Routing.** SCO owns the headset link. On classic Bluetooth, A2DP is
   suspended while SCO is active on the same device, so `STREAM_MUSIC` renders to
   the phone's own speaker — the app speaks to a speaker in a tank bag while the
   rider's ear is on SCO.

Mechanism 2 is the more damaging here. §5.1 addresses both and does not depend on
knowing which is operative.

---

## 7. Permission change

Add `MODIFY_AUDIO_SETTINGS`. Measured absent and not inherited (§2). Normal
permission: install-time, no prompt, no rider-visible change.

Explicitly NOT added: `BLUETOOTH_CONNECT` (would prompt riders — §5.1 avoids
needing it) and `READ_PHONE_STATE` (not needed — §5.2).

---

## 8. Accepted risk — AC4

On some hardware, voice-call-stream output may mix into the call uplink and the
remote party hears the instructions. Owner ruling: speak anyway.

- Can only occur in the §5.1 fallback branch (call active AND no media path).
  Multipoint intercom riders are unaffected.
- No device list, no rider toggle (owner declined both).
- **Recommendation, not a blocker:** disclose it once in release notes or a
  first-run note, so the first rider whose wife hears "turn right in 500 feet"
  knows it is the app and not the phone. Cheap; protects the support queue.
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
   navigation while speaking (the twelve prop setters that call `update()`) and
   confirm no audio-focus window shorter than a spoken word, i.e. no repeat of
   the measured 145 ms take/abandon from build 1417099. This is the regression v2
   would have caused and is mandatory.
6. **Mute across both players (§5.3).** Mute, start a call, confirm silence on
   both branches. Then unmute mid-call and confirm audibility. Then confirm the
   sound button still toggles correctly — the line-220 path.
7. AC4 measurement (record, do not block): ask the remote party whether they
   heard it. Record per device.
8. Regression: voice with no call, on A2DP, on speaker, on earpiece, wired.
9. No TTS leak across several call start/stop cycles and a view teardown
   (`setTTSPkgInfo` / bind-unbind churn in logcat; both instances shut down).

---

## 10. Questions to reviewers

1. §5.1 — is preferring a surviving media path over the voice-call stream
   correct, or are there devices where A2DP reports as an available output during
   a call but renders nothing? That would invert the ordering.
2. §5.4 — two players for the life of the view, or lazily construct
   `inCallVoicePlayer` on first call and then keep it forever? Both satisfy AC6.
   Which is right on low-memory devices?
3. §5.1/§4 — given `ttsStreamType` is construction-fixed and AC6 forbids
   destroying an instance, is holding two instances the correct resolution, or is
   there a supported in-place path I have missed in the measured API surface (§4)?
4. §5.4 — `clear()` (line 368) and SAFEROUTE-282 (line ~552) with two instances:
   should `clear()` apply to both unconditionally, or only to the selected one?

---

## 11. Out of scope / do not touch

- The line-220 `soundButton` polarity. See §5.3 for why it is correct. The owner
  has ruled three times; flipping it breaks mute.
- `apk_download_url` being unused — by design, owner confirmed, not a defect.
- Branch base: `syncforge-317` is branched from the shipped pin `6471b8f2`, NOT
  from `main`/`dc71895`, which lacks SAFEROUTE-288. Do not rebase onto main.
- SYNCFORGE-239's "retune in place" principle is not being revisited or weakened;
  §5.1 is designed to comply with it (§3, AC6).
