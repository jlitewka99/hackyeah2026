# Tokenizer provenance

DeepSeek V4.1 tokenizer from the official deepseek-ai/deepseek-recipe repository,
commit 8cadfede7063c896b944e7bae05daa3549ae97ea. The manifest pins its size and
SHA-256. No inference weights are downloaded. deepseek-recipe 0.1.1 is MIT licensed.
See LICENSE for recipe code and TOKENIZER_LICENSE for the bundled tokenizer.
Source: https://github.com/deepseek-ai/deepseek-recipe/blob/8cadfede7063c896b944e7bae05daa3549ae97ea/static/tokenizers/README.md
for upstream tokenizer notices. Recipe encoding is v41. Model availability from
DeepSeek's /models does not verify weights or guarantee tokenizer equivalence;
real API prompt_tokens comparisons remain a required acceptance check.

The optional Granite guard uses its own IBM Granite Guardian 4.1 8B tokenizer,
revision ab01ccca5dcfb80246369a086a4a87a29198f5af, under Apache-2.0.
granite.v1.json pins its file size and SHA-256. It is loaded with the separately
locked Hugging Face tokenizers package, not the DeepSeek recipe encoder.
See GRANITE_TOKENIZER_LICENSE for the Apache-2.0 license text.
Granite's local model digest is used only for guard verification; it does not
describe or verify the weights behind the DeepSeek API identifier.
