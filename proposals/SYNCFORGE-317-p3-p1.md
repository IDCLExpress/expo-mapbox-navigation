# SYNCFORGE-317 Part 3 — Protocol 1 (Design)

Repo: `expo-mapbox-navigation` (fork) — branch `syncforge-317` @ `08b07c7`
File under design: `android/src/main/java/expo/modules/mapboxnavigation/ExpoMapboxNavigationView.kt`
Status: design only. No code written.

Part 1 (`contentType = CONTENT_TYPE_SPEECH`) shipped as build 1445773 — no effect.
Part 2 (two players, stream selection) shipped as build 1448428 — no effect on the
defect, no regression. **Device logs now show why both failed, and neither cause
was what Parts 1 or 2 addressed.**

---

## 1. The measurement that settles it

Device: Galaxy S22 Ultra `R5CT81CKMHJ`, build **1448428** (Part 2) installed and
confirmed. Log: `logcat -d`, 195,102 lines, captured **while the owner was on a
live call with navigation running and no voice audible**. `MediaFocusControl` was
raised to verbose for this capture, which is why this evidence exists now and did
not in the Part 1 and Part 2 investigations.

Call active:
```
10-02 20:16:30.294  SCallUI : AudioModeSupplier - onAudioModeChanged: MODE_IN_CALL
10-02 20:16:50.813  Telecom : CallAudioModeStateMachine$SimCallFocusState: enter: AudioManager#setMode(MODE_IN_CALL)
10-02 20:16:50.817  Telecom : SamsungCallStateAudioParam : setAudioParam CALL_STATUS_VOLTE_CP_VOICE_CALL_ON
```

The app asking for audio focus, and being refused — repeatedly:
```
10-02 20:17:13.058  I MediaFocusControl: requestAudioFocus() from uid/pid 10669/16994
    AA=USAGE_ASSISTANCE_NAVIGATION_GUIDANCE/CONTENT_TYPE_SPEECH
    clientId=android.media.AudioManager@39cc7d9 callingPack=com.idclexpress.saferoute
    req=3 flags=0x0 sdk=36
10-02 20:17:13.058  D MediaFocusControl: requestAudioFocus failed while call
10-02 20:17:13.059  I MediaFocusControl: abandonAudioFocus() from uid/pid 10669/16994 ...
10-02 20:17:13.169  I MediaFocusControl: requestAudioFocus() ... req=3 flags=0x0
10-02 20:17:13.170  D MediaFocusControl: requestAudioFocus failed while call
10-02 20:17:14.135  I MediaFocusControl: requestAudioFocus() ... req=3 flags=0x0
10-02 20:17:14.135  D MediaFocusControl: requestAudioFocus failed while call
```
79 `MediaFocusControl` lines in the window. uid 10669 is SafeRoute (`u0a669`).

### What this proves

**A. Samsung refuses app audio focus unconditionally during a call.**
`requestAudioFocus failed while call` is a blanket refusal. It is not a function of
`focusGain` — `req=3` is `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK`, and the refusal
message names the call state as the reason, not the gain. Changing `focusGain`
to `AUDIOFOCUS_GAIN` or `..._TRANSIENT_EXCLUSIVE` would have been another wasted
build. Even Telecom's own non-call client is refused the same way at 20:16:56
(`AA=USAGE_VOICE_COMMUNICATION ... req=2 flags=0x4` → `failed while call`).

**B. Part 2's selection logic took the wrong branch.**
The refused request carries `AA=USAGE_ASSISTANCE_NAVIGATION_GUIDANCE`, which is
the **media** player's configuration. The in-call player uses
`USAGE_VOICE_COMMUNICATION`. And the `[SYNCFORGE-317]` log line that fires on the
in-call branch appears **0 times** in 195,102 lines. So `hasMediaOutputPath()`
returned true and the media player was selected throughout.

Corroborated: `MediaFocusControl: selectFocusStack, uid = 10669, appDevice = 0,
device = 80` — `0x80` is `DEVICE_OUT_BLUETOOTH_A2DP`. A2DP **is** reported as an
available output during the call.

**This answers P1 v4 reviewer question 1 directly, and the answer is the one that
inverts the design:** the headset reports A2DP as available during a call, but
navigation audio on `STREAM_MUSIC` is not heard. Preferring a "surviving media
path" is wrong.

**C. Why Parts 1 and 2 both failed.** Neither touched focus. Part 1 changed a
routing hint; Part 2 changed stream selection. Both are downstream of a focus
request that is refused before any audio is produced.

### Correction to the Part 2 design record

P1 v3 §4 and v4 §4 state that `AudioFocusDelegate` "cannot implement this fix,"
reasoning that it is only `requestFocus()`/`abandonFocus()` and has no influence
over stream type or routing. The stream claim is correct and stands. **The
conclusion was wrong.** Focus, not routing, is the binding constraint, and that
interface is the only lever over it. Recorded here rather than quietly reversed.

---

## 2. Measured API surface

`javap` on `voice-ndk27-3.11.0.aar` — bytecode, not documentation.

```java
public MapboxVoiceInstructionsPlayer(Context, String, VoiceInstructionsPlayerOptions, AudioFocusDelegate);
public MapboxVoiceInstructionsPlayer(Context, String, VoiceInstructionsPlayerOptions, AsyncAudioFocusDelegate);
public MapboxVoiceInstructionsPlayer(Context, String, VoiceInstructionsPlayerOptions, AsyncAudioFocusDelegate, Provider<Timer>);
public MapboxVoiceInstructionsPlayer(Context, String, VoiceInstructionsPlayerOptions);
public MapboxVoiceInstructionsPlayer(Context, String);

public interface AudioFocusDelegate {
    public abstract boolean requestFocus();
    public abstract boolean abandonFocus();
}
```

Two facts that make Part 3 possible:
1. A custom `AudioFocusDelegate` **can be injected through a public constructor**.
   Part 2's design did not know this; it had only read the three-argument form.
2. `requestFocus()` returns a `boolean` **which the player acts on**. A delegate
   that reports success lets playback proceed.

Also present and not yet investigated: `AudioFocusDelegateProvider`,
`AudioFocusRequestCallback`, `AsyncAudioFocusDelegate`. See §6 question 3.

Unchanged from Part 2 and still binding: `ttsStreamType`/`streamType` are fixed at
construction (no setter), `updateLanguage()` and `volume()` mutate in place, and
`voiceInstructionsPlayer` is a `private var`.

Also still true, from the Part 1 comment at lines 170–174: `STREAM_VOICE_CALL`
with **no** call active routes guidance to the earpiece instead of the speaker.
The configuration must remain call-state dependent.

---

## 3. Design

### 3.1 Invert the selection rule (fixes finding B)

```
if (no call active) -> mediaVoicePlayer    [unchanged, and measured working on A2DP]
else                -> inCallVoicePlayer
```

`hasMediaOutputPath()` and the `MEDIA_OUTPUT_TYPES` set are **deleted**. Their
purpose was to prefer a surviving media path during a call, and §1.B measures that
preference as wrong on real hardware: A2DP is reported, and is not heard.

This also removes the `getDevices()` call, its failure handling, and the open
question about device types going stale — the P1 v4 findings about all three
become moot rather than answered.

The multipoint case (Sena, Cardo) that motivated the preference is not abandoned:
it becomes a question to verify on that hardware (§6 question 1), not an
assumption baked into the code.

### 3.2 A focus delegate that does not depend on the grant (fixes finding A)

Inject a custom `AudioFocusDelegate` into **`inCallVoicePlayer` only**:

- `requestFocus()` — attempt the real system request, ignore its result, return
  `true`. Attempting it matters: on hardware that *does* grant focus during a
  call, the system is still told, so ducking and bookkeeping work properly. On One
  UI the request is refused and the delegate reports success anyway, so the player
  proceeds to speak. Audio focus in Android is cooperative, not enforced at the
  mixer, which is what makes this work rather than merely lie.
- `abandonFocus()` — abandon any real focus actually held, return `true`.

`mediaVoicePlayer` keeps the SDK's default delegate, untouched. It works today and
is measured working.

**Containment, and this is the point of putting the delegate on only one
instance:** the bypass can only ever apply while a call is active, because
`inCallVoicePlayer` is selected only then (§3.1). With no call in progress nothing
about focus behaviour changes, so SafeRoute cannot talk over the rider's music,
another navigation app, or a podcast. The blast radius is exactly the case the
owner asked for and nothing else.

### 3.3 What this deliberately does

It speaks over a live call without the system's permission. That is the owner's
explicit ruling ("Speak anyway", 2026-10-01) and the reported defect
("it can't override the call"). Stated plainly so it is a decision on the record
rather than a side effect:

- The rider hears navigation mixed with the call rather than instead of it.
- On hardware where the voice-call stream reaches the uplink, the remote party may
  hear instructions. Owner has accepted this; AC4 is measure-and-document.
- No device allow/block list and no rider toggle (owner declined both).

### 3.4 Unchanged from Part 2 — not reopened

Both players constructed once at view creation and never destroyed
(`SYNCFORGE-239`, measured at a 145 ms stranded-focus window on build 1417099).
Mute applied to both at all three volume sites. `clear()` on both at route-change
flush (`SAFEROUTE-282`). `shutdown()` on both at teardown. `updateLanguage()` on
both. `SAFEROUTE-283` drop-before-synthesis preserved. The sound-button polarity
at the toggle site is correct and must not be flipped — it reads the pre-toggle
value of `isMuted`; see the comment at that site.

Part 2 is measured as having caused **no regression**: the owner confirms
navigation voice works normally over Bluetooth on build 1448428. Nothing in Part 2
is reverted; Part 3 changes the selection rule and adds the delegate.

### 3.5 No new permission

`MODIFY_AUDIO_SETTINGS` is not required and is not added. The design reads audio
mode and requests/abandons focus; it never mutates global audio state
(`setMode`, `setSpeakerphoneOn`, `setStreamVolume`, `startBluetoothSco`). Removing
`getDevices()` (§3.1) reduces the surface further. `BLUETOOTH_CONNECT` was only
needed for device names, which are no longer read at all. `READ_PHONE_STATE` is
avoided by using `AudioManager.getMode()`.

---

## 4. Risks

1. **Focus-free playback may still be suppressed.** The premise is that Android
   focus is advisory and the refusal only stops Mapbox's player from *trying*.
   If Samsung also suppresses `STREAM_VOICE_CALL` output from a non-focus-holding
   app at the policy layer, this design fails too. That is the single thing the
   next device log must confirm, and the log now has `APM_AudioPolicyManager` at
   verbose to show `getOutputForAttrInt` and the selected device.
2. **Uplink bleed** (§3.3) — accepted by owner ruling, still measured.
3. **Voice colliding with call audio.** The rider hears both at once. No ducking
   is possible, since ducking is what focus buys. Reviewers should say whether
   lowering the in-call player's volume (`volume()` mutates in place) is worth it
   for intelligibility, and whether that conflicts with the mute logic in §3.4.
4. **Repeated refused requests.** The log shows request/abandon cycling several
   times per second. If the real request is still attempted (§3.2), that churn
   continues and is visible in logs. Harmless but noisy; reviewers may prefer
   skipping the real attempt while `MODE_IN_CALL` is known.
5. **Other OEMs.** `failed while call` is Samsung's string. The design does not
   depend on detecting Samsung, so it should be neutral elsewhere, but it is
   measured on one device only.

---

## 5. Verification plan

Protocol 2 passing is not sufficient. A device log must confirm behaviour before
this reaches the owner's phone.

1. P3 on the changed range.
2. Device run with navigation active and a live call. Must show: the
   `[SYNCFORGE-317]` in-call-branch log line appearing (it is absent today, which
   is finding B), the delegate reporting success, and
   `APM_AudioPolicyManager: getOutputForAttrInt` naming the stream and output
   device actually used.
3. **The rider hears the instruction during the call.** This is the acceptance
   test and no amount of log evidence substitutes for it.
4. Regression, all with no call active: voice on A2DP (measured working on 1448428
   — must stay working), speaker, earpiece, wired.
5. **No-call focus behaviour unchanged.** Start music, then navigate with no call.
   Navigation must duck the music as it does today, proving the bypass is not
   leaking outside the in-call branch (§3.2 containment).
6. Mute across both players, including mid-call, and the sound-button toggle.
7. `SYNCFORGE-239` regression: change props during active navigation while
   speaking; no audio-focus window shorter than a word, no repeat of the 145 ms
   take/abandon from 1417099.
8. Route-change flush with two players — nothing from the old route speaks after a
   reroute.
9. No TTS engine leak across several call start/stop cycles and a view teardown.
10. AC4: ask the remote party whether they heard it. Record per device.

---

## 6. Questions to reviewers

1. §3.1 — is deleting the media-path preference outright correct, or should the
   multipoint intercom case (Sena, Cardo keeping A2DP alive during a call) be
   preserved somehow? The measurement says the preference is wrong on a generic
   HFP headset; it is untested on an intercom, and the owner's fleet is mixed and
   uncontrolled.
2. §3.2 — is attempting the real focus request and ignoring the result better than
   not asking at all while in a call? Trade-off is correctness on hardware that
   would grant it, against log churn and pointless work on hardware that will not.
3. §2 — `AudioFocusDelegateProvider` and `AsyncAudioFocusDelegate` exist in the
   AAR and I have not characterised them. Is one of them the SDK's sanctioned
   extension point, making a hand-rolled `AudioFocusDelegate` the wrong shape?
4. §4.1 — is there a known Samsung policy-layer suppression of a
   non-focus-holding app's `STREAM_VOICE_CALL` output that would defeat this
   before it reaches a device?
5. §4.3 — should the in-call player's volume be reduced so the instruction is
   intelligible alongside call audio, and does that interact badly with the mute
   volume sites in §3.4?

---

## 7. Out of scope / do not touch

- The sound-button polarity (see §3.4 and the comment at that site). The owner has
  ruled three times; flipping it breaks mute.
- `apk_download_url` being unused — by design, owner confirmed.
- Branch base: `syncforge-317` descends from the shipped pin `6471b8f2`. Do not
  rebase onto `main`/`dc71895`, which lacks SAFEROUTE-288.
- `SYNCFORGE-239` "retune in place, never replace the player" — not weakened; §3.4
  complies.
- The ten pre-existing findings tabled in
  `docs/decisions/SYNCFORGE-317-P2-override.md` remain open and out of scope here.
