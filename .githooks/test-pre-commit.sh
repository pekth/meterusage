#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/meterusage-hook.XXXXXX")
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/.githooks"
cp "$root/.githooks/pre-commit" "$fixture/.githooks/pre-commit"
git -C "$fixture" init -q
git -C "$fixture" config user.email fixture@example.invalid
git -C "$fixture" config user.name Fixture
printf 'safe\n' > "$fixture/old name.txt"
git -C "$fixture" add "old name.txt"
git -C "$fixture" commit -qm initial
git -C "$fixture" mv "old name.txt" "new name.txt"
git -C "$fixture" add "new name.txt"
printf 'sk-proj-working-tree-only-abcdefghijklmnopqrstuvwxyz123456\n' >> "$fixture/new name.txt"
(cd "$fixture" && ./.githooks/pre-commit)
git -C "$fixture" add "new name.txt"
if (cd "$fixture" && ./.githooks/pre-commit); then
  echo "fixture expected staged secret rejection" >&2
  exit 1
fi
