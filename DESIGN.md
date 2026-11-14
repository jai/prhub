---
version: alpha
name: PRHub
description: >-
  The design reference for PRKit and PRHub. These tokens are the only source of the screens' colours, type, spacing,
  corners, motion and icon style: `make -C app design` writes the colour sets and PRKitDesign's DesignTokens.swift
  from them. Agent Pager, which embeds PRKit, takes its type, spacing, corners and motion from here.
colors:
  # The accent: controls only (buttons, tab selection, More), never a row's content.
  primary: "#F15D34"
  # Text and quiet text (meta, what you did, the ticket line).
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
  # Words on the accent or a tone. Black in dark: white on a dark tone (#3FB950) is 2.5:1, black is 8:1.
  on-accent: "#FFFFFF"
  on-accent-dark: "#000000"
  # Words on the person's own chat bubble: white in dark too. Jai's call over on-accent's contrast rule.
  on-bubble: "#FFFFFF"
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
# The Mac's size for each style, at View → Actual Size (MacTextSize 1.0): the Mac has no Dynamic Type, and the
# iPhone's sizes read a size too big there. Apple's macOS sizes, with nothing under 11 pt, so secondary lines stay
# readable. Same family and weights as typography.
x-mac-typography:
  large-title: 28px
  title: 22px
  title2: 18px
  title3: 16px
  headline: 14px
  subheadline: 13px
  body: 14px
  callout: 13px
  footnote: 12px
  caption: 11px
  caption2: 11px
  code: 12px
rounded:
  # Inside a block (buttons, fields), a box of its own, and a chat bubble or the chat field.
  sm: 6px
  md: 8px
  lg: 18px
spacing:
  xxs: 2px
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
# How long things take to move: AppMotion's fold (opening, closing, arriving), swap (one state replacing another in
# place), press (a control's press and focus) and screen (a Mac screen pushed or returned to).
x-motion:
  fold: 280ms
  swap: 180ms
  press: 120ms
  screen: 300ms
# Every SF Symbol's variant (none, fill, circle, circle-fill, square, square-fill), set once at the app's root. Which
# symbol means what is AppIcon.swift.
x-icons:
  variant: none
---

# Design

This page is the design reference for PRKit and PRHub. The tokens above set PRHub's type, colour, spacing, corners and
motion; the shared parts below set how each thing looks. Agent Pager embeds PRKit and follows this page for everything
PRKit draws.

**The rule:** new UI is built from these tokens and parts. A view never types a font size, colour, padding, gap,
corner or animation. `scripts/design-lint.sh` fails CI when one does (see Checking).

**How an agent uses this:** find the object's part in Components and put each element in its named place. If no part
fits, extend the nearest one rather than writing a near-copy. If that isn't possible, stop and ask.

Sections follow Google's `DESIGN.md` order. The contracts in Components use the shape of Design System Contracts and
Adobe Spectrum's component format: named parts, placement, states, rules and anti-patterns.

## Making a change

PRHub is a consumer app: a look should change in one place and stay consistent everywhere. Edit the one line below,
run `make -C app design` if it is a token, then look at the screenshots (Checking).

| To change | Edit | Reaches |
|---|---|---|
| The font family | `fontFamily` in `large-title` above | every text style |
| A text size | that style's `fontSize` above (`footnote: 13px`) | every view using `.appFootnote` |
| A text size on the Mac | that style in `x-mac-typography` above (`footnote: 12px`) | every view using `.appFootnote` on the Mac |
| Which size a part uses | the part's view (PRSectionTitle, PageHeader, PRButtonStyle) | every place the part is used |
| The accent | `colors.primary` | buttons, tab selection, focus rings, your own chat bubbles |
| A state's colour | `tone-good`, `tone-bad`, `tone-waiting`, `tone-merged` (and `-dark`) | state icons, signals, chips, review words |
| The page or block colour | `Color.groundPage`, `Color.groundCard` in `PRKitDesign/AppColor.swift` | every page and block |
| A spacing step | `spacing` above (`md: 12px`) | every gap and inset on that step |
| A corner | `rounded` above: `sm` buttons and fields, `md` boxes, `lg` chat | every button, field, box or bubble |
| A part's own measure | `PRKitDesign/Metrics.swift` (`PRStyle`, `ChatStyle`, `ChipStyle`, `MarkdownStyle`) | that part everywhere |
| How fast things move | `x-motion` above | every `AppMotion` animation |
| The icon style | `x-icons.variant` above | every SF Symbol |
| A meaning's icon | `PRKitDesign/AppIcon.swift` | every place showing that meaning |

PRKitDesign is public: a change there reaches Agent Pager at its next PRKit tag. A new or removed public name needs a
new minor version tag (AGENTS.md, Releases).

## Feature map

Every feature, where it lives, and what draws it. Before changing how something looks, find every row that shows it:
all of them are in scope. A new screen adds a row here and a step in `PRHubScreenshotTests`.

| Feature | Where | Drawn by |
|---|---|---|
| Sign in with GitHub | first run, on the hosted Worker | `OnboardingView`, `SignInWithGitHubButton`, `PageHeader`, `PRPageBlock` |
| Sign in again | GitHub signed the person out | `SignedOutView`, `PageHeader`, `PRPageBlock` |
| Connect to a pr-worker | first run, when the build allows it (`PRHUB_SELF_HOSTED`), under "Connect your own Worker" | `OnboardingView`, `SetupCodeScanner` |
| Sample PRs | onboarding's "Try with sample PRs" | the PR screens over `PRSampleSet.prHub` |
| PR list | PRs | `PRsView`, `PRsList`, `PrListBlock`, `PRSectionTitle`, `PRSwipeRow` |
| Review shortcut | PRs → a row's Review button, its swipe right, or its long-press menu | `PrListBlock`, `PRSwipeRow`, `PullRequestOpener` |
| PR filter | PRs → Filter | `PRFilterPanel`, `PRSectionTitle` |
| PR description | PRs → a PR: its title, who it is from, its tickets, then status, review and conversation | `PRScreen`, `PRDescriptionView`, `ObjectReferenceLines`, `PRChangesCard`, `PRStatusCard`, `PRReviewActions`, `.prCard()`, `PRCommentText`, `PRThreadCard` |
| Review in the background | PRs → a PR → Approve, Request changes or Comment → send: the box closes, the toast follows the review | `PRReviewComposer`, `PRReviewToastView` |
| Ask AI | PRs → a PR → the toolbar, a line's comment box, or a key line's Explain | `PRAskSheet`, `ChatView`, `SessionComposer` |
| PR diff | PRs → a PR → Review changes, or Files changed | `PRDiffScreen`, `DiffTableView`, `PRDiffPage`, `PRNavigator`, `PRReviewActions` |
| Settings | Settings; signed in: account, GitHub access, Anthropic key, Sign out, Delete account | `PRHubSettingsView`, `PRPageBlock`, `PRValueLine`, `AnthropicKeySection`, `DeleteAccountSheet` |
| GitHub access | Settings, signed in: each account the PRHub App is installed on (its repositories, Suspended), each opening its settings on GitHub, then Add another account; read again on every foreground | `GitHubAccessBlock`, `GitHubInstallationLine`, `PRAvatar`, `StatusChip` |
| Diff font | Settings → Diff font: a preview, the size (9 to 20 pt) and the face; every diff and code view follows it | `DiffFontSection`, `PRPageBlock`, `DiffFont` |
| No PRs yet | PRs, hosted, nothing listed: where the App is installed, and where it is missing or suspended | `PREmptyHint` in `PRsView` |
| iPad | the phone's tabs, every orientation; a regular width puts the list beside the PR | `PRsSplitView`, `PRDiffShortcuts`; `readableContentWidth()` centres scroll views |

## Overview

Principles, in order:

1. **A departures board.** One line per thing, the status always in the same place, so the eye learns where to look
   once. A row is finished when you can answer "what is it, where does it stand, what do I do" without reading all
   of it.
2. **Tight corners, roomy text, small type.** Corners are 6 and 8 pt; words sit 12 pt from a box's edge; text is
   footnote and caption, not body.
3. **Never stock.** iOS's defaults are where a screen starts, not where it ends: no `.bordered` capsules, no rounded
   text fields, no body-size text in a list.
4. **One part per thing.** A thing looks the same wherever it appears, because one view draws it.
5. **It moves.** Anything that opens, closes or arrives animates. A screen that jumps is unfinished.
6. **In place first.** Things open where the eye already is.

Hierarchy, most important first. Words get their weight from type; states from colour and shape.

1. **What is it:** the title. The only semibold line in a row.
2. **What do I do:** the note, and an "Asked again".
3. **Where does it stand:** state, then signals.
4. **Where and how old:** the meta line.
5. **What supports it:** the ticket. Weaker than every part of the PR.

The PR leads. A ticket leads only when an item has no PR. The app never says one thing twice: a title's `[NM-704]` goes
when the block shows NM-704.

## Colors

Every colour is a role in `PRKitDesign/AppColor.swift`. Views use the role, never a colour.

| Role | Use | Allowed on |
|---|---|---|
| Text | `Color.ink` (or `.primary`) | titles, notes |
| Quiet text | `Color.inkQuiet` (or `.secondary`) | meta, counts, section titles, what you did, the ticket line |
| Tones | `Color.toneGood`, `.toneBad`, `.toneWaiting`, `.toneMerged`: GitHub's, light and dark | a state, a signal, a review's word, a problem |
| On a colour | `Color.onAccent`: white in light, black in dark | words and spinners on the accent or a tone, except a chat bubble |
| On a bubble | `Color.onBubble`: white in light and dark | words on the person's own chat bubble |
| Accent | `.tint`, `Color.accentColor` | controls only: buttons, tab selection, a focused field's ring. Never a row's content |
| Ground | `Color.groundPage`, `Color.groundCard` | the page, and a block or box on it. Both, always: `.background` is black on black in dark |
| Fill | `Color.groundFill` | behind a field or a quiet button |
| Line | `Color.line` | a box's hairline border, or the edge between sidebar and detail |
| Scrim | `Color.scrim` | the dim under a side panel |
| Linear | `LinearMark`; a state's own colour from Linear's API | the mark and circle only, never words |

Tones are the colour sets DESIGN.md writes. Text, grounds, fill and line are the system's, so they follow Increase
Contrast and lift a step inside a sheet; their tokens above hold the same values. A tone means the same everywhere:
approved and passing are good, changes requested and failing are bad, pending and outdated are waiting. A review that
only commented is quiet, not a tone. `.tertiary` is not for words: it fails contrast. Nothing is told apart by colour
alone.

## Typography

Every style is `AppFont`: `.appTitle3`, `.appSubheadline`, `.appFootnote`, `.appCaption`, `.appCaption2`, or
`.app(_:design:weight:)`. Never `.body`, `.caption` or `.system(size:)`. Regular or semibold. One family, from the
tokens. Each style follows Dynamic Type.

The scale, at the default text size: caption2 11, caption 12, footnote 13, subheadline 15, callout 16, body 17,
title3 20.

**The Mac** has its own size for each style (`x-mac-typography`): caption2 11, caption 11, footnote 12, subheadline 13,
callout 13, body 14, title3 16, code 12. View → Make Text Bigger and Make Text Smaller scale all of them together
(`MacTextSize`); Actual Size is these sizes. What is sized with the text (an avatar, a mark, a row's padding) scales by
`MacTextSize.layoutScale`, the Mac's body over the iPhone's times the chosen scale, so it keeps its size beside the text.

| Style | Weight | Used for |
|---|---|---|
| `.appTitle3` | semibold | a screen's or a sheet's title (`PageHeader`) |
| `.appSubheadline` | semibold | an object's title (a PR row's title), and a heading over a page's comments |
| `.appFootnote` | semibold | a section's title (`PRSectionTitle`), a comment's author, buttons (`PRButtonStyle`) |
| `.appFootnote` | regular | notes, summaries, and all that people write on a PR (`PRCommentText`) |
| `.appCaption` | regular | meta, signals, what you did, the ticket line, a check's name |
| `.appCaption2` | semibold | inside a chip (`StatusChip`) |
| `.app(.caption, design: .monospaced)` | regular | a file and line reference outside the diff |
| `.appCallout` | regular | a chat message (`SessionBubble`) |

**A heading is a step bigger.** A section's heading is one step bigger than the content under it, and it follows the
content's size: when the content grows or shrinks, the heading moves with it. "Conversation" (subheadline) over comments
(footnote) is one; the diff's file header is the other: `DiffFont`'s face, bold, 2 pt over the code, at any diff font
and text size. Its chevron is the same size folded or open, and its viewed mark is about the path's size and grows with
it, in a tap target of 44 pt at least, the header row's height, that never
moves the path or the counts. A path too long for its row shrinks first, down to the code's size and no smaller, then is
cut from the front, so the file's name is what shows; the whole path is in the Files panel.

**The diff stops at its sideways edges.** The code stops at its left and right edges, with no bounce, so the file header
and the threads and notes, which stay where the screen is, are never pulled off it.

**The diff font.** Code (a diff, a code block, a line quoted in the comment box) is `DiffFont`: one monospaced face and
a size, chosen in Settings → Diff font and kept on the device. The default is the `code` token, the system's monospaced
font at 12 pt. The size follows Dynamic Type. The faces other than the system's ship in PRKit with their OFL licences.

## Layout

### Spacing

Space is 2, 4, 8, 12, 16 or 24 pt, `Space.xxs` to `Space.xl`: 2 for an optical nudge, 4 inside a group, 8 between
groups and between blocks, 12 for the avatar's gutter and a box's inset, 16 for page insets and the ticket's step in,
24 above a section. A gap that is none of these belongs to one part, and lives in `Metrics.swift` with a name.

Three columns, the same on every row: **leading** (avatar or `LeadingIcon`, `RowGrid.leading` 32 pt, grows with the
text; an icon is centred in it, so a wide icon never moves the title), **text**, and **state** (24 pt, right edge).
Text stays at the avatar's width plus 12, so a part that sits at the text column follows the avatar when the text
grows.

Division follows these boundaries. Keep edges quiet and continuous.

| Between | Signal |
|---|---|
| Sections | the section's title, on the page's grey |
| Blocks | a band of the page's grey, 8 pt, across the whole width |
| Sidebar and detail | a trailing `Color.line` hairline extending through the safe areas, with a soft `Color.scrim` shadow (`Space.sm` radius, `Space.xxs` offset) |
| A PR and its tickets | the rail: a line from the first avatar, turning right to each ticket |

Rows and blocks go to the screen's edges; their corners are square. A list with notes scrolls in a plain `VStack`: a
note's block measures its own height, and a `LazyVStack` rebuilds it from nothing and never settles. The PRs tab has no
notes, and is lazy.

### Corners

`Radius.sm` 6 for anything inside a block: a button, a field, a code block. `Radius.md` 8 for a box of its own
(`.prCard()`). `Radius.lg` 18 for a chat bubble and the chat field. Corners are continuous. A chip and a state icon's
ring are capsules and circles.

### Navigation

A PR and its diff are two screens on one stack, as on GitHub. `PRRoute` names them; `PRNavigation` holds them.

- **PR → diff is a push.** The PR's `PRChangesCard` (Files changed · N, with the lines added and removed, and Review
  changes) pushes the diff. Review changes opens its panel on Key lines, as the Review shortcut does, unless a
  line's comment box is open there; Files changed leaves the panel to its button. Back from the diff is the PR, and Back from the PR is where it came from. No
  segmented control switches them.
- **The Review shortcut.** A PR row's Review button (in the state column, under the state), its swipe right and its
  long-press menu push the PR with its diff on top, the panel open on Key lines. Back goes diff → PR → list, never
  skipping one. The menu also has Open, Open in GitHub and Copy link, and whatever the row's swipe holds.
- **Links land where they point.** A link to a PR opens the PR; a link to its files (`…/pull/N/files` or `/changes`)
  opens the diff with the PR under it.
- **Wide screens.** By size class, never by device. A regular width (an iPad, full screen or a wide Split View) puts the
  list in a column and the picked PR beside it; what the PR opens stacks over it there. A diff takes the list's room,
  and its panel is a column beside the code when there is room for both (`PRPanelPlacement`). A compact width (a phone,
  Slide Over, a narrow Split View) is the phone's stack. A change of width keeps what is open.
- **The keyboard.** On the diff: ⌥⌘↓ and ⌥⌘↑ the next and previous file, ⌃⌘V Viewed on the file at the top, ⌥⌘0 the
  panel (`PRDiffShortcuts`).

## Components

The shared parts. Use these; extend one rather than writing a near-copy. Each is the only place its thing is drawn.

| Part | What it draws | Where it lives |
|---|---|---|
| `PrListBlock`, `PullRequestRow`, `TicketRow` | an item in a list: its PRs, note and ticket | PRKit `Lists/` |
| `PullRequestLine`, `TicketLine` | a PR or ticket on one line, under something else | PRKit `Lists/ObjectLines.swift` |
| `ObjectReferenceLines`, `ObjectReferenceLine` | the PRs or tickets something names, a line each, each opening its page: a PR's tickets, Agent Pager's thread accessory | PRKit `Lists/ObjectLines.swift` |
| `PrStateIcon`, `PrStatusMarks`, `PrJaiMarkLabel` | a PR's state, its signals, what you did | PRKit `Lists/PrListParts.swift` |
| `PRSectionTitle` | a section's title on the page's grey | PRKit `Parts/` |
| `.prCard()` | a box on a PR's page | PRKit `PRParts.swift` |
| `PRAuthorLine`, `PRAvatar` | who said it and when | PRKit `PRParts.swift` |
| `PRCommentText`, `MarkdownText` | what people and agents write, in GitHub's Markdown: one renderer for descriptions, comments and chat | PRKit `Parts/Markdown*.swift` |
| `PRButtonStyle` | every button on a row or screen, its icon and words included | PRKit `PRParts.swift` |
| `PRReviewActions`, `PRReviewBar`, `PRReviewComposer` | a review: Approve, Request changes and Comment as one bar, and the box each opens, on a PR's page and under its diff | PRKit `PRReviewActions.swift` |
| `PRReviewToastView` | a review on its way after its box closed: Submitting, then what landed, or why it didn't with Retry | PRKit `PRReviewToast.swift` |
| `.prField(isFocused:)` | every field you type in | PRKit `PRParts.swift` |
| `InlineComposer` | writing on a PR, in place | PRKit `PRParts.swift` |
| `StatusChip` | state words outside lists | PRKit `Parts/` |
| `SessionBubble`, `SessionComposer` | a message in a chat, and its field; with `ComposerAttachments`, screenshots on it (a paperclip whose menu offers Photos, Files and, while the clipboard holds a picture, Paste; a tray of thumbnails above the field, no room taken while empty) | PRKit `Parts/` |
| `ChatView`, `ChatMessage` | the one chat screen: messages, ticks, tool lines, keeping the reader at the end, the field at the foot, and "Wait, what?" under the agent's newest words where the host turns it on (`waitWhat`; off in Ask AI and Feedback); a host's extras in its slots. Agent Pager's threads, Ask AI and Feedback are each one. A long press on a bubble is Copy, the whole message | PRKit `Parts/ChatView.swift` |
| `DeliveryTicksLine`, `.followsChatEnd` | under one of Jai's messages, how far it got (one tick: the Worker has it; two, the second half over the first: the agent has it); a chat that keeps its reader at its end as an answer grows it. Agent Pager's threads and Ask AI draw with the same ones | PRKit `Parts/` |
| `IconText`, `.labelStyle(.iconText)` | an icon and its words | PRKitDesign |
| `sidePanel` | a panel from the right | PRKit `Parts/SidePanel.swift` |
| `PRSwipeRow`, `PRSwipeAction` | the one swipe on a row: right for Review changes, left for Remove me | PRKit `Phone/`, `Parts/` |
| `PRChangesCard` | a PR's way into its diff: Files changed and Review changes | PRKit |
| `PRPageBlock`, `PRBlockNote`, `PRValueLine` | a page of blocks (onboarding, Sign in again, Settings): a block, the note under it, a setting's name and value | PRKit `Parts/PRPageBlock.swift` |
| `GitHubAccessBlock`, `GitHubInstallationLine` | where a GitHub App is installed: one line per account, opening its settings on GitHub | PRKit `Parts/GitHubAccessBlock.swift` |
| `PageHeader`, `ProblemLine` | PRHub's own pages: a title, why something failed | app `Views/PageParts.swift` |

### Status

Three kinds, one look each.

| Kind | What | Looks like | Where |
|---|---|---|---|
| State | where the object stands. Exactly one | PR: `PrStateIcon`. Ticket: `LinearStateCircle` | state column |
| Signal | a fact about a PR | `PrStatusMarks` | under the meta line |
| What you did | your review, or that you opened it | grey words; "Asked again" `toneWaiting`; "You're blocking" `toneBad`; "You approved" `toneGood` | last line |

A PR's state is GitHub's own, never worked out. First match wins:

| Data | State | Symbol | Tone |
|---|---|---|---|
| `found` is null | Resolving… | clock | quiet |
| `found` is false | Not found | question mark | `toneWaiting` |
| merged | Merged | GitHub's merged | `toneMerged` |
| closed | Closed | GitHub's closed | `toneBad` |
| draft | Draft | GitHub's draft | quiet |
| open | Open | GitHub's open | `toneGood` |
| anything else | Resolving… | clock | quiet |

Every icon comes from `AppIcon`, by meaning. A review is always a person: approved `person.fill.checkmark`, changes
requested `person.fill.xmark`, needs review `person.fill.questionmark`. A check is never a person: passing is a dot,
failing an x, running a clock. No two meanings share a symbol.

Signals are `signalMarks`: checks, review, merge, in that order. Merged and closed PRs have none. A draft's only merge
signal is Conflicts. No pills in a list: `StatusChip` is for elsewhere.

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
  review:  { row: 2, column: state, holds: "Review button (AppIcon.reviewChanges, accent), 44 pt to tap", optional: "where PR links push PR screens" }
states: [resolving, notFound, open, draft, merged, closed, faded, answered]
rules:
  - An empty optional part collapses. The state column never moves.
  - Meta gives way in this order, the name, then the repo's front. `#N` and the age stay.
  - Signals wrap whole. Words in status never truncate.
  - The Review button is the one button in a row. With it, meta and signals stop short of the state column.
  - A long press opens the row's menu: Open, Review changes, Open in GitHub, Copy link, then the swipe's actions.
  - Answered: you approved, requested changes or commented on a PR the list asked of you. It fades from the moment
    GitHub takes it, and stays until the PR closes. "You approved · 3m" says it in words.
antiPatterns:
  - A status anywhere but its part.
  - Any button inside the row but Review.
```

### Ticket line

```text
name: TicketLine
purpose: The ticket supporting a block's PRs, in Agent Pager's lists and on the PRs tab. Quiet. The whole line opens
  Linear, 44 pt tall at least.
parts:
  mark:   { column: text + 16, holds: LinearMark, size: 16 }
  key:    { after: mark, font: appCaption, never truncates }
  title:  { after: key, font: appCaption, lines: 1, gives way first, gone at xxLarge and up }
  word:   { before: circle, holds: Linear's state word, font: appCaption, never truncates }
  circle: { column: state, holds: LinearStateCircle }
rules:
  - One to a block, always last, on the rail.
  - No accent, no semibold, no chip.
```

### PR header

```text
name: PRDescriptionView.header
purpose: What the PR is, who it is from and what it is for, at the top of its page.
parts:
  title:   { holds: "the PR's title without the brackets of tickets shown below", font: appTitle3 semibold }
  state:   { holds: PrStateIcon, column: state }
  ref:     { holds: "repo#N", font: appCaption quiet }
  byline:  { holds: "PRAvatar and '<who> wants <branch> in <base>'", font: appCaption quiet }
  tickets: { holds: "ObjectReferenceLines of TicketLine, awaitsLinear false", optional: true }
  labels:  { holds: StatusChip per label, scrolls sideways, optional: true }
rules:
  - Who: the author's profile name, else their login. A bot's PR says "(bot)" after the bot's login, and leads with
    the person it was opened for when the Worker found one: "Mona Lisa via hubot (bot)". The face is that person's.
  - Tickets are the title's (in brackets), then the branch's, then the description's, as the Worker sends them, with
    Linear's state where it could ask. Without Linear a ticket is its key alone: no "Resolving…" that never resolves.
antiPatterns:
  - A ticket key both in the title and on a ticket line.
  - A bot shown as if a person wrote the PR.
```

### Toast

```text
name: PRReviewToastView
purpose: A review on its way after its box closed. It follows the review to GitHub's answer, over whatever is open.
parts:
  box:    { holds: "groundCard, Radius.md, hairline, ToastStyle's shadow, ToastStyle.maxWidth at most", place: "top, centred, Space.lg from the sides" }
  mark:   { holds: "a spinner while sending; AppIcon.done toneGood, .offline toneWaiting, .problem toneBad" }
  words:  { font: appFootnote semibold, lines: 3, holds: "Submitting review… (Posting comment…), Approved, Changes requested, Comment posted, Saved on this phone…, Review not sent. <why>" }
  bar:    { holds: "ToastStyle.progressHeight along its foot: the tint easing to ToastStyle.progressWhileSending while it goes, toneGood and full once landed", only: "sending, done" }
  retry:  { holds: PRButtonStyle(.secondary), only: failed }
  close:  { holds: AppIcon.close, only: failed }
states: [sending, waitingForNetwork, done, failed]
rules:
  - The box it came from closes at once, read-only while it goes. The review goes through the host's outbox, so it
    survives the app leaving the foreground; a late answer or refusal still reaches the toast.
  - It slides down from ToastStyle.travel above, past the top of the screen, and back up the same way, fading
    (AppMotion.fold); its words, mark and bar change in place (AppMotion.swap). Done stays ToastStyle.dwell, then goes.
    A line's Comment now and a reply go through it too, and it shows over a PR pushed on any tab. Failed stays until Retry or close, and gives the line comments back to the PR.
  - Opaque, never glass: over the nav bar, glass let the title's words show through its own. One at a time; a new
    review replaces it.
  - Success and failure each have their .sensoryFeedback.
antiPatterns:
  - A notice under the review bar for a review the toast is following.
  - Red for a review still going: offline is waiting, slow is still sending.
```

### Comment

```text
name: PRComment
purpose: What someone said on a PR. A review tool, not a chat: read as dense as the diff beside it, with room around the words.
parts:
  box:    { holds: .prCard(), radius: Radius.md, border: hairline }
  author: { holds: PRAuthorLine, avatar: 20, login: appFootnote semibold, age: appCaption }
  state:  { holds: StatusChip, tone: "the review's: Approved good, Changes requested bad, Reviewed quiet" }
  body:   { holds: PRCommentText, font: appFootnote, headings: appFootnote semibold }
rules:
  - Words sit PRStyle.inset (12) from the box on every side.
  - Box Radius.md, anything inside it Radius.sm.
antiPatterns:
  - MarkdownText without a font: it falls to 17 pt body.
  - A radius or inset typed in place of PRStyle.
---
name: InlineComposer
purpose: Writing, in place.
parts:
  field:  { holds: ".prField(isFocused:)", font: appFootnote, lines: 3 to 10 }
  cancel: { holds: PRButtonStyle(.plain) }
  other:  { holds: PRButtonStyle(.secondary), optional: true }
  send:   { holds: PRButtonStyle(.primary) }
rules:
  - Buttons sit at the right, send last. Approve stays at the left when its review box opens; Cancel stays at the right.
antiPatterns:
  - A sheet.
```

### Page and block

```text
name: PRPageBlock
purpose: A page of blocks (onboarding, Sign in again, Settings): a block on the page's grey, the width of the screen.
parts:
  header:  { holds: PageHeader, title: appTitle3 semibold, message: appFootnote quiet, once, at the top }
  title:   { holds: PRSectionTitle, optional: true, above the block }
  content: { inset: Space.lg, gap: Space.md, ground: groundCard }
  value:   { holds: PRValueLine, name: appFootnote, value: appFootnote quiet at the right, under the name at large text }
  note:    { holds: PRBlockNote, font: appCaption quiet, under the block, optional: true }
  problem: { holds: ProblemLine, under what it is about }
rules:
  - A field is .prField; a button is PRButtonStyle; a failure is ProblemLine, in place.
  - A destructive button (Delete account, Remove key, Disconnect) is PRButtonStyle(.secondary) tinted toneBad.
  - Whatever comes and goes in a block (a key set, an alert's state) folds in with AppMotion.fold.
antiPatterns:
  - A Form or inset-grouped list for a page of your own.
  - A LabeledContent: its value is body size.
```

### Icon and words

```text
name: IconText
purpose: An icon and its words on one line, wherever the two go together: a signal, a problem, "Key set".
parts:
  icon:  { holds: "AppIcon", slot: "fixed width (Space.lg, grows with the text)", aligned: leading }
  words: { after: icon, gap: Space.xs }
rules:
  - The icon sits on the words' first line (first text baseline).
  - Drawn by `Label(…).labelStyle(.iconText)` or `IconText(_:icon:)`; the font and colour come from around it.
antiPatterns:
  - HStack { Image; Text } with its own spacing or padding.
  - A list's default Label style, which puts the icon in a wide column of its own.
```

### Buttons and chips

```text
name: PRButtonStyle
purpose: Every button on a row or screen.
rules:
  - Primary for the one action a place asks (Connect, Save), secondary for the rest, plain for Cancel, chosen for a
    standing choice (your review in PRReviewBar): the tint's words on the tint at PRStyle.toneGroundOpacity.
  - Corner Radius.sm, height PRStyle.controlHeight, words appFootnote semibold.
  - The style lays out an icon and its words as `.iconText` does; a caller never sets a label style. Icon alone is
    `PRButtonStyle(_, iconOnly: true)`.
antiPatterns:
  - .bordered, .borderedProminent or .glassProminent on content. Glass only over the diff.
---
name: PRReviewBar
purpose: Approve, Request changes and Comment, wherever a review is sent: a PR's page and under its diff.
parts:
  buttons: { holds: "PRButtonStyle, words from the sides PRStyle.barButtonInset", widths: equal, gap: Space.sm }
  icons:   { holds: "AppIcon.reviewApproved, .reviewChangesRequested, .reviewCommented", label: "the words, for VoiceOver" }
rules:
  - One bar across the width of the content it sits in (the page's cards; the diff's column), each button the same width.
  - When one button's words don't fit its share, every button shows its icon instead, together.
  - Each is secondary: Approve's words in toneGood, Request changes' in toneBad, Comment's in the accent. None is solid:
    a solid one reads as already chosen. The author sees Comment alone.
  - Your standing review (Approved, Changes requested) is chosen: its icon and what you did ("Approved"), with
    `.isSelected`. It shows the moment you send it, ahead of the Worker. A tap opens its box again.
  - What a button opens (PRReviewComposer) opens in place: under the bar on the page, in the bar's place under the diff.
  - Under the diff it leaves with the bars as you read down, and returns with them.
antiPatterns:
  - A second way to send a review. The diff and the page share this one.
---
name: StatusChip
purpose: State words outside lists: a review's state on its comment, a label, Outdated, Pending.
parts: { words: appCaption2 semibold, ground: "its tone at PRStyle.toneGroundOpacity", shape: capsule }
```

### Other parts

- **A panel from the right:** `sidePanel`, over the page, dimming it with `Color.scrim`; a tap on the dim or a swipe
  right closes it. In place: no sheet. A diff's Files and Key lines (`PRNavigator`) use it. It opens on Key lines when
  the PR offers them, else on Files. Where a regular width has room (`PanelStyle`), the diff's panel is a column beside
  the code instead, open until its button puts it away, and a pick in it keeps it open.
- **A key line:** in Key lines, a heading (its kind as a `StatusChip`: Risk in `toneBad`, Decision and Logic quiet;
  its path and line, scrolling sideways, never cut; Explain, `AppIcon.askAI`, which asks Ask AI to explain that line;
  its tick), then why it matters across the whole width, copied whole from its long-press menu. Its note under the
  line in the diff: the kind and Close on top, the why (selectable, to copy), then Explain on the left and Mark
  reviewed / Reviewed on the right, as `PRButtonStyle(.secondary)` buttons. The note stays on screen while the code
  scrolls sideways, as threads and file headers do.
- **A PR at a glance:** `PRKeyLinesSummaryCard`, above the key lines on `groundFill`, and on a PR's page under its
  header as one of the page's cards (`prCard`), when the PR's key lines are already on the phone: the page never asks
  for them. Three parts, `Space.md` apart:
  its risk and why, the bugs found (each a tap to its line), and what it does. Each part has a heading, an icon and
  words through `IconText`'s line, `appSubheadline` semibold: the risk's `AppIcon.risk` in `toneBad` (high) or
  `toneWaiting` (medium), `.riskLow` in `toneGood`; `.ok` in `toneGood` for "No bugs found", `.bugsFound` in `toneBad`
  when there are some; `.whatItDoes`, quiet, over "What this does". Under a heading every line is `appFootnote` in the
  words' column, and a bullet's dot sits in the icons' column, so a second line stays under the first. No emoji: a
  heading's colour is its icon's tone.
- **A PR's link:** a long press on a PR's row, and on Open in GitHub in a PR's bar (a click and hold on the Mac),
  offers Copy link; the bar's also offers Share. A tap on Open in GitHub still opens it.
- **A key line's tick:** `PRKeyLineCheck`, `AppIcon.taskOpen` or `.taskDone` in `toneGood`, last in its heading in
  Key lines, 44 pt square; in the note it is the Mark reviewed button. A ticked line's words fade to
  `PRStyle.doneOpacity` and its controls stay, and the list says how many are reviewed. Previous and Next pass over
  ticked lines until all are ticked. Ticks are the Worker's, by head, so each device shows the same ones and a new
  commit starts again (docs/api.md, "Reviewed key lines").
- **A PR's checks:** each check once, as the Worker sends them (a check run again is its latest run). A name two
  workflows share says its workflow after it, quieter: "detect-changes · Test Coverage". A job's matrix legs ("visual
  proof (web 1/8)") are one line under the job's name with their count and their worst state ("visual proof · 8
  legs"), opening to the job's own check and each leg; one with a failing leg opens by itself
  (`PullRequestDetail.checkGroups`).
- **Markdown:** `MarkdownText` draws GitHub's flavour everywhere words are written: headings, nested and task lists
  (a description's tasks tick), quotes, rules, and bold, italic, strikethrough, `code` and links inline. A table is one
  grid, its header on `groundFill`, a hairline between rows, columns aligned as written; wider than the text it
  scrolls sideways, and a cell wraps at `MarkdownStyle.tableCellMaxWidth`. Fenced code scrolls sideways in the diff
  font. An image fits the width up to `MarkdownStyle.imageMaxHeight`, its alt text while it loads or when it can't be
  read. `<details>` is a fold that opens in place under its summary. Other HTML is dropped, keeping its words.
- **Room for the code:** on the phone the nav bar and tab bar leave as you scroll down and return as you scroll up, or
  when the keyboard goes. The diff runs under them, so they never move it. They never stay gone with no way back: they
  return at the top, when there is nothing to scroll, when a file folds or opens, on a tap of the status bar or below
  the last line, and when the diff comes back on screen. The edge swipe goes back to the PR while they are gone.
  `DiffBars` is the rule.

## Do's and Don'ts

- **Don't** type a number, colour or curve in a view. Use the token, or name it in `Metrics.swift`.
- **Don't** write a near-copy of a part. Extend the part.
- **Don't** put a status anywhere but its part.
- **Don't** use the accent for a link in a row. Position says it is a link.
- **Don't** add lines, boxes or shadows beyond the boundaries in Layout.
- **Don't** use the system's colours (`.green`, `.orange`, `.red`) for a state. Use its tone.
- **Don't** use `.bordered`, `.borderedProminent` or `.textFieldStyle(.roundedBorder)`. They read as stock.
- **Don't** use a list's swipe for a row: rows sit in a plain stack. `PRSwipeRow` is the one swipe, and it pans only
  sideways: right shows Review changes, left Remove me.
- **Don't** switch a PR and its diff in place. The diff is pushed, so Back is always one screen.
- **Don't** put glass on content. On a PR's screens it is for the controls that float over the diff: the panel button
  and the key line stepper.
- **Do** say a repo filter is on, under the switch: a filter can hide most of a list.
- **Do** check every screen in light, dark and large text (Checking).

`PrListState` is an enum from one function, so a state can't be a free word or colour. `PrListBlock`,
`PullRequestLine` and `TicketLine` are the only places a PR or ticket is laid out.

## Motion

Polish is part of done. A screen that jumps is unfinished.

- Anything that opens, closes or arrives animates, with `AppMotion`: `.fold` for opening, closing and arriving, `.swap`
  for one state replacing another and a picture arriving, `.press` for a press or focus, `.screen` for a Mac screen.
  SwiftUI does not animate a state change unless asked, so an unwrapped change simply jumps.
- Folding goes through `FoldSet`, whose toggle animates. Don't hold fold state in a plain `@State` Bool.
- Inserted content uses `.transition(.fold)`. UIKit rows use `insertRows`, `performBatchUpdates` or a cross-dissolve,
  not a bare `reloadData()`.
- Navigation pushes keep their animation.
- A success worth noticing gets `.sensoryFeedback`.

## In place first

Open things where the eye already is. A comment box on a diff line goes above the keyboard, with its line just over
it; a reply in its thread; an action's box under its button; a failure under what failed. Use a sheet only for a real
detour (Ask AI, Delete account).

## Checking

- `scripts/design-lint.sh` (or `make -C app design-lint`): no font size, colour, padding, gap, corner, animation or SF
  Symbol name typed in a view outside PRKitDesign; a symbol is its meaning in `AppIcon`. CI's design job runs it with
  `make -C app design-check`. A real exception carries `// design-lint: allow <why>` on its line or the line above; a
  file waiting on other work is listed in `scripts/design-lint-allow.txt` with its reason, or with `[symbols]` to be
  let off that one rule. AppIcon's raw values are unique, so the compiler refuses two meanings on one symbol: give the
  new meaning its own symbol, or use the existing case if it is the same meaning.
- `make -C app ui-test` writes a picture of every screen in the feature map, in light, dark and large text, to
  `app/build/screenshots` (CI uploads them). Look at them before calling UI work done; an agent reads the images, it
  doesn't count on a script to judge them.
- A screenshot cannot show motion. Record the Simulator (`xcrun simctl io <udid> recordVideo <file>`) while the UI
  tests or you drive the change, and look at frames from the recording.
