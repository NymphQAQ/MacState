#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${project_root}"
node --check Sources/MacState/Resources/Web/app.js
node --check Sources/MacState/Resources/Web/overview.js
node --check Sources/MacState/Resources/Web/disk-analysis.js
node scripts/generate-icons.js --check
bash -n scripts/build-app.sh
plutil -lint scripts/Info.plist

# Some Command Line Tools releases omit automatic TestingMacros discovery.
developer_dir="$(xcode-select -p)"
macro_library="${developer_dir}/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "${macro_library}" ]]; then
    swift test -Xswiftc -load-plugin-library -Xswiftc "${macro_library}"
else
    swift test
fi
