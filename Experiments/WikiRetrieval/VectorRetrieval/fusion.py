"""Rank fusion with a fixed reranker budget; no topic-specific rules."""
RRF_K=60
LIMIT=20

def unique(values):return list(dict.fromkeys(values))

def rank_fusion(rankings,available,k=RRF_K):
 if k<=0:raise ValueError('RRF constant must be positive')
 scores={}
 for ranking in rankings:
  for rank,source_id in enumerate(unique(ranking),1):
   if source_id in available:scores[source_id]=scores.get(source_id,0)+1/(k+rank)
 return sorted(scores,key=lambda s:(-scores[s],s)),scores

def shortlist(article,body,dense,available,limit=LIMIT):
 if not 1<=limit<=LIMIT:raise ValueError('Reranker budget must be 1..20')
 lexical,_=rank_fusion([article,body],available)
 # Lexical and semantic retrieval each get one vote, even though lexical has two routes.
 ordered,scores=rank_fusion([lexical,dense] if dense is not None else [lexical],available)
 selected=[];seen_text=set()
 for source_id in ordered:
  # Deduplicate final text within each arm, after ranking. Keep source preparation
  # independent so a different arm's identical source cannot erase this one's vote.
  text_key=' '.join(available[source_id]['text'].split()).casefold() if isinstance(available,dict) else source_id
  if text_key in seen_text:continue
  seen_text.add(text_key);selected.append(source_id)
  if len(selected)==limit:break
 return selected,{s:scores[s]for s in selected},lexical
