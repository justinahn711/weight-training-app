---
name: ChickenBreast
description: A dark, matte lifting log where colour only appears when something happened.
colors:
  chalkboard: "#0B0B0D"
  ember: "#EA8B52"
  on-ember: "#120F0D"
  quiet-label: "#BFBFBF"
  warmup-chalk: "#A3A3A3"
  fill-raised: "#7676803D"
  fill-recessed: "#7676802E"
  record-gold: "#FFCC3D"
  done-green: "#30D158"
  attention-coral: "#FF6B59"
  category-blue: "#3B82F6"
  category-magenta: "#C04AD8"
  category-teal: "#0FA98C"
  on-category: "#120F0D"
typography:
  large-title:
    fontFamily: "SF Pro (system, Dynamic Type: .largeTitle)"
    fontSize: "34pt"
    fontWeight: 700
  readout:
    fontFamily: "SF Pro Rounded (system, scaled relative to .largeTitle)"
    fontSize: "40pt"
    fontWeight: 900
    fontFeature: "tnum"
  headline:
    fontFamily: "SF Pro (system, Dynamic Type: .title2)"
    fontSize: "22pt"
    fontWeight: 700
  title:
    fontFamily: "SF Pro (system, Dynamic Type: .title3)"
    fontSize: "20pt"
    fontWeight: 600
    fontFeature: "tnum"
  body:
    fontFamily: "SF Pro (system, Dynamic Type: .body)"
    fontSize: "17pt"
    fontWeight: 400
  label:
    fontFamily: "SF Pro (system, Dynamic Type: .subheadline)"
    fontSize: "15pt"
    fontWeight: 600
  caption:
    fontFamily: "SF Pro (system, Dynamic Type: .caption)"
    fontSize: "12pt"
    fontWeight: 600
rounded:
  sm: "8pt"
  md: "12pt"
  card: "14pt"
  lg: "16pt"
  panel: "24pt"
  capsule: "999pt"
spacing:
  xs: "4pt"
  sm: "8pt"
  md: "12pt"
  gutter: "16pt"
  edge: "20pt"
components:
  button-hero:
    backgroundColor: "{colors.ember}"
    textColor: "{colors.on-ember}"
    typography: "{typography.headline}"
    rounded: "{rounded.lg}"
    height: "62pt"
  button-quiet:
    backgroundColor: "{colors.fill-raised}"
    textColor: "{colors.quiet-label}"
    rounded: "{rounded.capsule}"
    height: "44pt"
  stepper:
    backgroundColor: "{colors.fill-recessed}"
    typography: "{typography.title}"
    rounded: "{rounded.md}"
    height: "52pt"
  card:
    backgroundColor: "{colors.fill-raised}"
    rounded: "{rounded.card}"
    padding: "16pt"
  chip:
    backgroundColor: "{colors.fill-recessed}"
    rounded: "{rounded.capsule}"
    height: "36pt"
  rest-card:
    rounded: "{rounded.panel}"
    padding: "8pt 20pt"
---

# Design System: ChickenBreast

## Overview

**Creative North Star: "The Chalk Board"**

A gym's whiteboard at the end of the day: matte, dark and practical, chalked
over by people who were busy lifting. Everything ordinary is a shade of grey
on near-black, and colour is written on it only where something happened: a
record, a set done, the one thing to press next. When colour appears, it reads
as news, not decoration. The app is dark, always. A gym is bright overhead and
the phone sits on a bench or the floor, so a white screen at that angle is
glare.

The energy is tough and punchy, and it's concentrated, not spread. The punch
lives in the heavy numbers (bold, rounded, tabular), the single orange hero
button, and the moments of colour. The chrome around them stays native and
quiet so they hit harder. One hero, the rest stock iOS: Log Set is big,
unmistakable and thumb-sized, while navigation, sheets, lists, toggles and
secondary buttons are the platform's own, kept plain.

Density follows the bench: one glance answers "what's next, and how do I log
it". Information that doesn't serve the next set waits until the set is done.

**Key Characteristics:**
- Near-black chalkboard surface, never pure black, never light.
- One accent (ember orange), spent on the hero action and the rest ring only.
- Colour as signal: gold for records, green for done, coral for "behind".
- Depth from tonal fills and system materials; no shadows anywhere.
- System type only (SF Pro), Dynamic Type everywhere, heavy rounded numerals.
- Native controls; one oversized hero; 44 pt minimum on every target.

## Colors

A monochrome grey ramp on near-black, with a handful of saturated colours,
each held to one meaning.

### Primary
- **Ember** (#EA8B52): the one action the screen exists for (Log Set, the
  forward "Next lift" capsule) and the rest ring closing. Text on it is
  **Bar Shadow** (#120F0D, `on-ember`), because white measured 2.53:1 on this
  orange and failed even large-text contrast; near-black clears 7:1. The asset
  catalogue also defines a light-appearance ember (#B45129), unused while the
  app is forced dark.

### Secondary
- **Record Gold** (#FFCC3D): a personal record, and nothing else, so a flash
  of it mid-session can only mean one thing. Text on it is pure black.
- **Done Green** (#30D158, system green): a set logged, a rest complete.
- **Attention Coral** (#FF6B59): something is behind and worth a look, such as
  a muscle under its weekly band. It's never the only cue: always paired with
  a glyph and a sentence. 7.0:1 on the chalkboard.

### Tertiary
- **Category Blue / Magenta / Teal** (#3B82F6 / #C04AD8 / #0FA98C): *which
  kind of thing*, never news: day kinds on the History calendar, rings on
  Progress. Cool on purpose, because every warm hue already means something
  just happened. Validated against the dark surface (all above 3:1, normal-
  vision ΔE 21). Their worst colour-blind pair (blue/magenta, ΔE 7.1 deutan)
  is only legal beside a label, so every use keeps its text or letter. Text on
  them is `on-category` (#120F0D); white measured 2.97:1 on the teal.

### Neutral
- **Chalkboard** (#0B0B0D): the background. Near-black rather than black,
  because on OLED pure black makes every card float as a cut-out.
- **Chalk** (system `label`, white): numbers, titles, anything read at a glance.
- **Quiet Label** (#BFBFBF, 75% white): small grey text on working surfaces:
  More, Previous lift, the stepper's caption, the rest card's caption. Opaque,
  not an opacity of white, so the ratio doesn't move with what's behind it
  (7.1–10.1:1 on every surface it sits on).
- **Secondary Label** (system `secondaryLabel`): headings like TARGET / LAST
  TIME and explanatory lines, on the chalkboard only. It measured 5.1–6.3:1 on
  the raised working surfaces and failed the audit there, which is why Quiet
  Label exists.
- **Warmup Chalk** (#A3A3A3, 64% white): the Log Set fill on a warmup
  rung, and nothing else. Ember's luminance without its hue, so the hero
  weighs the same and keeps its near-black text (7.5:1).
- **Raised Fill / Recessed Fill** (system `tertiarySystemFill` / `quaternary`,
  #7676803D / #7676802E): cards, banners, steppers, chips. Grey layers, not
  borders.

### Named Rules
**The News Rule.** Colour is information. A saturated hue appears only when it
carries its one meaning (record, done, behind, act, category). Decorative
colour is a bug.

**The One Ember Rule.** Ember paints the primary action and the rest ring and
nothing else. Secondary controls (Undo, Skip, Stay, Go back) use the neutral
`quietTint`. When ember painted every button it stopped meaning anything (a
critique found it on eight controls at once).

**The Dark Text On Colour Rule.** Text on any brand fill (ember, gold,
categories) is near-black, never white. Every one of them measured below
contrast with white.

## Typography

**Display Font:** SF Pro Rounded (system), for the weight readout only
**Body Font:** SF Pro (system)

**Character:** All system type, so every word follows the lifter's Dynamic
Type setting. The punch comes from weight and numerals: bold, tabular,
rounded numbers that hold still as they change.

### Hierarchy
- **Large Title** (bold, 34 pt `.largeTitle`): the exercise name on tall
  screens. It doesn't switch style at accessibility sizes, so it only ever
  grows (#278).
- **Readout** (SF Pro Rounded black, 40 pt at the default size, scaled
  relative to `.largeTitle`, monospaced digits; the unit at 45% size,
  semibold, in Quiet Label): the weight on the stepper. The number the bench
  reads (#297).
- **Headline** (bold, 22 pt `.title2`; `.title3` when compact): the Log Set
  title and the rest clock.
- **Title** (semibold, 20 pt `.title3`, monospaced digits): stepper values and
  logged set rows.
- **Body** (regular, 17 pt `.body`): last time, explanations, list rows.
- **Label** (semibold, 15 pt `.subheadline`): secondary actions and the Log
  Set summary line ("135 lb × 8").
- **Caption** (semibold, 12 pt `.caption`, uppercase for section heads):
  TARGET, LAST TIME, TODAY, RESTING. Never `.caption2` for standalone text:
  it doesn't shrink below the default size, and the Dynamic Type audit fails
  it (#289).

### Named Rules
**The Tabular Number Rule.** Every number that changes in place (weights,
reps, RPE, the rest clock) uses monospaced digits, so it doesn't jitter as it
counts.

**The Grow-Only Rule.** Text never gets smaller as the lifter's text size
gets bigger: no style swaps or `minimumScaleFactor` shrinking at
accessibility sizes. Rearrange the layout instead (`AnyLayout`).

## Layout

A single column on iPhone, from SE through Pro Max, portrait first, with
landscape supported as two columns (context left, actions right). The session
screen is a scrolling document over a fixed action dock (stepper, reps/RPE,
Log Set, More / Next lift). At accessibility text sizes and on short
screens the dock compacts, and at accessibility sizes it scrolls instead of
compressing. Screen edges are 20 pt (16 pt in compact), and cards pad 16 pt.
Spacing runs on a 4 / 8 / 12 / 16 / 20 rhythm. Every tappable element is at
least 44 × 44 pt, and the hero is 62 pt tall (56 compact).

**The Bench Rule.** The next number and the action to take are visible
without scrolling in the default layout. Anything that pushes them below the
fold waits until after the set.

## Elevation & Depth

Flat, with tonal layering and system materials. There are no drop shadows in
the app. Depth comes from grey fills stacked on the chalkboard (raised for
cards, recessed for controls inside them), from the system `.bar` material
behind the action dock, and from ultra-thin material on the floating rest
card, the only thing that reads as hovering.

**The No-Shadow Rule.** Nothing casts a shadow. Separation is tone and
material, the way chalk sits on a board.

## Shapes

Gently curved, continuous corners throughout: 12 pt on controls and steppers,
14 pt on context cards, 16 pt on the hero and larger cards, 24 pt continuous
on the rest card (matching the system's own floating surfaces), and capsules
for quiet buttons, the forward action and filter chips. No borders or hard
outlines; edges are defined by the change of fill.

## Components

### Buttons
- **Hero (Log Set):** big, unmistakable, thumb-sized. Ember fill, full width,
  62 pt minimum (56 compact), 16 pt corners. One line in near-black that says
  the action and what one tap writes: "**Log 135** lb × **8**", with a heavy
  verb, the numbers in black SF Pro Rounded tabular numerals (`.title`,
  `.title2` compact), and the unit and "×" lighter. With nothing to log it
  falls back to "Log Set" over "Set a weight first".
- **Hero, warmup state:** on an active warmup rung the hero takes
  **Warmup Chalk** (#A3A3A3, `Theme.warmupFill`), Ember with the hue taken
  out: the same luminance, so it weighs the same and keeps the near-black
  text (7.5:1; the old `.secondary` fill under white text measured about
  2.8:1). It says "Log warmup 45 lb × 5", with a footnote line under it
  inside the same height, "1 of 4 · then 135 lb": where the ramp stands and
  what it builds to, so the warmup number never reads alone. It's still the
  thing to tap, but it no longer claims a working set. Its accessible name
  stays "Log Set".
- **Forward (Next lift / Finish workout):** a bordered capsule tinted
  ember, the only other ember element on the dock.
- **Quiet (Undo, Skip, Stay, Go back, Review / Edit set plan):** system
  bordered buttons in the neutral `quietTint`, never ember.
- **Text actions (More, Previous lift, warmup Clear):** plain buttons in
  Quiet Label with a 44 pt frame and a full-row content shape.
- **Lists in sheets** (the exercise chooser): rows in chalk and Secondary
  Label under a `quietTint`, the current one marked by a neutral checkmark
  and the selected trait. A List paints button rows in the tint, so without
  it every row came out ember.

### Chips
- **Style:** recessed-fill capsules, 36 pt drawn inside a 44 pt tap frame.
- **State:** selected adds a bolder label and a checkmark glyph, never colour
  alone (#217, #251).

### Cards / Containers
- **Corner Style:** 14 pt (context card), 16 pt (larger cards).
- **Setup route:** a lift's settings line ("Dumbbell rack · 5 lb steps")
  heads the context card only when it states a fact; with nothing to say it
  is a 44 pt slider glyph in the card's top-right corner, never a row that
  only reads "Gym setup" or "Standard setup".
- **Background:** Raised Fill on the chalkboard.
- **Shadow Strategy:** none; see Elevation.
- **Border:** none.
- **Internal Padding:** 16 pt.

### Inputs / Fields
- **Steppers:** the session's inputs are steppers, not text fields:
  − value + on a recessed fill, 12 pt corners, 52 pt tall, title-weight
  tabular values. The weight stepper carries the rounded Readout and a Quiet
  Label caption (rack, increment). Tapping the value opens exact entry in a
  sheet.
- **Settings:** native Form rows, toggles and system steppers.

### Navigation
- System tab bar for the top-level sections (Train, History, Progress,
  Settings), navigation stacks with large titles, and sheets for focused
  tasks (exercise chooser, set plan, finish confirmation) with clear
  Cancel / Done. Edge-swipe back is never overridden.

### Rest Card (signature)
The floating rest clock pinned under the navigation bar: ultra-thin material
in a 24 pt continuous card on a 20 pt margin, a 22 pt progress ring in ember
(Done Green when complete), the caption "RESTING" in Quiet Label on its own
row, and the clock in bold tabular Headline. Skip sits beside the clock, and
moves under it at accessibility sizes.

## Do's and Don'ts

### Do:
- **Do** keep the background Chalkboard (#0B0B0D) and the app dark-only.
- **Do** spend Ember (#EA8B52) on the one primary action and the rest ring;
  put near-black (#120F0D) text on it.
- **Do** give every recurring meaning one colour and keep it there: gold
  records, green done, coral behind.
- **Do** use system text styles and SF Symbols; set numbers that change in
  monospaced digits.
- **Do** make every tap target at least 44 × 44 pt, and make the hero
  obviously the biggest thing on the dock.
- **Do** build depth from Raised / Recessed fills and system materials.
- **Do** honour Reduce Motion through `Theme.spring` / `quick` /
  `edgeTransition`: things still move, they ease instead of spring.

### Don't:
- **Don't** add drop shadows, borders or outlines.
- **Don't** paint secondary buttons ember, or use colour as the only cue for a
  state.
- **Don't** put white text on ember, gold or a category colour.
- **Don't** use `.caption2` for standalone text, `.system(size:)` without
  scaling, or `minimumScaleFactor` to fit text at large sizes.
- **Don't** use `.secondary` for small text on the raised working surfaces;
  use Quiet Label (#BFBFBF).
- **Don't** introduce a light appearance, a custom font for UI text, or a
  custom navigation bar.
