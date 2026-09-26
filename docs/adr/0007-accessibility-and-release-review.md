# ADR 0007: Accessibility and release review checkpoint

- Status: Accepted for the MVP checkpoint
- Date: 2026-09-26

## Context

The MVP review found targeted interface improvements and several distribution
configuration gaps. The app accesses app-owned preferences through
`UserDefaults`. Apple lists reason `CA92.1` for UserDefaults access to
app-only preferences in its [required-reason API documentation](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

The tracked `Oesap-Info.plist` contained literal version values (`1.0` and
`1`), but the built review product lacked those version keys and `project.yml`
had no explicit version settings. The project also lacked a launch screen;
Apple's [launch-screen submission requirements](https://developer.apple.com/documentation/technotes/tn3208-preparing-your-apps-launch-screen-to-meet-app-store-requirements)
require one for apps built with the iOS 27 SDK or later.

The bundle identifier remains provisional as documented in ADR 0001. The
checkpoint version is likewise provisional: `0.1.0` with build number `1` is a
development baseline, not an approved public release version.

## Decisions

- Add `PrivacyInfo.xcprivacy` with only the
  `NSPrivacyAccessedAPICategoryUserDefaults` accessed API declaration and
  reason `CA92.1`, for app-only preferences. Do not declare data collection,
  tracking, or unrelated required-reason APIs without verified evidence.
- Configure an empty `UILaunchScreen` dictionary through XcodeGen. A branded
  launch screen can be considered when final launch artwork is available.
- Set `MARKETING_VERSION` to `0.1.0` and `CURRENT_PROJECT_VERSION` to `1` in
  `project.yml`, and bind the generated `CFBundleShortVersionString` and
  `CFBundleVersion` values to those settings.
- Keep `project.yml` as the configuration source of truth and regenerate the
  project and generated `Oesap-Info.plist` with `just generate`.
- Focus the MVP accessibility pass on larger touch targets and clear labels
  for compact controls, readable adaptive message colors, layouts that reflow
  at accessibility text sizes, and wording that accurately describes
  session-only drafts. Continue reviewing the remaining workspace, tool-call,
  empty-state, light/dark, and VoiceOver flows before distribution.

## Consequences

The app target carries a required-reason manifest for its confirmed
UserDefaults usage, and its generated Info.plist has an explicit launch screen
and version source. The empty launch screen is configuration only; it does not
provide custom launch artwork. Version values and the bundle identifier must be
confirmed before distribution. This checkpoint does not claim full Apple HIG
conformance or complete App Store readiness; policy/support information,
distribution identity, icon artwork, review access, and any remaining
accessibility checks still require release work.
