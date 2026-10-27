from pathlib import Path
import argparse,json
from huggingface_hub import snapshot_download
MODEL='sentence-transformers/all-MiniLM-L6-v2'
REVISION='1110a243fdf4706b3f48f1d95db1a4f5529b4d41'
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--output',required=True);a=p.parse_args()
 path=snapshot_download(MODEL,revision=REVISION,local_dir=a.output,allow_patterns=['config.json','model.safetensors','tokenizer.json','tokenizer_config.json','special_tokens_map.json','vocab.txt','README.md','modules.json','1_Pooling/config.json','sentence_bert_config.json'])
 print(path)
