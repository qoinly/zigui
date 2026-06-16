#!/usr/bin/env bash
# fetch the sqlite + lmdb sources the comparison links. run once before
# `zig build compare -Dcompare`. the sources are gitignored, not vendored in the repo.
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)/vendor"
mkdir -p "$dir"
cd "$dir"

sqlite="sqlite-amalgamation-3530200"
curl -fsSL -o sqlite.zip "https://www.sqlite.org/2026/${sqlite}.zip"
unzip -oj sqlite.zip "${sqlite}/sqlite3.c" "${sqlite}/sqlite3.h" >/dev/null
rm sqlite.zip

lmdb="https://raw.githubusercontent.com/LMDB/lmdb/LMDB_0.9.31/libraries/liblmdb"
for f in lmdb.h mdb.c midl.c midl.h; do
    curl -fsSL -o "$f" "${lmdb}/${f}"
done

echo "fetched sqlite 3.53.2 and lmdb 0.9.31 into ${dir}"
