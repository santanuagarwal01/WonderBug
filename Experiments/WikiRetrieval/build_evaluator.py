#!/usr/bin/env python3
"""Build the Mac evaluator from current app sources, including exact Swift prompt strings."""
from pathlib import Path
import argparse
import hashlib
import re
import subprocess

def build(output):
    here=Path(__file__).resolve().parent
    services=here.parents[1]/'WonderBug/Services'
    output=Path(output); output.mkdir(parents=True,exist_ok=True)
    source=(services/'QwenAnswerService.swift').read_text()
    blocks=[]
    for name in ['persona','lengthRule','sharedRules','groundedRule','systemPrompt']:
        m=re.search(r'(    private static let '+name+r' =.*?)(?=\n\n|\n    ///|\n    private)',source,re.S)
        if not m: raise ValueError('Prompt moved: '+name)
        blocks.append(m[1].replace('private static','static'))
    prompts=output/'AppPrompts.swift'
    prompts.write_text('enum AppPrompts {\n'+'\n'.join(blocks)+'\n}\n')
    files=[here/'EvaluationMain.swift',prompts]+[services/f for f in
        ['WikiSearchService.swift','WikiRetrievalTrace.swift','WikiPassageReranker.swift','SafetyService.swift','AnswerCleanup.swift','DebugLog.swift']]
    binary=output/'evaluate'
    subprocess.run(['swiftc','-O','-module-cache-path',str(output/'modules'),*[str(f) for f in files],'-o',str(binary)],check=True)
    (output/'source.sha256').write_text(hashlib.sha256(b''.join(f.read_bytes() for f in files)).hexdigest()+'\n')
    print(binary)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('output'); a=p.parse_args();build(a.output)
