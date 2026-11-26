"""Fails unless two lockfiles have one originHash: same-origin-hash.py <SwiftPM's> <the committed one>."""

import json
import sys

hashes = []
for path in sys.argv[1:3]:
    with open(path) as file:
        hashes.append(json.load(file).get("originHash"))
if not hashes[0] or hashes[0] != hashes[1]:
    sys.exit(f"error: {sys.argv[2]} has originHash {hashes[1]}, SwiftPM writes {hashes[0]}. Run make resolve.")
