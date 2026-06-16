# comparison benchmark

qodb vs SQLite vs LMDB on one identical workload (200k records, a secondary index on
`country`; bulk insert, point gets, indexed queries, full scans). The SQLite and LMDB
sources are fetched, not vendored in the repo:

    ./fetch.sh
    cd ../.. && zig build compare -Dcompare -Doptimize=ReleaseFast

Each engine runs through its own fast path so none is handicapped: SQLite uses prepared
statements, one transaction for the bulk insert, the index present during load, and the
fast PRAGMAs; LMDB uses one write transaction, `MDB_APPEND` for the in-order keys, and a
DUPSORT named DB for the index. The same pre-generated records and random inputs feed
every engine.

Read it as two halves. The in-memory rows (SQLite `:memory:`, LMDB nosync) are the
like-for-like comparison - qodb's category. The file/sync rows show the per-transaction
durability the disk engines give and qodb does not. The memory columns measure different
things per engine (qodb heap, SQLite's allocator highwater, LMDB's mapped pages) and are
labeled, not summed.
