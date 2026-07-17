#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/scripts/setup-local-signing.sh"
BUILD="$ROOT/scripts/build-release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

expect_fixed() {
  local needle="$1"
  local file="$2"
  grep -Fq -- "$needle" "$file" || fail "$file is missing: $needle"
}

test -x "$SETUP" || fail 'setup-local-signing.sh must exist and be executable'
zsh -n "$SETUP"
zsh -n "$BUILD"

expect_fixed 'SIGNING_IDENTITY_NAME="${CODEX_QUICK_OK_SIGNING_IDENTITY:-Codex Quick OK Local Signing}"' "$SETUP"
expect_fixed 'umask 077' "$SETUP"
expect_fixed 'WORK="$(mktemp -d)"' "$SETUP"
expect_fixed 'trap cleanup EXIT' "$SETUP"
expect_fixed 'P12_PASSWORD="$("$OPENSSL" rand -hex 32)"' "$SETUP"
expect_fixed '"$SECURITY" find-identity -p codesigning "$LOGIN_KEYCHAIN"' "$SETUP"
expect_fixed '"$SECURITY" find-certificate -a -c "$SIGNING_IDENTITY_NAME" -p "$LOGIN_KEYCHAIN" > "$CERTIFICATE_CANDIDATES_PEM"' "$SETUP"
expect_fixed 'candidate_sha1="$("$OPENSSL" x509 -in "$candidate" -noout -fingerprint -sha1)"' "$SETUP"
expect_fixed '[[ "$candidate_sha1" == "$identity_sha1" ]] || continue' "$SETUP"
expect_fixed '-passout "pass:$P12_PASSWORD"' "$SETUP"
expect_fixed '"$SECURITY" import "$IDENTITY_P12" -k "$LOGIN_KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign' "$SETUP"
expect_fixed '"$SECURITY" add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$CERTIFICATE_PEM"' "$SETUP"
expect_fixed '"$SECURITY" verify-cert -c "$CERTIFICATE_PEM" -p codeSign -k "$LOGIN_KEYCHAIN"' "$SETUP"
expect_fixed '"$CODESIGN" --force --timestamp=none --sign "$identity_sha1" --keychain "$LOGIN_KEYCHAIN" "$probe"' "$SETUP"

if grep -Eq -- '(^|[[:space:]])-A([[:space:]]|$)|set-key-partition-list|add-trusted-cert.*[[:space:]]-d([[:space:]]|$)|find-identity -v -p codesigning' "$SETUP"; then
  fail 'setup script broadens key or trust access'
fi
if grep -Fq -- '-passout pass:' "$SETUP" || grep -Fq -- '-P ""' "$SETUP"; then
  fail 'setup script uses an empty PKCS#12 password that macOS security import rejects'
fi
if grep -Fq -- '"$SECURITY" find-certificate -c "$SIGNING_IDENTITY_NAME" -p "$LOGIN_KEYCHAIN"' "$SETUP"; then
  fail 'setup script selects the first name-matched certificate instead of the identity fingerprint'
fi

expect_fixed 'SIGNING_IDENTITY_NAME="${CODEX_QUICK_OK_SIGNING_IDENTITY:-Codex Quick OK Local Signing}"' "$BUILD"
expect_fixed 'BUNDLE_IDENTIFIER="com.codexquickok.CodexQuickOK"' "$BUILD"
expect_fixed 'DESIGNATED_REQUIREMENT_EXPRESSION="identifier \"$BUNDLE_IDENTIFIER\" and certificate leaf = H\"$identity_sha1\""' "$BUILD"
expect_fixed 'DESIGNATED_REQUIREMENT="designated => $DESIGNATED_REQUIREMENT_EXPRESSION"' "$BUILD"
expect_fixed '"$SECURITY" find-identity -v -p codesigning "$LOGIN_KEYCHAIN"' "$BUILD"
expect_fixed '"$CODESIGN" --force --timestamp=none --sign "$identity_sha1" --keychain "$LOGIN_KEYCHAIN" --requirements "=$DESIGNATED_REQUIREMENT" "$APP"' "$BUILD"
expect_fixed '"$CODESIGN" --verify --deep --strict --test-requirement "=$DESIGNATED_REQUIREMENT_EXPRESSION" "$APP"' "$BUILD"
if grep -Fq -- '--sign -' "$BUILD"; then
  fail 'build script must not fall back to ad-hoc signing'
fi

FAKE_SECURITY="$WORK/security"
SWIFT_MARKER="$WORK/swift-was-called"
cat > "$FAKE_SECURITY" <<'SCRIPT'
#!/bin/zsh
if [[ "${1:-}" == find-identity ]]; then
  print '     0 valid identities found'
  exit 0
fi
exit 70
SCRIPT
cat > "$WORK/swift" <<'SCRIPT'
#!/bin/zsh
touch "$SWIFT_MARKER"
exit 99
SCRIPT
chmod +x "$FAKE_SECURITY" "$WORK/swift"
touch "$WORK/login.keychain-db"
export SWIFT_MARKER

if CODEX_QUICK_OK_SECURITY="$FAKE_SECURITY" \
  CODEX_QUICK_OK_KEYCHAIN="$WORK/login.keychain-db" \
  PATH="$WORK:/usr/bin:/bin:/usr/sbin:/sbin" \
  zsh "$BUILD" >"$WORK/stdout" 2>"$WORK/stderr"; then
  fail 'build unexpectedly accepted a missing signing identity'
fi
grep -Fq 'No unique valid code-signing identity named "Codex Quick OK Local Signing".' "$WORK/stderr" \
  || fail 'build did not explain the missing stable identity'
test ! -e "$SWIFT_MARKER" || fail 'build started before signing identity preflight'

FAKE_SETUP_SECURITY="$WORK/setup-security"
FAKE_OPENSSL="$WORK/openssl"
OPENSSL_MARKER="$WORK/openssl-was-called"
cat > "$FAKE_SETUP_SECURITY" <<'SCRIPT'
#!/bin/zsh
if [[ "${1:-}" == find-identity ]]; then
  exit 71
fi
exit 72
SCRIPT
cat > "$FAKE_OPENSSL" <<'SCRIPT'
#!/bin/zsh
if [[ "${1:-}" == rand ]]; then
  print '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
  exit 0
fi
touch "$OPENSSL_MARKER"
exit 99
SCRIPT
chmod +x "$FAKE_SETUP_SECURITY" "$FAKE_OPENSSL"
export OPENSSL_MARKER

if CODEX_QUICK_OK_SECURITY="$FAKE_SETUP_SECURITY" \
  CODEX_QUICK_OK_OPENSSL="$FAKE_OPENSSL" \
  CODEX_QUICK_OK_KEYCHAIN="$WORK/login.keychain-db" \
  zsh "$SETUP" >"$WORK/setup-stdout" 2>"$WORK/setup-stderr"; then
  fail 'setup unexpectedly accepted a failed identity query'
fi
grep -Fq 'Unable to query code-signing identities from the login keychain.' "$WORK/setup-stderr" \
  || fail 'setup did not explain the failed identity query'
test ! -e "$OPENSSL_MARKER" || fail 'setup generated key material after identity query failure'

print 'Stable signing checks passed.'
