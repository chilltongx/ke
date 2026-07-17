#!/bin/zsh
set -euo pipefail

umask 077

SIGNING_IDENTITY_NAME="${CODEX_QUICK_OK_SIGNING_IDENTITY:-Codex Quick OK Local Signing}"
LOGIN_KEYCHAIN="${CODEX_QUICK_OK_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
SECURITY="${CODEX_QUICK_OK_SECURITY:-/usr/bin/security}"
CODESIGN="${CODEX_QUICK_OK_CODESIGN:-/usr/bin/codesign}"
OPENSSL="${CODEX_QUICK_OK_OPENSSL:-/usr/bin/openssl}"
WORK=""

cleanup() {
  if [[ -n "$WORK" && -d "$WORK" ]]; then
    rm -rf "$WORK"
  fi
}

trap cleanup EXIT
trap 'exit 130' HUP INT TERM

if [[ ! "$SIGNING_IDENTITY_NAME" =~ '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$' ]]; then
  print -u2 -- 'Signing identity name contains unsupported characters.'
  exit 64
fi

if [[ ! -f "$LOGIN_KEYCHAIN" ]]; then
  print -u2 -- "Login keychain not found: $LOGIN_KEYCHAIN"
  exit 66
fi

identity_hashes=()
find_identity_hashes() {
  local line remainder sha1 common_name
  identity_hashes=()
  while IFS= read -r line; do
    [[ "$line" == *') '*'"'* ]] || continue
    remainder="${line#*) }"
    sha1="${remainder%% *}"
    common_name="${line#*\"}"
    common_name="${common_name%%\"*}"
    if [[ "$common_name" == "$SIGNING_IDENTITY_NAME" && ${#sha1} -eq 40 && "$sha1" != *[^[:xdigit:]]* ]]; then
      identity_hashes+=("$sha1")
    fi
  done < <("$SECURITY" find-identity -p codesigning "$LOGIN_KEYCHAIN")
}

verify_codesigning_identity() {
  local identity_sha1="$1"
  local probe="$WORK/codesign-probe"
  cp /usr/bin/true "$probe"
  "$CODESIGN" --force --timestamp=none --sign "$identity_sha1" --keychain "$LOGIN_KEYCHAIN" "$probe"
  "$CODESIGN" --verify --strict "$probe"
}

WORK="$(mktemp -d)"
CERTIFICATE_PEM="$WORK/certificate.pem"
PRIVATE_KEY_PEM="$WORK/private-key.pem"
IDENTITY_P12="$WORK/identity.p12"
OPENSSL_CONFIG="$WORK/openssl.cnf"
PROBE="$WORK/codesign-probe"

find_identity_hashes
if (( ${#identity_hashes} > 1 )); then
  print -u2 -- "More than one valid code-signing identity is named \"$SIGNING_IDENTITY_NAME\"."
  exit 65
fi

if (( ${#identity_hashes} == 1 )); then
  identity_sha1="${identity_hashes[1]}"
  "$SECURITY" find-certificate -c "$SIGNING_IDENTITY_NAME" -p "$LOGIN_KEYCHAIN" > "$CERTIFICATE_PEM"
  if ! "$SECURITY" verify-cert -c "$CERTIFICATE_PEM" -p codeSign -k "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
    "$SECURITY" add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$CERTIFICATE_PEM"
  fi
  "$SECURITY" verify-cert -c "$CERTIFICATE_PEM" -p codeSign -k "$LOGIN_KEYCHAIN"
  verify_codesigning_identity "$identity_sha1"
  print -- "Signing identity is ready: $SIGNING_IDENTITY_NAME"
  exit 0
fi

cat > "$OPENSSL_CONFIG" <<CONFIG
[req]
distinguished_name = subject
x509_extensions = codesign
prompt = no

[subject]
CN = $SIGNING_IDENTITY_NAME
O = Codex Quick OK Local

[codesign]
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, keyCertSign
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always, issuer
CONFIG

"$OPENSSL" req -new -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
  -config "$OPENSSL_CONFIG" -keyout "$PRIVATE_KEY_PEM" -out "$CERTIFICATE_PEM"
"$OPENSSL" pkcs12 -export -inkey "$PRIVATE_KEY_PEM" -in "$CERTIFICATE_PEM" \
  -name "$SIGNING_IDENTITY_NAME" -out "$IDENTITY_P12" -passout pass:

"$SECURITY" import "$IDENTITY_P12" -k "$LOGIN_KEYCHAIN" -P "" -T /usr/bin/codesign
"$SECURITY" add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$CERTIFICATE_PEM"
"$SECURITY" verify-cert -c "$CERTIFICATE_PEM" -p codeSign -k "$LOGIN_KEYCHAIN"

find_identity_hashes
if (( ${#identity_hashes} != 1 )); then
  print -u2 -- "The imported identity is not uniquely usable for code signing."
  exit 69
fi
identity_sha1="${identity_hashes[1]}"
verify_codesigning_identity "$identity_sha1"
print -- "Signing identity created and verified: $SIGNING_IDENTITY_NAME"
