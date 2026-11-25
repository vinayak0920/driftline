#!/bin/bash
# One-time setup for automatic updates. Run from the repo folder:  bash scripts/setup-updates.sh
#  1. Creates a signing key pair on your Mac
#  2. Stores the private key as a GitHub secret (it never goes into the repo)
#  3. Writes the public key into Info.plist, so the app trusts only updates you sign
set -euo pipefail
cd "$(dirname "$0")/.."

if /usr/libexec/PlistBuddy -c "Print :DriftlineUpdatePublicKey" Info.plist 2>/dev/null | grep -q .; then
  echo "A public key is already set in Info.plist. Remove it first if you really want a new key."
  exit 1
fi
command -v gh >/dev/null || { echo "Install the GitHub CLI first: https://cli.github.com"; exit 1; }

KEYS="$(xcrun swift scripts/keygen.swift)"
PRIVATE="$(echo "$KEYS" | sed -n 1p)"
PUBLIC="$(echo "$KEYS" | sed -n 2p)"

REPO="$(/usr/libexec/PlistBuddy -c "Print :DriftlineUpdateRepo" Info.plist)"
printf '%s' "$PRIVATE" | gh secret set DRIFTLINE_SIGNING_KEY --repo "$REPO"
/usr/libexec/PlistBuddy -c "Set :DriftlineUpdatePublicKey $PUBLIC" Info.plist

echo "Done."
echo "  Private key saved as GitHub secret DRIFTLINE_SIGNING_KEY in $REPO"
echo "  Public key written to Info.plist"
echo "Keep a backup of the private key somewhere safe (a password manager):"
echo "  $PRIVATE"
echo "If you lose it, users would have to download the next version manually."
