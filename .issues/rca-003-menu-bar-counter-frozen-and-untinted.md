---
title: "Menu bar counter froze while the menu was open, and the recording tint never applied"
date: 2026-08-20
status: fixed
affects: "menu bar recording indicator"
---

## Context

While recording, `AppController` runs a 1 Hz `Timer` that calls
`MenuBarController.update(recording:elapsed:)` to refresh the elapsed counter
and colour the feather red. `README.md:49` described "the icon turns red with a
running elapsed counter".

## Problem statement

Two separate defects, reported together as "the counter only updates when you
click the menu bar icon again".

1. The counter did not advance while the menu was open.
2. Neither the feather nor the counter was ever red. In dark mode the content
   went **white when idle, black while recording** — near-invisible against a
   dark menu bar.

Also, the counter was only ever rendered into the menu's state label, never
into the menu bar itself, so `README.md:49` described behaviour that did not
exist.

## RCA

**Frozen counter.** `Timer.scheduledTimer` registers the timer in the default
run loop mode only. An open `NSMenu` puts the main run loop into
`NSEventTrackingRunLoopMode`, where a default-mode timer does not fire at all.
The counter froze at whatever value it held when the menu opened and advanced
one step on reopen, when the loop briefly returned to the default mode — which
is exactly the reported symptom.

**Missing tint.** The status item is drawn in a *vibrant* appearance, confirmed
by instrumenting the button:

```
tint-diag: appearance=NSAppearanceNameVibrantDark
tint-diag: systemRed resolves to r=1.00 g=0.31 b=0.27 a=1.00
tint-diag: image.isTemplate=true
```

The colour resolved correctly, so this was never a colour problem — it was
rendering. A template image is *defined* as an alpha mask painted in the
system-determined colour, and vibrancy discards `contentTintColor` against
`NSStatusBarButton`. The feather then fell back to its rasterised pixels, and
because the inlined SVG uses `stroke="currentColor"` with no CSS context to
resolve it, those pixels are **black** — hence white-when-masked, black-when-not.

`NSButton.contentTintColor` is documented to override the title and template
image, which is why it looked correct in review. It does not survive vibrancy
here.

## Fix

- Schedule the ticker with `RunLoop.main.add(ticker, forMode: .common)`;
  `NSEventTrackingRunLoopMode` is a common mode, so it keeps firing while the
  menu is open.
- Stop tinting. Keep a template image for idle (so the system paints it
  correctly in either appearance) and swap in a **non-template** image with the
  colour baked into its pixels while recording. `tinted(_:with:)` repaints the
  alpha channel, so the source's own colour is irrelevant.
- Render the counter into `button.attributedTitle` so it is visible without
  opening the menu, making `README.md:49` accurate rather than aspirational.
  Monospaced digits, or the title reflows as digit widths change and the menu
  bar jitters once a second.
- The digits use `labelColor`, not `systemRed`: the feather carries the state
  signal, the digits are data, and a saturated indicator colour reads poorly as
  text.

## Notes

An `attributedTitle` renders with its own attributes and inherits nothing from
the button, so its colour must be set explicitly.

Process note: the first two attempts at the tint were guesses (add a
`foregroundColor`, then question the colour). Instrumenting the button settled
it in one pass and should have come first.

Possible future refinement, raised and deliberately deferred: match the system
microphone indicator's style — a filled rounded-rect background behind the
glyph rather than a tinted glyph. That is a drawn background, not a tweak.
