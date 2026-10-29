# 2,000 isolated Foldera operation cases

Manual workflow: `.github/workflows/qa-2000.yml`, running on a temporary macOS runner.
There are no push triggers, credentials, external model calls or automatic code fixes.
The reviewed application revision is `56c75d12238c3099ecafbc4a4b7047e284db695e`;
the workflow checks it out in a separate local clone, leaving the original source alone.

The generator creates 20 operation families × 10 names × 10 fixture shapes = exactly
2,000 Swift Testing invocations. They exercise real `FileOps`, `Transfer`, and rename
`FileUndo` APIs, not Python filesystem substitutes or clicks in the GUI.

Covered: copy/move, same-folder no-op/copy, Keep Both/Skip/Stop, rename and rename
Undo/Redo, collisions and invalid names, whitespace trimming, refusing recursive
destinations, missing sources/raced targets, unique new item naming, disposable
permanent deletion and folder merge. Every failing case retries once with fresh data.

Fixtures cover empty/text/Unicode/binary files, empty/nested/wide/deep folders and
symbolic links. Names include accents, CJK, emoji, quotes, HTML characters, hidden names,
multiple extensions and long names. Checks compare byte hashes, full trees, symlinks,
source retention, unchanged targets, referents and a separate sentinel.

All operated files live in fresh temporary directories. Tests never empty Trash,
use real documents or mutate the real clipboard. Actual replacement via Trash,
cross-volume/cloud/network operations, power loss, disk full and GUI interaction
need separate coverage. No screenshots are claimed by this API campaign.

The artifact `foldera-2000-macos-results` contains HTML/JSON/JSONL reports and logs.
It distinguishes build/harness failure, untested cases, first failure, repeated failure
and an intermittent pass. A repeated check failure is still a candidate for review,
not an automatically confirmed product bug.

For a local Mac with macOS 14+, Swift 6 and Python 3:

```bash
python3 qa/foldera/test_harness.py
python3 qa/foldera/build_campaign.py --output /tmp/foldera-campaign
bash /tmp/foldera-campaign/run-on-mac.sh "$PWD" "$HOME/FolderaQA"
```

An optional `review_with_qwen.py` accepts only loopback llama-server endpoints;
model opinions remain unconfirmed and no generated code is executed.
