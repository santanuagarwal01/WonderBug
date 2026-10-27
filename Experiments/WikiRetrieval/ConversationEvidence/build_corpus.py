#!/usr/bin/env python3
"""Rebuild body evidence from the pinned local dump into a NEW SQLite file.

Preserve the baseline's article/redirect set, lead text and legacy title index. Replace
body paragraphs with bounded structured extraction, then rebuild the same FTS5 index.
This is an offline experiment; never overwrite a source or the app's bundled database.
"""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import time
import xml.etree.ElementTree as ET
from extract_evidence import extract, VERSION, BODY_BUDGET

NS='{http://www.mediawiki.org/xml/export-0.11/}'
SCHEMA='''
CREATE TABLE passage_map(id INTEGER PRIMARY KEY, article INTEGER NOT NULL,
 ordinal INTEGER NOT NULL, paragraph_rowid INTEGER, source_id TEXT NOT NULL UNIQUE);
CREATE INDEX passage_map_article ON passage_map(article,ordinal);
INSERT INTO passage_map(article,ordinal,paragraph_rowid,source_id)
 SELECT id,-1,NULL,'a:'||id||':lead' FROM articles WHERE trim(lead)<>'' ORDER BY id;
INSERT INTO passage_map(article,ordinal,paragraph_rowid,source_id)
 SELECT article,ord,rowid,'a:'||article||':p:'||ord FROM paragraphs WHERE trim(text)<>'' ORDER BY article,ord;
CREATE VIEW passage_documents AS SELECT m.id,m.source_id,m.article,m.ordinal,a.title,
 CASE WHEN m.ordinal=-1 THEN '' ELSE p.section END AS section,
 CASE WHEN m.ordinal=-1 THEN a.lead ELSE p.text END AS text
 FROM passage_map m JOIN articles a ON a.id=m.article LEFT JOIN paragraphs p ON p.rowid=m.paragraph_rowid;
CREATE VIRTUAL TABLE passage_fts USING fts5(title,section,text,content='passage_documents',
 content_rowid='id',tokenize='porter unicode61 remove_diacritics 2',detail='none');
INSERT INTO passage_fts(passage_fts) VALUES('rebuild');
INSERT INTO passage_fts(passage_fts) VALUES('optimize');
CREATE TABLE passage_index_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
'''

def digest(path):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()

def pages(path):
    root=None
    for event,el in ET.iterparse(path,events=('start','end')):
        if root is None: root=el; continue
        if event=='end' and el.tag==NS+'page':
            if el.findtext(NS+'ns')=='0' and el.find(NS+'redirect') is None:
                yield {'id':int(el.findtext(NS+'id')),'title':el.findtext(NS+'title'),
                       'revision':el.findtext(NS+'revision/'+NS+'id'),
                       'text':el.findtext(NS+'revision/'+NS+'text') or ''}
            root.clear()

def build(source,dump,output,budget=BODY_BUDGET):
    source=Path(source).resolve(); dump=Path(dump).resolve(); output=Path(output).absolute()
    if output.exists() or output.is_symlink() or output.resolve() in {source,dump}:
        raise ValueError('Output must be a new path, distinct from source and dump.')
    output.parent.mkdir(parents=True,exist_ok=True)
    fd,temp=tempfile.mkstemp(prefix='.corpus-',suffix='.db',dir=output.parent); os.close(fd)
    started=time.monotonic(); counts=Counter(); seen=set()
    try:
        with sqlite3.connect(source.as_uri()+'?mode=ro',uri=True) as src, sqlite3.connect(temp) as db:
            original=dict((i,(title,lead)) for i,title,lead in src.execute('SELECT id,title,lead FROM articles'))
            src.backup(db)
            db.executescript('''
            DROP TABLE IF EXISTS passage_fts;
            DROP VIEW IF EXISTS passage_documents;
            DROP TABLE IF EXISTS passage_map;
            DROP TABLE IF EXISTS passage_index_metadata;
            DELETE FROM paragraphs;
            CREATE TABLE evidence_provenance(article INTEGER,ord INTEGER,kind TEXT,
              revision TEXT,raw_sha256 TEXT,PRIMARY KEY(article,ord));
            ''')
            for page in pages(dump):
                if page['id'] not in original: continue
                title,lead=original[page['id']]
                if page['title']!=title: raise ValueError('Dump and database article identity mismatch: '+title)
                blocks=extract(page['text'],title,lead,budget)
                sourcehash=hashlib.sha256(page['text'].encode()).hexdigest()
                for ordinal,block in enumerate(blocks):
                    db.execute('INSERT INTO paragraphs VALUES(?,?,?,?)',(page['id'],ordinal,block.section,block.text))
                    db.execute('INSERT INTO evidence_provenance VALUES(?,?,?,?,?)',(page['id'],ordinal,block.kind,page['revision'],sourcehash))
                    counts[block.kind]+=1
                counts['body_characters']+=sum(len(b.text) for b in blocks)
                seen.add(page['id']); counts['articles']+=1
                if counts['articles']%10000==0:
                    db.commit(); print(json.dumps({'articles':counts['articles'],'seconds':round(time.monotonic()-started)}),flush=True)
            if seen!=set(original): raise ValueError(f'Dump missing {len(set(original)-seen)} baseline articles; refusing incomplete rebuild')
            db.commit()
            print('Rebuilding FTS5...',flush=True)
            db.executescript(SCHEMA)
            metadata={'schema_version':'1','builder':VERSION,'source_sha256':digest(source),
                      'dump_sha256':digest(dump),'body_budget':str(budget),
                      'passages':str(db.execute('SELECT count(*) FROM passage_map').fetchone()[0])}
            db.executemany('INSERT INTO passage_index_metadata VALUES(?,?)',metadata.items())
            db.execute("INSERT INTO passage_fts(passage_fts,rank) VALUES('integrity-check',1)")
            if db.execute('PRAGMA integrity_check').fetchone()[0]!='ok': raise ValueError('Integrity check failed')
            db.commit(); db.execute('VACUUM')
        os.link(temp,output)
        manifest=dict(metadata,counts=dict(counts),source_bytes=source.stat().st_size,
                      output_bytes=output.stat().st_size,output_sha256=digest(output),
                      seconds=round(time.monotonic()-started,2),
                      note='Same article set and leads; paragraph ordinals identify this corpus version only. No runtime model or gate changes.')
        output.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        return manifest
    finally:
        Path(temp).unlink(missing_ok=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',required=True);p.add_argument('--dump',required=True);p.add_argument('--output',required=True)
    p.add_argument('--body-budget',type=int,default=BODY_BUDGET)
    a=p.parse_args();print(json.dumps(build(a.source,a.dump,a.output,a.body_budget),indent=2))
