#!/usr/bin/env bash
set -euo pipefail

if [ -z "${MACOS_CERTIFICATE_BASE64:-}" ]; then
  echo "::error::MACOS_CERTIFICATE_BASE64 secret is required."
  exit 1
fi

certificate_path="$RUNNER_TEMP/anibaka-macos-signing.p12"
keychain_path="$RUNNER_TEMP/anibaka-signing.keychain-db"
keychain_password=$(openssl rand -hex 24)

printf '%s' "$MACOS_CERTIFICATE_BASE64" | base64 -D > "$certificate_path"
security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$certificate_path" \
  -P "${MACOS_CERTIFICATE_PASSWORD:-}" \
  -A \
  -t cert \
  -f pkcs12 \
  -k "$keychain_path"
security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "$keychain_password" \
  "$keychain_path"

existing_keychains=()
while IFS= read -r existing_keychain; do
  existing_keychain=${existing_keychain//\"/}
  [ -n "$existing_keychain" ] && existing_keychains+=("$existing_keychain")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$keychain_path" "${existing_keychains[@]}"

identity_line=$(security find-identity -v -p codesigning "$keychain_path" | awk '/"/ { print; exit }')
if [ -z "$identity_line" ]; then
  public_certificate_path="$RUNNER_TEMP/anibaka-macos-signing.pem"
  security find-certificate -a -p "$keychain_path" > "$public_certificate_path"
  security add-trusted-cert \
    -r trustRoot \
    -k "$keychain_path" \
    "$public_certificate_path"
  identity_line=$(security find-identity -v -p codesigning "$keychain_path" | awk '/"/ { print; exit }')
fi

identity_hash=$(printf '%s\n' "$identity_line" | awk '{ print $2 }')
identity_name=$(printf '%s\n' "$identity_line" | sed -E 's/^[^"]*"([^"]+)".*/\1/')

if [ -z "$identity_hash" ]; then
  echo "::error::The imported macOS P12 does not contain a code-signing identity."
  exit 1
fi

use_timestamp=false
case "$identity_name" in
  "Developer ID Application:"*) use_timestamp=true ;;
esac

sed -i.bak \
  "s/CODE_SIGN_IDENTITY = \"-\";/CODE_SIGN_IDENTITY = \"$identity_hash\";/g" \
  macos/Runner.xcodeproj/project.pbxproj

echo "identity=$identity_hash" >> "$GITHUB_OUTPUT"
echo "keychain=$keychain_path" >> "$GITHUB_OUTPUT"
echo "timestamp=$use_timestamp" >> "$GITHUB_OUTPUT"
echo "macOS fixed signing: enabled (\`$identity_hash\`, \`$identity_name\`)." >> "$GITHUB_STEP_SUMMARY"
