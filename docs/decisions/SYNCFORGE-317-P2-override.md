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
