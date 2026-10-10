#!/bin/sh
# Builds the release disk image (`make dmg`) from the installer app: the installer, the read-me and
# the licenses, with the app icon as the volume icon. Signs the image if IDENTITY picks a Developer
# ID certificate in the keychain; with a notarytool keychain profile, also notarizes and staples it.
# Writes OUT.dmg.sha256 next to it.
# Usage: Scripts/make-dmg.sh INSTALLER.app OUT.dmg VOLUME-NAME [IDENTITY] [NOTARY-PROFILE]
set -eu

installer=$1 dmg=$2 volume=$3 identity=${4:-} profile=${5:-}
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/allinoneime-dmg.XXXXXX")
# The physical path (/private/var/…), as mount(8) prints it.
work=$(cd "$work" && pwd -P)
mnt="$work/mnt"

# Spotlight or Finder can hold the volume for a moment.
detach() {
    for _ in 1 2 3 4 5; do
        hdiutil detach -quiet "$1" 2>/dev/null && return 0
        sleep 1
    done
    hdiutil detach -quiet -force "$1"
}
cleanup() {
    if [ -d "$mnt" ] && mount | grep -qF " on $mnt "; then detach "$mnt" || true; fi
    if ! mount | grep -qF " on $mnt "; then rm -rf "$work"; fi
}
trap cleanup EXIT

# What the volume shows.
stage="$work/stage"
mkdir -p "$stage"
ditto "$installer" "$stage/$(basename "$installer")"
cp "$repo/Resources/DMG-ReadMe.txt" "$stage/Read Me 安装说明.txt"
cp "$repo/LICENSE" "$stage/LICENSE.txt"
cp "$repo/THIRD_PARTY_NOTICES.md" "$stage/THIRD_PARTY_NOTICES.md"
cp "$repo/Resources/AppIcon.icns" "$stage/.VolumeIcon.icns"

# A writable image first: the volume icon needs the custom-icon flag on the mounted volume itself.
hdiutil create -quiet -volname "$volume" -srcfolder "$stage" -fs HFS+ -format UDRW "$work/rw.dmg"
mkdir "$mnt"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$mnt" "$work/rw.dmg"
xcrun SetFile -a C "$mnt"
rm -rf "$mnt/.fseventsd" "$mnt/.Spotlight-V100"
detach "$mnt"
rmdir "$mnt"

# LZMA: the smallest; macOS 10.15 and later open it.
rm -f "$dmg" "$dmg.sha256"
hdiutil convert -quiet "$work/rw.dmg" -format ULMO -o "$dmg"
hdiutil verify -quiet "$dmg"

# The certificate IDENTITY picks (a name or a hash); only a Developer ID one signs the image.
certificate=$( [ -n "$identity" ] && security find-identity -v -p codesigning | grep -F -- "$identity" | head -1 || true)
signed=no
case $certificate in
*"Developer ID Application"*)
    codesign --force --timestamp --sign "$identity" "$dmg"
    codesign --verify --strict "$dmg"
    signed=yes
    ;;
esac

notarized=no
if [ -n "$profile" ]; then
    if [ "$signed" = no ]; then
        echo "error: notarizing needs a Developer ID Application certificate; '$identity' picks ${certificate:-none}" >&2
        exit 1
    fi
    if ! result=$(xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json); then
        echo "$result"
        echo "error: notarytool failed; details: xcrun notarytool log <id> --keychain-profile '$profile'" >&2
        exit 1
    fi
    echo "$result"
    if ! echo "$result" | grep -q '"status" *: *"Accepted"'; then
        echo "error: notarization failed; details: xcrun notarytool log <id> --keychain-profile '$profile'" >&2
        exit 1
    fi
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature -v "$dmg"
    notarized=yes
fi

(cd "$(dirname "$dmg")" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
commit=$(git -C "$repo" describe --always --dirty 2>/dev/null || echo unknown)
echo "Built $dmg ($(du -h "$dmg" | cut -f1 | tr -d ' ')) from $commit, signed: $signed, notarized: $notarized"
cat "$dmg.sha256"
if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
    echo "warning: built from uncommitted changes; publish one built from the release commit" >&2
fi
if [ "$notarized" = no ]; then
    echo "warning: not notarized; macOS asks users to allow the installer once" >&2
    echo "         (System Settings → Privacy & Security → Open Anyway)" >&2
fi
