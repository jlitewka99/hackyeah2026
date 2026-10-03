# Detector and model provenance

`builtin.v1` contains project-authored candidate patterns, validators and exploit
signatures. No detect-secrets code or regular expressions were copied. Stable
rule IDs, supported formats and safe alternatives are in `detectors.v1.json`;
its SHA-256 is in the adjacent file. Changes require a new catalog version.

The foreign IBAN country lengths and BBAN structures in `iban.v1.json` were
transformed from Arthur de Jong's python-stdnum `stdnum/iban.dat`, whose header
identifies **SWIFT IBAN Registry release 101** as its source. The catalog records
the upstream URL and SHA-256; the adjacent hash pins the transformed bytes.
This is an explicit historical catalog, not a claim to support the latest
registry. The original LGPL-2.1-or-later notice is preserved in
`licenses/PYTHON-STDNUM-COPYING`. Runtime does not fetch the registry.
Primary reference: [SWIFT IBAN Registry](https://www.swift.com/standards/data-standards/iban-international-bank-account-number).

Presidio Analyzer 2.2.362 uses the MIT license, preserved in
`licenses/PRESIDIO-LICENSE`. Stanza 1.11.0 and the pinned Polish model repository
declare Apache-2.0; the upstream Stanza notice is preserved in
`licenses/STANZA-LICENSE`. See the
[Stanza license](https://github.com/stanfordnlp/stanza/blob/v1.11.0/LICENSE) and
[Polish model card](https://huggingface.co/stanfordnlp/stanza-pl).
`sidecar/ner/models.v1.json` records the model repository commit, file sizes,
SHA-256 hashes and download URLs. The Polish model uses NKJP named entities and
PDB tokenization/linguistic processors with the published supporting weights.
Model training data are not bundled.

The model's NKJP labels are mapped as documented by
[Stanza](https://stanfordnlp.github.io/stanza/ner_models.html): `persName` → person,
`placeName` → place, `geogName` → geographical location, `orgName` → organization.
Date and time labels are ignored. The project-authored address recognizer is
separate from these statistical labels.
