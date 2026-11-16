#!/bin/zsh
# Creates a local code signing certificate named "Snapmark Dev" in your Keychain.
#
# Why: macOS ties the Screen Recording permission to the app's signature.
# With ad-hoc signing every build has a different signature and the permission is lost.
# With this certificate, every build has the same signature.
#
# It doesn't replace an Apple certificate: other Macs still block the first launch.
# macOS will ask for your password to trust the certificate (for code signing only).
set -e
NAME="Snapmark Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Certificate \"$NAME\" already exists. Nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="$(uuidgen)"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

# Keychain only imports .p12 files in the legacy format; OpenSSL 3 needs -legacy for that.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS"

security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "macOS will now ask for your password to trust the certificate for code signing."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Done: \"$NAME\" created. Run ./build.sh and new builds will be signed with it."
else
  echo "The certificate was imported, but macOS doesn't list it as valid for signing yet."
  exit 1
fi
