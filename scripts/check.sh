#!/bin/sh
# Compile every module, type-check the modules that do not depend on `tern` and
# run the tests. Needs luau (`brew install luau`) and Node.js.
set -eu
cd "$(dirname "$0")/.."

echo "== compile"
find . -name '*.luau' -not -path './design/*' -print0 | xargs -0 luau-compile --null

echo "== type-check (pure core and shared modules)"
luau-analyze --mode=strict src/core/*.luau $(grep -L 'require("tern")' src/shared/*.luau) src/services/stage.luau src/ui/ids.luau src/ui/input.luau tests/*.luau

echo "== tests"
for f in tests/*.spec.luau; do
	echo "-- $f"
	luau "$f"
done

echo "== isolated-stage guard"
node --test tests/*.spec.mjs
