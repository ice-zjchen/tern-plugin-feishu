#!/bin/sh
# Compile every module, type-check the modules that do not depend on `tern` and
# run the tests. Needs luau (`brew install luau`).
set -eu
cd "$(dirname "$0")/.."

echo "== compile"
find . -name '*.luau' -not -path './design/*' -print0 | xargs -0 luau-compile --null

echo "== type-check (modules without tern)"
luau-analyze --mode=strict $(grep -L 'require("tern")' $(find src tests -name '*.luau'))

echo "== tests"
for f in tests/*.spec.luau; do
	echo "-- $f"
	luau "$f"
done
