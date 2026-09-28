set shell := ["bash", "-euo", "pipefail", "-c"]

project := "Oesap.xcodeproj"
scheme := "Oesap"
bundle_identifier := "com.oesap.app"
simulator_destination := env_var_or_default("OESAP_SIMULATOR_DESTINATION", "")
simulator_udid := env_var_or_default("OESAP_SIMULATOR_UDID", "")
development_team := env_var_or_default("OESAP_DEVELOPMENT_TEAM", "")
simulator_derived_data := ".build/ios-simulator"
device_derived_data := ".build/ios-device"
mac_derived_data := ".build/mac-catalyst"
mac_destination := "platform=macOS,variant=Mac Catalyst"

default: check

# Regenerate the Xcode project from the checked-in XcodeGen specification.
generate:
    ./Scripts/generate-project

# Run Swift Format's strict source linter over app and test code.
lint:
    swift format lint --recursive --strict Sources Tests

# Exercise device selection without contacting or installing on any device.
test-scripts:
    python3 -m unittest discover -s Tests/ScriptTests -v

# Run the iOS test scheme on an explicitly selected iPhone or iPad simulator.
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

# List Xcode's available destinations; select an iPhone or iPad simulator for tests.
simulator-destinations: generate
    xcodebuild -showdestinations -project "{{project}}" -scheme "{{scheme}}"

# Build, install, and launch on a booted or available iPhone or iPad simulator.
simulator: generate
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "{{simulator_udid}}" ]]; then
      printf 'Set OESAP_SIMULATOR_UDID to an available iPhone or iPad simulator UDID.\n' >&2
      exit 2
    fi
    xcrun simctl boot "{{simulator_udid}}" 2>/dev/null || true
    xcrun simctl bootstatus "{{simulator_udid}}" -b
    xcodebuild build -project "{{project}}" -scheme "{{scheme}}" -destination "platform=iOS Simulator,id={{simulator_udid}}" -derivedDataPath "{{simulator_derived_data}}" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
    xcrun simctl install "{{simulator_udid}}" "{{simulator_derived_data}}/Build/Products/Debug-iphonesimulator/Oesap.app"
    xcrun simctl launch --terminate-running-process "{{simulator_udid}}" "{{bundle_identifier}}"

# Build, install, and launch on a selected, provisioned iPhone or iPad.
device-install: generate
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "{{development_team}}" ]]; then
      printf 'Set OESAP_DEVELOPMENT_TEAM for device installation.\n' >&2
      exit 2
    fi
    selected_device_id="$(python3 Scripts/select_connected_device.py)"
    printf 'Using device: %s\n' "$selected_device_id"
    xcodebuild build -project "{{project}}" -scheme "{{scheme}}" -destination "platform=iOS,id=${selected_device_id}" -derivedDataPath "{{device_derived_data}}" DEVELOPMENT_TEAM="{{development_team}}"
    xcrun devicectl device install app --device "$selected_device_id" "{{device_derived_data}}/Build/Products/Debug-iphoneos/Oesap.app"
    xcrun devicectl device process launch --terminate-existing --device "$selected_device_id" "{{bundle_identifier}}"

# Launch the installed app on a selected iPhone or iPad and stream its console.
device-console:
    #!/usr/bin/env bash
    set -euo pipefail
    selected_device_id="$(python3 Scripts/select_connected_device.py)"
    xcrun devicectl device process launch --console --terminate-existing --device "$selected_device_id" "{{bundle_identifier}}"

# Follow Oesap logs from the configured iPhone or iPad simulator.
simulator-logs:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "{{simulator_udid}}" ]]; then
      printf 'Set OESAP_SIMULATOR_UDID to an available iPhone or iPad simulator UDID.\n' >&2
      exit 2
    fi
    xcrun simctl spawn "{{simulator_udid}}" log stream --style compact --level info --predicate 'subsystem == "{{bundle_identifier}}"'

# Read recent Oesap logs from the configured iPhone or iPad simulator.
simulator-logs-recent:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "{{simulator_udid}}" ]]; then
      printf 'Set OESAP_SIMULATOR_UDID to an available iPhone or iPad simulator UDID.\n' >&2
      exit 2
    fi
    xcrun simctl spawn "{{simulator_udid}}" log show --info --last 15m --style compact --predicate 'subsystem == "{{bundle_identifier}}"'

# Run the fast checks and simulator-compilable app build.
check: lint test-scripts test compile

# Compile a provisioned Mac Catalyst app with working Keychain access.
mac-build: generate
    #!/usr/bin/env bash
    set -euo pipefail
    resolved_signing_team="$(python3 Scripts/read_development_team.py)"
    xcodebuild build -project "{{project}}" -scheme "{{scheme}}" -destination "{{mac_destination}}" -derivedDataPath "{{mac_derived_data}}" -allowProvisioningUpdates CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES "CODE_SIGN_IDENTITY=Apple Development" CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=${resolved_signing_team}"

# Build and open the Mac Catalyst app; never installs on a mobile device.
mac-run: mac-build
    open -n "{{mac_derived_data}}/Build/Products/Debug-maccatalyst/Oesap.app"

# Run shared unit tests and Mac Catalyst UI smoke tests with development signing.
mac-test: generate
    #!/usr/bin/env bash
    set -euo pipefail
    resolved_signing_team="$(python3 Scripts/read_development_team.py)"
    xcodebuild test -project "{{project}}" -scheme "{{scheme}}" -destination "{{mac_destination}}" -derivedDataPath "{{mac_derived_data}}" -allowProvisioningUpdates -only-testing:OesapTests -only-testing:OesapUITests/WorkspacePlatformUITests -only-testing:OesapUITests/ChatPerformanceUITests CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES "CODE_SIGN_IDENTITY=Apple Development" CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=${resolved_signing_team}"
