#!/usr/bin/env python3
"""Choose a corpus-wide storage budget without reading evaluation questions/results.

Existing long articles receive larger allocations; previously empty bodies have a small
floor for structured facts. Choose the largest 0.05 scale whose retained body text fits
90% of the baseline body-character count (headroom for extra short-row index overhead).
Keep complete blocks in extraction priority order. This can lose facts: evaluate it.
"""
import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import sqlite3
import tempfile
from build_corpus import SCHEMA,digest

def plan(old_lengths,blocks,fraction=.9):
    target=int(sum(old_lengths.values())*fraction)
    profiles=[]
    for step in range(1,21):
        scale=step/20;total=0;count=0
        for aid,rows in blocks.items():
            budget=int(max(600,min(4000,old_lengths.get(aid,0)))*scale);used=0
            for _,n in rows:
                if used+n<=budget:used+=n;total+=n;count+=1
        profiles.append({'scale':scale,'body_characters':total,'paragraphs':count})
    eligible=[p for p in profiles if p['body_characters']<=target]
    if not eligible:raise ValueError('No profile fits storage target')
    selected=eligible[-1];keep=[]
    for aid,rows in blocks.items():
        budget=int(max(600,min(4000,old_lengths.get(aid,0)))*selected['scale']);used=0
        for ordinal,n in rows:
            if used+n<=budget:used+=n;keep.append((aid,ordinal))
    return keep,{'target_body_characters':target,'fraction':fraction,'selected':selected,'profiles':profiles}

def compact(source,baseline,output):
    source=Path(source).resolve();baseline=Path(baseline).resolve();output=Path(output).absolute()
    if output.exists() or output.is_symlink() or output.resolve()in{source,baseline}:raise ValueError('Output must be new')
    output.parent.mkdir(parents=True,exist_ok=True)
    fd,temp=tempfile.mkstemp(prefix='.compact-',suffix='.db',dir=output.parent);os.close(fd)
    try:
        with sqlite3.connect(source.as_uri()+'?mode=ro',uri=True)as src,sqlite3.connect(baseline.as_uri()+'?mode=ro',uri=True)as base,sqlite3.connect(temp)as dst:
            old_lengths=dict(base.execute('SELECT article,sum(length(text)) FROM paragraphs GROUP BY article'))
            blocks=defaultdict(list)
            for aid,ordinal,n in src.execute('SELECT article,ord,length(text) FROM paragraphs ORDER BY article,ord'):blocks[aid].append((ordinal,n))
            keep,report=plan(old_lengths,blocks)
            print(json.dumps(report['selected']),flush=True)
            src.backup(dst)
            metadata=dict(dst.execute('SELECT key,value FROM passage_index_metadata'))
            dst.executescript('''DROP TABLE passage_fts;DROP VIEW passage_documents;DROP TABLE passage_map;DROP TABLE passage_index_metadata;
                CREATE TEMP TABLE kept(article INTEGER,ord INTEGER,PRIMARY KEY(article,ord));''')
            dst.executemany('INSERT INTO kept VALUES(?,?)',keep)
            dst.execute('DELETE FROM paragraphs WHERE NOT EXISTS(SELECT 1 FROM kept k WHERE k.article=paragraphs.article AND k.ord=paragraphs.ord)')
            dst.commit();dst.executescript(SCHEMA)
            metadata.update({'builder':'structured-evidence-compact-v1','compaction_source_sha256':digest(source),
                'baseline_sha256':digest(baseline),'compaction_scale':str(report['selected']['scale']),
                'passages':str(dst.execute('SELECT count(*) FROM passage_map').fetchone()[0])})
            dst.executemany('INSERT INTO passage_index_metadata VALUES(?,?)',metadata.items())
            dst.execute("INSERT INTO passage_fts(passage_fts,rank) VALUES('integrity-check',1)")
            if dst.execute('PRAGMA integrity_check').fetchone()[0]!='ok':raise ValueError('Integrity check failed')
            dst.commit();dst.execute('VACUUM')
        os.link(temp,output)
        report.update({'source_sha256':digest(source),'baseline_sha256':digest(baseline),'output_sha256':digest(output),
            'baseline_bytes':baseline.stat().st_size,'output_bytes':output.stat().st_size,
            'selection_basis':'Storage only; no evaluation questions, answers, labels, or scores are read.',
            'warning':'Per-article pruning can remove supporting facts. Do not promote from size alone.'})
        output.with_suffix('.manifest.json').write_text(json.dumps(report,indent=2)+'\n')
        return report
    finally:Path(temp).unlink(missing_ok=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',required=True);p.add_argument('--baseline',required=True);p.add_argument('--output',required=True)
    a=p.parse_args();print(json.dumps(compact(a.source,a.baseline,a.output),indent=2))
