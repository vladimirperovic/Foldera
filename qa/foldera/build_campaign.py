"""Build exactly 2,000 parameterized tests for Foldera's real macOS code.

This only writes a portable test bundle. It never mutates the Foldera checkout.
"""
import argparse
import hashlib
import itertools
import json
from pathlib import Path

SOURCE_REVISION = "56c75d12238c3099ecafbc4a4b7047e284db695e"
OPERATIONS = [
    "copy", "move", "same-copy", "same-move", "keep-copy", "keep-move",
    "skip-copy", "skip-move", "stop", "rename", "rename-collision",
    "rename-invalid", "rename-trim", "descendant", "stale-copy", "stale-move",
    "new-items", "remove-tree", "merge-copy", "merge-move",
]
NAMES = ["report.txt", "ČćŽšĐ.txt", "报告.txt", "emoji-🪚.bin",
         "O'Connor & Sons.txt", '<tag> & "quote".txt', ".hidden",
         "archive.tar.gz", "v1.2 release", "x" * 180 + ".txt"]
FIXTURES = ["empty-file", "text", "unicode-content", "binary-4k", "binary-128k",
            "empty-folder", "nested-folder", "wide-folder", "deep-folder", "symlink"]


def matrix():
    cases = []
    for number, (operation, name, fixture) in enumerate(
            itertools.product(OPERATIONS, NAMES, FIXTURES), 1):
        cases.append({"id": f"foldera-{number:04d}", "operation": operation,
                      "name": name, "fixture": fixture,
                      "fixture_index": FIXTURES.index(fixture)})
    assert len(cases) == 2000
    assert len({(c["operation"], c["name"], c["fixture"]) for c in cases}) == 2000
    return cases


def build(output, revision=SOURCE_REVISION):
    output.mkdir(parents=True, exist_ok=True)
    here = Path(__file__).resolve().parent
    cases = matrix()
    # Base64 avoids shell interpolation and Swift string-literal/Unicode escapes.
    import base64
    payload = json.dumps(cases, ensure_ascii=False).encode("utf-8")
    encoded = base64.b64encode(payload).decode("ascii")
    template = (here / "FolderaCampaign.template.swift").read_text(encoding="utf-8")
    assert template.count("__CASES_BASE64__") == 1
    swift = template.replace("__CASES_BASE64__", encoded)
    (output / "FolderaCampaignTests.swift").write_text(swift, encoding="utf-8")
    (output / "cases.json").write_bytes(payload)
    for filename in ["run-on-mac.sh", "report.py", "review_with_qwen.py"]:
        (output / filename).write_text((here / filename).read_text(encoding="utf-8"), encoding="utf-8", newline="\n")
    metadata = {
        "status": "prepared_not_run", "expected_cases": 2000,
        "reviewed_revision": revision, "operations": {op: 100 for op in OPERATIONS},
        "dimensions": {"names": 10, "fixtures": 10, "operation_families": 20},
        "test_layer": "macOS Swift Testing, real FileOps/Transfer APIs; not GUI clicks",
        "runtime": "macOS 14+, Swift 6 Command Line Tools; Windows cannot run AppKit",
        "swift_sha256": hashlib.sha256(swift.encode("utf-8")).hexdigest(),
        "limits": ["Only disposable fixtures on one local filesystem; no network shares, cloud providers, power-loss or disk-full injection",
                   "No Trash or actual existing-target replacement; rename Undo/Redo is covered through the real API",
                   "Visual GUI evidence must be collected separately on a Mac",
                   "A failed check needs independent reproduction before being called an app bug"],
    }
    (output / "campaign.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"output": str(output.resolve()), "cases": len(cases), "status": metadata["status"]}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent / "prepared")
    parser.add_argument("--revision", default=SOURCE_REVISION)
    args = parser.parse_args()
    if len(args.revision) != 40 or any(c not in "0123456789abcdef" for c in args.revision):
        parser.error("--revision must be a full lowercase Git SHA")
    build(args.output, args.revision)
