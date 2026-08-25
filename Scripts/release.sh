#!/bin/zsh

set -euo pipefail

required_variables=(
    ENTREVOIX_VERSION
    ENTREVOIX_BUILD_NUMBER
    DEVELOPER_ID_CERTIFICATE_BASE64
    DEVELOPER_ID_CERTIFICATE_PASSWORD
    DEVELOPER_ID_PROVISIONING_PROFILE_BASE64
    BUILD_KEYCHAIN_PASSWORD
    APP_STORE_CONNECT_KEY_BASE64
    APP_STORE_CONNECT_KEY_ID
    APP_STORE_CONNECT_ISSUER_ID
)

for variable in "${required_variables[@]}"; do
    if [[ -z "${(P)variable:-}" ]]; then
        print -u2 "Required environment variable: $variable"
        exit 1
    fi
done

script_directory=${0:A:h}
repository_directory=${script_directory:h}
info_plist_path="$repository_directory/Configuration/Info.plist"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/entrevoix-signing.XXXXXX")
certificate_path="$temporary_directory/developer-id.p12"
provisioning_profile_path="$temporary_directory/entrevoix.provisionprofile"
keychain_path="$temporary_directory/entrevoix-signing.keychain-db"
api_key_path="$temporary_directory/AuthKey_$APP_STORE_CONNECT_KEY_ID.p8"
original_keychains=("${(@f)$(security list-keychains -d user | sed 's/^[[:space:]]*"\(.*\)"$/\1/')}")

sparkle_feed_url=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$info_plist_path" 2>/dev/null || true)
sparkle_public_ed_key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$info_plist_path" 2>/dev/null || true)
if [[ -z "$sparkle_feed_url" || "$sparkle_feed_url" == "https://example.com/entrevoix/appcast.xml" || "$sparkle_feed_url" != "https://entrevoix-app.github.io/entrevoix-macos/appcast.xml" ]]; then
	print -u2 "Set SUFeedURL in Configuration/Info.plist to https://entrevoix-app.github.io/entrevoix-macos/appcast.xml before release. Sparkle appcast feed URL required."
    exit 1
fi
if [[ -z "$sparkle_public_ed_key" || "$sparkle_public_ed_key" == "REPLACE_WITH_SPARKLE_ED25519_PUBLIC_KEY" || "$sparkle_public_ed_key" == "TODO_REPLACE_WITH_PRODUCTION_SPARKLE_ED25519_PUBLIC_KEY_DO_NOT_RELEASE" || "$sparkle_public_ed_key" == TODO_* ]]; then
    print -u2 "Set SUPublicEDKey in Configuration/Info.plist before release. Sparkle EdDSA public key required."
    exit 1
fi

cleanup() {
    security list-keychain -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
    security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
    /bin/rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

printf '%s' "$DEVELOPER_ID_CERTIFICATE_BASE64" | /usr/bin/base64 -D > "$certificate_path"
printf '%s' "$DEVELOPER_ID_PROVISIONING_PROFILE_BASE64" | /usr/bin/base64 -D > "$provisioning_profile_path"
if ! /usr/bin/security cms -D -i "$provisioning_profile_path" | /usr/bin/xmllint --xpath 'count(//key[.="com.apple.developer.icloud-container-identifiers"]/following-sibling::array[1]/string[.="iCloud.app.entrevoix.shared"])' - | /usr/bin/grep -qx '1'; then
    print -u2 "The Developer ID provisioning profile does not authorize the iCloud.app.entrevoix.shared CloudKit container."
    exit 1
fi
security create-keychain -p "$BUILD_KEYCHAIN_PASSWORD" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$BUILD_KEYCHAIN_PASSWORD" "$keychain_path"
security import "$certificate_path" -k "$keychain_path" -P "$DEVELOPER_ID_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$BUILD_KEYCHAIN_PASSWORD" "$keychain_path"
security list-keychain -d user -s "$keychain_path" "${original_keychains[@]}"

signing_identity=$("$script_directory/resolve-provisioning-profile-identity.sh" "$provisioning_profile_path")

export ENTREVOIX_SIGNING_IDENTITY="$signing_identity"
export ENTREVOIX_PROVISIONING_PROFILE_PATH="$provisioning_profile_path"
export ENTREVOIX_REQUIRE_ICLOUD_PROVISIONING_PROFILE=1
"$script_directory/build-dmg.sh"

dmg_path="$repository_directory/.build/release-artifacts/Entrevoix-$ENTREVOIX_VERSION-macos.dmg"
printf '%s' "$APP_STORE_CONNECT_KEY_BASE64" | /usr/bin/base64 -D > "$api_key_path"

xcrun notarytool submit "$dmg_path" \
    --key "$api_key_path" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
dmg_checksum=$(/usr/bin/shasum -a 256 "$dmg_path" | /usr/bin/cut -d ' ' -f 1)

print "Notarized DMG: $dmg_path"
print "Notarized DMG SHA-256: $dmg_checksum"
print "Sparkle feed URL: $sparkle_feed_url"
print "Appcast publication: GitHub Actions workflow signs and uploads appcast.xml as a release asset. Do not publish appcast manually."
