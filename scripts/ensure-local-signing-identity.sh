#!/usr/bin/env bash
# Create (once) a stable self-signed code-signing identity so TCC grants for
# Input Monitoring / Accessibility survive rebuilds. Ad-hoc (`-`) signing
# changes the code directory hash every build and forces re-authorization.
#
# Uses /usr/bin/openssl (LibreSSL) so Security.framework can import the P12.
# The identity may show as CSSMERR_TP_NOT_TRUSTED in `find-identity -v` but
# `codesign -s "ChooseMyMusicPlayer Local"` still works for local installs.
set -euo pipefail

CERT_NAME="${CHOOSEMYMUSICPLAYER_SIGN_NAME:-ChooseMyMusicPlayer Local}"
SUPPORT_DIR="${HOME}/Library/Application Support/ChooseMyMusicPlayer/signing"
P12_PATH="${SUPPORT_DIR}/local-signing.p12"
P12_PASS="cmmp"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
OPENSSL="/usr/bin/openssl"

identity_present() {
  security find-identity -p codesigning 2>/dev/null | grep -F "\"${CERT_NAME}\"" >/dev/null
}

if identity_present; then
  echo "Signing identity already present: ${CERT_NAME}"
  security find-identity -p codesigning 2>/dev/null | grep -F "\"${CERT_NAME}\"" || true
  exit 0
fi

mkdir -p "${SUPPORT_DIR}"
chmod 700 "${SUPPORT_DIR}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

cat >"${TMP}/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no

[dn]
CN = ${CERT_NAME}
O = ChooseMyMusicPlayer
C = CN

[v3_req]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "Creating stable local signing certificate: ${CERT_NAME}"
"${OPENSSL}" req -new -newkey rsa:2048 -nodes \
  -keyout "${TMP}/key.pem" \
  -out "${TMP}/csr.pem" \
  -config "${TMP}/cert.cnf" >/dev/null 2>&1

"${OPENSSL}" x509 -req -days 3650 \
  -in "${TMP}/csr.pem" \
  -signkey "${TMP}/key.pem" \
  -out "${TMP}/cert.pem" \
  -extfile "${TMP}/cert.cnf" \
  -extensions v3_req >/dev/null 2>&1

"${OPENSSL}" pkcs12 -export \
  -out "${P12_PATH}" \
  -inkey "${TMP}/key.pem" \
  -in "${TMP}/cert.pem" \
  -passout "pass:${P12_PASS}" >/dev/null 2>&1
chmod 600 "${P12_PATH}"

security unlock-keychain -p "" "${KEYCHAIN}" 2>/dev/null || true
security import "${P12_PATH}" \
  -k "${KEYCHAIN}" \
  -P "${P12_PASS}" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  -T /usr/bin/productsign >/dev/null

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "" \
  "${KEYCHAIN}" >/dev/null 2>&1 || true

# Best-effort user trust for Code Signing (no sudo). Safe to ignore failure.
security add-trusted-cert -d -r unspecified -p codeSign "${TMP}/cert.pem" >/dev/null 2>&1 || true

if ! identity_present; then
  echo "error: failed to create signing identity ${CERT_NAME}" >&2
  echo "Import ${P12_PATH} (password: ${P12_PASS}) in Keychain Access." >&2
  exit 1
fi

# Smoke-test codesign even if find-identity -v marks it NOT_TRUSTED.
echo 'cmmp' >"${TMP}/sign-smoke"
if ! codesign -s "${CERT_NAME}" -f "${TMP}/sign-smoke" >/dev/null 2>&1; then
  echo "error: codesign cannot use ${CERT_NAME}" >&2
  exit 1
fi

echo "Created signing identity: ${CERT_NAME}"
echo "P12 backup: ${P12_PATH}"
echo "Authorize Input Monitoring / Accessibility once for this signed app; later rebuilds with the same identity keep the grant."
security find-identity -p codesigning 2>/dev/null | grep -F "\"${CERT_NAME}\"" || true
