#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

if [[ -d Sources/EntrevoixCore ]]; then
    echo "EntrevoixCore belongs to the entrevoix-shared package, not this repository." >&2
    exit 1
fi

adapter_owned_ports='protocol (PermissionProviding|HotkeyHandling|LaunchAtLoginControlling|FeedbackPlaying)'
if find Sources/Entrevoix/Adapters -type f -name '*.swift' -print0 \
    | xargs -0 grep -nH -E "$adapter_owned_ports"; then
    echo "System-facing ports must live in the shared EntrevoixCore package." >&2
    exit 1
fi

adapter_types="$(
    find Sources/Entrevoix/Adapters -type f -name '*.swift' -print0 \
        | xargs -0 grep -hEo \
            '^(@MainActor )?(private )?(final )?(class|struct|actor) [A-Z][A-Za-z0-9_]*' \
        | awk '{ print $NF }' \
        | sort -u \
        | paste -sd '|' -
)"
composition_owned_types="${adapter_types}|AppLogStore|ListeningIndicatorController|QueuedProviderAlertPresenter"
adapter_construction="(^|[^[:alnum:]_])(${composition_owned_types})[[:space:]]*\\("
violations="$(
    find Sources/Entrevoix/App Sources/Entrevoix/Presentation \
        -type f -name '*.swift' \
        ! -path 'Sources/Entrevoix/App/CompositionRoot.swift' \
        -print0 \
        | xargs -0 grep -nH -E "$adapter_construction" \
        || true
)"
if [[ -n "$violations" ]]; then
    echo "Concrete adapters may only be constructed in App/CompositionRoot.swift:" >&2
    printf '%s\n' "$violations" >&2
    exit 1
fi

echo "Architecture boundaries verified."
