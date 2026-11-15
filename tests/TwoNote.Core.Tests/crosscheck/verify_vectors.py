"""Independent cross-check of docs/test-vectors.json.

Recomputes every expected value from the inputs using implementations that share no code
with TwoNote.Core (which uses libsodium through Geralt, plus .NET's HKDF and normaliser):

  Argon2id            argon2-cffi   (the PHC reference C implementation)
  HKDF-SHA256         cryptography  (OpenSSL)
  Ed25519             cryptography  (OpenSSL)
  XChaCha20-Poly1305  pycryptodome
  NFKC                Python unicodedata
  Crockford base32, base64url, hex: written out below / Python stdlib

Usage:
  python -m venv .venv
  .venv/Scripts/pip install argon2-cffi cryptography pycryptodome     (bin/pip on Linux)
  .venv/Scripts/python verify_vectors.py [path/to/test-vectors.json]

Exits non-zero if anything differs.
"""

import base64
import json
import pathlib
import sys
import unicodedata

from argon2.low_level import Type, hash_secret_raw
from Crypto.Cipher import ChaCha20_Poly1305
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
checks = 0
failures = []


def check(label, actual, expected):
    global checks
    checks += 1
    if actual != expected:
        failures.append(f"{label}\n    expected {expected!r}\n    actual   {actual!r}")


def hkdf(ikm, salt, info):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(ikm)


def format_secret_key(raw):
    bits = "".join(f"{b:08b}" for b in raw) + "00"  # 128 bits, then two zero bits -> 26 symbols
    s = "".join(CROCKFORD[int(bits[i:i + 5], 2)] for i in range(0, 130, 5))
    return f"T2-{s[0:6]}-{s[6:12]}-{s[12:18]}-{s[18:26]}"


def parse_secret_key(text):
    s = "".join(c for c in text if c != "-" and not c.isspace()).upper()
    if len(s) == 28 and s.startswith("T2"):
        s = s[2:]
    if len(s) != 26:
        return None
    s = s.replace("O", "0").replace("I", "1").replace("L", "1")
    if any(c not in CROCKFORD for c in s):
        return None
    bits = "".join(f"{CROCKFORD.index(c):05b}" for c in s)
    if bits[128:] != "00":
        return None
    return bytes(int(bits[i:i + 8], 2) for i in range(0, 128, 8))


def main():
    default = pathlib.Path(__file__).resolve().parents[3] / "docs" / "test-vectors.json"
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else default
    v = json.loads(path.read_text(encoding="utf-8"))

    # 1.1 Secret Key
    sk = v["secretKey"]
    raw = bytes.fromhex(sk["bytes"])
    check("secretKey.formatted", format_secret_key(raw), sk["formatted"])
    for text in sk["accepted"]:
        check(f"secretKey.accepted {text!r}", parse_secret_key(text), raw)
    for text in sk["rejected"]:
        check(f"secretKey.rejected {text!r}", parse_secret_key(text), None)

    # 1.2 Key derivation
    for c in v["keyDerivation"]:
        n = c["name"]
        p = c["kdfParams"]
        check(f"kdf[{n}].alg", p["alg"], "argon2id13")
        pw = unicodedata.normalize("NFKC", c["password"]).encode("utf-8")
        check(f"kdf[{n}].passwordNfkcUtf8", pw.hex(), c["passwordNfkcUtf8"])
        k_pw = hash_secret_raw(
            secret=pw, salt=bytes.fromhex(c["kdfSalt"]), time_cost=p["ops"], memory_cost=p["memKiB"],
            parallelism=1, hash_len=32, type=Type.ID, version=0x13)
        check(f"kdf[{n}].kPw", k_pw.hex(), c["kPw"])
        k_sk = hkdf(bytes.fromhex(c["secretKey"]), bytes.fromhex(c["accountId"]), b"twonote/v1/2skd")
        check(f"kdf[{n}].kSk", k_sk.hex(), c["kSk"])
        root = bytes(a ^ b for a, b in zip(k_pw, k_sk))
        check(f"kdf[{n}].root", root.hex(), c["root"])
        unlock = hkdf(root, None, b"twonote/v1/unlock")
        check(f"kdf[{n}].unlockKey", unlock.hex(), c["unlockKey"])
        check(f"kdf[{n}].unlockKey (explicit zero salt)", hkdf(root, bytes(32), b"twonote/v1/unlock").hex(), c["unlockKey"])
        seed = hkdf(root, None, b"twonote/v1/auth")
        check(f"kdf[{n}].authSeed", seed.hex(), c["authSeed"])
        pub = Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        check(f"kdf[{n}].authPublicKey", pub.hex(), c["authPublicKey"])

    # 1.3 Sealed blob
    for c in v["sealedBlob"]:
        n = c["name"]
        key, nonce = bytes.fromhex(c["key"]), bytes.fromhex(c["nonce"])
        plaintext, blob = bytes.fromhex(c["plaintext"]), bytes.fromhex(c["blob"])
        aad = ("twonote/v1|" + c["kind"] + "|" + c["id"]).encode("utf-8")
        check(f"sealed[{n}].aad", aad.decode(), c["aad"])

        enc = ChaCha20_Poly1305.new(key=key, nonce=nonce)
        enc.update(aad)
        ciphertext, tag = enc.encrypt_and_digest(plaintext)
        check(f"sealed[{n}].blob", (b"\x01" + nonce + ciphertext + tag).hex(), c["blob"])

        dec = ChaCha20_Poly1305.new(key=key, nonce=blob[1:25])
        dec.update(aad)
        check(f"sealed[{n}].open", dec.decrypt_and_verify(blob[25:-16], blob[-16:]).hex(), c["plaintext"])

    # 1.4 Login signature
    s = v["loginSignature"]
    nonce = bytes.fromhex(s["nonce"])
    message = b"twonote/v1/login" + nonce
    check("login.message", message.hex(), s["message"])
    private = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(s["authSeed"]))
    check("login.signature", private.sign(message).hex(), s["signature"])
    try:
        Ed25519PublicKey.from_public_bytes(bytes.fromhex(s["authPublicKey"])).verify(
            bytes.fromhex(s["signature"]), message)
        verified = True
    except InvalidSignature:
        verified = False
    check("login.verify", verified, True)

    # Wire encodings
    for item in v["wireEncoding"]["base64Url"]:
        text = base64.urlsafe_b64encode(bytes.fromhex(item["bytes"])).rstrip(b"=").decode()
        check(f"base64Url {item['bytes']!r}", text, item["text"])
    check("id", bytes.fromhex(v["wireEncoding"]["id"]["bytes"]).hex(), v["wireEncoding"]["id"]["text"])

    for f in failures:
        print("MISMATCH " + f)
    print(f"{checks - len(failures)} of {checks} checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
