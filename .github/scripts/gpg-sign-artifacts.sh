#!/usr/bin/env bash
set -euo pipefail

if [ -z "${RELEASE_GPG_PRIVATE_KEY_BASE64:-}" ]; then
  echo "::error::RELEASE_GPG_PRIVATE_KEY_BASE64 secret is required."
  exit 1
fi

export GNUPGHOME="$RUNNER_TEMP/anibaka-gnupg"
mkdir -m 700 "$GNUPGHOME"
printf '%s' "$RELEASE_GPG_PRIVATE_KEY_BASE64" |
  base64 --decode |
  gpg --batch --import

signing_fingerprint=$(
  gpg --batch --with-colons --list-secret-keys |
    awk -F: '$1 == "fpr" { print $10; exit }'
)
if [ -z "$signing_fingerprint" ]; then
  echo "::error::The configured OpenPGP key does not contain a private signing key."
  exit 1
fi

release_basename=${RELEASE_BASENAME:-baka-release}

gpg \
  --batch \
  --armor \
  --local-user "$signing_fingerprint" \
  --export "$signing_fingerprint" \
  > "release-assets/${release_basename}-public-key.asc"

signed_count=0
while IFS= read -r -d '' file; do
  case "$(basename "$file")" in
    *-ios-*) continue ;;
  esac
  gpg \
    --batch \
    --yes \
    --pinentry-mode loopback \
    --passphrase "${RELEASE_GPG_PASSPHRASE:-}" \
    --local-user "$signing_fingerprint" \
    --armor \
    --detach-sign \
    "$file"
  signed_count=$((signed_count + 1))
done < <(find release-assets -maxdepth 1 -type f ! -name '*.asc' -print0)

echo "fingerprint=$signing_fingerprint" >> "$GITHUB_OUTPUT"
echo "Detached release signing: enabled for $signed_count non-iOS asset(s) (\`$signing_fingerprint\`)." >> "$GITHUB_STEP_SUMMARY"
