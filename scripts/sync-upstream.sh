#!/usr/bin/env zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Upstream sync & audit utility for ztat
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
LOCKFILE="$ROOT/upstreams.lock.json"
CACHE_DIR="$ROOT/upstreams"

usage() {
    cat <<'EOF'
Usage: ./scripts/sync-upstream.sh <command> [upstream]

Commands:
  status                 Show locked vs remote HEAD and commits behind for all upstreams
  fetch [name]           Clone (if missing) or fetch latest upstream commits into upstreams/
  diff <name>            Show commit log and stat diff from locked commit to upstream HEAD
  plan <name>            Categorize changed files since locked commit (apply / excluded / patched)
  patches [name]         List all '// ZTAT-PATCH:' markers across Packages/
  lock <name> [sha]      Update upstreams.lock.json commit & describe for <name> (defaults to HEAD)

Valid upstream names:
  vorssaint-utils | status-trio | stats | budhold | atoll | pearcleaner
EOF
}

py() {
    python3 - "$@"
}

cmd="${1:-help}"
shift || true

case "$cmd" in
    fetch)
        target="${1:-all}"
        py "$LOCKFILE" "$CACHE_DIR" "$target" <<'PY'
import json, os, subprocess, sys
lock_path, cache_dir, target = sys.argv[1:4]
data = json.load(open(lock_path))
os.makedirs(cache_dir, exist_ok=True)
names = list(data["upstreams"].keys()) if target == "all" else [target]
for name in names:
    if name not in data["upstreams"]:
        sys.exit(f"Unknown upstream: {name}")
    u = data["upstreams"][name]
    dest = os.path.join(cache_dir, name)
    if not os.path.exists(os.path.join(dest, ".git")):
        print(f"▸ Cloning {name} ({u['url']})...")
        subprocess.run(["git", "clone", "--branch", u["branch"], u["url"], dest], check=True)
    else:
        print(f"▸ Fetching {name} ({u['branch']})...")
        subprocess.run(["git", "-C", dest, "fetch", "origin", u["branch"], "--tags"], check=True)
print("✓ Upstream cache updated.")
PY
        ;;

    status)
        py "$LOCKFILE" "$CACHE_DIR" <<'PY'
import json, os, subprocess, sys
lock_path, cache_dir = sys.argv[1:3]
data = json.load(open(lock_path))
print(f"{'UPSTREAM':<18} {'LOCKED':<10} {'REMOTE':<10} {'BEHIND':<8} {'MODE'}")
print("-" * 76)
for name, u in data["upstreams"].items():
    locked = u["commit"][:8]
    dest = os.path.join(cache_dir, name)
    remote = "not-cached"
    behind = "-"
    if os.path.exists(os.path.join(dest, ".git")):
        ref = f"origin/{u['branch']}"
        r = subprocess.run(["git", "-C", dest, "rev-parse", ref], capture_output=True, text=True)
        if r.returncode == 0:
            remote_full = r.stdout.strip()
            remote = remote_full[:8]
            cnt = subprocess.run(
                ["git", "-C", dest, "rev-list", "--count", f"{u['commit']}..{remote_full}"],
                capture_output=True, text=True
            )
            behind = cnt.stdout.strip() if cnt.returncode == 0 else "?"
    print(f"{name:<18} {locked:<10} {remote:<10} {behind:<8} {u['integrationMode']}")
PY
        ;;

    diff)
        name="${1:-}"
        [[ -n "$name" ]] || { usage; exit 2; }
        py "$LOCKFILE" "$CACHE_DIR" "$name" <<'PY'
import json, os, subprocess, sys
lock_path, cache_dir, name = sys.argv[1:4]
data = json.load(open(lock_path))
if name not in data["upstreams"]:
    sys.exit(f"Unknown upstream: {name}")
u = data["upstreams"][name]
dest = os.path.join(cache_dir, name)
if not os.path.exists(os.path.join(dest, ".git")):
    sys.exit(f"Cache missing for {name}. Run: ./scripts/sync-upstream.sh fetch {name}")
rev_range = f"{u['commit']}..origin/{u['branch']}"
print(f"=== {name}: {rev_range} ===")
subprocess.run(["git", "-C", dest, "log", "--oneline", "--no-merges", rev_range], check=False)
print("\n=== File stat ===")
subprocess.run(["git", "-C", dest, "diff", "--stat", rev_range], check=False)
PY
        ;;

    plan)
        name="${1:-}"
        [[ -n "$name" ]] || { usage; exit 2; }
        py "$LOCKFILE" "$CACHE_DIR" "$ROOT" "$name" <<'PY'
import json, os, subprocess, sys
lock_path, cache_dir, root, name = sys.argv[1:5]
data = json.load(open(lock_path))
if name not in data["upstreams"]:
    sys.exit(f"Unknown upstream: {name}")
u = data["upstreams"][name]
dest = os.path.join(cache_dir, name)
if not os.path.exists(os.path.join(dest, ".git")):
    sys.exit(f"Cache missing for {name}. Run: ./scripts/sync-upstream.sh fetch {name}")
if u["integrationMode"] == "clean-room-feature-reference":
    print(f"⚠ {name} is clean-room reference only (no OSS license). Do NOT copy code; inspect commit summaries and re-implement in {u['targetPath']}.")
    sys.exit(0)
rev_range = f"{u['commit']}..origin/{u['branch']}"
r = subprocess.run(["git", "-C", dest, "diff", "--name-status", rev_range], capture_output=True, text=True)
lines = [l for l in r.stdout.splitlines() if l.strip()]
if not lines:
    print(f"✓ {name} is already up to date with origin/{u['branch']}.")
    sys.exit(0)
target_dir = os.path.join(root, u["targetPath"])
SKIP_DIRS = {".build", ".swiftpm", ".git", "DerivedData", "dist"}
TEXT_EXTS = {".swift", ".m", ".mm", ".h", ".c", ".cpp", ".plist", ".json", ".sh", ".md", ".strings", ".pl"}
patched = set()
if os.path.isdir(target_dir):
    for rdir, dirs, files in os.walk(target_dir):
        dirs[:] = [d for d in sorted(dirs) if d not in SKIP_DIRS]
        for f in files:
            if os.path.splitext(f)[1].lower() not in TEXT_EXTS:
                continue
            p = os.path.join(rdir, f)
            try:
                if "ZTAT-PATCH:" in open(p, errors="ignore").read():
                    patched.add(os.path.relpath(p, target_dir))
            except Exception:
                pass
print(f"Changed upstream files ({len(lines)}) -> target {u['targetPath']} (patched files in target: {len(patched)}):")
for l in lines:
    status, path = l.split("\t", 1)
    mark = "[CHECK-PATCH]" if any(os.path.basename(path) == os.path.basename(pf) for pf in patched) else "[SYNC]"
    print(f"  {status}  {mark:<13} {path}")
PY
        ;;

    patches)
        summary_only=0
        if [[ "${1:-}" == "--summary" ]]; then
            summary_only=1
            shift
        fi
        target="${1:-all}"
        py "$LOCKFILE" "$ROOT" "$target" "$summary_only" <<'PY'
import json, os, sys
lock_path, root, target, summary_flag = sys.argv[1:5]
summary_only = summary_flag == "1"
data = json.load(open(lock_path))
names = list(data["upstreams"].keys()) if target == "all" else [target]
SKIP_DIRS = {".build", ".swiftpm", ".git", "DerivedData", "dist"}
TEXT_EXTS = {".swift", ".m", ".mm", ".h", ".c", ".cpp", ".plist", ".json", ".sh", ".md", ".strings", ".pl"}
try:
    total_markers = 0
    total_files = 0
    for name in names:
        if name not in data["upstreams"]:
            sys.exit(f"Unknown upstream: {name}")
        u = data["upstreams"][name]
        tdir = os.path.join(root, u["targetPath"])
        if not summary_only:
            print(f"\n=== ZTAT-PATCH markers in {u['targetPath']} ({name}) ===")
        if not os.path.isdir(tdir):
            print(f"  {name:<18} (directory not yet populated)")
            continue
        found = 0
        patched_files = 0
        for rdir, dirs, files in os.walk(tdir):
            dirs[:] = [d for d in sorted(dirs) if d not in SKIP_DIRS]
            for f in sorted(files):
                if os.path.splitext(f)[1].lower() not in TEXT_EXTS:
                    continue
                p = os.path.join(rdir, f)
                file_hits = 0
                try:
                    with open(p, errors="ignore") as fp:
                        for idx, line in enumerate(fp, 1):
                            if "ZTAT-PATCH:" in line:
                                if not summary_only:
                                    rel = os.path.relpath(p, root)
                                    print(f"  {rel}:{idx}: {line.strip()}")
                                found += 1
                                file_hits += 1
                except Exception:
                    pass
                if file_hits:
                    patched_files += 1
        total_markers += found
        total_files += patched_files
        if summary_only:
            print(f"  {name:<18} {u['targetPath']:<26} {patched_files:>3} files, {found:>4} markers")
        elif found == 0:
            print("  (no inline markers found)")
    if summary_only:
        print(f"  {'TOTAL':<18} {'':<26} {total_files:>3} files, {total_markers:>4} markers")
except BrokenPipeError:
    try:
        sys.stdout.close()
    except Exception:
        pass
PY
        ;;

    lock)
        name="${1:-}"
        sha="${2:-}"
        [[ -n "$name" ]] || { usage; exit 2; }
        py "$LOCKFILE" "$CACHE_DIR" "$name" "$sha" <<'PY'
import datetime, json, os, subprocess, sys
lock_path, cache_dir, name, sha = sys.argv[1:5]
data = json.load(open(lock_path))
if name not in data["upstreams"]:
    sys.exit(f"Unknown upstream: {name}")
u = data["upstreams"][name]
dest = os.path.join(cache_dir, name)
ref = sha if sha else f"origin/{u['branch']}"
full_sha = subprocess.check_output(["git", "-C", dest, "rev-parse", ref], text=True).strip()
desc = subprocess.check_output(["git", "-C", dest, "describe", "--tags", "--always", full_sha], text=True).strip()
u["commit"] = full_sha
u["describe"] = desc
data["lastUpdated"] = datetime.date.today().isoformat()
with open(lock_path, "w") as fp:
    json.dump(data, fp, indent=2, ensure_ascii=False)
    fp.write("\n")
print(f"✓ Locked {name} at {full_sha[:10]} ({desc})")
PY
        ;;

    *)
        usage
        ;;
esac
