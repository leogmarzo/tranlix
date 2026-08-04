#!/bin/bash
#
# Builds, signs, notarizes and packages Tranlix for hand delivery.
#
# The output is a .dmg that opens on any Mac without Gatekeeper arguing. Both the app and
# the disk image get their notarization ticket stapled: the app so it still validates once
# dragged out of the image, the image so it validates before it is ever opened. Either alone
# leaves a case that only works while the machine is online.
#
# Prerequisites, both one-time and both belonging to whoever runs this:
#
#   1. A "Developer ID Application" certificate in the login keychain.
#   2. A notarization credential stored under a keychain profile:
#        xcrun notarytool store-credentials "tranlix" \
#          --apple-id <apple-id> --team-id 5DBQ7XM8R8 --password <app-specific-password>
#
# Usage:
#   scripts/release.sh                 # full pipeline
#   scripts/release.sh --no-notarize   # build, sign and package only, no waiting on Apple
#   scripts/release.sh --resume <id>   # finish a submission that was left queued
#
# The --resume form exists because Apple's queue has no upper bound worth waiting on. A
# submission keeps processing server-side after the local `--wait` is killed, so an hour
# spent queueing is never lost: come back with the submission id and it staples the app that
# is already built and packages the disk image from there.
#
set -euo pipefail

TEAM_ID="5DBQ7XM8R8"
SCHEME="Tranlix"
APP_NAME="Tranlix"
KEYCHAIN_PROFILE="${TRANLIX_NOTARY_PROFILE:-tranlix}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$APP_NAME.app"
STAGING="$BUILD_DIR/dmg"

NOTARIZE=1
RESUME_ID=""
case "${1:-}" in
    --no-notarize) NOTARIZE=0 ;;
    --resume)
        RESUME_ID="${2:-}"
        [[ -n "$RESUME_ID" ]] || { echo "uso: $0 --resume <submission-id>" >&2; exit 2; }
        ;;
    "") ;;
    *) echo "opción desconocida: $1" >&2; exit 2 ;;
esac

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------------------
# Checked up front rather than discovered twenty minutes in: the archive alone takes
# minutes, and finding out afterwards that the certificate is missing wastes all of it.

step "Comprobando requisitos"

command -v xcodegen >/dev/null || fail "falta xcodegen (brew install xcodegen)"

IDENTITY="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" \
    | grep "$TEAM_ID" \
    | head -1 \
    | sed -E 's/.*"(.+)"$/\1/')"
[[ -n "$IDENTITY" ]] || fail "no hay certificado \"Developer ID Application\" del equipo $TEAM_ID en el llavero"
echo "Identidad: $IDENTITY"

if (( NOTARIZE )); then
    xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1 \
        || fail "el perfil de notarización \"$KEYCHAIN_PROFILE\" no existe o no autentica. Ver el encabezado de este script."
    echo "Perfil de notarización: $KEYCHAIN_PROFILE"
fi

VERSION="$(grep -E '^\s+MARKETING_VERSION:' "$REPO_ROOT/project.yml" | sed -E 's/.*: *"?([^"]+)"?/\1/')"
echo "Versión: $VERSION"

# --- Resuming a queued submission -------------------------------------------------------
# Rebuilding would produce a different binary than the one Apple accepted, and its ticket
# would not apply. So this path insists on the app the earlier run already exported.

if [[ -n "$RESUME_ID" ]]; then
    step "Retomando el envío $RESUME_ID"
    [[ -d "$APP" ]] || fail "no está $APP. El --resume grapa la app que ya se construyó; si se borró, hay que correr el pipeline entero de nuevo."

    STATUS="$(xcrun notarytool info "$RESUME_ID" --keychain-profile "$KEYCHAIN_PROFILE" \
        | awk '/status:/ { $1=""; sub(/^ /,""); print }')"
    echo "Estado: $STATUS"

    case "$STATUS" in
        Accepted) ;;
        "In Progress")
            fail "Apple sigue procesándolo. Volvé a intentar más tarde." ;;
        *)
            echo
            xcrun notarytool log "$RESUME_ID" --keychain-profile "$KEYCHAIN_PROFILE" || true
            fail "el envío quedó en \"$STATUS\". El log de arriba dice por qué." ;;
    esac

    step "Grapando el ticket a la app"
    xcrun stapler staple "$APP"
fi

# --- Build -----------------------------------------------------------------------------

if [[ -z "$RESUME_ID" ]]; then

step "Regenerando el proyecto"
(cd "$REPO_ROOT" && xcodegen generate >/dev/null)

step "Archivando (Release)"
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$STAGING"
mkdir -p "$BUILD_DIR"

# The signing identity is overridden here instead of in project.yml so that everyday debug
# builds keep using the development certificate. Release signing is a property of shipping,
# not of the project.
xcodebuild archive \
    -project "$REPO_ROOT/$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    | grep -E "error:|warning: (unable|failed)|ARCHIVE" || true

[[ -d "$ARCHIVE" ]] || fail "el archive no se generó"

step "Exportando la app firmada"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <!-- Export to disk. Without this Xcode offers to upload, which is not what this is. -->
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    | grep -E "error:|EXPORT" || true

[[ -d "$APP" ]] || fail "la app exportada no apareció en $EXPORT_DIR"

step "Verificando la firma"
codesign --verify --deep --strict --verbose=2 "$APP"
# The Hardened Runtime flag is what notarization requires and what would otherwise be
# rejected after the upload rather than here.
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID|flags=.*runtime" \
    || fail "la app no quedó firmada con Developer ID o sin Hardened Runtime"

# --- Notarize the app ------------------------------------------------------------------

if (( NOTARIZE )); then
    step "Notarizando la app (puede tardar varios minutos)"
    ZIP="$BUILD_DIR/$APP_NAME.zip"
    # ditto, not zip: it preserves the bundle's symlinks and extended attributes, and a
    # plain zip corrupts the signature on the way.
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    rm -f "$ZIP"

    step "Grapando el ticket a la app"
    xcrun stapler staple "$APP"
fi

fi # end of the build path skipped by --resume

# --- Disk image ------------------------------------------------------------------------

step "Armando el .dmg"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" >/dev/null

step "Firmando el .dmg"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if (( NOTARIZE )); then
    step "Notarizando el .dmg"
    xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait

    step "Grapando el ticket al .dmg"
    xcrun stapler staple "$DMG"

    step "Comprobando que Gatekeeper lo acepta"
    xcrun stapler validate "$DMG"
    # What the receiving Mac will actually run at first launch.
    spctl --assess --type open --context context:primary-signature -vv "$DMG"
    spctl --assess --type execute -vv "$APP"
fi

rm -rf "$STAGING"

step "Listo"
echo "$DMG"
shasum -a 256 "$DMG"
if (( ! NOTARIZE )); then
    printf '\n\033[33mSin notarizar:\033[0m este .dmg solo sirve para probar en esta máquina.\n'
fi
