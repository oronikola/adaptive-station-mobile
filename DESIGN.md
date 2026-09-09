# Adaptive Station Parent — first UI

A separate Flutter application for parents, connected to Adaptive Station in a future integration. It has no dependency on the Adaptive learning app. All names, gate events, dates and notification examples are explicitly sample data. No authentication, API, Firebase delivery or persistence is implemented by this UI prototype.

## Dashboard mockups

- `test/previews/dashboard-phone.png`: 390 × 844 phone viewport.
- `test/previews/dashboard-tablet.png`: 1280 × 1100 tablet viewport.
- Run with `flutter run`. Home, Attendance, Updates and Account are navigable. Child cards open filtered attendance; history filters and preview preference switches work.

## Alignment with Adaptive Station

Reference sources: `adaptive-station/resources/css/components/navigation.css`, `platform-dashboard.css`, `app.css`, and `tailwind.config.js`.

| Principle | Flutter implementation |
| --- | --- |
| Shared palette | Primary #0B2A5B, heading #071C44, blue #174A96, background #F4F7FD, muted #64748B, border #E7ECF4 |
| Typography | Bundled Plus Jakarta Sans; bold page heading, section heading, body, supporting metadata |
| Shell hierarchy | Persistent brand/navigation, white top bar, padded pale content area, grouped white cards |
| Cards | 18px radii, thin borders, soft shadow modeled on Station’s card token |
| Spacing | 8px base rhythm; 12–16px internal groups; 20px phone padding; 24px sections; 32px tablet padding |
| Buttons | Navy filled primary, outlined secondary, pill shape; minimum 48px touch height |
| Human focus | Children before logs, clear tap language, station/time context, text plus icons for status |
| Time semantics | AM/PM, GMT+8 context; a tap is not represented as continuous location tracking |

## Component breakdown

- `lib/design/station_theme.dart`: colors, typography, buttons, form fields and navigation theme.
- `lib/design/components.dart`: StationCard, StationAvatar, StationBrand, SectionHeading, StatusPill.
- `lib/data/demo_attendance.dart`: immutable student/tap models and isolated preview fixtures.
- `lib/features/dashboard/dashboard_screen.dart`: dashboard composition, ChildCard and reusable TapRow.
- `lib/features/dashboard/parent_shell.dart`: responsive navigation and secondary preview destinations.
- `lib/main.dart`: application entry point.

The form example lives under Account: a visibly disabled invitation field and primary action, with an explanation of the future school-approved linking flow. It does not pretend to create an account or connect a child.

## Responsive behavior

Below 760px: bottom navigation, single content area and scrollable stacked cards. From 760px: persistent 232px sidebar and 32px content padding. Child cards use two columns only when their actual content area reaches 620px; smaller tablets retain stacked cards. Main content is capped at 1100px. Labels wrap, controls have accessible tooltips, status includes text, and content remains scrollable.

## Next integration boundary

Replace the sample data source with authenticated parent API responses; keep widgets independent of HTTP and Firebase. Add school-approved parent/student relationships, secure token storage, loading/error/empty states, notification permission handling, and queued delivery for new server-accepted tap events. Preserve kiosk retry deduplication and identify delayed offline events. Keep persistent history as the source of truth rather than assuming every push arrives.

## Verification

`flutter analyze` and `flutter test` cover phone/tablet layouts, child filtering and notification preference interaction. Golden images can be deliberately regenerated using `flutter test --update-goldens` after reviewing visual changes.
