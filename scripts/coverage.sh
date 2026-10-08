#!/bin/bash
# Use SwiftPM's paths so the report follows the selected architecture and toolchain.
set -euo pipefail

kit="$(cd "$(dirname "$0")/../Packages/OTMKit" && pwd)"
swift test --package-path "$kit" --enable-code-coverage
codecov="$(swift test --package-path "$kit" --enable-code-coverage --show-codecov-path)"
bin="$(swift build --package-path "$kit" --show-bin-path)"
profdata="$(dirname "$codecov")/default.profdata"

if [[ ! -s "$codecov" || ! -s "$profdata" ]]; then
    echo "SwiftPM did not produce coverage data beside $codecov" >&2
    exit 1
fi

# macOS bundles put the executable under Contents/MacOS, not beside the profdata.
binaries=()
while IFS= read -r -d '' candidate; do
    binaries+=("$candidate")
done < <(find "$bin" -path '*.xctest/Contents/MacOS/*' -type f -perm -111 -print0)
if [[ ${#binaries[@]} -ne 1 ]]; then
    echo "Expected one SwiftPM test executable under $bin; found ${#binaries[@]}" >&2
    exit 1
fi
sources=()
while IFS= read -r -d '' source; do
    sources+=("$source")
done < <(find "$kit/Sources/OTMKit" -name '*.swift' -type f -print0)
if [[ ${#sources[@]} -eq 0 ]]; then
    echo "No OTMKit sources found under $kit" >&2
    exit 1
fi

report="$(mktemp)"
trap 'rm -f "$report"' EXIT
# Restrict both the rows and TOTAL to library sources, excluding tests and the CLI.
xcrun llvm-cov report "${binaries[0]}" -instr-profile="$profdata" -use-color=false \
    -show-region-summary=false --sources "${sources[@]}" > "$report"
cat "$report"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        printf '### OTMKit source coverage\n\n```text\n'
        cat "$report"
        printf '```\n'
    } >> "$GITHUB_STEP_SUMMARY"
fi
