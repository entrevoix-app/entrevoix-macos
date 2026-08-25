#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_directory=${script_directory:h}
cloudkit_environment=${ENTREVOIX_CLOUDKIT_ENVIRONMENT:-Development}
case "$cloudkit_environment" in
    Development)
        default_provisioning_profile_path="$repository_directory/../Entrevoix_macOS_Development_Mac.provisionprofile"
        source_entitlements_path="$repository_directory/Configuration/Entrevoix.development.entitlements"
        ;;
    Production)
        default_provisioning_profile_path="$repository_directory/../Entrevoix.provisionprofile"
        source_entitlements_path="$repository_directory/Configuration/Entrevoix.entitlements"
        ;;
    *)
        print -u2 "ENTREVOIX_CLOUDKIT_ENVIRONMENT must be Development or Production."
        exit 64
        ;;
esac
if [[ ! -f "$default_provisioning_profile_path" ]]; then
    primary_worktree=$(git -C "$repository_directory" worktree list --porcelain | awk '/^worktree / { print substr($0, 10); exit }')
    if [[ -n "$primary_worktree" ]]; then
        default_provisioning_profile_path="${primary_worktree:h}/$(basename "$default_provisioning_profile_path")"
    fi
fi
ENTREVOIX_PROVISIONING_PROFILE_PATH=${ENTREVOIX_PROVISIONING_PROFILE_PATH:-"$default_provisioning_profile_path"}
signing_directory=$(mktemp -d "${TMPDIR:-/tmp}/entrevoix-development-signing.XXXXXX")

cleanup() {
    /bin/rm -rf -- "$signing_directory"
}
trap cleanup EXIT

swift build --package-path "$repository_directory"
binary_directory=$(swift build --package-path "$repository_directory" --show-bin-path)
"$repository_directory/Scripts/patch-keyboard-shortcuts-resources.sh"
swift build --package-path "$repository_directory"
application_path="$binary_directory/Entrevoix.app"
contents_path="$application_path/Contents"

if [[ "$application_path" != "$binary_directory/Entrevoix.app" || "$binary_directory" != *"/.build/"* ]]; then
    print -u2 "Unexpected bundle path: $application_path"
    exit 1
fi

if /usr/bin/pgrep -x Entrevoix >/dev/null; then
    print "Closing all running Entrevoix instances before launching the development build."
    /usr/bin/pkill -TERM -x Entrevoix || true

    for _ in {1..20}; do
        if ! /usr/bin/pgrep -x Entrevoix >/dev/null; then
            break
        fi
        /bin/sleep 0.5
    done

    if /usr/bin/pgrep -x Entrevoix >/dev/null; then
        print "Some Entrevoix instances did not quit within 10 seconds; forcing them to stop."
        /usr/bin/pkill -KILL -x Entrevoix || true

        for _ in {1..10}; do
            if ! /usr/bin/pgrep -x Entrevoix >/dev/null; then
                break
            fi
            /bin/sleep 0.1
        done

        if /usr/bin/pgrep -x Entrevoix >/dev/null; then
            print -u2 "Unable to stop every Entrevoix instance; aborting without rebuilding the development app."
            exit 1
        fi
    fi
fi

/bin/rm -rf -- "$application_path"
/bin/mkdir -p "$contents_path/MacOS" "$contents_path/Frameworks" "$contents_path/Resources"
/usr/bin/install -m 755 "$binary_directory/Entrevoix" "$contents_path/MacOS/Entrevoix"
/bin/cp "$repository_directory/Configuration/Info.plist" "$contents_path/Info.plist"
/usr/bin/ditto "$repository_directory/Configuration/AppIcon/Entrevoix.icon" "$contents_path/Resources/Entrevoix.icon"

if ! actool_path=$(/usr/bin/xcrun --find actool 2>/dev/null); then
    print -u2 "A full Xcode installation is required to compile the app icon."
    exit 1
fi
icon_partial_plist="$contents_path/Resources/Entrevoix-icon-partial.plist"
"$actool_path" \
    --compile "$contents_path/Resources" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon Entrevoix \
    --output-partial-info-plist "$icon_partial_plist" \
    "$repository_directory/Configuration/AppIcon/Entrevoix.icon" >/dev/null
/bin/rm -f -- "$icon_partial_plist"

sparkle_framework="$binary_directory/Sparkle.framework"
if [[ ! -d "$sparkle_framework" ]]; then
    print -u2 "Missing Sparkle framework: $sparkle_framework"
    exit 1
fi
/usr/bin/ditto "$sparkle_framework" "$contents_path/Frameworks/Sparkle.framework"
/usr/bin/install_name_tool \
    -add_rpath "@executable_path/../Frameworks" \
    "$contents_path/MacOS/Entrevoix"

if ! xcstringstool_path=$(/usr/bin/xcrun --find xcstringstool 2>/dev/null); then
    print -u2 "A full Xcode installation is required to compile Entrevoix localization catalogs."
    exit 1
fi

localization_bundle="$contents_path/Resources/Entrevoix_Entrevoix.bundle"
if [[ ! -d "$binary_directory/Entrevoix_Entrevoix.bundle" ]]; then
    print -u2 "Missing Entrevoix resource bundle: $binary_directory/Entrevoix_Entrevoix.bundle"
    exit 1
fi
/usr/bin/ditto "$binary_directory/Entrevoix_Entrevoix.bundle" "$localization_bundle"
"$xcstringstool_path" compile "$localization_bundle/Localizable.xcstrings" --output-directory "$localization_bundle"
"$xcstringstool_path" compile "$localization_bundle/InfoPlist.xcstrings" --output-directory "$localization_bundle"

for localization_directory in "$localization_bundle"/*.lproj; do
    [[ -d "$localization_directory" ]] || continue
    localization_name=${localization_directory:t}
    /bin/mkdir -p "$contents_path/Resources/$localization_name"
    if [[ -f "$localization_directory/InfoPlist.strings" ]]; then
        /bin/cp "$localization_directory/InfoPlist.strings" "$contents_path/Resources/$localization_name/InfoPlist.strings"
    fi
done

for required_resource in \
    "$localization_bundle/en.lproj/Localizable.strings" \
    "$localization_bundle/fr-FR.lproj/Localizable.strings" \
    "$contents_path/Resources/fr-FR.lproj/InfoPlist.strings"; do
    [[ -f "$required_resource" ]] || { print -u2 "Missing localized resource: $required_resource"; exit 1; }
done

resource_bundle="$binary_directory/KeyboardShortcuts_KeyboardShortcuts.bundle"
if [[ -d "$resource_bundle" ]]; then
    /usr/bin/ditto "$resource_bundle" "$contents_path/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle"
fi

signing_entitlements_path="$signing_directory/Entrevoix.entitlements"
if [[ -f "$ENTREVOIX_PROVISIONING_PROFILE_PATH" ]]; then
    codesign_identity=${ENTREVOIX_CODESIGN_IDENTITY:-}
    if [[ -z "$codesign_identity" ]]; then
        codesign_identity=$("$repository_directory/Scripts/resolve-provisioning-profile-identity.sh" "$ENTREVOIX_PROVISIONING_PROFILE_PATH")
    fi
    print "Signing development app with the identity authorized by the provisioning profile: $codesign_identity"
    /bin/cp "$ENTREVOIX_PROVISIONING_PROFILE_PATH" "$contents_path/embedded.provisionprofile"
    "$repository_directory/Scripts/resolve-signing-entitlements.sh" \
        "$source_entitlements_path" \
        "$ENTREVOIX_PROVISIONING_PROFILE_PATH" \
        "$signing_entitlements_path"
    export ENTREVOIX_REQUIRE_ICLOUD_PROVISIONING_PROFILE=1
else
    if [[ "${ENTREVOIX_ALLOW_ADHOC_SIGNING:-0}" != "1" ]]; then
        print -u2 "A provisioning profile is required when signing an app with iCloud entitlements. Set ENTREVOIX_PROVISIONING_PROFILE_PATH to its path."
        exit 1
    fi
    print "No provisioning profile is available; assembling a CI-only ad hoc bundle without CloudKit entitlements."
    /bin/cp "$source_entitlements_path" "$signing_entitlements_path"
    for entitlement in \
        com.apple.application-identifier \
        aps-environment \
        com.apple.developer.icloud-container-environment \
        com.apple.developer.icloud-container-development-container-identifiers \
        com.apple.developer.icloud-container-identifiers \
        com.apple.developer.icloud-services \
        com.apple.developer.team-identifier; do
        if /usr/libexec/PlistBuddy -c "Print :$entitlement" "$signing_entitlements_path" >/dev/null 2>&1; then
            /usr/libexec/PlistBuddy -c "Delete :$entitlement" "$signing_entitlements_path"
        fi
    done
    codesign_identity=-
    unset ENTREVOIX_REQUIRE_ICLOUD_PROVISIONING_PROFILE
fi

if [[ "$codesign_identity" == "-" ]]; then
    /usr/bin/codesign --force --deep --sign - "$contents_path/Frameworks/Sparkle.framework"
    /usr/bin/codesign --force --sign - \
        --entitlements "$signing_entitlements_path" \
        "$application_path"
elif [[ "$cloudkit_environment" == "Development" ]]; then
    /usr/bin/codesign --force --deep --options runtime --sign "$codesign_identity" \
        "$contents_path/Frameworks/Sparkle.framework"
    /usr/bin/codesign --force --options runtime --sign "$codesign_identity" \
        --entitlements "$signing_entitlements_path" \
        "$application_path"
else
    # Sign embedded code before the enclosing app. Re-signing the app deeply can
    # leave Sparkle with a different Team ID, which dyld refuses to load.
    /usr/bin/codesign --force --deep --options runtime --timestamp --sign "$codesign_identity" \
        "$contents_path/Frameworks/Sparkle.framework"
    /usr/bin/codesign --force --options runtime --timestamp --sign "$codesign_identity" \
        --entitlements "$signing_entitlements_path" \
        "$application_path"
fi
"$repository_directory/Scripts/verify-app-bundle.sh" "$application_path"
if [[ "${ENTREVOIX_SKIP_OPEN:-0}" == "1" ]]; then
    print "Assembled Entrevoix without launching it: $application_path"
else
    /usr/bin/open "$application_path"
    print "Entrevoix launched from $application_path"
fi
