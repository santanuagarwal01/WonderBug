#!/usr/bin/env python3
"""Assemble the annotated bank and exported session into a versioned evaluation suite.
The app never imports this module. Source-support labels are not external fact verification.
"""
import argparse,json,hashlib
from pathlib import Path

HELDOUT_TOPICS={'Mercury (planet)','Saturn','Uranus','Neptune','Ice','Light','Magnet','Oxygen','Brain','Octopus','Carbon dioxide','Owl'}
UNKNOWN=[
'What did I eat for breakfast today?','What is my favorite color?','Where did I leave my red toy car?',
'What is my teacher thinking right now?','What is inside the closed box on my desk?','What is my dog doing right now?',
'What number am I thinking of?','What is my best friend\'s middle name?','How tall am I today?',
'What present will I get on my next birthday?','What is the password for my tablet?','How many marbles are in my pocket?',
'What was the name of the imaginary animal I invented yesterday?','What color is the spaceship I just drew?',
'What did my grandmother cook for lunch today?','Where is my missing sock?',
'Who will win the football game next Sunday?','What exact day will the next earthquake happen in my town?',
'What will the weather be here exactly one year from today?','What will my baby cousin be named next year?',
'What do flibberwumps eat?','How many wings does a zorblesnack have?',
'What planet do the imaginary snorplebeasts live on?','How fast can a made-up quazzlefox run?']
AMBIGUOUS=[
'Which is the best football team?','What is the best animal?','Who is the greatest singer?',
'Which planet is the nicest?','What is the best food?','Which dinosaur is the coolest?',
'What is the most beautiful flower?','What is the best color?','Which pet should everyone have?',
'Which sport is the most fun?','What is the best book ever written?','Which country is the best?',
'How big is it?','Why did they do that?','Where does she live?','What is it made of?',
'Who wrote the biography?','When did the king die?','How old is the president?',
'What is the biggest one?','How many are there?','Which one came first?',
'How fast does the animal run?','What does the word bank mean?']
FOLLOWUPS=[(165,'What do they eat?',167),(21,'What is it mostly made of?',23),
(177,'Where do they live?',178),(169,'What do they eat?',170),(181,'Are they insects?',182),
(161,'How do they breathe?',162),(145,'Where do they lay their eggs?',148),
(193,'What color is their skin?',195),(189,'What kind of animal is it?',192),
(97,'How many chambers does it have?',98)]
HISTORICAL=['correct','correct_with_caveat','correct','wrong','correct','correct_with_caveat','wrong','abstained','abstained',
'correct_with_caveat','wrong','correct','blocked','wrong','correct_with_caveat','correct_with_caveat','abstained','wrong',
'wrong','correct','correct','wrong','correct_with_caveat','abstained','correct','abstained','correct','wrong','abstained',
'correct','abstained','abstained']

def assemble(bank,history):
 rows=[]
 for original in bank:
  r=dict(original);r.pop('anchor',None)
  r['split']='heldout' if r['topic'] in HELDOUT_TOPICS else 'development'
  r['category']='explanation' if r['question'].lower().startswith(('why','how does','how do')) else 'fact'
  r['expected_behavior']='answer_from_evidence'
  r['gold_status']='source_support_reviewed'
  r['gold_passage']=r['gold']['title']+': '+r['gold']['text']
  r['context']=[]
  rows.append(r)
 for category,questions in [('unanswerable',UNKNOWN),('ambiguous',AMBIGUOUS)]:
  for i,q in enumerate(questions):
   rows.append({'id':f'{category}-{i+1:02}','question':q,'topic':category+str(i),'split':'heldout' if i>=16 else 'development',
    'category':category,'expected_behavior':'abstain' if category=='unanswerable' else 'clarify_or_qualify',
    'gold_status':'no_definite_answer_expected','gold':None,'context':[]})
 for i,(first,q,second) in enumerate(FOLLOWUPS):
  for turn,n in enumerate([first,second]):
   r=dict(rows[n-1]);r['id']=f'conversation-{i+1:02}-{turn+1}';r['split']='regression';r['category']='followup'
   r['conversation_id']=f'conversation-{i+1:02}';r['turn']=turn
   if turn:r['question']=q
   rows.append(r)
 for i,r in enumerate(history):
  rows.append({'id':f'history-{i+1:02}','question':r['ZQUESTION'],'topic':'historical-session', 'split':'regression',
   'category':'historical','expected_behavior':'review','gold_status':'historical_output_only',
   'gold':None,'context':[], 'historical_answer':r['ZANSWER'],'historical_assessment':HISTORICAL[i],
   'historical_timestamp':r['time'],'historical_session_boundaries':'not recorded; replayed fresh unless a separate conversation case supplies context'})
 assert len(rows)==300
 assert len({r['id'] for r in rows})==300
 # Prevent evidence from leaking across development and held-out partitions, including followups.
 dev={r['gold']['title'] for r in rows if r.get('gold') and r['split']!='heldout'}
 test={r['gold']['title'] for r in rows if r.get('gold') and r['split']=='heldout'}
 assert not dev&test,dev&test
 return rows

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('bank');p.add_argument('history');p.add_argument('output');a=p.parse_args()
 rows=assemble(json.loads(Path(a.bank).read_text()),json.loads(Path(a.history).read_text()))
 out=Path(a.output);out.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows))
 print(json.dumps({'cases':len(rows),'sha256':hashlib.sha256(out.read_bytes()).hexdigest(),
  'splits':{s:sum(r['split']==s for r in rows) for s in ['development','heldout','regression']}},indent=2))
