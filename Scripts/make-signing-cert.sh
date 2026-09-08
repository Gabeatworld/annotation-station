#!/bin/bash
# One-time: create a self-signed code-signing certificate "Annotation Station Dev" in the
# login keychain and trust it for code signing.
#
# Why: TCC (Screen Recording / Accessibility) remembers grants by bundle id + code
# requirement. An ad-hoc signature's requirement is the binary's cdhash, which changes on
# every rebuild, so grants silently stop matching. A certificate gives a stable identity
# across rebuilds; the grant is remembered once.
set -euo pipefail

NAME="Annotation Station Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✓ certificate '$NAME' already exists in the login keychain"
else
    cat > "$WORK/cert.cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
CFG
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cfg" >/dev/null 2>&1
    /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -out "$WORK/id.p12" -passout pass:annotation-station >/dev/null 2>&1
    # -A: any app may use the key; -T: explicitly allow codesign/security without a prompt.
    security import "$WORK/id.p12" -k "$KEYCHAIN" -P annotation-station -A \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    echo "✓ imported '$NAME' into the login keychain"
    cp "$WORK/cert.pem" "$WORK/cert.cer"
fi

# Trust it for code signing (user domain). This can ask for your login password once.
if security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$WORK/existing.pem" 2>/dev/null; then
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/existing.pem" \
        && echo "✓ trusted '$NAME' for code signing" \
        || echo "⚠ could not add trust settings; codesign may still work, see below"
fi

echo "--- code-signing identities:"
security find-identity -v -p codesigning | grep -E "$NAME|valid identities" || true
