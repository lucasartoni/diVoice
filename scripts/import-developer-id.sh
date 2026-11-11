#!/bin/bash
# Imports into the login Keychain the "Developer ID Application" certificate downloaded from
# developer.apple.com, together with the private key generated with the CSR in .signing/.
#
#   scripts/import-developer-id.sh ~/Downloads/developerID_application.cer
#
# With -T /usr/bin/codesign the key can be used to sign without Keychain confirmations.
# The intermediate .p12 is in legacy format (LibreSSL), the only one `security import` reads.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CER="${1:?Give the path of the .cer downloaded from developer.apple.com}"
KEY="$ROOT/.signing/developer-id.key"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl

[ -f "$KEY" ] || { echo "Missing private key $KEY (generated together with the CSR)."; exit 1; }

TMP=$(mktemp -d)
trap 'rc=$?; rm -rf "$TMP"; exit $rc' EXIT

# Apple's .cer is DER; PEM is accepted too.
"$OPENSSL" x509 -inform DER -in "$CER" -out "$TMP/cert.pem" 2>/dev/null || "$OPENSSL" x509 -in "$CER" -out "$TMP/cert.pem"

SUBJECT=$("$OPENSSL" x509 -noout -subject -in "$TMP/cert.pem")
echo "$SUBJECT" | grep -q "Developer ID Application" || { echo "Not a Developer ID Application certificate: $SUBJECT"; exit 1; }
CERT_MOD=$("$OPENSSL" x509 -noout -modulus -in "$TMP/cert.pem" | shasum)
KEY_MOD=$("$OPENSSL" rsa -noout -modulus -in "$KEY" 2>/dev/null | shasum)
[ "$CERT_MOD" = "$KEY_MOD" ] || { echo "The certificate does not match the key in .signing/: was it created with another CSR?"; exit 1; }

PASS=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -inkey "$KEY" -in "$TMP/cert.pem" -name "Developer ID Application" \
  -out "$TMP/identity.p12" -passout "pass:$PASS"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$PASS" -T /usr/bin/codesign

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  # Without Xcode often only the G1 intermediate is present: add G2 from apple.com,
  # after checking that it is signed by the "Apple Root CA" already on the system.
  echo "Adding Apple's Developer ID G2 intermediate certificate…"
  curl -fsSL --max-time 60 -o "$TMP/g2.cer" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
  "$OPENSSL" x509 -inform DER -in "$TMP/g2.cer" -out "$TMP/g2.pem"
  security find-certificate -a -c "Apple Root CA" -p /System/Library/Keychains/SystemRootCertificates.keychain > "$TMP/roots.pem"
  "$OPENSSL" verify -CAfile "$TMP/roots.pem" "$TMP/g2.pem" >/dev/null || { echo "The downloaded intermediate is not signed by Apple Root CA."; exit 1; }
  # -ignore_critical: the critical extension that marks Developer IDs is private to Apple.
  "$OPENSSL" verify -ignore_critical -CAfile "$TMP/roots.pem" -untrusted "$TMP/g2.pem" "$TMP/cert.pem" >/dev/null || { echo "The certificate does not descend from Developer ID G2."; exit 1; }
  security add-certificates -k "$KEYCHAIN" "$TMP/g2.pem"
fi

echo
security find-identity -v -p codesigning | grep "Developer ID Application" || {
  echo "Imported, but the identity is not valid."
  exit 1
}
echo
echo "Done. Back up the identity (Keychain Access › Developer ID Application › Export, .p12 with a password,"
echo "to keep in 1Password), then delete the plain-text key: rm \"$KEY\""
