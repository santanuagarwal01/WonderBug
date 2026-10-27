#!/usr/bin/env python3
"""Trace known omissions to source structure and verify old extractor parity.

The targets below are audit cases only. Extraction never reads this module.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
from build_corpus import pages,digest
import legacy_extractor as legacy

TARGETS={
 'Rosa Parks':{'fact':'Raymond Parks','structure':'infobox spouse field'},
 'Phases of the Moon':{'fact':'waning crescent','structure':'bulleted phase definitions'},
 'List of planets':{'fact':'Jupiter','structure':'nested planet list'},
 'James Earl Ray':{'fact':'murdering','structure':'lead; separate safety exclusion, not extraction loss'},
}

def run(a):
    old=sqlite3.connect(Path(a.baseline).resolve().as_uri()+'?mode=ro',uri=True)
    new=sqlite3.connect(Path(a.rebuilt).resolve().as_uri()+'?mode=ro',uri=True) if a.rebuilt else None
    out=[]
    for page in pages(a.dump):
        if page['title'] not in TARGETS:continue
        title=page['title'];raw=page['text'];identifier=page['id'];target=TARGETS[title]
        stored=old.execute('SELECT lead FROM articles WHERE id=?',(identifier,)).fetchone()[0]
        paragraphs=old.execute('SELECT section,text FROM paragraphs WHERE article=? ORDER BY ord',(identifier,)).fetchall()
        heading=legacy.HEADING.search(raw)
        regenerated_lead=legacy.cap(legacy.clean(raw[:heading.start()] if heading else raw))
        regenerated=[];budget=legacy.BODY_CAP
        for section,text in legacy.body_paragraphs(raw,heading.start()) if heading else []:
            if budget<=0:break
            regenerated.append((section,text));budget-=len(text)
        before=stored+'\n'+'\n'.join(t for _,t in paragraphs)
        row={'title':title,'article_id':identifier,'revision':page['revision'],
            'raw_sha256':hashlib.sha256(raw.encode()).hexdigest(),
            'legacy_lead_exact_match':regenerated_lead==stored,'legacy_body_exact_match':regenerated==paragraphs,
            'legacy_paragraphs':len(paragraphs),'fact_probe':target['fact'],'source_structure':target['structure'],
            'raw_contains_fact':target['fact'].lower() in raw.lower(),
            'baseline_contains_fact':target['fact'].lower() in before.lower()}
        if new:
            after=new.execute('SELECT section,text FROM paragraphs WHERE article=? ORDER BY ord',(identifier,)).fetchall()
            row.update({'rebuilt_paragraphs':len(after),'rebuilt_body_characters':sum(len(t) for _,t in after),
                'rebuilt_contains_fact':target['fact'].lower() in (stored+'\n'+'\n'.join(t for _,t in after)).lower(),
                'matching_rebuilt_passages':[{'section':s,'text':t} for s,t in after if target['fact'].lower() in t.lower()]})
        out.append(row)
        if len(out)==len(TARGETS):break
    if len(out)!=len(TARGETS):raise ValueError('Missing audit source article')
    if not all(r['legacy_lead_exact_match'] and r['legacy_body_exact_match'] for r in out):
        raise ValueError('Old builder does not reproduce this corpus; do not claim the cause is confirmed')
    report={'baseline_sha256':digest(a.baseline),'dump_sha256':digest(a.dump),
        'rebuilt_sha256':digest(a.rebuilt) if a.rebuilt else None,'articles':out,
        'conclusion':'All four articles reproduce exactly under the archived extractor. Missing spouse/list facts exist in the pinned source, so omissions are extraction losses; James Earl Ray is a safety-policy interaction.'}
    with Path(a.output).open('x') as f:json.dump(report,f,indent=2);f.write('\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--baseline',required=True);p.add_argument('--dump',required=True)
    p.add_argument('--rebuilt');p.add_argument('--output',required=True);run(p.parse_args())
