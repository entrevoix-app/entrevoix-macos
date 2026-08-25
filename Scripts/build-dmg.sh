#!/bin/zsh

set -euo pipefail

version=${ENTREVOIX_VERSION:-}
build_number=${ENTREVOIX_BUILD_NUMBER:-1}
signing_identity=${ENTREVOIX_SIGNING_IDENTITY:--}
provisioning_profile_path=${ENTREVOIX_PROVISIONING_PROFILE_PATH:-}

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
    print -u2 "ENTREVOIX_VERSION must use the x.y.z format."
    exit 1
fi
if [[ ! "$build_number" =~ '^[0-9]+$' ]]; then
    print -u2 "ENTREVOIX_BUILD_NUMBER must be an integer."
    exit 1
fi

script_directory=${0:A:h}
repository_directory=${script_directory:h}
binary_directory=$(swift build --package-path "$repository_directory" -c release --show-bin-path)
"$repository_directory/Scripts/patch-keyboard-shortcuts-resources.sh"
application_path="$binary_directory/Entrevoix.app"
contents_path="$application_path/Contents"
release_directory="$repository_directory/.build/release-artifacts"
dmg_path="$release_directory/Entrevoix-$version-macos.dmg"
staging_directory=$(mktemp -d "${TMPDIR:-/tmp}/entrevoix-release.XXXXXX")

cleanup() {
    /bin/rm -rf -- "$staging_directory"
}
trap cleanup EXIT

if [[ "$application_path" != "$binary_directory/Entrevoix.app" || "$binary_directory" != *"/.build/"* ]]; then
    print -u2 "Unexpected bundle path: $application_path"
    exit 1
fi

swift build --package-path "$repository_directory" -c release
/bin/rm -rf -- "$application_path"
/bin/mkdir -p "$contents_path/MacOS" "$contents_path/Frameworks" "$contents_path/Resources" "$release_directory" "$staging_directory"
/usr/bin/install -m 755 "$binary_directory/Entrevoix" "$contents_path/MacOS/Entrevoix"
/bin/cp "$repository_directory/Configuration/Info.plist" "$contents_path/Info.plist"
/usr/bin/ditto "$repository_directory/Configuration/AppIcon/Entrevoix.icon" "$contents_path/Resources/Entrevoix.icon"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$contents_path/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$contents_path/Info.plist"

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

if [[ -z "$provisioning_profile_path" || ! -f "$provisioning_profile_path" ]]; then
    print -u2 "A Developer ID provisioning profile is required when signing an app with iCloud entitlements."
    exit 1
fi
if [[ "$signing_identity" != "-" ]]; then
    profile_signing_identity=$("$repository_directory/Scripts/resolve-provisioning-profile-identity.sh" "$provisioning_profile_path")
    if [[ "$signing_identity" != "$profile_signing_identity" ]]; then
        print -u2 "ENTREVOIX_SIGNING_IDENTITY must match the Developer ID certificate authorized by the provisioning profile ($profile_signing_identity)."
        exit 1
    fi
fi
/bin/cp "$provisioning_profile_path" "$contents_path/embedded.provisionprofile"
signing_entitlements_path="$staging_directory/Entrevoix.entitlements"
"$repository_directory/Scripts/resolve-signing-entitlements.sh" \
    "$repository_directory/Configuration/Entrevoix.entitlements" \
    "$provisioning_profile_path" \
    "$signing_entitlements_path"

if [[ "$signing_identity" == "-" ]]; then
    /usr/bin/codesign --force --deep --sign - \
        --entitlements "$signing_entitlements_path" \
        "$application_path"
else
    /usr/bin/codesign --force --deep --options runtime --timestamp --sign "$signing_identity" \
        --entitlements "$signing_entitlements_path" \
        "$application_path"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$application_path"
export ENTREVOIX_REQUIRE_ICLOUD_PROVISIONING_PROFILE=1
"$repository_directory/Scripts/verify-app-bundle.sh" "$application_path"

/bin/mv "$application_path" "$staging_directory/Entrevoix.app"
/bin/ln -s /Applications "$staging_directory/Applications"
/bin/rm -f -- "$dmg_path" "$dmg_path.sha256"
/usr/bin/hdiutil create -volname "Entrevoix $version" -srcfolder "$staging_directory" -ov -format UDZO "$dmg_path"
dmg_checksum=$(/usr/bin/shasum -a 256 "$dmg_path" | /usr/bin/cut -d ' ' -f 1)

print "DMG: $dmg_path"
print "DMG SHA-256: $dmg_checksum"
