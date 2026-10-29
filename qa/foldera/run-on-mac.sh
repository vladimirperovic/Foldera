#!/bin/bash
# Manual only. No daemon, model API, autostart, credentials or production files.
set -euo pipefail
if [ "$(uname -s)" != Darwin ]; then
  echo 'Foldera requires macOS 14+ and Swift 6; Windows/WSL cannot run AppKit.' >&2
  exit 2
fi
if [ "${FOLDERA_CAMPAIGN_AWAKE:-0}" != 1 ]; then
  export FOLDERA_CAMPAIGN_AWAKE=1
  exec caffeinate -i /bin/bash "$0" "$@"
fi
bundle="$(cd "$(dirname "$0")" && pwd)"
repo="${1:?Usage: bash run-on-mac.sh /path/to/Foldera [/path/to/reports]}"
revision="$(python3 - "$bundle/campaign.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['reviewed_revision'])
PY
)"
command -v python3 >/dev/null
xcrun --find swift >/dev/null
git -C "$repo" cat-file -e "$revision^{commit}"
out="${2:-$HOME/FolderaQA}/run-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
export FOLDERA_CAMPAIGN_RESULTS="$out"
export FOLDERA_CAMPAIGN_ATTEMPT=1
unset FOLDERA_CAMPAIGN_RETRY_IDS
# Test a separate local clone, at the reviewed revision, not uncommitted files.
git clone --no-hardlinks --no-checkout "$repo" "$out/checkout" >"$out/clone.log" 2>&1
git -C "$out/checkout" checkout --detach "$revision" >>"$out/clone.log" 2>&1
cp "$bundle/FolderaCampaignTests.swift" "$out/checkout/Tests/FolderaTests/FolderaCampaignTests.swift"
cp "$bundle/campaign.json" "$bundle/cases.json" "$out/"
git -C "$out/checkout" rev-parse HEAD >"$out/source-revision.txt"
{
  sw_vers
  xcrun swift --version
  uname -m
} >"$out/environment.txt"
cd "$out/checkout"
set +e
bash ./test.sh --filter FolderaCampaign >"$out/attempt-1.log" 2>&1
initial_exit=$?
set -e
printf '%s\n' "$initial_exit" >"$out/attempt-1.exit"
python3 "$bundle/report.py" "$out"
if [ -s "$out/retry-ids.txt" ]; then
  export FOLDERA_CAMPAIGN_RETRY_IDS="$(cat "$out/retry-ids.txt")"
  export FOLDERA_CAMPAIGN_ATTEMPT=2
  # Every retried case creates a new temporary fixture and independent sentinel.
  set +e
  bash ./test.sh --skip-build --filter FolderaCampaign >"$out/attempt-2.log" 2>&1
  retry_exit=$?
  set -e
  printf '%s\n' "$retry_exit" >"$out/attempt-2.exit"
fi
python3 "$bundle/report.py" "$out"
echo "Report: $out/report.html"
echo 'No GUI screenshots were taken. API failures are candidates for reproduction and review.'
python3 - "$out" <<'PY'
import json, sys
from pathlib import Path
s = json.loads((Path(sys.argv[1]) / 'status.json').read_text())
sys.exit(0 if s['status'] == 'completed' and s['initial_failures'] == 0 else 1)
PY
