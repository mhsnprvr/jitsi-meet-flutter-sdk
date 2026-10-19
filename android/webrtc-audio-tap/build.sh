#!/usr/bin/env bash
# Rebuilds org.jitsi:webrtc with PodiumAudioTap (see webrtc-audio-tap.patch) and installs it into
# ../libs as org.jitsi:webrtc:$OUT_VERSION. Only Java classes change; the native libraries are the
# upstream ones, so the patched classes must keep every native method signature as is.
set -euo pipefail

BASE_VERSION=124.0.0
OUT_VERSION=124.0.0-podium.1
# Head of jitsi/webrtc M124, the sources org.jitsi:webrtc:124.0.0 was built from.
WEBRTC_COMMIT=e7fccf32f8833bbe66b9ffdb73e5990af0809840
ANDROIDX_ANNOTATION=1.3.0
ANDROID_PLATFORM=${ANDROID_PLATFORM:-android-34}

here="$(cd "$(dirname "$0")" && pwd)"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
android_jar="$sdk/platforms/$ANDROID_PLATFORM/android.jar"
[ -f "$android_jar" ] || { echo "Missing $android_jar (set ANDROID_HOME or ANDROID_PLATFORM)" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

# WEBRTC_AAR may point to an already downloaded org.jitsi:webrtc:$BASE_VERSION aar.
if [ -n "${WEBRTC_AAR:-}" ]; then
  cp "$WEBRTC_AAR" webrtc.aar
else
  curl -fsSLo webrtc.aar \
    "https://repo1.maven.org/maven2/org/jitsi/webrtc/$BASE_VERSION/webrtc-$BASE_VERSION.aar"
fi
curl -fsSLo annotation.jar \
  "https://dl.google.com/android/maven2/androidx/annotation/annotation/$ANDROIDX_ANNOTATION/annotation-$ANDROIDX_ANNOTATION.jar"

src_dir=sdk/android/src/java/org/webrtc/audio
mkdir -p "$src_dir"
for f in WebRtcAudioTrack WebRtcAudioRecord; do
  curl -fsSLo "$src_dir/$f.java" \
    "https://raw.githubusercontent.com/jitsi/webrtc/$WEBRTC_COMMIT/$src_dir/$f.java"
done
patch -p1 < "$here/webrtc-audio-tap.patch"
cp "$here/src/org/webrtc/audio/PodiumAudioTap.java" "$src_dir/"

mkdir aar classes
(cd aar && unzip -q ../webrtc.aar)
# The JDK provides java.* (android.jar lacks LambdaMetafactory); android.* comes from android.jar.
javac --release 8 -nowarn -Xlint:-options \
  -cp "$android_jar:aar/libs/libwebrtc.jar:annotation.jar" \
  -d classes \
  "$src_dir/WebRtcAudioTrack.java" "$src_dir/WebRtcAudioRecord.java" "$src_dir/PodiumAudioTap.java"

cp aar/libs/libwebrtc.jar libwebrtc.jar
(cd classes && zip -q -r ../libwebrtc.jar org)
cp libwebrtc.jar aar/libs/libwebrtc.jar
(cd aar && rm -f ../out.aar && zip -q -r -X ../out.aar .)

repo="$here/../libs/org/jitsi/webrtc"
dest="$repo/$OUT_VERSION"
mkdir -p "$dest"
cp out.aar "$dest/webrtc-$OUT_VERSION.aar"
cat > "$dest/webrtc-$OUT_VERSION.pom" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>org.jitsi</groupId>
  <artifactId>webrtc</artifactId>
  <version>$OUT_VERSION</version>
  <packaging>aar</packaging>
  <description>org.jitsi:webrtc:$BASE_VERSION with PodiumAudioTap</description>
</project>
EOF
cat > "$repo/maven-metadata.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<metadata>
  <groupId>org.jitsi</groupId>
  <artifactId>webrtc</artifactId>
  <versioning>
    <release>$OUT_VERSION</release>
    <versions>
      <version>$OUT_VERSION</version>
    </versions>
  </versioning>
</metadata>
EOF
echo "Installed $dest"
