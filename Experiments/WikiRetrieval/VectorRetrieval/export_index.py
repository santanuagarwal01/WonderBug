#!/usr/bin/env python3
"""Export one index representation without copying corpus text into the vector database."""
import argparse,json,os,tempfile
from pathlib import Path
from build_index import connect
from embedding import digest

def export(source,output,kind):
 source=Path(source).resolve();output=Path(output).absolute()
 if kind not in {'binary','float'}:raise ValueError('Unknown representation')
 if output.exists()or output.is_symlink()or output.resolve()==source:raise ValueError('New output required')
 output.parent.mkdir(parents=True,exist_ok=True)
 fd,name=tempfile.mkstemp(dir=output.parent,prefix='.vector-export-',suffix='.db');os.close(fd)
 try:
  with connect(source,True)as src,connect(name)as dst:
   if src.execute("select value from metadata where key='complete'").fetchone()[0]!='true':raise ValueError('Incomplete source')
   src.backup(dst)
   other='float' if kind=='binary' else 'binary'
   dst.execute('drop table vectors_'+other)
   dst.execute("insert into metadata values('representation',?)",(kind,));dst.commit();dst.execute('vacuum')
   count=dst.execute('select count(*)from vectors_'+kind).fetchone()[0]
   assert count==src.execute('select count(*)from vectors_'+kind).fetchone()[0]
   # Verify all vector bytes and IDs survived the export, not just counts.
   left=src.execute('select rowid,embedding from vectors_'+kind+' order by rowid')
   right=dst.execute('select rowid,embedding from vectors_'+kind+' order by rowid')
   for a,b in zip(left,right):
    if a!=b:raise ValueError('Vector content changed')
   assert dst.execute('pragma integrity_check').fetchone()[0]=='ok'
  os.link(name,output)
  report={'representation':kind,'vectors_verified':count,'source_sha256':digest(source),'output_sha256':digest(output),'output_bytes':output.stat().st_size}
  output.with_suffix('.manifest.json').write_text(json.dumps(report,indent=2)+'\n');return report
 finally:Path(name).unlink(missing_ok=True)

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('source');p.add_argument('output');p.add_argument('--kind',choices=['float','binary'],required=True);a=p.parse_args();print(json.dumps(export(a.source,a.output,a.kind),indent=2))
