#!/usr/bin/env python3
"""Render the translated policy sources with browser shaping for Arabic/RTL.

Usage: python3 scripts/generate-localized-policies.py [locale ...]
Requires a local Chrome installation; makes no network requests.
"""
import html
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
POLICIES = ROOT / 'PalmiAgent' / 'Resources' / 'Policies'
LOCALES = ('de', 'sv', 'ar-EG', 'tr', 'id', 'fr')
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'


def inline(text):
    text = html.escape(text)
    text = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', text)
    text = re.sub(r'\[([^\]]+)\]\((https?://[^\s)]+)\)', r'<a href="\2">\1</a>', text)
    # Some translators use Markdown links, others keep readable bare policy URLs.
    parts = re.split(r'(<a\b[^>]*>.*?</a>)', text)
    return ''.join(part if part.startswith('<a ') else re.sub(
        r'https?://[^\s<]+', lambda match: f'<a dir="ltr" href="{match[0]}">{match[0]}</a>', part
    ) for part in parts)


def document(source, locale):
    blocks = []
    for block in re.split(r'\n\s*\n', source.strip()):
        lines = block.splitlines()
        heading = re.fullmatch(r'(#{1,3})\s+(.+)', block)
        if heading:
            level = len(heading[1])
            element_id = 'providers' if level == 2 and heading[2].startswith('9.') else ''
            blocks.append(f'<h{level} id="{element_id}">{inline(heading[2])}</h{level}>')
        elif all(re.match(r'^[-*]\s', line) for line in lines):
            blocks.append('<ul>' + ''.join(f'<li>{inline(line[2:])}</li>' for line in lines) + '</ul>')
        else:
            blocks.append('<p>' + '<br>'.join(inline(line) for line in lines) + '</p>')
    direction = 'rtl' if locale == 'ar-EG' else 'ltr'
    return f'''<!doctype html>
<html lang="{locale}" dir="{direction}"><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<style>
@page {{ size: A4; margin: 18mm 18mm 20mm; }}
body {{ color: #18212b; font-family: Arial, 'Geeza Pro', sans-serif; font-size: 10.5pt; line-height: 1.55; }}
h1 {{ font-size: 22pt; line-height: 1.25; margin: 0 0 16pt; }}
h2 {{ font-size: 15pt; margin-top: 22pt; break-after: avoid; }}
h3 {{ font-size: 11.5pt; margin-top: 17pt; break-after: avoid; }}
p {{ margin: 0 0 9pt; orphans: 3; widows: 3; }}
a {{ color: #1b4d80; overflow-wrap: anywhere; unicode-bidi: isolate; }}
li {{ margin-bottom: 7pt; }}
</style></head><body>{''.join(blocks)}</body></html>'''


def render(locale):
    source = ROOT / 'scripts' / 'policy-sources' / f'PalmiUserNotice.{locale}.md'
    output = POLICIES / f'PalmiUserNotice.{locale}.pdf'
    with tempfile.TemporaryDirectory(prefix='palmi-policy-') as temporary:
        directory = Path(temporary)
        page = directory / 'policy.html'
        page.write_text(document(source.read_text(), locale))
        subprocess.run([
            CHROME, '--headless', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
            '--disable-background-networking', '--disable-extensions', '--disable-sync',
            f'--user-data-dir={directory / "profile"}', '--no-pdf-header-footer',
            f'--print-to-pdf={output}', page.as_uri()
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=60)
    if not output.exists() or output.stat().st_size < 10_000:
        raise RuntimeError(f'PDF was not generated: {output}')
    print(f'{locale}: {output.stat().st_size:,} bytes')


if __name__ == '__main__':
    for locale in sys.argv[1:] or LOCALES:
        if locale not in LOCALES:
            raise SystemExit(f'Unsupported policy locale: {locale}')
        render(locale)
