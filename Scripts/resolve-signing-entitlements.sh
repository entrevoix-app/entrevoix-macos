#!/bin/zsh

set -euo pipefail

source_entitlements_path=${1:-}
provisioning_profile_path=${2:-}
resolved_entitlements_path=${3:-}

if [[ -z "$source_entitlements_path" || -z "$provisioning_profile_path" || -z "$resolved_entitlements_path" ]]; then
    print -u2 "Usage: $0 source-entitlements provisioning-profile output-entitlements"
    exit 64
fi

team_identifier=$(
    /usr/bin/security cms -D -i "$provisioning_profile_path" \
        | /usr/bin/xmllint --xpath 'string(//key[.="ApplicationIdentifierPrefix"]/following-sibling::array[1]/string[1])' -
)
if [[ ! "$team_identifier" =~ '^[A-Z0-9]+$' ]]; then
    print -u2 "Unable to read a valid team identifier from the Developer ID provisioning profile."
    exit 1
fi

/usr/bin/sed \
    -e "s/\\\$(TeamIdentifierPrefix)/$team_identifier./g" \
    -e "s/\\\$(TeamIdentifier)/$team_identifier/g" \
    "$source_entitlements_path" > "$resolved_entitlements_path"

profile_application_identifier=$(
    /usr/bin/security cms -D -i "$provisioning_profile_path" \
        | /usr/bin/xmllint --xpath 'string(//key[.="com.apple.application-identifier"]/following-sibling::string[1])' -
)
resolved_application_identifier=$(
    /usr/bin/xmllint --xpath 'string(//key[.="com.apple.application-identifier"]/following-sibling::string[1])' "$resolved_entitlements_path"
)
if [[ -z "$profile_application_identifier" || "$profile_application_identifier" != "$resolved_application_identifier" ]]; then
    print -u2 "The Developer ID provisioning profile must authorize the app identifier '$resolved_application_identifier'."
    exit 1
fi

cloudkit_container='iCloud.app.entrevoix.shared'
profile_cloudkit_container_count=$(
    /usr/bin/security cms -D -i "$provisioning_profile_path" \
        | /usr/bin/xmllint --xpath "count(//key[.=\"com.apple.developer.icloud-container-identifiers\"]/following-sibling::array[1]/string[.=\"$cloudkit_container\"])" -
)
resolved_cloudkit_container_count=$(
    /usr/bin/xmllint --xpath "count(//key[.=\"com.apple.developer.icloud-container-identifiers\"]/following-sibling::array[1]/string[.=\"$cloudkit_container\"])" "$resolved_entitlements_path"
)
resolved_cloudkit_service_count=$(
    /usr/bin/xmllint --xpath 'count(//key[.="com.apple.developer.icloud-services"]/following-sibling::array[1]/string[.="CloudKit"])' "$resolved_entitlements_path"
)
if [[ "$profile_cloudkit_container_count" != "1" || "$resolved_cloudkit_container_count" != "1" || "$resolved_cloudkit_service_count" != "1" ]]; then
    print -u2 "The Developer ID provisioning profile and app entitlements must authorize the CloudKit container '$cloudkit_container'."
    exit 1
fi
