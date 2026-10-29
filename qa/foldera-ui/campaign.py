"""Disposable macOS GUI campaign; actual AppKit controls, no model-generated actions."""
import argparse
import hashlib
import html
import json
import os
import platform
import shutil
import struct
import subprocess
import time
import zlib
import zipfile
from pathlib import Path

REVISION = "56c75d12238c3099ecafbc4a4b7047e284db695e"
FLOWS = ["navigation", "search", "filters", "preview-toggle", "preview-detach", "preview-edit",
         "two-panes", "tabs", "new-folder", "new-document", "rename-inline", "rename-sheet",
         "copy-paste", "cut-paste", "copy-same", "trash-undo", "properties", "batch-rename",
         "quick-open", "find-command", "selection", "image-viewer", "sync-window",
         "new-menu", "sort-menu", "view-menu", "more-menu", "share-menu", "compare-files",
         "markdown-editor", "permanent-delete-cancel", "archive-browse"]


def cases(smoke=False):
    result = []
    for theme in ("light", "dark"):
        for width in (640, 800, 1100, 1440):
            for mode in ("details", "icons", "columns", "usage"):
                result.append({"scenario": "layout-" + mode, "theme": theme, "width": width})
    for theme, width in (("light", 1440), ("dark", 760)):
        for flow in FLOWS:
            result.append({"scenario": flow, "theme": theme, "width": width})
    for theme in ("light", "dark"):
        result.append({"scenario": "native-fullscreen", "theme": theme, "width": 1100})
    if smoke:
        result = [r for r in result if r["theme"] == "light" and (
            (r["scenario"] == "layout-details" and r["width"] == 1100) or
            r["scenario"] in ("new-menu", "rename-inline", "properties"))]
    for i, row in enumerate(result, 1):
        row["id"] = f"ui-{i:03d}"
    return result


def prepare(repo, checkout, harness):
    subprocess.run(["git", "clone", "--no-hardlinks", "--no-checkout", str(repo), str(checkout)], check=True)
    subprocess.run(["git", "-C", str(checkout), "checkout", "--detach", REVISION], check=True)
    source = checkout / "Sources/Foldera/AppDelegate.swift"
    text = source.read_text(encoding="utf-8")
    anchor = '        if args.contains("--verify-preview") {'
    if text.count(anchor) != 1:
        raise RuntimeError("Snapshot hook changed; refusing blind source patch")
    hook = '''        // Disposable CI-only overlay, not a product modification.
        if args.contains("--qa-ui-case") {
            guard let controller else { exit(2) }
            Task { @MainActor in
                FolderaUIAudit(tab: controller, output: URL(fileURLWithPath: args[1]), fixture: path).run()
            }
            return
        }
'''
    source.write_text(text.replace(anchor, hook + anchor), encoding="utf-8")
    shutil.copyfile(harness / "FolderaUIAudit.swift", checkout / "Sources/Foldera/FolderaUIAudit.swift")


def png(path, alternate=False):
    width, height = 320, 240
    pixels = b"".join(b"\x00" + bytes(c for x in range(width)
        for c in ((x + (50 if alternate else 0)) % 256, y % 256, (x + y) % 256)) for y in range(height))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def fixture(root):
    left, right = root / "Left", root / "Right"
    left.mkdir(parents=True)
    right.mkdir()
    (left / "Folder A").mkdir()
    (left / "Folder A/nested.txt").write_text("Nested synthetic file", encoding="utf-8")
    (left / "plain.txt").write_text("Synthetic UI fixture\n", encoding="utf-8")
    (left / "second.txt").write_text("Other synthetic text\n", encoding="utf-8")
    (left / ".hidden.txt").write_text("Hidden fixture", encoding="utf-8")
    (left / ('Dug naziv ČćŽšĐ emoji 🪚 ' + 'x' * 100 + '.txt')).write_text("Long name", encoding="utf-8")
    (left / "Reading.md").write_text("# Foldera UI audit\n\n**Bold**, *italic*, ČćŽšĐ and 柜子 🪚.\n\n| Item | Value |\n|---|---|\n| Test | Synthetic |\n\n- First\n- Second\n", encoding="utf-8")
    png(left / "picture.png")
    png(left / "picture-2.png", True)
    with zipfile.ZipFile(left / "sample.zip", "w") as archive:
        archive.writestr("inside.txt", "Synthetic archived file")
    return left


def execute(binary, root, spec, attempt):
    destination = root / "cases" / spec["id"] / f"attempt-{attempt}"
    destination.mkdir(parents=True)
    left = fixture(destination / "workspace")
    env = {**os.environ, "FOLDERA_UI_SCENARIO": spec["scenario"]}
    command = [str(binary), "--snapshot", str(left), str(destination / "capture.png"),
               "--size", f"{spec['width']}x740", "--" + spec["theme"], "--pane", "--select", "Reading.md",
               "--sync-library", str(destination / "sync-library")]
    command += ["--verify-preview"] if spec["scenario"] == "native-fullscreen" else ["--qa-ui-case"]
    started = time.monotonic()
    try:
        with (destination / "process.log").open("w", encoding="utf-8") as log:
            process = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=48)
        result_file = destination / "result.json"
        if result_file.exists():
            record = json.loads(result_file.read_text(encoding="utf-8"))
        elif spec["scenario"] == "native-fullscreen":
            log = (destination / "process.log").read_text(encoding="utf-8", errors="replace")
            valid = process.returncode == 0 and "Preview verification passed:" in log and len(list(destination.glob("*.png"))) >= 3
            record = {"status": "passed" if valid else "needs_reproduction",
                      "error": "" if valid else "Native fullscreen verification did not finish successfully",
                      "steps": [{"action": "Preview detach → fullscreen button → exit fullscreen → dock", "method": "Existing native PreviewVerification and notification/state assertions"}]}
        else:
            record = {"status": "harness_blocker", "error": f"No result.json; process exit {process.returncode}"}
        record["exit_code"] = process.returncode
        if process.returncode != 0 and record["status"] == "passed":
            record["status"] = "harness_blocker"
    except subprocess.TimeoutExpired:
        record = {"status": "harness_blocker", "error": "Process exceeded 48 seconds; killed on disposable runner"}
    except Exception as exc:
        record = {"status": "harness_blocker", "error": repr(exc)}
    record.update({"case": spec, "attempt": attempt, "seconds": round(time.monotonic() - started, 3),
                   "directory": destination.relative_to(root).as_posix(),
                   "screenshots": [p.name for p in sorted(destination.glob("*.png"))]})
    (destination / "evidence.json").write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
    return record


def report(root, planned, records, state):
    first = {r["case"]["id"]: r for r in records if r["attempt"] == 1}
    second = {r["case"]["id"]: r for r in records if r["attempt"] == 2}
    failed = {k: r for k, r in first.items() if r["status"] != "passed"}
    repeated = [k for k in failed if second.get(k, {}).get("status") in ("needs_reproduction", "harness_blocker")]
    shots = sum(len(r.get("screenshots", [])) for r in records)
    controls = []
    for path in (root / "cases").glob("*/*/*-controls.json"):
        try:
            for window in json.loads(path.read_text(encoding="utf-8")):
                for control in window["controls"]:
                    if control["class"] == "ToolButton" and not control["hidden"] and control["frame"][2] > 2 and control["visible_fraction"] < .97:
                        controls.append({"evidence": path.relative_to(root).as_posix(), "window": window["title"], **control})
        except (ValueError, KeyError):
            pass
    summary = {"status": state, "planned_cases": len(planned), "executed_cases": len(first),
        "initial_passes": sum(r["status"] == "passed" for r in first.values()),
        "initial_candidates_or_blockers": len(failed), "failed_again": len(repeated),
        "screenshots": shots, "clipped_toolbar_candidates": len(controls), "confirmed_bugs": 0,
        "source_revision": REVISION, "cloud_model_calls": 0, "local_model_calls": 0,
        "method": "Native in-process AppKit controls + event handlers, screenshot captures, filesystem/state assertions",
        "limitations": ["No claim every control/window/keyboard path is covered", "No external accessibility/XCUITest click automation",
            "No real network/server/cloud/AirDrop/mail delivery or default-file-manager changes",
            "Layout/clipping findings and failed checks require independent review; screenshots are preserved",
            "One macOS version and Chromium is not used; this is the actual native macOS app"]}
    payload = {"summary": summary, "cases": records, "clipping_candidates": controls,
        "not_exercised": ["Make Foldera/Finder default", "connect to real server", "AirDrop/share delivery",
                          "real cloud/file-provider placeholders", "all image/PDF/video formats", "every context-menu item", "OS permission dialogs on a personal Mac"]}
    (root / "results.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    (root / "status.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    esc = lambda value: html.escape(str(value), quote=True)
    parts = ["<!doctype html><html lang='sr'><meta charset='utf-8'><title>Foldera UI audit</title>",
        "<style>body{font:16px system-ui;max-width:1300px;margin:30px auto;padding:0 18px}img{max-width:420px;max-height:280px;border:1px solid #aaa}table{border-collapse:collapse;width:100%}td,th{border:1px solid #bbb;padding:9px;vertical-align:top}pre{white-space:pre-wrap;overflow-wrap:anywhere}</style>",
        "<h1>Foldera — native UI audit</h1>", f"<p><b>{esc(state)}</b> · {len(first)}/{len(planned)} slučajeva · {shots} snimaka ekrana.</p>",
        "<p>Aktiviranje stvarnih AppKit kontrola u testnoj aplikaciji. Pad provjere ili clipping kandidat nije automatski potvrđena greška.</p>",
        "<p><a href='results.json'>JSON sa koracima</a> · <a href='build.log'>Build log</a></p>",
        "<details><summary>Obuhvat, ograničenja i brojevi</summary><pre>" + esc(json.dumps(summary, ensure_ascii=False, indent=2)) + "</pre></details>",
        "<table><tr><th>Slučaj</th><th>Ishod / koraci</th><th>Snimci</th></tr>"]
    for identifier, row in first.items():
        spec = row["case"]
        links = []
        for name in row.get("screenshots", []):
            relative = row["directory"] + "/" + name
            links.append(f"<a href='{esc(relative)}'><img loading='lazy' src='{esc(relative)}' alt='{esc(name)}'></a>")
        detail = {"status": row["status"], "error": row.get("error", ""), "steps": row.get("steps", []), "retry": second.get(identifier, {}).get("status", "not needed/not run")}
        parts.append(f"<tr><td>{esc(identifier)}<br>{esc(spec['scenario'])}<br>{spec['width']}px {esc(spec['theme'])}</td><td><pre>{esc(json.dumps(detail, ensure_ascii=False, indent=2))}</pre></td><td>{''.join(links)}</td></tr>")
    parts.append("</table><h2>Neprovjereno</h2><pre>" + esc("\n".join(payload["not_exercised"])) + "</pre></html>")
    (root / "report.html").write_text("\n".join(parts), encoding="utf-8")
    return summary


def run(binary, root, smoke=False):
    if platform.system() != "Darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("This UI campaign only runs on disposable GitHub macOS runners")
    root.mkdir(parents=True, exist_ok=True)
    planned, records = cases(smoke), []
    deadline = time.monotonic() + 22 * 60
    (root / "plan.json").write_text(json.dumps(planned, indent=2), encoding="utf-8")
    for spec in planned:
        if time.monotonic() > deadline:
            break
        row = execute(binary, root, spec, 1)
        records.append(row)
        print(json.dumps({"case": spec["id"], "scenario": spec["scenario"], "result": row["status"], "seconds": row["seconds"]}), flush=True)
        if row["status"] != "passed" and time.monotonic() < deadline:
            records.append(execute(binary, root, spec, 2))
        report(root, planned, records, "running")
    summary = report(root, planned, records, "completed" if len({r["case"]["id"] for r in records}) == len(planned) else "deadline_reached")
    print(json.dumps(summary), flush=True)
    return 0 if summary["initial_candidates_or_blockers"] == 0 and summary["status"] == "completed" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_cmd = commands.add_parser("prepare")
    prepare_cmd.add_argument("repo", type=Path); prepare_cmd.add_argument("checkout", type=Path)
    run_cmd = commands.add_parser("run")
    run_cmd.add_argument("binary", type=Path); run_cmd.add_argument("output", type=Path)
    run_cmd.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.repo, args.checkout, Path(__file__).resolve().parent)
    else:
        raise SystemExit(run(args.binary.resolve(), args.output.resolve(), args.smoke))
