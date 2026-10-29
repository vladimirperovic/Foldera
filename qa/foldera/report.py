"""Render honest per-case API results, preserving compile failures and retries."""
import html
import json
import sys
from collections import Counter
from pathlib import Path


def generate(root):
    metadata = json.loads((root / "campaign.json").read_text(encoding="utf-8"))
    specs = json.loads((root / "cases.json").read_text(encoding="utf-8"))
    expected_ids = {case["id"] for case in specs}
    records, malformed = [], []
    raw = root / "cases.jsonl"
    if raw.exists():
        for number, line in enumerate(raw.read_text(encoding="utf-8").splitlines(), 1):
            try:
                row = json.loads(line)
                if row["id"] not in expected_ids or row["attempt"] not in (1, 2):
                    raise ValueError("Unknown case ID or attempt")
                if row["status"] not in ("passed", "needs_reproduction"):
                    raise ValueError("Unknown result status")
                records.append(row)
            except (ValueError, KeyError, TypeError) as exc:
                malformed.append({"line": number, "error": str(exc)})
    first = {r["id"]: r for r in records if r["attempt"] == 1}
    second = {r["id"]: r for r in records if r["attempt"] == 2}
    duplicates = len(records) - len(first) - len(second)
    failed = {key: row for key, row in first.items() if row["status"] != "passed"}
    repeated = {key for key in failed if second.get(key, {}).get("status") == "needs_reproduction"}
    flaky = {key for key in failed if second.get(key, {}).get("status") == "passed"}
    exit_path = root / "attempt-1.exit"
    exit_code = int(exit_path.read_text().strip()) if exit_path.exists() else None
    status = "completed" if len(first) == len(expected_ids) and not malformed and not duplicates else "incomplete_or_blocked"
    if not records and exit_code is None and not malformed:
        status = "prepared_not_run"
    if exit_code not in (None, 0) and not failed:
        status = "harness_or_build_failure"
    summary = {
        "status": status, "expected_cases": len(expected_ids), "cases_executed": len(first),
        "untested": len(expected_ids - set(first)), "initial_passes": len(first) - len(failed),
        "initial_failures": len(failed), "failed_again_on_fresh_fixture": len(repeated),
        "passed_on_retry": len(flaky), "failures_without_retry": len(set(failed) - set(second)),
        "confirmed_product_bugs": 0,
        "bug_note": "Repeated API failures still need code/expectation review; no GUI coverage or automatic bug confirmation.",
        "malformed_records": malformed, "duplicate_records": duplicates,
        "first_process_exit": exit_code, "cloud_model_calls": 0, "local_model_calls": 0,
        "source_revision": metadata["reviewed_revision"],
        "by_operation": dict(Counter(r["operation"] for r in first.values())),
        "limits": metadata["limits"],
    }
    (root / "status.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    (root / "retry-ids.txt").write_text(",".join(sorted(failed)), encoding="utf-8")
    results = {"summary": summary, "cases": records}
    (root / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    esc = lambda value: html.escape(str(value), quote=True)
    parts = ["<!doctype html><html lang='sr'><meta charset='utf-8'><title>Foldera — 2.000 API testova</title>",
             "<style>body{font:16px system-ui;max-width:1150px;margin:32px auto;padding:0 18px}pre,td{overflow-wrap:anywhere;white-space:pre-wrap}table{border-collapse:collapse;width:100%}td,th{border:1px solid #aaa;padding:8px;text-align:left}</style>",
             "<h1>Foldera — 2.000 API testova</h1>",
             f"<p><b>{esc(status)}</b> · {len(first)}/{len(expected_ids)} izvršeno · {len(failed)} početnih padova · {len(repeated)} ponovljenih.</p>",
             "<p>Stvarni FileOps/Transfer kod na Macu, odvojeni privremeni podaci po slučaju. Ovo nije izvještaj o klikanju interfejsa. Nema izmišljenih snimaka ekrana ili AI potvrda.</p>",
             "<p><a href='results.json'>Svi rezultati</a> · <a href='attempt-1.log'>Izlaz builda/testova</a> · <a href='cases.json'>Plan 2.000 slučajeva</a></p>",
             "<details><summary>Obuhvat i ograničenja</summary><pre>" + esc(json.dumps(summary, ensure_ascii=False, indent=2)) + "</pre></details>",
             "<h2>Padovi za provjeru</h2><table><tr><th>ID / operacija</th><th>Ulaz</th><th>Dokaz / ponavljanje</th></tr>"]
    for key, row in sorted(failed.items()):
        parts.append(f"<tr><td>{esc(key)}<br>{esc(row['operation'])}</td><td>{esc(row['name'])}<br>{esc(row['fixture'])}</td><td>{esc(row['error'])}<br>Ponavljanje: {esc(second.get(key,{}).get('status','nije završeno'))}</td></tr>")
    if not failed:
        parts.append("<tr><td colspan='3'>Nema zabilježenih padova" + ("; testovi još nisu izvršeni." if not first else ".") + "</td></tr>")
    parts.append("</table></html>")
    (root / "report.html").write_text("\n".join(parts), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False))
    return summary


if __name__ == "__main__":
    generate(Path(sys.argv[1]).resolve())
