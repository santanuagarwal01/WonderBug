#!/usr/bin/env python3
import argparse
import hashlib
from pathlib import Path
import subprocess

def build(repo,output):
    repo=Path(repo);here=Path(__file__).resolve().parent;output=Path(output)
    output.mkdir(parents=True,exist_ok=True)
    files=[here/'ConversationMain.swift']+[repo/'WonderBug/Services'/f for f in
      ['WikiSearchService.swift','WikiRetrievalTrace.swift','WikiPassageReranker.swift','SafetyService.swift','DebugLog.swift']]
    binary=output/'conversation-eval'
    subprocess.run(['swiftc','-O','-module-cache-path',str(output/'modules'),*[str(f) for f in files],'-o',str(binary)],check=True)
    (output/'source.sha256').write_text(hashlib.sha256(b''.join(f.read_bytes() for f in files)).hexdigest()+'\n')
    print(binary)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--repo',required=True);p.add_argument('--output',required=True)
    a=p.parse_args();build(a.repo,a.output)
