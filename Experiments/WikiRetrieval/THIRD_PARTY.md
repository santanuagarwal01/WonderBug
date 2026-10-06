# MiniLM reranker

Source: https://huggingface.co/cross-encoder/ms-marco-MiniLM-L6-v2
Revision: 233902d25c440f23af6f7d6e94d2946bac0bee0a
License declared by the publisher: Apache-2.0.

The experiment converts the published model to Core ML and compresses its weights to
8-bit integers. The vocabulary is copied unchanged. Model weights remain a generated,
git-ignored asset; the reproducible conversion script and tokenizer parity fixtures are
tracked. The source model and tokenizer were developed by the Sentence Transformers
contributors. No training or fine-tuning was performed for this branch.

See Apache-2.0.txt for the license. Retain this notice with redistributed assets.
