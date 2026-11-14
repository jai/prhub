#!/usr/bin/env python3
"""The UI tests in slices for CI (.github/workflows/ios.yml): each slice runs on a Mac of its own, side by side.

    scripts/ui-test-slices.py args <slice> <of> <device>   xcodebuild's -only-testing arguments for one slice
    scripts/ui-test-slices.py show <of> <device>           each slice's tests and seconds
    scripts/ui-test-slices.py times <device> <tests.json>… rewrite a device's seconds from a run's result bundles
                                                   (xcrun xcresulttool get test-results tests --path <bundle> --compact)
    scripts/ui-test-slices.py plans [--check]              write app/TestPlans (Xcode Cloud's PRHub Tests), or
                                                           fail when they differ from what the slices are now

Xcode Cloud runs one Test action a plan, side by side, each on the iPhone and the iPad at once: app/TestPlans/ui-N
is slice N of the iPad's (the slower device's) slices, and ui-1 also holds the unit tests. all.xctestplan, every
test, is the scheme's default, so a run from Xcode or with -only-testing runs what it names as before.

<device> is iPhone or iPad (its name's first word). The tests are read from app/PRHubUITests/*.swift, so a new test is
in a slice from its first push. Their seconds on each device are in app/PRHubUITests/times.txt ("Class/test iPhone
iPad"), from a run on GitHub's Mac; a test not listed there counts as the middle one. Longest first, each test goes to
the slice with the fewest seconds so far, so a device's slices end together.
"""

from __future__ import annotations

import json
import re
import statistics
import sys
from pathlib import Path

TESTS = Path(__file__).resolve().parent.parent / "app" / "PRHubUITests"
TIMES = TESTS / "times.txt"
CLASS = re.compile(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase", re.M)
TEST = re.compile(r"^\s*func\s+(test\w*)\s*\(", re.M)


def tests() -> list[str]:
    """Every UI test, as Class/test."""
    found = []
    for path in sorted(TESTS.glob("*.swift")):
        text = path.read_text()
        found += [
            f"{cls}/{test}"
            for cls in CLASS.findall(text)
            for test in TEST.findall(text)
        ]
    return found


DEVICES = ("iPhone", "iPad")


def column(device: str) -> int:
    family = device.split()[0]
    if family not in DEVICES:
        sys.exit(f"ui-test-slices: no device {device!r}: iPhone or iPad")
    return DEVICES.index(family)


def times() -> dict[str, list[float]]:
    """Each listed test's seconds, on the iPhone and on the iPad."""
    if not TIMES.exists():
        return {}
    lines = [
        line.split()
        for line in TIMES.read_text().splitlines()
        if line and not line.startswith("#")
    ]
    return {name: [float(iphone), float(ipad)] for name, iphone, ipad in lines}


def slices(count: int, device: str) -> list[list[tuple[str, float]]]:
    which = column(device)
    known = {name: seconds[which] for name, seconds in times().items()}
    middle = statistics.median(known.values()) if known else 30.0
    weighed = sorted(
        ((name, known.get(name, middle)) for name in tests()),
        key=lambda t: (-t[1], t[0]),
    )
    made: list[list[tuple[str, float]]] = [[] for _ in range(count)]
    for test in weighed:
        min(made, key=lambda s: sum(seconds for _, seconds in s)).append(test)
    return made


def write_times(device: str, tree_paths: list[str]) -> None:
    def cases(node: dict, suite: str = ""):
        if node.get("nodeType") == "Test Case" and suite:
            yield (
                f"{suite}/{node['name'].removesuffix('()')}",
                float(node.get("durationInSeconds", 0)),
            )
        for child in node.get("children", []):
            yield from cases(
                child, node["name"] if node.get("nodeType") == "Test Suite" else suite
            )

    which = column(device)
    kept = times()
    found = 0
    for name in tests():
        kept.setdefault(name, [0.0, 0.0])
    for tree_path in tree_paths:
        tree = json.loads(Path(tree_path).read_text())
        for root in tree.get("testNodes", []):
            for name, seconds in cases(root):
                if name in kept:
                    kept[name][which] = seconds
                    found += 1
    names = set(tests())
    head = (
        [line for line in TIMES.read_text().splitlines() if line.startswith("#")]
        if TIMES.exists()
        else []
    )
    rows = [
        f"{name} {seconds[0]:.0f} {seconds[1]:.0f}"
        for name, seconds in sorted(kept.items(), key=lambda t: (-max(t[1]), t[0]))
        if name in names
    ]
    TIMES.write_text("\n".join(head + rows) + "\n")
    print(f"{device}: {found} tests timed, {len(rows)} listed")


PLANS = TESTS.parent / "TestPlans"
PLAN_SLICES = 4
# The test targets as the generated project names them: XcodeGen derives an id from the target's name, so they hold.
UI_TARGET = {
    "containerPath": "container:PRHub.xcodeproj",
    "identifier": "ECC363D5E63C730E3779F386",
    "name": "PRHubUITests",
}
UNIT_TARGETS = [
    {
        "target": {
            "containerPath": "container:PRHub.xcodeproj",
            "identifier": "FDE14B3D00FCA91A6857FCF5",
            "name": "PRHubTests",
        }
    },
    {
        "target": {
            "containerPath": "container:..",
            "identifier": "PRKitTests",
            "name": "PRKitTests",
        }
    },
]


def plan(targets: list[dict]) -> str:
    """An Xcode test plan: a failed test runs once more, as on GitHub's Macs the slow Simulator made some flaky."""
    return (
        json.dumps(
            {
                "configurations": [
                    {
                        "id": "6C1E3F2A-0000-4000-8000-000000000001",
                        "name": "Tests",
                        "options": {},
                    }
                ],
                "defaultOptions": {
                    "maximumTestRepetitions": 2,
                    "testRepetitionMode": "retryOnFailure",
                },
                "testTargets": targets,
                "version": 1,
            },
            indent=2,
        )
        + "\n"
    )


def plans() -> dict[str, str]:
    made = {"all": plan(UNIT_TARGETS + [{"target": UI_TARGET}])}
    for number, chosen in enumerate(slices(PLAN_SLICES, "iPad"), 1):
        ui = [
            {
                "selectedTests": sorted(f"{name}()" for name, _ in chosen),
                "target": UI_TARGET,
            }
        ]
        made[f"ui-{number}"] = plan((UNIT_TARGETS if number == 1 else []) + ui)
    return made


def write_plans(check: bool) -> None:
    wanted = plans()
    stale = [
        name
        for name, text in wanted.items()
        if not (PLANS / f"{name}.xctestplan").exists()
        or (PLANS / f"{name}.xctestplan").read_text() != text
    ]
    if check:
        if stale:
            sys.exit(
                f"ui-test-slices: app/TestPlans differ from the slices ({', '.join(stale)}): "
                "run scripts/ui-test-slices.py plans and commit them"
            )
        print(f"ui-test-slices: {len(wanted)} test plans match the slices")
        return
    PLANS.mkdir(exist_ok=True)
    for name, text in wanted.items():
        (PLANS / f"{name}.xctestplan").write_text(text)
    print(f"wrote {len(wanted)} test plans ({', '.join(stale) or 'none changed'})")


def main() -> None:
    match sys.argv[1:]:
        case ["args", index, count, device] if 1 <= int(index) <= int(count):
            for name, _ in slices(int(count), device)[int(index) - 1]:
                print(f"-only-testing:PRHubUITests/{name}")
        case ["show", count, device]:
            for number, made in enumerate(slices(int(count), device), 1):
                print(f"slice {number}: {sum(s for _, s in made):.0f} s")
                for name, seconds in made:
                    print(f"  {seconds:5.0f}  {name}")
        case ["times", device, *tree_paths] if tree_paths:
            write_times(device, tree_paths)
        case ["plans"]:
            write_plans(check=False)
        case ["plans", "--check"]:
            write_plans(check=True)
        case _:
            sys.exit(__doc__)


main()
