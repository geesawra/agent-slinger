# ADR 0001: iOS project setup

- Status: Accepted for the initial scaffold
- Date: 2026-09-25

## Context

Oesap is a greenfield, native iOS client. The repository needs a reproducible
project-generation workflow before app implementation begins. Hydraulophone
provides a working precedent for keeping project configuration in YAML and
generating the Xcode project from the command line.

## Decisions

- Use XcodeGen 2.46.0 and keep `project.yml` as the project configuration
  source of truth.
- Generate `Oesap.xcodeproj` with `Scripts/generate-project`; it skips an
  existing project unless passed `--force`. Do not commit or edit the generated
  project directly.
- Target iPhone only. Do not add iPad, Mac, or Mac Catalyst targets.
- Carry over Hydraulophone's iOS 17.0 deployment target as the initial Oesap
  baseline.
- Use `com.oesap.app` as a provisional development bundle identifier. Confirm
  its ownership and replace it if needed before distribution.
- Use `Justfile` for the repeatable generation, lint, build, test, simulator,
  and connected-device workflows. Simulator names/UDIDs are selected from
  installed destinations rather than guessed in the recipes.

## Consequences

The generated Xcode project can be recreated locally with the pinned tool
version, while source review remains focused on the checked-in specification.
The initial configuration deliberately contains no Mac, Catalyst, or iPad
target. The deployment target and bundle identifier are documented bootstrap
choices and should be revisited before release planning.
