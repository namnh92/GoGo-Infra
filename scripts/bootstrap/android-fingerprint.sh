#!/usr/bin/env bash
#
# Print the SHA-256 fingerprint of a Java keystore certificate.
#
#   ./scripts/bootstrap/android-fingerprint.sh ../GoGo-MobileApp/android/app/debug.keystore
#
# keytool needs a Java runtime, which a machine that only builds through EAS
# does not necessarily have. An Android fingerprint is just SHA-256 over the
# certificate's DER bytes, and JKS is a simple enough container to read
# directly — so this works with nothing but Python.
#
# For a PKCS12 keystore (magic 0x30, newer Android Studio), openssl reads it:
#   openssl pkcs12 -in ks.p12 -nokeys -passin pass:PASS |
#     openssl x509 -noout -fingerprint -sha256
#
# WHICH FINGERPRINT GOES IN assetlinks.json
#
# Not this one, for production. With Play App Signing — the default for new
# apps — Google re-signs the upload with its own certificate, so the fingerprint
# that verifies App Links is the app signing certificate shown in Play Console
# under Setup → App signing. Using the upload or debug key there fails silently:
# no error, the link just opens in the browser.

set -euo pipefail

KEYSTORE="${1:?usage: android-fingerprint.sh <keystore>}"
[[ -f "$KEYSTORE" ]] || { echo "no such file: ${KEYSTORE}" >&2; exit 1; }

python3 - "$KEYSTORE" <<'PY'
import hashlib, struct, sys

data = open(sys.argv[1], "rb").read()
pos = 0

def u4():
    global pos
    v = struct.unpack(">I", data[pos:pos + 4])[0]; pos += 4; return v

def utf():
    global pos
    n = struct.unpack(">H", data[pos:pos + 2])[0]; pos += 2
    v = data[pos:pos + n].decode(); pos += n; return v

magic = u4()
if magic != 0xFEEDFEED:
    sys.exit("not a JKS keystore (magic %08X). PKCS12 starts with 0x30 — use openssl." % magic)

version = u4()
count = u4()
found = []

for _ in range(count):
    tag = u4()
    alias = utf()
    pos += 8                      # creation timestamp
    chain = 1
    if tag == 1:                  # private key entry
        # Not `pos += u4()`: augmented assignment loads pos before calling u4(),
        # so the four bytes u4() itself consumed are lost and the walk drifts by
        # exactly the length field. That produced a plausible, wrong fingerprint.
        key_length = u4()
        pos += key_length         # wrapped key
        chain = u4()
    for index in range(chain):
        if version == 2:
            utf()                 # certificate type
        length = u4()
        der = data[pos:pos + length]; pos += length
        if index == 0:
            found.append((alias, der))

# A JKS file ends with a 20-byte SHA-1 integrity digest. Landing exactly there
# is what says the walk did not drift — an earlier version of this parser
# mis-sliced the DER and produced a plausible but wrong fingerprint.
remaining = len(data) - pos
if remaining != 20:
    sys.exit("parse drifted: %d trailing bytes, expected 20" % remaining)

for alias, der in found:
    if der[:1] != b"\x30":
        sys.exit("certificate for %s is not DER" % alias)
    fmt = lambda h: ":".join(h[i:i + 2] for i in range(0, len(h), 2))
    print("alias   : %s" % alias)
    print("SHA-256 : %s" % fmt(hashlib.sha256(der).hexdigest().upper()))
    print("SHA-1   : %s" % fmt(hashlib.sha1(der).hexdigest().upper()))
PY
