#!/bin/sh
# Compile every module, type-check the modules that do not depend on `tern` and
# run the tests. Needs luau (`brew install luau`).
set -eu
cd "$(dirname "$0")/.."

echo "== compile"
find . -name '*.luau' -not -path './design/*' -print0 | xargs -0 luau-compile --null

echo "== type-check (pure core and shared modules)"
luau-analyze --mode=strict src/core/*.luau src/shared/text.luau src/shared/time.luau src/shared/template.luau src/shared/markup.luau src/shared/schema.luau tests/*.luau

echo "== tests"
for f in tests/*.spec.luau; do
	echo "-- $f"
	luau "$f"
done
