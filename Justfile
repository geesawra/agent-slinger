set shell := ["bash", "-euo", "pipefail", "-c"]

project := "Oesap.xcodeproj"
scheme := "Oesap"
bundle_identifier := "com.oesap.app"
simulator_destination := env_var_or_default("OESAP_SIMULATOR_DESTINATION", "")
simulator_udid := env_var_or_default("OESAP_SIMULATOR_UDID", "")
device_id := env_var_or_default("OESAP_DEVICE_ID", "")
development_team := env_var_or_default("OESAP_DEVELOPMENT_TEAM", "")
simulator_derived_data := ".build/ios-simulator"
device_derived_data := ".build/ios-device"

default: check

# Regenerate the Xcode project from the checked-in XcodeGen specification.
generate:
    ./Scripts/generate-project

# Run Swift Format's strict source linter over app and test code.
lint:
    swift format lint --recursive --strict Sources Tests

# Run the iOS test scheme on an explicitly selected iPhone simulator.
test: generate
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "{{simulator_destination}}" ]]; then
      printf 'Set OESAP_SIMULATOR_DESTINATION. Discover valid iPhone destinations with `just simulator-destinations`.\n' >&2
      exit 2
    fi
    xcodebuild test -project "{{project}}" -scheme "{{scheme}}" -destination "{{simulator_destination}}" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

# Compile the iOS app for a generic simulator destination.
compile: generate
    xcodebuild build -project "{{project}}" -scheme "{{scheme}}" -destination 'generic/platform=iOS Simulator' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

# Backwards-compatible alias for compile.
build: compile

# List Xcode's available destinations; select an iPhone simulator for tests.
simulator-destinations: generate
    xcodebuild -showdestinations -project "{{project}}" -scheme "{{scheme}}"

# Build, install, and launch on a booted or available iPhone simulator.
simulator: generate
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "{{simulator_udid}}" ]]; then
      printf 'Set OESAP_SIMULATOR_UDID to an available iPhone simulator UDID.\n' >&2
      exit 2
    fi
    xcrun simctl boot "{{simulator_udid}}" 2>/dev/null || true
    xcrun simctl bootstatus "{{simulator_udid}}" -b
    xcodebuild build -project "{{project}}" -scheme "{{scheme}}" -destination "platform=iOS Simulator,id={{simulator_udid}}" -derivedDataPath "{{simulator_derived_data}}" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
    xcrun simctl install "{{simulator_udid}}" "{{simulator_derived_data}}/Build/Products/Debug-iphonesimulator/Oesap.app"
    xcrun simctl launch --terminate-running-process "{{simulator_udid}}" "{{bundle_identifier}}"

# Build and install on a connected, provisioned iPhone.
device-install: generate
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "{{device_id}}" || -z "{{development_team}}" ]]; then
      printf 'Set OESAP_DEVICE_ID and OESAP_DEVELOPMENT_TEAM for device installation.\n' >&2
      exit 2
    fi
    xcodebuild build -project "{{project}}" -scheme "{{scheme}}" -destination "platform=iOS,id={{device_id}}" -derivedDataPath "{{device_derived_data}}" DEVELOPMENT_TEAM="{{development_team}}"
    xcrun devicectl device install app --device "{{device_id}}" "{{device_derived_data}}/Build/Products/Debug-iphoneos/Oesap.app"
    xcrun devicectl device process launch --terminate-existing --device "{{device_id}}" "{{bundle_identifier}}"

# Launch the installed app on a connected iPhone and stream its console.
device-console:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "{{device_id}}" ]]; then
      printf 'Set OESAP_DEVICE_ID to a connected iPhone device ID.\n' >&2
      exit 2
    fi
    xcrun devicectl device process launch --console --terminate-existing --device "{{device_id}}" "{{bundle_identifier}}"

# Follow Oesap logs from the configured iPhone simulator.
simulator-logs:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "{{simulator_udid}}" ]]; then
      printf 'Set OESAP_SIMULATOR_UDID to an available iPhone simulator UDID.\n' >&2
      exit 2
    fi
    xcrun simctl spawn "{{simulator_udid}}" log stream --style compact --level info --predicate 'subsystem == "{{bundle_identifier}}"'

# Read recent Oesap logs from the configured iPhone simulator.
simulator-logs-recent:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "{{simulator_udid}}" ]]; then
      printf 'Set OESAP_SIMULATOR_UDID to an available iPhone simulator UDID.\n' >&2
      exit 2
    fi
    xcrun simctl spawn "{{simulator_udid}}" log show --info --last 15m --style compact --predicate 'subsystem == "{{bundle_identifier}}"'

# Run the fast checks and simulator-compilable app build.
check: lint test compile
