"""HPKE interoperability for the push sender.

Three independent checks:

1. A from-the-RFC reference implementation (test only) reproduces the RFC 9180
   Appendix A.2 vector byte for byte. That vector is the ciphersuite CryptoKit
   calls `Curve25519_SHA256_ChachaPoly`.
2. The same reference implementation reproduces the committed shared vector
   (`fixtures/push_hpke_vectors.json`) that the iOS tests open with CryptoKit.
3. The production `seal()` (the `cryptography` library) produces messages the
   reference implementation opens, and the library opens the shared vector.

The vector uses RFC 9180's published, non-secret test keys.
"""
import hashlib
import hmac
import importlib.util
import json
from pathlib import Path
import sys
import unittest

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

BASE = Path(__file__).resolve().parents[1]
FIXTURE = Path(__file__).with_name("fixtures") / "push_hpke_vectors.json"
spec = importlib.util.spec_from_file_location(
    "fleet_liveops_plugin_hpke", BASE / "dashboard" / "plugin_api.py")
plugin = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = plugin
spec.loader.exec_module(plugin)
payload_lib = plugin.push_module("push_payload")
store_lib = plugin.push_module("push_store")

KEM_ID, KDF_ID, AEAD_ID = 32, 1, 3
KEM_SUITE = b"KEM" + KEM_ID.to_bytes(2, "big")
HPKE_SUITE = b"HPKE" + KEM_ID.to_bytes(2, "big") + KDF_ID.to_bytes(2, "big") + AEAD_ID.to_bytes(2, "big")


def extract(salt, ikm):
    return hmac.new(salt or b"\0" * 32, ikm, hashlib.sha256).digest()


def expand(prk, info, length):
    output, block = b"", b""
    for counter in range(1, -(-length // 32) + 1):
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        output += block
    return output[:length]


def labeled_extract(suite, salt, label, ikm):
    return extract(salt, b"HPKE-v1" + suite + label + ikm)


def labeled_expand(suite, prk, label, info, length):
    return expand(prk, length.to_bytes(2, "big") + b"HPKE-v1" + suite + label + info, length)


def derive_key_pair(ikm):
    private = labeled_expand(KEM_SUITE, labeled_extract(KEM_SUITE, b"", b"dkp_prk", ikm), b"sk", b"", 32)
    return private, raw_public(private)


def raw_public(private):
    from cryptography.hazmat.primitives import serialization
    return X25519PrivateKey.from_private_bytes(private).public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def dh(private, public):
    return X25519PrivateKey.from_private_bytes(private).exchange(X25519PublicKey.from_public_bytes(public))


def key_schedule(shared_secret, info):
    context = (b"\0" + labeled_extract(HPKE_SUITE, b"", b"psk_id_hash", b"")
               + labeled_extract(HPKE_SUITE, b"", b"info_hash", info))
    secret = labeled_extract(HPKE_SUITE, shared_secret, b"secret", b"")
    return (labeled_expand(HPKE_SUITE, secret, b"key", context, 32),
            labeled_expand(HPKE_SUITE, secret, b"base_nonce", context, 12))


def shared_secret_for(dh_value, enc, recipient_public):
    prk = labeled_extract(KEM_SUITE, b"", b"eae_prk", dh_value)
    return labeled_expand(KEM_SUITE, prk, b"shared_secret", enc + recipient_public, 32)


def reference_seal(plaintext, recipient_public, ephemeral_ikm, info, aad=b""):
    ephemeral_private, enc = derive_key_pair(ephemeral_ikm)
    secret = shared_secret_for(dh(ephemeral_private, recipient_public), enc, recipient_public)
    key, nonce = key_schedule(secret, info)
    return enc, ChaCha20Poly1305(key).encrypt(nonce, plaintext, aad)


def reference_open(message, recipient_private, info, aad=b""):
    enc, ciphertext = message[:32], message[32:]
    recipient_public = raw_public(recipient_private)
    secret = shared_secret_for(dh(recipient_private, enc), enc, recipient_public)
    key, nonce = key_schedule(secret, info)
    return ChaCha20Poly1305(key).decrypt(nonce, ciphertext, aad)


class HPKEInteroperabilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vectors = json.loads(FIXTURE.read_text())

    def test_reference_reproduces_rfc9180_appendix_a2(self):
        rfc = self.vectors["rfc9180_a2"]
        ikm_e, info = bytes.fromhex(rfc["ikmE"]), bytes.fromhex(rfc["info"])
        private_e, public_e = derive_key_pair(ikm_e)
        self.assertEqual(public_e.hex(), rfc["enc"])
        recipient_private = bytes.fromhex(rfc["skRm"])
        self.assertEqual(raw_public(recipient_private).hex(), rfc["pkRm"])
        secret = shared_secret_for(dh(private_e, bytes.fromhex(rfc["pkRm"])), public_e,
                                   bytes.fromhex(rfc["pkRm"]))
        self.assertEqual(secret.hex(), rfc["shared_secret"])
        key, nonce = key_schedule(secret, info)
        self.assertEqual((key.hex(), nonce.hex()), (rfc["key"], rfc["base_nonce"]))
        enc, ciphertext = reference_seal(bytes.fromhex(rfc["pt"]), bytes.fromhex(rfc["pkRm"]),
                                         ikm_e, info, aad=bytes.fromhex(rfc["aad"]))
        self.assertEqual(ciphertext.hex(), rfc["ct"])

    def test_committed_vector_is_reproduced_by_the_reference(self):
        vector = self.vectors["push_v1"]
        recipient_public = bytes.fromhex(vector["recipient_public_key"])
        enc, ciphertext = reference_seal(
            vector["plaintext"].encode(), recipient_public, bytes.fromhex(vector["ephemeral_ikm"]),
            payload_lib.INFO)
        self.assertEqual(vector["info"], payload_lib.INFO.decode())
        self.assertEqual(store_lib.encode_b64url(enc + ciphertext), vector["sealed"])

    def test_library_opens_the_committed_vector(self):
        vector = self.vectors["push_v1"]
        private = X25519PrivateKey.from_private_bytes(bytes.fromhex(vector["recipient_private_key"]))
        opened = payload_lib.hpke_suite().decrypt(
            store_lib.decode_b64url(vector["sealed"]), private, info=payload_lib.INFO)
        self.assertEqual(opened.decode(), vector["plaintext"])
        self.assertEqual(json.loads(opened)["v"], 1)

    def test_production_seal_opens_with_the_reference(self):
        private = X25519PrivateKey.generate()
        raw_private = private.private_bytes_raw()
        sealed = payload_lib.seal(b"synthetic payload", store_lib.encode_b64url(raw_public(raw_private)))
        message = store_lib.decode_b64url(sealed)
        self.assertEqual(len(message), 32 + len(b"synthetic payload") + 16)
        self.assertEqual(reference_open(message, raw_private, payload_lib.INFO), b"synthetic payload")

    def test_seal_is_randomized_and_wrong_key_or_info_cannot_open(self):
        private = X25519PrivateKey.generate()
        public = store_lib.encode_b64url(raw_public(private.private_bytes_raw()))
        first, second = payload_lib.seal(b"same", public), payload_lib.seal(b"same", public)
        self.assertNotEqual(first, second)
        suite = payload_lib.hpke_suite()
        with self.assertRaises(Exception):
            suite.decrypt(store_lib.decode_b64url(first), X25519PrivateKey.generate(),
                          info=payload_lib.INFO)
        with self.assertRaises(Exception):
            suite.decrypt(store_lib.decode_b64url(first), private, info=b"other")


if __name__ == "__main__":
    unittest.main()
