# SQLite-vec for the iPhone experiment

Unmodified SQLite-vec 0.1.6 amalgamation from:

https://github.com/asg017/sqlite-vec/releases/download/v0.1.6/sqlite-vec-0.1.6-amalgamation.tar.gz

Upstream source revision in the release header: `639fca5739fe056fdc98f3d539c4cd79328d7dc7`.
The C target uses `SQLITE_CORE` and `SQLITE_VEC_STATIC` and links Apple's `sqlite3`.
The Swift owner calls `sqlite3_vec_init` on its private, read-only connection; it does not
enable dynamic extension loading or register the extension on every app connection.

The public module map and Package.swift are WonderBug integration files. The upstream C
and header are unchanged. The MIT license is included here and in the experiment app's
`wiki-vector-LICENSE.txt`. The version is intentionally the same as the evaluated index
builder, rather than an untested library upgrade.
