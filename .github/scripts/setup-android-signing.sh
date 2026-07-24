#!/usr/bin/env bash
set -euo pipefail

if [ -z "${ANDROID_KEYSTORE_BASE64:-}" ] || \
   [ -z "${ANDROID_STORE_PASSWORD:-}" ] || \
   [ -z "${ANDROID_KEY_PASSWORD:-}" ] || \
   [ -z "${ANDROID_KEY_ALIAS:-}" ]; then
  echo "::error::Android signing secrets (ANDROID_KEYSTORE_BASE64, ANDROID_STORE_PASSWORD, ANDROID_KEY_PASSWORD, ANDROID_KEY_ALIAS) are required."
  exit 1
fi

mkdir -p android/app
printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 --decode > android/app/upload-keystore.jks

cat <<EOF > android/key.properties
storePassword=$ANDROID_STORE_PASSWORD
keyPassword=$ANDROID_KEY_PASSWORD
keyAlias=$ANDROID_KEY_ALIAS
storeFile=../app/upload-keystore.jks
EOF

actual_fingerprint=$(
  keytool -list -v \
    -keystore android/app/upload-keystore.jks \
    -storepass "$ANDROID_STORE_PASSWORD" \
    -alias "$ANDROID_KEY_ALIAS" |
    sed -n 's/.*SHA256: //p' |
    tr -d ':' |
    tr '[:lower:]' '[:upper:]' |
    head -n 1
)

if [ "$actual_fingerprint" != "$ANDROID_SIGNING_CERT_SHA256" ]; then
  echo "::error::Android signing certificate fingerprint does not match the fixed AniBaka certificate."
  exit 1
fi

echo "fingerprint=$actual_fingerprint" >> "$GITHUB_OUTPUT"
echo "Android fixed signing: enabled (\`$actual_fingerprint\`)." >> "$GITHUB_STEP_SUMMARY"
