#!/usr/bin/env python3
"""Validate shipped localization tables without launching the app."""
import collections
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LOCALES = ('en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'de', 'sv', 'ar-EG', 'tr', 'id', 'fr')
TABLES = ('Localizable', 'InfoPlist', 'AppShortcuts')
FORMAT = re.compile(r'%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztL])?[@diuoxXfFeEgGaAcCsSp%]')
URL = re.compile(r'https?://[A-Za-z0-9][^\s)\]"<>]*')

def read(locale, table):
    path = ROOT / 'PalmiAgent' / f'{locale}.lproj' / f'{table}.strings'
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))

def validate():
    failures = []
    for table in TABLES:
        source = read('en', table)
        for locale in LOCALES:
            try:
                target = read(locale, table)
            except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
                failures.append(f'{locale}/{table}: cannot parse table: {error}')
                continue
            for key in source.keys() - target.keys():
                failures.append(f'{locale}/{table}: missing {key}')
            if locale in ('de', 'sv', 'ar-EG', 'tr', 'id', 'fr'):
                for key in target.keys() - source.keys():
                    failures.append(f'{locale}/{table}: unexpected {key}')
            for key in source.keys() & target.keys():
                left, right = source[key], target[key]
                if not right.strip():
                    failures.append(f'{locale}/{table}/{key}: empty translation')
                if FORMAT.findall(left) != FORMAT.findall(right):
                    failures.append(f'{locale}/{table}/{key}: format placeholders differ')
                # Existing locales have their own report/policy links. New translations must preserve links.
                if locale in ('de', 'sv', 'ar-EG', 'tr', 'id', 'fr'):
                    if collections.Counter(URL.findall(left)) != collections.Counter(URL.findall(right)):
                        failures.append(f'{locale}/{table}/{key}: URLs differ')
                if left.count('${applicationName}') != right.count('${applicationName}'):
                    failures.append(f'{locale}/{table}/{key}: application-name token differs')
    if failures:
        print('\n'.join(failures))
        raise SystemExit(f'{len(failures)} localization errors')
    print(f'Validated {len(LOCALES)} languages × {len(TABLES)} tables: keys, formats, tokens and new-locale URLs match.')

if __name__ == '__main__':
    validate()
