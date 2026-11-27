# Pull to refresh: is the PR list getting stuck?

Issue #55. PRKit watches each pull to refresh of the PR list and of a PR's page (`PRListRefreshWatch`; every event
says which in `screen`: `list` or `pr`) and PRHub sends what it saw to
PostHog. It also writes the same fields to the system log, under PRHub's subsystem with the category `refresh`, so a
sysdiagnose shows them too. The events carry counts and states only, never anything about a PR.

| Event | When | Properties |
|---|---|---|
| `pr_list_refresh_started` | A pull begins | `rows`, `screen` |
| `pr_list_refresh_finished` | It ends | `outcome` (ok, error, cancelled, offline), `duration_ms`, `rows_before`, `rows_after`, `source` (network, cached), `screen`, and the scroll view at that moment: `end_scroll` (resting, gliding, dragged), `end_offset_y`, `end_inset_top`, `end_gap` (points below rest, the spinner's room counted as rest), `ms_since_lift` (since the finger lifted; -1 if it had not) |
| `pr_list_refresh_stuck` | The list is not back at rest 2 s after the end | `gap` (points below rest), `content_offset_y`, `adjusted_inset_top`, `resting_inset_top`, `is_refreshing`, `is_loading`, `is_interacting` (0 or 1), `scene` |
| `pr_list_refresh_backgrounded` | The app leaves the foreground mid-refresh | `ms` since the pull began, `screen` |

`outcome` is what the read said. Up to build 318 most pulls said `cancelled`: SwiftUI cancels a pull's task whenever the
refresh changes the screen, and the watch took that for the outcome. A PR page's pull has no rows (`rows` 0) and its
`cancelled` means the read itself was cancelled or the page had nothing loaded.

## Stuck refreshes per build

Paste into PostHog's SQL editor (HogQL). A build with the fix (ec39b68, first in 0.24.1) should show no stuck rows.

```sql
SELECT
    properties.$app_build AS build,
    countIf(event = 'pr_list_refresh_finished') AS refreshes,
    countIf(event = 'pr_list_refresh_stuck') AS stuck,
    round(100 * stuck / nullIf(refreshes, 0), 1) AS stuck_pct,
    median(if(event = 'pr_list_refresh_stuck', toFloat(properties.gap), NULL)) AS median_gap,
    countIf(event = 'pr_list_refresh_stuck' AND properties.is_loading = 1) AS stuck_while_loading
FROM events
WHERE event IN ('pr_list_refresh_finished', 'pr_list_refresh_stuck')
  AND timestamp > now() - INTERVAL 30 DAY
GROUP BY build
ORDER BY build DESC
```

## Reading a stuck event

- **`gap` comes from the offset** (`content_offset_y` below `-adjusted_inset_top`): the scroll view was left pulled down.
- **`gap` comes from the inset** (`adjusted_inset_top` above `resting_inset_top`): the refresh control's room was never
  given back.
- **`is_loading` 1:** a sync was still running when the list should have been at rest.
- **`pr_list_refresh_backgrounded` just before it:** leaving the app mid-refresh is the trigger.
