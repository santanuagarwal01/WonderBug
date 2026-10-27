#!/usr/bin/env python3
"""Remove build-only provenance from a separate runtime copy; retain the audit database."""
import argparse
import json
import os
from pathlib import Path
import sqlite3
import tempfile
from build_corpus import digest

def export(source,output):
    source=Path(source).resolve();output=Path(output).absolute()
    if output.exists() or output.is_symlink() or output.resolve()==source:
        raise ValueError('Choose a new output path, distinct from the source')
    output.parent.mkdir(parents=True,exist_ok=True)
    fd,temp=tempfile.mkstemp(prefix='.runtime-',suffix='.db',dir=output.parent);os.close(fd)
    try:
        with sqlite3.connect(source.as_uri()+'?mode=ro',uri=True) as src,sqlite3.connect(temp) as dst:
            src.backup(dst)
            count=src.execute('SELECT count(*) FROM passage_documents').fetchone()[0]
            dst.execute('DROP TABLE evidence_provenance')
            dst.execute('INSERT INTO passage_index_metadata VALUES(?,?)',('audit_database_sha256',digest(source)))
            dst.commit();dst.execute('VACUUM')
            # Logical data equality checked by ordered row comparison, not just counts.
            before=src.execute('SELECT * FROM passage_documents ORDER BY id')
            after=dst.execute('SELECT * FROM passage_documents ORDER BY id')
            for left,right in zip(before,after):
                if left!=right:raise ValueError('Runtime evidence changed during export')
            if dst.execute('SELECT count(*) FROM passage_documents').fetchone()[0]!=count:raise ValueError('Passage count changed')
            dst.execute("INSERT INTO passage_fts(passage_fts,rank) VALUES('integrity-check',1)")
            if dst.execute('PRAGMA integrity_check').fetchone()[0]!='ok':raise ValueError('Integrity check failed')
            dst.commit()
        os.link(temp,output)
        manifest={'audit_database':str(source),'audit_sha256':digest(source),
            'runtime_sha256':digest(output),'audit_bytes':source.stat().st_size,
            'runtime_bytes':output.stat().st_size,'passages_verified_identical':count,
            'removed':'evidence_provenance (build-only audit metadata)'}
        output.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        return manifest
    finally:Path(temp).unlink(missing_ok=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('source');p.add_argument('output');a=p.parse_args()
    print(json.dumps(export(a.source,a.output),indent=2))
