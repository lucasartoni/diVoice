#!/bin/bash
# Creates a self-signed "DiVoice Dev" certificate in the login Keychain for development
# builds, until the Developer ID arrives.
#
# With a stable signature macOS remembers the permissions (Accessibility, microphone,
# Keychain) from one build to the next. Run it once.
#
# The .p12 must be created in "legacy" format (3DES, MAC SHA-1): `security import` can't read
# the OpenSSL 3+ default (AES, MAC SHA-256) and fails with
# "MAC verification failed during PKCS12 import". That is why /usr/bin/openssl
# (LibreSSL) is used, or OpenSSL 3+ with -legacy.
set -euo pipefail

NAME="DiVoice Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "The certificate \"$NAME\" is already in the Keychain."
else
  if [ -x /usr/bin/openssl ]; then
    OPENSSL=/usr/bin/openssl
    P12_ARGS=()
  else
    OPENSSL=openssl
    P12_ARGS=(-legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1)
  fi
  if "$OPENSSL" version | grep -qE '^OpenSSL [3-9]'; then
    P12_ARGS=(-legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1)
  fi

  TMP=$(mktemp -d)
  trap 'rc=$?; rm -rf "$TMP"; exit $rc' EXIT

  cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = DiVoice
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null

  # Temporary password, never empty: it only serves to hand the .p12 to `security import`.
  PASS=$("$OPENSSL" rand -hex 16)
  # ${arr[@]+...}: with bash 3.2 and `set -u` an empty array would be "unbound".
  "$OPENSSL" pkcs12 -export ${P12_ARGS[@]+"${P12_ARGS[@]}"} -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/cert.p12" -passout "pass:$PASS"

  # -T: only codesign can use the key without asking for confirmation.
  security import "$TMP/cert.p12" -k "$KEYCHAIN" -f pkcs12 -P "$PASS" -T /usr/bin/codesign
  echo "Certificate \"$NAME\" imported into the login Keychain."
fi

# Signing test on a temporary binary.
PROBE=$(mktemp -d)
cp /usr/bin/true "$PROBE/probe"
if codesign --force --sign "$NAME" "$PROBE/probe" 2>"$PROBE/err" && codesign --verify "$PROBE/probe" 2>/dev/null; then
  rm -rf "$PROBE"
  echo "Ready: scripts/build-app.sh will sign with \"$NAME\"."
  exit 0
fi
echo "codesign still can't use \"$NAME\": $(cat "$PROBE/err")"
rm -rf "$PROBE"
echo
echo "The certificate must be trusted for code signing. Run this yourself (macOS asks for the password):"
echo
echo "  security find-certificate -c \"$NAME\" -p \"$KEYCHAIN\" > /tmp/divoice-dev.pem && \\"
echo "    security add-trusted-cert -r trustRoot -p codeSign -k \"$KEYCHAIN\" /tmp/divoice-dev.pem && rm /tmp/divoice-dev.pem"
exit 2
