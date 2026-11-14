#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )) || [[ -n "${1:-}" && "${1}" != --ad-hoc ]]; then
    printf 'Usage: %s [--ad-hoc]\n' "${0}" >&2
    exit 1
fi
if [[ "${1:-}" == --ad-hoc ]]; then
    identity_hash="-"
else
    # Keep the same local certificate across builds so privacy grants can match updates.
    signing_identity="${MACSTATE_CODESIGN_IDENTITY:-MacState Local Code Signing}"
    identity_hash="$(security find-identity -v -p codesigning | awk -v identity="${signing_identity}" '
        $2 == identity || index($0, "\"" identity "\"") { print $2 }
    ')"
    if [[ -z "${identity_hash}" || "${identity_hash}" == *$'\n'* ]]; then
        printf 'Expected one valid code-signing identity: %s\nInstall the existing certificate and private key; do not recreate them for each build.\n' "${signing_identity}" >&2
        exit 1
    fi
fi
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${project_root}"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="${project_root}/dist/MacState.app"
mkdir -p "${app_dir}/Contents/MacOS" "${app_dir}/Contents/Resources"
cp "${binary_dir}/MacState" "${app_dir}/Contents/MacOS/MacState"
cp -R "${binary_dir}/MacState_MacState.bundle" "${app_dir}/Contents/Resources/"
cp "${project_root}/scripts/Info.plist" "${app_dir}/Contents/Info.plist"
if [[ -f "${project_root}/scripts/AppIcon.icns" ]]; then
    cp "${project_root}/scripts/AppIcon.icns" "${app_dir}/Contents/Resources/"
fi
codesign --force --sign "${identity_hash}" "${app_dir}"
codesign --verify --deep --strict "${app_dir}"
printf "Built: %s\n" "${app_dir}"
