#!/bin/zsh

set -euo pipefail

application_path=${1:-}
if [[ -z "$application_path" ]]; then
    print -u2 "Usage: $0 /path/to/Entrevoix.app"
    exit 64
fi

contents_path="$application_path/Contents"
executable_path="$contents_path/MacOS/Entrevoix"
sparkle_binary="$contents_path/Frameworks/Sparkle.framework/Versions/B/Sparkle"
localization_bundle="$contents_path/Resources/Entrevoix_Entrevoix.bundle"
icon_path="$contents_path/Resources/Entrevoix.icon"
compiled_icon_path="$contents_path/Resources/Entrevoix.icns"
compiled_assets_path="$contents_path/Resources/Assets.car"
keyboard_shortcuts_bundle="$contents_path/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle"
binary_directory="$application_path:h"
raw_resource_bundle="$binary_directory/Entrevoix_Entrevoix.bundle"
disabled_resource_directory=$(mktemp -d "$binary_directory/.entrevoix-localization-verification.XXXXXX")
disabled_resource_bundle="$disabled_resource_directory/Entrevoix_Entrevoix.bundle"

restore_raw_bundle() {
    local original_status=$?
    if [[ -d "$disabled_resource_bundle" ]]; then
        if [[ ! -e "$raw_resource_bundle" ]]; then
            /bin/mv "$disabled_resource_bundle" "$raw_resource_bundle"
        else
            /bin/rm -rf -- "$disabled_resource_bundle"
        fi
    fi
    /bin/rmdir "$disabled_resource_directory" 2>/dev/null || true
    exit "$original_status"
}
trap restore_raw_bundle EXIT

[[ -d "$application_path" ]] || { print -u2 "Missing application bundle: $application_path"; exit 1; }
[[ -x "$executable_path" ]] || { print -u2 "Missing executable: $executable_path"; exit 1; }
[[ -x "$sparkle_binary" ]] || { print -u2 "Missing Sparkle framework binary: $sparkle_binary"; exit 1; }
[[ -f "$icon_path/icon.json" ]] || { print -u2 "Missing layered app icon: $icon_path"; exit 1; }
[[ -f "$compiled_icon_path" ]] || { print -u2 "Missing compiled app icon: $compiled_icon_path"; exit 1; }
[[ -f "$compiled_assets_path" ]] || { print -u2 "Missing compiled asset catalog: $compiled_assets_path"; exit 1; }
[[ -d "$keyboard_shortcuts_bundle" ]] || {
    print -u2 "Missing KeyboardShortcuts resource bundle: $keyboard_shortcuts_bundle"
    exit 1
}
icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$contents_path/Info.plist" 2>/dev/null || true)
[[ "$icon_name" == "Entrevoix" ]] || { print -u2 "Unexpected app icon name: $icon_name"; exit 1; }
icon_file=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$contents_path/Info.plist" 2>/dev/null || true)
[[ "$icon_file" == "Entrevoix" ]] || { print -u2 "Unexpected app icon file: $icon_file"; exit 1; }
for localization in en fr-FR; do
    [[ -f "$localization_bundle/$localization.lproj/Localizable.strings" ]] || {
        print -u2 "Missing compiled localization: $localization_bundle/$localization.lproj/Localizable.strings"
        exit 1
    }
done

if ! /usr/bin/otool -L "$executable_path" | /usr/bin/grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle'; then
    print -u2 "Entrevoix does not link against Sparkle through @rpath."
    exit 1
fi

if ! /usr/bin/otool -l "$executable_path" | /usr/bin/grep -A3 'cmd LC_RPATH' | /usr/bin/grep -Fq '@executable_path/../Frameworks'; then
    print -u2 "Entrevoix is missing the Frameworks rpath."
    exit 1
fi

/usr/bin/codesign --verify --deep --strict "$application_path"
/usr/bin/codesign --verify --deep --strict "$contents_path/Frameworks/Sparkle.framework"

if [[ "${ENTREVOIX_REQUIRE_ICLOUD_PROVISIONING_PROFILE:-0}" == "1" ]]; then
    application_team_identifier=$(
        /usr/bin/codesign -dvv "$application_path" 2>&1 \
            | /usr/bin/sed -n 's/^TeamIdentifier=//p'
    )
    sparkle_team_identifier=$(
        /usr/bin/codesign -dvv "$sparkle_binary" 2>&1 \
            | /usr/bin/sed -n 's/^TeamIdentifier=//p'
    )
    if [[ -z "$application_team_identifier" || "$application_team_identifier" != "$sparkle_team_identifier" ]]; then
        print -u2 "Entrevoix and Sparkle.framework must use the same Team ID."
        exit 1
    fi
fi

entitlements_output=$(/usr/bin/codesign -d --entitlements :- "$application_path" 2>/dev/null || true)
if ! print -r -- "$entitlements_output" | /usr/bin/grep -Fq '<key>com.apple.security.device.audio-input</key>'; then
    print -u2 "Entrevoix is missing the microphone audio-input entitlement."
    exit 1
fi

if [[ "${ENTREVOIX_REQUIRE_ICLOUD_PROVISIONING_PROFILE:-0}" == "1" ]]; then
    provisioning_profile="$contents_path/embedded.provisionprofile"
    [[ -f "$provisioning_profile" ]] || {
        print -u2 "Entrevoix is missing its embedded Developer ID provisioning profile."
        exit 1
    }
    cloudkit_container='iCloud.app.entrevoix.shared'
    profile_cloudkit_container_count=$(
        /usr/bin/security cms -D -i "$provisioning_profile" \
            | /usr/bin/xmllint --xpath "count(//key[.=\"com.apple.developer.icloud-container-identifiers\"]/following-sibling::array[1]/string[.=\"$cloudkit_container\"])" -
    )
    signed_cloudkit_container_count=$(print -r -- "$entitlements_output" | /usr/bin/xmllint --xpath "count(//key[.=\"com.apple.developer.icloud-container-identifiers\"]/following-sibling::array[1]/string[.=\"$cloudkit_container\"])" -)
    signed_cloudkit_service_count=$(print -r -- "$entitlements_output" | /usr/bin/xmllint --xpath 'count(//key[.="com.apple.developer.icloud-services"]/following-sibling::array[1]/string[.="CloudKit"])' -)
    profile_application_identifier=$(
        /usr/bin/security cms -D -i "$provisioning_profile" \
            | /usr/bin/xmllint --xpath 'string(//key[.="com.apple.application-identifier"]/following-sibling::string[1])' -
    )
    signed_application_identifier=$(print -r -- "$entitlements_output" | /usr/bin/xmllint --xpath 'string(//key[.="com.apple.application-identifier"]/following-sibling::string[1])' -)
    if [[ "$profile_cloudkit_container_count" != "1" || "$signed_cloudkit_container_count" != "1" || "$signed_cloudkit_service_count" != "1" || "$profile_application_identifier" != "$signed_application_identifier" ]]; then
        print -u2 "Entrevoix and its Developer ID provisioning profile must authorize the CloudKit container '$cloudkit_container'."
        exit 1
    fi
fi

if [[ -d "$raw_resource_bundle" && "$raw_resource_bundle" != "$contents_path/Resources/Entrevoix_Entrevoix.bundle" ]]; then
    /bin/mv "$raw_resource_bundle" "$disabled_resource_directory/"
fi

executable_output() {
    "$executable_path" --verify-localization "$1" "${@:2}"
}

assert_output() {
    local mode="$1"
    local expected="$2"
    shift 2
    local actual
    if ! actual="$(executable_output "$mode" "$@")"; then
        print -u2 "Localization verification could not run for $mode."
        exit 1
    fi
    if [[ "$actual" != "$expected" ]]; then
        print -u2 "Unexpected localization output for $mode:"
        print -u2 "$actual"
        print -u2 "Expected:"
        print -u2 "$expected"
        exit 1
    fi
}

assert_output "french" $'locale=fr-FR\nonboarding.welcome.title=Bienvenue dans Entrevoix\nmenu.settings=Réglages\naction.next=Suivant'
assert_output "english" $'locale=en\nonboarding.welcome.title=Welcome to Entrevoix\nmenu.settings=Settings\naction.next=Next'
assert_output "automatic" $'locale=fr-FR\nonboarding.welcome.title=Bienvenue dans Entrevoix\nmenu.settings=Réglages\naction.next=Suivant' \
    -AppleLanguages '(fr-FR)'
assert_output "automatic" $'locale=en\nonboarding.welcome.title=Welcome to Entrevoix\nmenu.settings=Settings\naction.next=Next' \
    -AppleLanguages '(de-DE)'

keyboard_shortcuts_output="$("$executable_path" --verify-keyboard-shortcuts)"
if [[ "$keyboard_shortcuts_output" != "keyboardShortcuts.resourceBundle=available" ]]; then
    print -u2 "KeyboardShortcuts resource bundle verification failed:"
    print -u2 "$keyboard_shortcuts_output"
    exit 1
fi

print "Verified app bundle: $application_path"
