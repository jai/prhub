"""Gives a package's lockfile the app's version of every package both have: keep-app-versions.py <app's> <package's>."""

import json
import sys

with open(sys.argv[1]) as file:
    app = {pin["identity"]: pin for pin in json.load(file)["pins"]}
with open(sys.argv[2]) as file:
    lockfile = json.load(file)
lockfile["pins"] = [app.get(pin["identity"], pin) for pin in lockfile["pins"]]
with open(sys.argv[2], "w") as file:
    json.dump(lockfile, file, indent=2, separators=(",", " : "))
    file.write("\n")
