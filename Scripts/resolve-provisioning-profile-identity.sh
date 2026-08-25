#!/bin/zsh

set -euo pipefail

provisioning_profile_path=${1:-}
if [[ -z "$provisioning_profile_path" || ! -f "$provisioning_profile_path" ]]; then
    print -u2 "Usage: $0 /path/to/Developer-ID.provisionprofile"
    exit 64
fi

profile_certificate_sha1=$(
    /usr/bin/security cms -D -i "$provisioning_profile_path" \
        | /usr/bin/plutil -extract DeveloperCertificates.0 raw -o - - \
        | /usr/bin/base64 -D \
        | /usr/bin/openssl x509 -inform der -noout -fingerprint -sha1 \
        | /usr/bin/sed -n 's/^.*Fingerprint=//p' \
        | /usr/bin/tr -d ':'
)
if [[ ! "$profile_certificate_sha1" =~ '^[0-9A-F]{40}$' ]]; then
    print -u2 "Unable to read the Developer ID certificate from the provisioning profile."
    exit 1
fi

identity=$(
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/awk -v fingerprint="$profile_certificate_sha1" '$2 == fingerprint { print $2; exit }'
)
if [[ -z "$identity" ]]; then
    print -u2 "The Developer ID certificate authorized by the provisioning profile ($profile_certificate_sha1) is not available with its private key in the current keychains."
    exit 1
fi

print "$identity"
