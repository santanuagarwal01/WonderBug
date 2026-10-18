#!/usr/bin/env python3
"""Build a separate, reproducible passage-search database. Never mutate the input."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import time

SCHEMA = """
CREATE TABLE passage_map(id INTEGER PRIMARY KEY, article INTEGER NOT NULL,
    ordinal INTEGER NOT NULL, paragraph_rowid INTEGER, source_id TEXT NOT NULL UNIQUE);
CREATE INDEX passage_map_article ON passage_map(article, ordinal);
INSERT INTO passage_map(article, ordinal, paragraph_rowid, source_id)
SELECT id, -1, NULL, 'a:' || id || ':lead' FROM articles WHERE trim(lead) <> '' ORDER BY id;
INSERT INTO passage_map(article, ordinal, paragraph_rowid, source_id)
SELECT article, ord, rowid, 'a:' || article || ':p:' || ord FROM paragraphs
WHERE trim(text) <> '' ORDER BY article, ord;
CREATE VIEW passage_documents AS
SELECT m.id, m.source_id, m.article, m.ordinal, a.title,
       CASE WHEN m.ordinal = -1 THEN '' ELSE p.section END AS section,
       CASE WHEN m.ordinal = -1 THEN a.lead ELSE p.text END AS text
FROM passage_map m JOIN articles a ON a.id=m.article
LEFT JOIN paragraphs p ON p.rowid=m.paragraph_rowid;
CREATE VIRTUAL TABLE passage_fts USING fts5(title, section, text,
    content='passage_documents', content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2', detail='none');
INSERT INTO passage_fts(passage_fts) VALUES ('rebuild');
INSERT INTO passage_fts(passage_fts) VALUES ('optimize');
CREATE TABLE passage_index_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""

def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1024*1024), b''): h.update(b)
    return h.hexdigest()

def build(source, output):
    source, output = Path(source).resolve(), Path(output).absolute()
    if source == output.resolve() or output.exists():
        raise ValueError('Output must be a new file, distinct from the source (including symlinks).')
    output.parent.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    fd, temporary = tempfile.mkstemp(prefix='.passage-index-', suffix='.db', dir=output.parent)
    os.close(fd)
    try:
        with sqlite3.connect(source.as_uri()+'?mode=ro', uri=True) as src, sqlite3.connect(temporary) as dst:
            src.backup(dst)
            dst.executescript(SCHEMA)
            metadata = {'schema_version': '1', 'source_sha256': digest(source),
                        'builder': 'passage-fts-v1', 'passages': str(dst.execute('SELECT count(*) FROM passage_map').fetchone()[0])}
            dst.executemany('INSERT INTO passage_index_metadata VALUES (?,?)', metadata.items())
            dst.execute("INSERT INTO passage_fts(passage_fts, rank) VALUES ('integrity-check', 1)")
            assert dst.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
            dst.commit()
        # No clobber even if another process created output during the build.
        os.link(temporary, output)
        report = dict(metadata, source_bytes=source.stat().st_size, output_bytes=output.stat().st_size,
                      added_bytes=output.stat().st_size-source.stat().st_size,
                      elapsed_seconds=round(time.monotonic()-start, 2))
        output.with_suffix('.manifest.json').write_text(json.dumps(report, indent=2)+'\n')
        return report
    finally:
        Path(temporary).unlink(missing_ok=True)

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('source'); p.add_argument('output')
    a=p.parse_args(); print(json.dumps(build(a.source,a.output), indent=2))
