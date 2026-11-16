#!/bin/bash
# Lists UI strings in the code that have no translation yet.
# UI text in the code is Russian and doubles as the lookup key; Resources/Localization/<lang>.lproj
# hold the translations (ru.lproj maps every key to itself). `swift test` checks that all tables
# have the same keys; this script checks the tables against the code.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
find Sources -name '*.swift' -exec touch {} +
for product in TinyPrinter tinyprint; do
  swift build --product "$product" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null
done
python3 - "$OUT" <<'PY'
import glob, json, re, subprocess, sys
out = sys.argv[1]
cyr = re.compile('[А-Яа-яЁё]')
code = {}
for f in glob.glob(f'{out}/*.stringsdata'):
    d = json.load(open(f))
    for entries in d.get('tables', {}).values():
        for e in entries:
            if cyr.search(e['key']):
                code.setdefault(e['key'], f"{d['source'].split('/Sources/')[-1]}:{e['location']['startingLine']}")
status = 0
for lang in sorted(p.split('/')[-2][:-6] for p in glob.glob('Resources/Localization/*.lproj/Localizable.strings')):
    path = f'Resources/Localization/{lang}.lproj/Localizable.strings'
    table = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', path]))
    missing = sorted(set(code) - set(table))
    unused = sorted(set(table) - set(code))
    for k in missing: print(f'{lang}: missing  {code[k]}  {k!r}'); status = 1
    for k in unused: print(f'{lang}: unused   {k!r}')
print(f'{len(code)} strings in code' + ('' if status else ', all translated'))
sys.exit(status)
PY
