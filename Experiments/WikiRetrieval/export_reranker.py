"""Build the experiment's offline Core ML reranker; never runs inside the app."""
import argparse
import json
from pathlib import Path
import shutil
import numpy as np
import torch
import coremltools as ct
from coremltools.optimize.coreml import OptimizationConfig, OpLinearQuantizerConfig, linear_quantize_weights
from huggingface_hub import snapshot_download
from transformers import AutoModelForSequenceClassification, AutoTokenizer

MODEL = 'cross-encoder/ms-marco-MiniLM-L6-v2'
# Pin weights and tokenizer together, rather than silently following future model changes.
REVISION = '233902d25c440f23af6f7d6e94d2946bac0bee0a'
LENGTH = 256

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--revision', default=REVISION)
    parser.add_argument('--source', type=Path, help='Locally trained checkpoint; same architecture/tokenizer')
    parser.add_argument('--parity-output', type=Path, help='Separate parity report for adapted checkpoints')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    source = str(args.source) if args.source else snapshot_download(MODEL, revision=args.revision, cache_dir=str(args.cache),
        allow_patterns=['config.json', 'model.safetensors', 'tokenizer.json', 'tokenizer_config.json',
                        'special_tokens_map.json', 'vocab.txt', 'README.md'])
    tokenizer = AutoTokenizer.from_pretrained(source, local_files_only=True)
    base = AutoModelForSequenceClassification.from_pretrained(source, local_files_only=True,
                                                              attn_implementation='eager').eval()
    class Wrapper(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.model = base
        def forward(self, input_ids, attention_mask, token_type_ids):
            return self.model(input_ids=input_ids, attention_mask=attention_mask,
                              token_type_ids=token_type_ids).logits
    def encode(question, passage):
        # Match Swift: reserve at most 48 query tokens; truncate only the passage afterwards.
        q = tokenizer.encode(question, add_special_tokens=False)[:48]
        p = tokenizer.encode(passage, add_special_tokens=False)[:LENGTH-len(q)-3]
        ids = [101] + q + [102] + p + [102]
        types = [0] * (len(q)+2) + [1] * (len(p)+1)
        mask = [1] * len(ids)
        padding = LENGTH-len(ids)
        return {k: np.array([v+[0]*padding], dtype=np.int32) for k,v in
                [('input_ids',ids),('attention_mask',mask),('token_type_ids',types)]}
    example = encode('What do koalas eat?', 'Koalas eat eucalyptus leaves.')
    inputs = tuple(torch.from_numpy(example[k]).long() for k in example)
    with torch.no_grad():
        traced = torch.jit.trace(Wrapper().eval(), inputs)
    model = ct.convert(traced, convert_to='mlprogram', minimum_deployment_target=ct.target.iOS17,
        inputs=[ct.TensorType(name=k, shape=(1,LENGTH), dtype=np.int32) for k in example],
        outputs=[ct.TensorType(name='score', dtype=np.float32)], compute_precision=ct.precision.FLOAT16)
    model = linear_quantize_weights(model, config=OptimizationConfig(
        global_config=OpLinearQuantizerConfig(mode='linear_symmetric', dtype='int8', granularity='per_channel')))
    model.author = 'Sentence Transformers; Core ML conversion for WonderBug'
    model.license = 'Apache-2.0'
    model.short_description = 'MiniLM passage reranker; raw relevance logit, not answer confidence.'
    model.user_defined_metadata.update({'source':MODEL, 'revision':args.revision, 'sequence_length':str(LENGTH)})
    if args.source:
        import hashlib
        model.user_defined_metadata['adapted_weights_sha256'] = hashlib.sha256((args.source/'model.safetensors').read_bytes()).hexdigest()
    model.save(str(args.output/'WikiMiniLM.mlpackage'))
    if (Path(source)/'vocab.txt').exists():
        shutil.copyfile(Path(source)/'vocab.txt', args.output/'wiki-minilm-vocab.txt')
    else:
        vocabulary = tokenizer.get_vocab()
        (args.output/'wiki-minilm-vocab.txt').write_text(''.join(token+'\n' for token, index in sorted(vocabulary.items(), key=lambda x:x[1])))
    samples = [
        ('What do koalas eat?', 'Koalas eat eucalyptus leaves.'),
        ('What do koalas eat?', 'Koalas have grey fur and live in Australia.'),
        ('Why do giraffes have long necks?', 'Giraffes can reach leaves on tall trees with their long necks.'),
        ('Why do we get goosebumps?', 'Goosebumps is a series of horror books.'),
        ('Why do we get goosebumps?', 'Tiny muscles tighten and pull hairs upright when people feel cold.'),
        ('Café cats—why?', 'The cat’s fur is soft. 水'),
        ('What is ' + 'very '*90 + 'long?', 'Padding and truncation example.'),
    ]
    fixtures = []
    for question, passage in samples:
        values = encode(question, passage)
        with torch.no_grad():
            reference = float(base(**{k:torch.from_numpy(v).long() for k,v in values.items()}).logits.item())
        actual = float(model.predict(values)['score'].reshape(-1)[0])
        fixtures.append({'question':question,'passage':passage,'inputs':{k:v[0].tolist() for k,v in values.items()},
                         'reference_score':reference,'coreml_score':actual})
        print(f'{question[:65]} | PyTorch={reference:.4f} CoreML={actual:.4f}', flush=True)
        if abs(reference-actual) > 0.75:
            raise RuntimeError('Quantized conversion differs too much from the source model')
    (args.parity_output or Path(__file__).parent/'tokenizer-parity.json').write_text(json.dumps(fixtures, indent=2)+'\n')
    print('Wrote', args.output, flush=True)

if __name__ == '__main__':
    main()
