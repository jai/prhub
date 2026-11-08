# App Store privacy answers

The answers for PRHub's App Privacy section in App Store Connect (app 6831601628). Jai submits them. They match
[PRIVACY.md](../PRIVACY.md), [the hosted policy](privacy/hosted.md) and `app/PRHub/PrivacyInfo.xcprivacy`.

## Data collection

**Do you or your third-party partners collect data from this app?** Yes.

Apple counts data as collected when it leaves the phone and is kept longer than needed to serve a request. PRHub's
anonymous usage events to PostHog are the only such data that goes to Jai or a partner. Data that goes only to a
Worker that the user deployed is not collected by the developer.

## Data types

Select two types: **Usage Data → Product Interaction**, and **Diagnostics → Performance Data** (how long a PR took to
open, and whether an alert's PR was fetched before the tap: `pr_opened`, `push_prefetch`). For each, answer:

| Question | Answer |
|---|---|
| Purposes | Analytics |
| Is it linked to the user's identity? | No |
| Is it used for tracking? | No |

Leave every other type unselected:

- **Identifiers (User ID, Device ID).** The random ID that the app makes is not linked to an account, and it is not
  the advertising identifier.
- **Contact Info, User Content, Location, Browsing History, Search History, Crash Data, Other Diagnostic Data.** The
  events carry none of these. Crash reports go through TestFlight only, and Apple discloses them.

## Hosted service

Sign in with GitHub sends the GitHub user ID and the user's PRs to the hosted service. Apple counts that as collection
if the developer keeps it. Answer these types too while the hosted service is on:

| Type | Purposes | Linked to identity | Tracking |
|---|---|---|---|
| Identifiers → User ID | App Functionality | Yes | No |
| User Content → Other User Content (pull requests, comments) | App Functionality | Yes | No |

## Tracking

PRHub does not track. It does not use the advertising identifier (IDFA), does not combine its data with other
companies' data and shares nothing with data brokers. So:

- No App Tracking Transparency prompt is needed, and the app does not call `ATTrackingManager`.
- `NSPrivacyTracking` is `false` in the privacy manifest, with no tracking domains.
