#!/usr/bin/env python3
"""Merkle root of a file (or of standard input), with the tree of RFC 6962.

An independent implementation of what the wrapper computes while it writes: the data is
cut into chunks of a fixed size, a leaf is SHA-256(0x00 + chunk), an inner node is
SHA-256(0x01 + left + right), and a tree of n leaves splits at the largest power of two
below n (written recursively, unlike the wrapper's streaming version). The empty input
has the hash of the empty string.

Usage: merkle_root.py CHUNK_SIZE [FILE]       prints: ROOT LENGTH CHUNKS
"""
import hashlib
import sys


def mth(leaves, lo, hi):
    n = hi - lo
    if n == 1:
        return leaves[lo]
    k = 1
    while k * 2 < n:
        k *= 2
    return hashlib.sha256(b"\x01" + mth(leaves, lo, lo + k) + mth(leaves, lo + k, hi)).digest()


def read_chunk(stream, size):
    buf = b""
    while len(buf) < size:
        part = stream.read(size - len(buf))
        if not part:
            break
        buf += part
    return buf


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    chunk = int(sys.argv[1])
    stream = open(sys.argv[2], "rb") if len(sys.argv) > 2 else sys.stdin.buffer
    leaves, total = [], 0
    while True:
        data = read_chunk(stream, chunk)
        if not data:
            break
        leaves.append(hashlib.sha256(b"\x00" + data).digest())
        total += len(data)
    root = hashlib.sha256(b"").digest() if not leaves else mth(leaves, 0, len(leaves))
    print(root.hex(), total, len(leaves))
    return 0


if __name__ == "__main__":
    sys.exit(main())
