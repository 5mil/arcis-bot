#!/usr/bin/env python3
"""Generate a DigiByte mainnet keypair (P2PKH, starts with D).

Prints the address and WIF. Does not store the key.
PAPER builds ignore it. For live mode pass the address with -Dfunding=D...

Usage:
  python3 tools/gen_dgb_wallet.py
  python3 tools/gen_dgb_wallet.py --save hearth/wallets/funding.key
"""
import argparse
import hashlib
import os
import sys

from ecdsa import SigningKey, SECP256k1

DGB_P2PKH_VERSION = b"\x1e"  # addresses start with D
DGB_WIF_VERSION = b"\x80"
ALPHABET = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58check(payload: bytes) -> str:
    chk = hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
    data = payload + chk
    n = int.from_bytes(data, "big")
    out = b""
    while n:
        n, r = divmod(n, 58)
        out = ALPHABET[r : r + 1] + out
    # leading zeros
    pad = 0
    for b in data:
        if b == 0:
            pad += 1
        else:
            break
    return (ALPHABET[0:1] * pad + out).decode()


def hash160(b: bytes) -> bytes:
    return hashlib.new("ripemd160", hashlib.sha256(b).digest()).digest()


def main() -> None:
    ap = argparse.ArgumentParser(description="Generate a DigiByte funding wallet")
    ap.add_argument("--save", help="write WIF to this path (0600); address is printed")
    args = ap.parse_args()

    sk = SigningKey.generate(curve=SECP256k1)
    priv = sk.to_string()
    pub = sk.get_verifying_key().to_string()  # 64 bytes x||y
    # compressed
    x = pub[:32]
    y_odd = pub[63] & 1
    compressed = bytes([0x03 if y_odd else 0x02]) + x

    addr = b58check(DGB_P2PKH_VERSION + hash160(compressed))
    wif = b58check(DGB_WIF_VERSION + priv + b"\x01")

    print(f"address: {addr}")
    print(f"wif:     {wif}")
    print()
    print("Fund this address, then build with:")
    print(f"  zig build -Dfunding={addr}")
    print()
    print("Keep the WIF offline. The bot only reads it from a local file")
    print("when the live gate is open. Never commit it.")

    if args.save:
        os.makedirs(os.path.dirname(args.save) or ".", exist_ok=True)
        with open(args.save, "w") as f:
            f.write(wif + "\n")
        os.chmod(args.save, 0o600)
        print(f"\nWIF written to {args.save} (mode 0600)")


if __name__ == "__main__":
    main()
