---
version: alpha
name: PRHub
description: >-
  PRKit's and PRHub's design. These tokens are the only source of the PR screens' colours, type, spacing, corners and
  icon style: `make -C app design` writes the colour sets and PRKitDesign's DesignTokens.swift from them.
colors:
  # The accent: controls only (buttons, tab selection, More), never a row's content.
  primary: "#F15D34"
  # Text and quiet text (meta, what Jai did, the ticket line).
  ink: "#000000"
  ink-dark: "#FFFFFF"
  ink-quiet: "#3C3C4399"
  ink-quiet-dark: "#EBEBF599"
  # The page, a block on it, a field or quiet button, and a hairline.
  ground-page: "#F2F2F7"
  ground-page-dark: "#000000"
  ground-card: "#FFFFFF"
  ground-card-dark: "#1C1C1E"
  ground-fill: "#7676801F"
  ground-fill-dark: "#7676803D"
  line: "#3C3C434A"
  line-dark: "#54545899"
  # States: GitHub's, light and dark.
  tone-good: "#1A7F37"
  tone-good-dark: "#3FB950"
  tone-bad: "#CF222E"
  tone-bad-dark: "#F85149"
  tone-waiting: "#9A6700"
  tone-waiting-dark: "#D29922"
  tone-merged: "#8250DF"
  tone-merged-dark: "#A371F7"
  # Linear's mark, and nothing else.
  linear: "#5E6AD2"
typography:
  # One family for every style: change `system` here (any installed font's name) and every style follows.
  large-title: { fontFamily: &family system, fontSize: 34px, fontWeight: 400 }
  title: { fontFamily: *family, fontSize: 28px, fontWeight: 400 }
  title2: { fontFamily: *family, fontSize: 22px, fontWeight: 400 }
  title3: { fontFamily: *family, fontSize: 20px, fontWeight: 400 }
  headline: { fontFamily: *family, fontSize: 17px, fontWeight: 600 }
  subheadline: { fontFamily: *family, fontSize: 15px, fontWeight: 400 }
  body: { fontFamily: *family, fontSize: 17px, fontWeight: 400 }
  callout: { fontFamily: *family, fontSize: 16px, fontWeight: 400 }
  footnote: { fontFamily: *family, fontSize: 13px, fontWeight: 400 }
  caption: { fontFamily: *family, fontSize: 12px, fontWeight: 400 }
  caption2: { fontFamily: *family, fontSize: 11px, fontWeight: 400 }
  code: { fontFamily: system-mono, fontSize: 12px, fontWeight: 400 }
rounded:
  # Inside a block (chips, buttons, fields), and a box of its own.
  sm: 6px
  md: 8px
spacing:
  xs: 4px
  sm: 8px
  md: 12px
  lg: 16px
  xl: 24px
components:
  page: { backgroundColor: "{colors.ground-page}" }
  block: { backgroundColor: "{colors.ground-card}" }
  row-title: { textColor: "{colors.ink}", typography: "{typography.subheadline}" }
  meta: { textColor: "{colors.ink-quiet}", typography: "{typography.caption}" }
  chip: { typography: "{typography.caption2}", rounded: "{rounded.sm}", backgroundColor: "{colors.ground-fill}" }
  button: { textColor: "{colors.primary}", rounded: "{rounded.sm}" }
  box: { rounded: "{rounded.md}", backgroundColor: "{colors.ground-card}" }
  separator: { backgroundColor: "{colors.line}" }
  diff: { typography: "{typography.code}" }
  state-good: { textColor: "{colors.tone-good}" }
  state-bad: { textColor: "{colors.tone-bad}" }
  state-waiting: { textColor: "{colors.tone-waiting}" }
  state-merged: { textColor: "{colors.tone-merged}" }
# Every SF Symbol's variant (none, fill, circle, circle-fill, square, square-fill), set once at the app's root. Which
# symbol means what is AppIcon.swift.
x-icons:
  variant: none
---

# Design

PRHub is iOS's type and colours, set by the tokens above, and its own controls where the system's look stock.
**Changing the design:** edit one token above and run `make -C app design`. The font family is `fontFamily` in
`large-title` (every style shares it), a size is its `fontSize`, a colour is its token (`-dark` is the dark appearance),
and the icon style is `x-icons.variant`. Never write a colour, size or symbol in Swift: use the tokens
(`Color("ToneGood")`, `.appCaption`, `Space.sm`, `Radius.md`, `AppIcon`).

An app that embeds PRKit ships these colour sets in its own asset catalogue (PRKit/README.md); `make -C app design`
writes PRHub's. This page says which parts to reuse, where things go, and how things move. **How an agent uses this:**
find the object's contract and put each element in its named part. If the element has no part, stop and ask.

## Feature map

| Feature | Where | Drawn by |
|---|---|---|
| Connect to a pr-worker | first run, until a setup link pairs it | `OnboardingView`, `SetupCodeScanner` |
| Sample PRs | onboarding's "Try with sample PRs" | the PR screens over `PRSampleSet.prHub` |
| PR list | PRs | `PRsView`, `PrListBlock` |
| PR description | PRs → a PR | `PRDescriptionView`, `.prCard()`, `PRCommentText` |
| Ask AI | PRs → a PR → the toolbar, or a line's comment box | `PRAskSheet`, `SessionBubble` |
| PR diff | PRs → a PR → Diff | `DiffTableView` |
| Settings | Settings | `PRHubSettingsView` |
| iPad | the phone's tabs, every orientation | the same views; `readableContentWidth()` centres scroll views |

## Overview

A departures board you read between other things: one line per thing, the status always in the same place, so the eye
learns where to look once. A row is finished when you can answer "what is it, where does it stand, what do I do" without
reading all of it.

Hierarchy, most important first. Words get their weight from type; states from colour and shape.

1. **What is it:** the title. The only semibold line in a row.
2. **What do I do:** the agent's note, and an "Asked again".
3. **Where does it stand:** state, then signals.
4. **Where and how old:** the meta line.
5. **What supports it:** the ticket. Weaker than every part of the PR.

The PR leads. A ticket leads only when an item has no PR. The app never says one thing twice: a title's `[NM-704]` goes when
the block shows NM-704.

## Colors

| Role | Colour | Allowed on |
|---|---|---|
| Text | `Color.primary` | titles, notes |
| Quiet text | `Color.secondary` | meta, what Jai did, ticket line |
| Tones | `ToneGood`, `ToneBad`, `ToneWaiting`, `ToneMerged`: GitHub's, light and dark | PR state, signals |
| Linear | `#5E6AD2` for the mark; a state's own colour from Linear's API | the mark and circle only, never words |
| Accent | `AccentColor` | controls only: buttons, tab selection, More. Never a row's content |
| Ground | `HomePalette.screenBackground`, `HomePalette.cardBackground` | the page, and a block on it. Both, always: `.background` is black on black in dark |

`.tertiary` is not for words: it fails contrast. Nothing is told apart by colour alone.

## Typography

Only these, all `AppFont`, never `.body` or `.caption`. Regular or semibold. One family: the system font. The Message
widget is the exception: the message is its whole content, at 24 to 36 pt semibold, shrinking as it gets longer.

| Style | Weight | Used for |
|---|---|---|
| `.appTitle3` | semibold | a screen's title |
| `.appSubheadline` | semibold | an object's title, and nothing else |
| `.appFootnote` | semibold | a section's title, a comment's author, a PR's buttons |
| `.appFootnote` | regular | notes, summaries, and all that people write on a PR |
| `.appCaption` | regular | meta, signals, what Jai did, ticket line |
| `.appCaption2` | semibold | inside a chip |

## Layout

Space is 4, 8, 12, 16 or 24 pt: 4 inside a group, 8 between groups and between blocks, 12 for the avatar's gutter, 16 for
insets and the ticket's step in, 24 above a section.

Three columns, the same on every row: **leading** (avatar or `LeadingIcon`, `RowGrid.leading` 32 pt, grows with the text; an icon is centred in it, so a wide icon never moves the title), **text**, and **state** (24 pt, right
edge). Text stays at the avatar's width plus 12, so a part that sits at the text column follows the avatar when the text
grows. Never pad by a fixed number.

Division has three levels, one signal each. No other lines, boxes or shadows.

| Between | Signal |
|---|---|
| Sections | the section's title, on the page's grey |
| Blocks | a band of the page's grey, 8 pt, across the whole width |
| A PR and its ticket | the rail: a line from the first avatar, turning right to the ticket |

Rows go to the screen's edges; the corners are square. A screen that needs a `List` (swipes, search, folds) is a
`.blockList()`: each block a `BlockSection` (or `BlockSections` for items under one title), titles `BlockSectionTitle`,
chips and switches `.onPageRow()` on the grey. Never an inset-grouped list on a tab's screen. A list with notes scrolls in a plain `VStack`: a note's block measures
its own height, and a `LazyVStack` rebuilds it from nothing and never settles. The PRs tab has no notes, and is lazy.

## Components

### Status

Three kinds, one look each.

| Kind | What | Looks like | Where |
|---|---|---|---|
| State | where the object stands. Exactly one | PR: `PrStateIcon`. Ticket: `LinearStateCircle` | state column |
| Signal | a fact about a PR | `PrStatusMarks` | under the meta line |
| What Jai did | his review, or that he opened it | grey words; "Asked again" `ToneWaiting`; "You're blocking" `ToneBad`; "You approved" `ToneGood`, with the review's person and check | last line |

A PR's state is GitHub's own, never worked out. First match wins:

| Data | State | Symbol | Tone |
|---|---|---|---|
| `found` is null | Resolving… | clock | quiet |
| `found` is false | Not found | question mark | `ToneWaiting` |
| merged | Merged | GitHub's merged | `ToneMerged` |
| closed | Closed | GitHub's closed | `ToneBad` |
| draft | Draft | GitHub's draft | quiet |
| open | Open | GitHub's open | `ToneGood` |
| anything else | Resolving… | clock | quiet |

A ticket says Resolving…, then Not found, then Linear's word. The circle's fill comes from `state_type`, its colour from
`state_color`, else Linear's default for the type. Todo and Backlog stay grey: Linear's `#E2E2E2` can't be seen as a ring.

Every icon comes from `AppIcon`, by meaning. A review, the PR's or one reviewer's, is always a person: approved
`person.fill.checkmark`, changes requested `person.fill.xmark`, needs review `person.fill.questionmark`. A check is never a
person: passing is a dot, failing an x, running a clock. No two meanings share a symbol.

Signals are `signalMarks`: checks, review, merge, in that order. Merged and closed PRs have none. A draft's only merge signal
is Conflicts. No pills in a list: `StatusChip` is for elsewhere.

### PR row

```text
name: PullRequestRow
purpose: One PR in a list. The whole row is one tap target and opens the PR.
parts:
  avatar:  { row: 1, column: leading, holds: "author's GitHub picture; nothing, never an empty circle, with no author" }
  title:   { row: 1, column: text, holds: PR title else the item's title else the ref, font: appSubheadline semibold, lines: 3 }
  state:   { row: 1, column: state, holds: PrStateIcon, centred on the title's first line }
  meta:    { row: 2, column: text, holds: "first name · repo#N · age", font: appCaption, lines: 1 }
  signals: { row: 3, column: text, holds: signalMarks, optional: true }
  yours:   { row: 4, column: text, holds: PrJaiMarkLabel, optional: true }
states: [resolving, notFound, open, draft, merged, closed, faded, answered]
rules:
  - An empty optional part collapses. The state column never moves.
  - Meta gives way in this order, the name, then the repo's front. `#N` and the age stay.
  - A ref that is already the title leaves meta. Age shows only once GitHub has said it.
  - Signals wrap whole. Words in status never truncate.
  - Faded dims every part but yours, once Jai decided that PR since the list was sent.
  - Answered is the PRs tab's: Jai approved, requested changes or commented on a PR the review list asked of him. It fades
    like a decided PR, from the moment GitHub takes it, and stays until the PR closes. "You approved · 3m" says it in words.
antiPatterns:
  - A status anywhere but its part.
  - A button inside the row.
```

### Ticket line

```text
name: TicketLine
purpose: The ticket supporting a block's PRs. Quiet. The whole line opens Linear, 44 pt tall at least.
parts:
  mark:  { column: text + 16, holds: LinearMark, size: 16 }
  key:   { after: mark, font: appCaption, never truncates }
  title: { after: key, font: appCaption, lines: 1, gives way first, gone at xxLarge and up }
  word:  { before: circle, holds: Linear's state word, font: appCaption, never truncates }
  circle: { column: state, holds: LinearStateCircle }
rules:
  - One to a block, always last, on the rail.
  - No accent, no semibold, no chip.
```

### Ticket row

```text
name: TicketRow
purpose: An item with no PR. PullRequestRow's places. Opens Linear.
parts:
  mark:   { row: 1, column: leading, holds: LinearMark, size: 22 }
  title:  { row: 1, column: text, holds: ticket title else the item's title else the key }
  circle: { row: 1, column: state, holds: LinearStateCircle }
  meta:   { row: 2, column: text, holds: "NM-669 · Done" }
```

### Block and section

```text
name: PrListBlock
purpose: One item an agent sent.
parts: [PullRequestRow..., note, TicketLine]
rules:
  - Note is the agent's words at the text column, once, after the last PR. It folds at 4 lines with More, in place.
  - Note and ticket fade only once every PR in the block is decided.
  - The note opens nothing but More.
---
name: PrListSection
purpose: The agent's grouping, on the page's grey.
parts: { title: appFootnote semibold, note: appFootnote secondary }
rules:
  - A section with only a note has no block.
```

### Comment

```text
name: PRComment
purpose: What someone said on a PR. A review tool, not a chat: read as dense as the diff beside it, with room around the words.
parts:
  box:    { holds: .prCard(), radius: 8, border: hairline }
  author: { holds: PRAuthorLine, avatar: 20, login: appFootnote semibold, age: appCaption }
  body:   { holds: PRCommentText, font: appFootnote, headings: appFootnote semibold }
rules:
  - Words sit PRStyle.inset (12) from the box on every side.
  - Corners are continuous. Box 8, anything inside it 6.
antiPatterns:
  - MarkdownText without a font: it falls to 17 pt body.
  - A radius or inset typed in place of PRStyle.
---
name: InlineComposer
purpose: Writing, in place.
parts:
  field:  { font: appFootnote, lines: 3 to 10, padding: 12 by 8, radius: 6, focused: 1 pt accent border }
  cancel: { holds: PRButtonStyle(.plain) }
  other:  { holds: PRButtonStyle(.secondary), optional: true }
  send:   { holds: PRButtonStyle(.primary), last }
rules:
  - Buttons sit at the right, send last.
antiPatterns:
  - A sheet.
```

### Thread line

```text
name: ThreadLine
purpose: One thread in a list, the same everywhere: Agents → Threads, Needs you and search alike. Three lines at most.
parts:
  mark:    { row: 1, holds: ThreadAppIcon, size: 16 }
  title:   { row: 1, font: appSubheadline semibold, lines: 1 }
  age:     { row: 1, trailing, holds: "12m, 3d; the clock time is the thread page's", font: appCaption }
  line:    { row: 2, holds: "a reply's note, else the question, else the status, else the latest words", font: appFootnote, lines: 1 }
  meta:    { row: 3, holds: "machine · place, only what no header above says; gives way whole", font: appCaption }
  state:   { row: 3, trailing, holds: ThreadStatusLine, font: appCaption medium }
  chevron: { column: trailing, holds: "folds ThreadAccessories in as the list's next row; shown only when an accessory has something" }
rules:
  - Never wraps: every line truncates.
  - A row whose answer is with the agent dims all but its state, which says why.
  - Accessories are data (ThreadsViewState.Accessories): one view per kind, in their order.
```

### Icon and words

```text
name: IconText
purpose: An icon and its words on one line, wherever the two go together: a reply's status, "Acknowledged", a monitor's
  state, a PR's signal, a thread's status.
parts:
  icon:  { holds: "AppIcon, or the model's symbol", slot: "fixed width (Space.lg, grows with the text)", aligned: leading }
  words: { after: icon, gap: Space.xs }
rules:
  - The icon slot's leading edge is the text column's: the icon lines up with the text above it.
  - The icon sits on the words' first line (first text baseline).
  - Drawn by `Label(…).labelStyle(.iconText)` or `IconText(_:icon:)`; the font and colour come from around it.
antiPatterns:
  - HStack { Image; Text } with its own spacing or padding.
  - A list's default Label style, which puts the icon in a wide column of its own.
```

### Chip and button

```text
name: ChipButtonStyle
purpose: One choice of several that narrows or sets something: Alerts' and Threads' filters, the View sheet's choices.
parts: { words: appCaption2 semibold, ground: GroundFill, chosen: the accent, corner: Radius.sm }
---
name: PRButtonStyle
purpose: Every button on a row or screen: Ack, Snooze, Done, a link an agent sent, Show everything.
rules:
  - Primary for the one action a row asks (Ack, Done), secondary for the rest. Corner Radius.sm.
antiPatterns:
  - .bordered, .borderedProminent or .glassProminent on content. Glass only over red or over the diff.
```

### Components

The shared views. Use these; extend one rather than writing a near-copy.

- `.blockList()`, `BlockSection`, `BlockSections`, `BlockSectionTitle`: a `List` in the layout above.
- `IconText` / `.labelStyle(.iconText)`: an icon and its words.
- `ChipButtonStyle`: a chip. `FilterChips` is a row of them.

- `ThreadLine`: a thread as a row, wherever threads are listed.
- `ThreadsGroupHeader`: every header of the thread list, any level, Needs you included: chevron, the level's mark, name, counts.
- `ThreadAccessories`: what folds in as the list's next row after a `ThreadLine`; `ThreadQuestion`, `ThreadReferencesAccessory` and `ThreadReplyAccessory` (the latest reply as plain text, 8 lines at most), one per kind.
- `ThreadQuestion`: a thread's question, its answers (`ThreadAnswerButtons`) and Reply, on a card or folded in.
- `ThreadRow`: a thread waiting on Jai as a card, in Alerts → Agents.
- `ThreadSenderLabel`: the thread a page or session message came from, as a link's label.
- `ThreadStatusLine`: a thread's status in its tone.
- `PullRequestLine`, `TicketLine`: a PR or ticket on one line, under something else.
- `PrListBlock`, `PullRequestRow`, `TicketRow`: an item an agent sent, in a list.
- `StatusChip`: state words outside lists.
- `SessionBubble`: a message in any chat (a thread, a session message, Ask AI, Feedback), with what hangs under it:
  `SessionReplyStatus` (where a reply of Jai's stands, Retry and Cancel) under his, `ThreadQuestion` under the agent's
  words that asked.
- `.prCard()`, `PRAuthorLine`, `InlineComposer`, `PRButtonStyle`: the PR screens' box, author, writing and buttons.

### Other parts

- **Text from people and agents:** `MarkdownText`; on a PR, `PRCommentText`.
- **State words outside lists:** `StatusChip`.
- **A panel from the right:** `sidePanel`, over the page, dimming it; a tap on the dim or a swipe right closes it. In place:
  no sheet. A diff's Files and Key lines (`PRNavigator`) and a thread's details (`ThreadDetailsPanel`) use it.
- **Room for the code:** on the phone the nav bar and tab bar leave as you scroll down and return as you scroll up, or when the keyboard goes. The diff runs under them, so they never move it.
- **PR screens:** `.prCard()` for a box, `PRAuthorLine` for who and when, `InlineComposer` for writing, `PRButtonStyle` for
  a button.

## Do's and Don'ts

- **Don't** put a status anywhere but its part. Build 90 had "Done" in three shapes.
- **Don't** use the accent for a link in a row. Position says it is a link.
- **Don't** add a line, box or shadow to separate things. There are three divisions.
- **Don't** colour words with Linear's colours. `#F2C94C` can't be read.
- **Don't** use `.bordered` or `.borderedProminent` on any screen. They are capsules on iOS 26, and they read as stock.
- **Do** say a repo filter is on, under the switch: a filter can hide most of a list.
- **Don't** use a list's swipe for a row: rows sit in a plain stack. `PRSwipeRow` is the one swipe, and it pans only sideways.
- **Don't** put glass on content. On a PR's screens it is for the controls that float over the diff: Finish, the panel button and the key line stepper, in
  the same 6 pt corner as the other buttons, with no custom bar behind it.
- **Do** check every state in `UXFixtures`, in light, dark and `accessibility-medium`.

`PrListState` is an enum from one function, so a state can't be a free word or colour. `PrListBlock`, `PullRequestLine` and
`TicketLine` are the only places a PR or ticket is laid out.

Look at the contact sheet and ask:

1. Does each object have exactly one state, in the state column?
2. Squint: can you see where each block ends, and which part is the ticket?
3. Is the ticket weaker than every part of the PR?
4. Did anything go somewhere that isn't a part?

## Motion

Polish is part of done. A screen that jumps is unfinished.

- Anything that opens, closes or arrives animates, with `AppMotion`. SwiftUI does not animate a state change unless asked,
  so an unwrapped change simply jumps.
- Folding goes through `FoldSet`, whose toggle animates. Don't hold fold state in a plain `@State` Bool.
- Inserted content uses `.transition(.fold)`. UIKit rows use `insertRows`, `performBatchUpdates` or a cross-dissolve, not
  a bare `reloadData()`.
- Navigation pushes keep their animation.
- A success worth noticing gets `.sensoryFeedback`.

## In place first

Open things where the eye already is. A comment box on a diff line goes above the keyboard, with its line just over it, a reply in its thread, an action under its
button. Use a sheet only for a real detour.

## Checking

A screenshot cannot show motion. `make -C ios ui-test SIM_DEVICE=<udid> VIDEO=<file>` drives the real app and records it.
Look at frames from the recording before calling UI work done.

For everything else, `make -C ios design-sheet SIM_DEVICE=<udid>` writes a contact sheet: one image with every screen in the
feature map, for each of light, dark and large text, in `/tmp/agent-pager-design-sheet`. It runs on sample data. Look at it
before calling UI work done; an agent reads the image, it doesn't count on a script to judge it.
