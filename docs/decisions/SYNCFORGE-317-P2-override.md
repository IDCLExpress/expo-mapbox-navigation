# SYNCFORGE-317 P2 — lead-coder override of a REJECTED verdict

Task: `91a7d510-b825-439f-b959-9c64ab1285cc` (Protocol 2, `mapbox-nav-fork`,
`syncforge-317` @ `86ccfa9`)
Verdicts: **primary REJECTED**, second UNKNOWN (no parseable verdict token;
substantive text returned and read).
Decision: **overridden**. Change stands. Reasoning below, per the owner's ruling
that a rejection may be overridden only after scrutiny and only with the
reasoning written down.

## The rejection's own findings, judged one at a time

**A + C — mute polarity in the sound button. OVERRIDDEN as incorrect.**
The same finding counted twice. The claim is that
`volume(SpeechVolume(if (isMuted) 1.0f else 0.0f))` in the sound button is
inverted against `if (isMuted) 0.0f else 1.0f` in `setIsMuted` and `update()`.

It is not. The sound-button site runs inside the click handler, *before*
`isMuted = !isMuted` a few lines below, so `isMuted` there still holds the
pre-toggle value. Muted rider taps to unmute, volume goes to 1.0f: correct. The
other two sites run after `isMuted` holds its final value, so they spell the same
meaning the opposite way. A toggle handler and a state setter necessarily read
opposite.

Three independent reasons to override rather than defer:
1. The code comment at that site already states this, and the critique quotes the
   comment ("The comment says 'polarity is correct'") and proceeds anyway.
2. **The second critic in this same run independently refuted it**, reaching the
   same conclusion from the same evidence: "The logic is correct for a toggle
   button. **Verdict: Challenge.**"
3. Finding C is internally self-contradictory — it asserts that both sites use
   `if (isMuted) 0.0f else 1.0f` and then that the sound button uses
   `if (isMuted) 1.0f else 0.0f`.

The owner has ruled against this flip three times on the record. This is the
fourth demand. **Flipping it breaks mute.** Not changed.

**I — `android.content.res.Resources` unused. OVERRIDDEN as incorrect.**
It is used, at file scope: `val PIXEL_DENSITY = Resources.getSystem().displayMetrics.density`.
The second critic also flagged this claim as wrong.

**E — comment bloat. OVERRIDDEN as not a defect.**
The volume of comment is deliberate and is what Pipeline Pro requires: findings,
measurements and the reasoning for a decision are recorded next to the code they
govern. SYNCFORGE-239 is the proof — that comment is the only reason this ticket
did not reintroduce a fixed defect. Moving design rationale to a README is how it
stops being read.

**G (log tags), J (`setVisibility` vs `visibility`). Noted, not defects.**
Pre-existing style, unchanged by this ticket.

## Real findings, out of scope, recorded for scheduling — NOT ignored

None of these is introduced by this change; all predate it and none is in the
diff. Per the owner's rule they are written down with file and reasoning rather
than dropped.

| # | Finding | Note |
|---|---|---|
| B | Force-unwraps: `currentCoordinates!!`, `currentMapMatchingRequestId!!`, `currentRoutesRequestId!!`, `currentRouteProfile!!`, `currentRouteExcludeList!!`, `currentCustomRasterSourceUrl!!` | Real crash surface. Guarded in `update()` today, but the guarantee is not local to the use site. Own ticket. |
| D | `speechApi` / both players not nulled after `shutdown()`/`cancel()`; no idempotency guard if `onDetachedFromWindow` runs twice | This change adds a second `shutdown()` call, so it touches the same area. Low severity but genuine. Own ticket. |
| F | `routeSignature()` re-joins strings on every `update()` | Twelve prop setters call `update()`. Measure before optimising. |
| H | No cleanup of `EventDispatcher` listeners | Possible leak if strong refs are held. |
| — | `enqueueSpeech` main-thread violation logs but does not throw | From task `70249c35`. SF-244 chose log-not-crash deliberately ("not worth ending a drive over"); revisit only as a debug-build assertion. |
| — | `findViewById` on Mapbox-owned icon IDs has no null check | Silent failure on an SDK layout change. |
| — | `requestRoutes` / `requestMapMatchingRoutes` option-builder duplication | Refactor. |
| — | Hardcoded `"raster-source"` / `"raster-layer"` / `"water"` layer IDs | Breaks on complex styles. |
| — | Route requests short-circuit silently on missing inputs | Add a log. |
| — | Mute polarity could be unified by toggling `isMuted` *before* applying volume | Behaviour-preserving in principle and would end this recurring finding permanently. **Mute is on the owner's do-not-touch list; this needs the owner's decision, not mine.** |

## What is NOT claimed by this override

- The change is **not compiled.** There is no Kotlin toolchain on the build
  machine.
- **No device test has run.** The standing rule is that Protocol 2 passing is not
  sufficient for anything that changes runtime audio behaviour on the device, and
  a device log must confirm the behaviour before it reaches the owner's phone.
  That gate is unaffected by this override and still closed.
- The two items P1 v4 left NOT VERIFIED remain open: whether
  `getDevices()` reports A2DP during an active call as genuinely *routable*
  rather than merely present, and whether the player's internal
  `AudioFocusDelegate` honours the configured `ttsStreamType` when it requests
  focus. Both are device measurements.

## Pipeline reliability notes from this ticket

1. **`Code-mode dispatch` reads the committed branch, not the working tree.**
   Task `5f6cb9aa` was dispatched against uncommitted local edits and reviewed the
   *unpatched* file — zero mentions of `selectVoicePlayer`, `inCallVoicePlayer` or
   `hasMediaOutputPath`, and pre-patch line numbers. Its REJECTED was void. Always
   commit and push before Protocol 2, and probe the result for a symbol that only
   exists in the new code before trusting the verdict.
2. **Task `aab8af73` (P1 v2): the primary claimed to have "scanned the relevant
   Kotlin"** for a submission that stated "design only. No code written." Its
   APPROVED was discounted. The second critic caught it, which is why the halt
   mattered — and why neither critic outranking the other is the right rule.
3. **Task `91a7d510`: the primary mentions `inCallVoicePlayer` but not
   `MEDIA_OUTPUT_TYPES`, `companion` or `USB_HEADSET`,** all present at the
   reviewed commit `86ccfa9`. Possibly a stale blob from the Contents API, possibly
   just unmentioned. Flagged, not concluded.

---

# Part 3 — override of task `3b938a56` (primary REJECTED, second UNKNOWN)

Protocol 2 on `bb1109c`. Primary REJECTED; second returned 10,391 characters of
substantive text but no parseable verdict token (UNKNOWN). Both read the new code.
Decision: **overridden**, with one finding accepted as real and promoted to its own
ticket.

## A + B — mute polarity. OVERRIDDEN as incorrect. Fifth demand.

Both critics agree with each other this time, and both are wrong. The second
critic states:

> If `isMuted` is `false` (sound is currently ON), the volume is set to `0.0f`
> (mute), `isMuted` becomes `true`, and the icon is set to
> `R.drawable.icon_sound` (sound ON). This is incorrect.

That is a mis-evaluation of the conditional. The expression is
`if (isMuted) R.drawable.icon_sound else R.drawable.icon_mute`. With
`isMuted == false` it takes the **else** branch, which is `icon_mute` — not
`icon_sound` as claimed. The stated reasoning inverts the branch it is reasoning
about.

The icon convention is settled by `createSoundButton` itself, line 1029:

```kotlin
.setImageResource(R.drawable.icon_sound)
```

That is the button's initial icon, set at construction, when `isMuted` is `false`.
So `icon_sound` is what shows **while unmuted**: the icon displays the current
state, not the pending action. Walking both paths against that convention:

| before click | volume set | icon set | after |
|---|---|---|---|
| `isMuted=false` (unmuted, `icon_sound`) | `0.0f` muted | `icon_mute` | muted, muted icon |
| `isMuted=true` (muted, `icon_mute`) | `1.0f` audible | `icon_sound` | unmuted, sound icon |

And `setIsMuted` at line 1433, evaluated **after** assignment:
`if (isMuted) icon_mute else icon_sound` → muted shows `icon_mute`. **Identical
semantics.** Finding B's claim of prop/button inconsistency does not survive:
both paths end on the same icon for the same state. A toggle handler reading
pre-toggle state and a setter reading post-assignment state necessarily spell the
same meaning opposite ways.

Owner has ruled against this flip three times; the pipeline has now demanded it
five. **Flipping it breaks mute.** Not changed.

## C — deprecated focus API without version gating. NOT a defect.

Deliberate. `minSdk` is 24 and `AudioFocusRequest` is API 26+, so the deprecated
three-argument form is the one call that behaves identically across the whole
supported range. The delegate discards the result by design (§3.2 of the Part 3
design), so the richer API buys nothing here. Gating would add two code paths to
reach the same ignored outcome.

## D — `maneuverApi` / `tripProgressApi` rebuilt on every `update()`. REAL. ACCEPTED.

This one is correct and the pipeline earned it. Measured:

```
1560:            speechApi = MapboxSpeechApi(...)        <- INSIDE if (lastAppliedLocale != currentLocale)
1587:        maneuverApi = MapboxManeuverApi(...)        <- UNGUARDED
1595:        tripProgressApi = MapboxTripProgressApi(...) <- UNGUARDED
```

The second critic's premise is wrong for `speechApi` — it sits inside the locale
guard and is not rebuilt per update. But `maneuverApi` and `tripProgressApi` are
reassigned **unconditionally on every `update()`**, and twelve prop setters call
`update()`.

This is the same pattern SYNCFORGE-239 removed for the voice player — rebuilding a
live component whenever any prop changes — left in place for two neighbours.
Whether it leaks depends on whether those two hold cancellable resources;
`maneuverApi.cancel()` exists, which suggests they might.

**Not fixed here.** It is pre-existing, untouched by Parts 1–3, and outside this
ticket's range; folding an unrelated lifecycle change into an audio fix is how a
diff becomes unreviewable. Raised as its own ticket with this evidence.

## E, F, G — pre-existing, already tabled

Force-unwraps (E) and main-thread-by-contract (F) are in the Part 2 table above.
G (sound-button icon state if `setIsMuted` lands before inflation) is new but sits
in the mute area the owner has placed off limits, so it goes to the owner with the
restructure question rather than being changed here.

## Pipeline observation

The mute finding has now cost five review cycles across Parts 2 and 3, every one a
false positive, because the line is read in isolation from the toggle three lines
below it. The code comment has not stopped it. The durable fix is to restructure
the handler so `isMuted` is assigned before volume and icon are applied, making
all three sites read identically — behaviour-preserving in principle, but it is
mute, it is on the owner's do-not-touch list, and it needs the owner's decision
and its own device test. Recorded as the standing cost of not doing it.

Second observation: `second_verdict` came back UNKNOWN on both `91a7d510` and
`3b938a56` — both times the primary REJECTED this same file. The second critic
produced full text on both occasions, so the verdict token is being lost rather
than the critique failing. Worth a look at `_extract_second_verdict`.
