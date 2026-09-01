#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

swift test --enable-code-coverage -Xswiftc -warnings-as-errors
coverage_json="$(swift test --show-codecov-path)"
application_coverage_pattern='(/Sources/Entrevoix/(Presentation/Stores/[^/]+|Adapters/(Accessibility/FocusedTextElementResolver|Codex/CodexCleanupService|Delivery/TextDelivery|Providers/ProviderRouters))|/Vendor/entrevoix-shared/Sources/(EntrevoixAppleAdapters/(KeychainStore|UserDefaultsPreferencesStore)|EntrevoixOpenAIAdapters/(OpenAITextCleanupService|OpenAITranscriptionService|RemoteModelCatalogClient|SafeNetworkSession)))\.swift$'

if [[ ! -f "$coverage_json" ]]; then
    echo "Coverage report not found: $coverage_json" >&2
    exit 1
fi

print_files() {
    local group_filter="$1"
    jq -r \
        --arg group "$group_filter" \
        --arg applicationPattern "$application_coverage_pattern" \
        '.data[0].files[]
        | select(
            if $group == "core" then
                .filename | contains("/Vendor/entrevoix-shared/Sources/EntrevoixCore/")
            else
                .filename | test($applicationPattern)
            end
        )
        | "  \(.filename): \(.summary.lines.covered)/\(.summary.lines.count) lines (\(.summary.lines.percent * 100 | round / 100)%)"' \
        "$coverage_json" | sort
}

check_group() {
    local label="$1"
    local group_filter="$2"
    local threshold="$3"
    local metrics
    metrics="$(jq -r \
        --arg group "$group_filter" \
        --arg applicationPattern "$application_coverage_pattern" \
        '[.data[0].files[]
          | select(
              if $group == "core" then
                    .filename | contains("/Vendor/entrevoix-shared/Sources/EntrevoixCore/")
              else
                  .filename | test($applicationPattern)
              end
          )
          | .summary.lines]
        | [(map(.covered) | add // 0), (map(.count) | add // 0)]
        | @tsv' \
        "$coverage_json")"

    local covered
    local total
    read -r covered total <<< "$metrics"
    if [[ "$total" -eq 0 ]]; then
        echo "$label: no source files found in coverage report" >&2
        return 1
    fi

    local percentage
    percentage="$(awk -v covered="$covered" -v total="$total" 'BEGIN { printf "%.2f", covered * 100 / total }')"
    echo "$label: $covered/$total lines ($percentage%, required: $threshold%)"
    print_files "$group_filter"

    if (( covered * 100 < total * threshold )); then
        echo "$label coverage is below $threshold%" >&2
        return 1
    fi
}

failure=0
check_group "Shared EntrevoixCore" "core" 85 || failure=1
check_group "Testable application logic" "application" 80 || failure=1
exit "$failure"
