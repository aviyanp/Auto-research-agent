#!/usr/bin/env bash
# Build a clean, portable macOS 14+ universal app on an ephemeral macOS runner.
# Local development and user research workspaces remain subject to check_workspace.py.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This packaging script requires macOS." >&2
  exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
WORK_ROOT="${RESEARCH_RELEASE_WORK_ROOT:-${RUNNER_TEMP:-$PROJECT_ROOT/.build}/autoresearch-universal}"
DIST="$WORK_ROOT/dist"
STAGE="$WORK_ROOT/staging"
APP="$STAGE/Auto Research.app"
RESOURCES="$APP/Contents/Resources"
mkdir -p "$DIST" "$RESOURCES" "$APP/Contents/MacOS"
rm -rf "$STAGE"
mkdir -p "$RESOURCES" "$APP/Contents/MacOS"

# Separate build directories are mandatory: we explicitly merge both binaries.
for arch in arm64 x86_64; do
  scratch="$WORK_ROOT/build-$arch"
  echo "::group::Compiling $arch"
  swift build -c release --arch "$arch" --scratch-path "$scratch"
  bin_dir="$(swift build -c release --arch "$arch" --scratch-path "$scratch" --show-bin-path)"
  test -x "$bin_dir/AutoResearch"
  actual="$(lipo -archs "$bin_dir/AutoResearch")"
  if [[ "$actual" != "$arch" ]]; then
    echo "Expected a single $arch slice, found: $actual" >&2
    exit 1
  fi
  echo "::endgroup::"
done

arm_bin="$(swift build -c release --arch arm64 --scratch-path "$WORK_ROOT/build-arm64" --show-bin-path)/AutoResearch"
intel_bin="$(swift build -c release --arch x86_64 --scratch-path "$WORK_ROOT/build-x86_64" --show-bin-path)/AutoResearch"
lipo -create "$arm_bin" "$intel_bin" -output "$APP/Contents/MacOS/AutoResearch"
chmod 755 "$APP/Contents/MacOS/AutoResearch"
lipo -verify_arch arm64 x86_64 "$APP/Contents/MacOS/AutoResearch"
file "$APP/Contents/MacOS/AutoResearch"
lipo -info "$APP/Contents/MacOS/AutoResearch"

# Use an explicit allowlist. No local credentials, settings, sessions or checkouts
# are copied into distributable artifacts.
for name in ResearchPolicy.md ContinuePolicy.md CatalogPolicy.json BuiltinProjects.json \
  SharedContextDefaults.json SharedAgentPolicy.md SharedContextPolicy.md \
  Agent37Defaults.json DaytonaDefaults.json DaytonaWorker.py \
  MethodTelemetry.py CloudResumeProbe.py IndependentAgentPolicy.md \
  ResearchMethodsDefaults.json ResearchMethodsPolicy.md ResearchMethods.py \
  Info.plist AppIcon.icns; do
  cp "$PROJECT_ROOT/Resources/$name" "$RESOURCES/$name"
done
cp "$PROJECT_ROOT/Resources/Defaults.example.json" "$RESOURCES/Defaults.json"
cp "$PROJECT_ROOT/LICENSE" "$RESOURCES/LICENSE"
cp -R "$PROJECT_ROOT/Resources/StarterPrompts" "$RESOURCES/StarterPrompts"
cp -R "$PROJECT_ROOT/Resources/LeanSearch" "$RESOURCES/LeanSearch"

# Online catalog refreshes normally. An offline snapshot is best-effort and is
# public web content, never the user's installation-specific generated catalog.
if ! curl --fail --location --silent --show-error --max-time 25 \
  "https://app.getsupers.com/auto-research" -o "$RESOURCES/catalog-source.html"; then
  rm -f "$RESOURCES/catalog-source.html"
  echo "::warning::Catalog snapshot unavailable; built-in projects still work."
fi

plutil -lint "$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ "$VERSION" != "1.5.0" ]]; then
  echo "Expected app version 1.5.0 but got $VERSION." >&2
  exit 1
fi

# No Apple Developer ID or notarization credentials are stored in this fork.
# Ad-hoc signing keeps the app bundle structurally valid without claiming trust.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me.txt" <<'TXT'
Auto Research — macOS universal (Apple Silicon and Intel)
Requires macOS 14.0 or newer.

Drag Auto Research.app into Applications.
This community release is ad-hoc signed, not Developer ID signed or notarized.
If Gatekeeper blocks the app, check System Settings > Privacy & Security
and use Open Anyway only if you trust the source and build.

On first launch, select a writable workspace on a mounted external drive.
Install and authenticate your preferred Codex, Claude, OpenCode or Antigravity CLI,
or configure Daytona / Agent37 cloud access in Connections & settings.

Source: https://github.com/aviyanp/Auto-research-agent
TXT

DMG="$DIST/Auto-research-agent-$VERSION-universal.dmg"
ZIP="$DIST/Auto-research-agent-$VERSION-universal.zip"
hdiutil create -volname 'Auto Research' -srcfolder "$STAGE" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(
  cd "$DIST"
  shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS
)

cat > "$DIST/release-notes.md" <<'TXT'
## Auto Research v1.5.0 — macOS Universal

- Native **Apple Silicon (arm64)** and **Intel (x86_64)** slices in one executable (verified with `lipo`).
- macOS 14.0 or newer; portable app bundle with installation-neutral defaults, bundled starter projects and research resources.
- Download the DMG, drag **Auto Research.app** into Applications, and choose a mounted external-drive research workspace on first launch.
- **Signing:** ad-hoc signed; **not Apple Developer ID signed or notarized**. Gatekeeper may require **System Settings → Privacy & Security → Open Anyway**. Use only if you trust this repository and its source.
- `SHA256SUMS` includes checksums for the DMG and ZIP.

This is a separately built community release from `aviyanp/Auto-research-agent`. It does not contain user credentials or local sessions.
TXT
echo "Created $DMG, $ZIP and SHA256SUMS"
