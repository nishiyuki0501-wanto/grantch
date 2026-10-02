"""Check that every Japanese UI string has an English translation with matching format specifiers."""
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[2]


def read_strings(path):
    output = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)], check=True, capture_output=True)
    return json.loads(output.stdout)


def swift_unescape(literal):
    return re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), literal)


app = (root / 'Sources/GrantchApp/GrantchApp.swift').read_text()
risk = (root / 'Sources/GrantchCore/RiskAnalyzer.swift').read_text()
keys = {swift_unescape(k) for k in re.findall(r'\bL\("((?:[^"\\]|\\.)*)"', app)}
keys |= set(re.findall(r'\("([^"]+)", [\d *]+\)', app))           # auto-approval durations
keys |= set(re.findall(r'flag\(\d, "([^"]+)"\)', risk))             # risk reasons
keys |= set(re.findall(r'\["([^"]+)"\] : reasons', risk))           # default reason

english = read_strings(root / 'Localization/en.lproj/Localizable.strings')
specifier = re.compile(r'%(?:\d+\$)?(?:ld|lld|d|@)')
problems = []
for key in sorted(keys):
    if key not in english:
        problems.append(f'missing English: {key!r}')
    elif sorted(specifier.findall(key)) != sorted(specifier.findall(english[key])):
        problems.append(f'format mismatch: {key!r} -> {english[key]!r}')
for key in sorted(set(english) - keys):
    problems.append(f'unused English entry: {key!r}')

for language in ['ja', 'en']:
    names = read_strings(root / f'Localization/{language}.lproj/InfoPlist.strings')
    if not names.get('CFBundleName') or not names.get('CFBundleDisplayName'):
        problems.append(f'{language}: InfoPlist.strings needs CFBundleName and CFBundleDisplayName')

assert not problems, '\n'.join(problems)
print(f'PASS: {len(keys)} UI strings have English translations with matching format specifiers')
