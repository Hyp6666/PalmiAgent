#!/usr/bin/env python3
"""Render the policy sources as single-column, paper-style PDFs.

Usage: python3 scripts/generate-localized-policies.py [Document.locale ...]
  e.g. python3 scripts/generate-localized-policies.py PalmiUserNotice.de PalmiAIDataNotice.ja
Without arguments every source in scripts/policy-sources is rendered.
Requires a local Chrome installation; makes no network requests.

Typesetting: A4, 2.54 cm top/bottom and 3.17 cm left/right margins; title 18 pt bold, first-level
headings 14 pt bold, second-level headings 12 pt bold, body 12 pt with 1.5 line spacing, page
numbers 10.5 pt centred in the footer. Chinese uses Songti, Latin script uses Times New Roman.
"""
import html
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'scripts' / 'policy-sources'
POLICIES = ROOT / 'PalmiAgent' / 'Resources' / 'Policies'
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

# Times New Roman 覆盖拉丁、土耳其与阿拉伯字母；中日韩文字回落到对应的衬线字体。
FONTS = {
    'zh-Hans': "'Times New Roman', 'Songti SC'",
    'zh-Hant': "'Times New Roman', 'Songti TC'",
    'ja': "'Times New Roman', 'Hiragino Mincho ProN'",
    'ko': "'Times New Roman', 'AppleMyungjo'",
}
CJK = ('zh-Hans', 'zh-Hant', 'ja', 'ko')


def inline(text, cjk=False):
    text = html.escape(text)
    # 论文格式不使用加粗强调，只保留文字。
    text = re.sub(r'\*\*(.+?)\*\*', r'\1', text)
    colon = '：' if cjk else ': '
    text = re.sub(r'\[([^\]]+)\]\((https?://[^\s)]+)\)', rf'\1{colon}<a href="\2">\2</a>', text)
    parts = re.split(r'(<a\b[^>]*>.*?</a>)', text)
    return ''.join(part if part.startswith('<a ') else re.sub(
        r'https?://[^\s<]+', lambda match: f'<a href="{match[0]}">{match[0]}</a>', part
    ) for part in parts)


def document(source, locale):
    cjk = locale in CJK
    blocks = []
    section, subsection = '', 0
    for block in re.split(r'\n\s*\n', source.strip()):
        lines = block.splitlines()
        heading = re.fullmatch(r'(#{1,3})\s+(.+)', block)
        if heading:
            level, title = len(heading[1]), heading[2]
            if level == 2:
                section = re.match(r'(\d+)\.', title)[1] if re.match(r'\d+\.', title) else section
                subsection = 0
                title = re.sub(r'^(\d+)\.\s*', r'\1 ', title)
            elif level == 3:
                subsection += 1
                title = f'{section}.{subsection} {title}'
            blocks.append(f'<h{level}>{inline(title)}</h{level}>')
        elif all(re.match(r'^\d+\.\s', line) for line in lines):
            for line in lines:
                number, text = re.match(r'^(\d+)\.\s+(.*)$', line).groups()
                label = f'（{number}）' if cjk else f'({number})'
                blocks.append(f'<p class="item"><span class="n">{label}</span>{inline(text)}</p>')
        elif all(re.match(r'^[-*]\s', line) for line in lines):
            blocks.extend(f'<p class="link">{inline(line[2:], cjk and locale != "ko")}</p>' for line in lines)
        elif blocks and blocks[-1].startswith('<h1>') and re.search(r'\bv\d+\.\d+\b', block):
            # 标题下的版本行：与正文同字号，居中，不缩进。
            blocks.append(f'<p class="meta">{inline(block)}</p>')
        else:
            blocks.append('<p>' + ' '.join(inline(line) for line in lines) + '</p>')
    direction = 'rtl' if locale == 'ar-EG' else 'ltr'
    family = FONTS.get(locale, "'Times New Roman'")
    indent = '2em' if cjk else '0.5in'
    return f'''<!doctype html>
<html lang="{locale}" dir="{direction}"><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<style>
@page {{
  size: A4; margin: 2.54cm 3.17cm;
  @bottom-center {{ content: counter(page); font-family: {family}; font-size: 10.5pt; color: #000; }}
}}
html {{ font-family: {family}; font-size: 12pt; line-height: 1.5; color: #000; }}
body {{ margin: 0; hyphens: {'manual' if cjk else 'auto'}; word-break: {'keep-all' if locale == 'ko' else 'normal'}; }}
h1 {{ font-size: 18pt; font-weight: bold; text-align: center; line-height: 1.4; margin: 0 0 6pt; }}
p.meta {{ text-align: center; text-indent: 0; margin: 0 0 18pt; }}
h2 {{ font-size: 14pt; font-weight: bold; margin: 18pt 0 6pt; break-after: avoid; }}
h3 {{ font-size: 12pt; font-weight: bold; margin: 12pt 0 4pt; break-after: avoid; }}
p {{ margin: 0 0 6pt; text-align: justify; text-indent: {indent}; orphans: 2; widows: 2; }}
p.item {{ text-indent: 0; padding-inline-start: 2.5em; position: relative; }}
p.item .n {{ position: absolute; inset-inline-start: 0; }}
p.link {{ text-indent: 0; text-align: start; padding-inline-start: {indent}; }}
a {{ color: inherit; text-decoration: none; overflow-wrap: anywhere; unicode-bidi: isolate; direction: ltr; }}
</style></head><body>{''.join(blocks)}</body></html>'''


def render(name):
    locale = name.split('.', 1)[1]
    source = SOURCES / f'{name}.md'
    output = POLICIES / f'{name}.pdf'
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
    print(f'{name}: {output.stat().st_size:,} bytes')


if __name__ == '__main__':
    available = sorted(path.stem for path in SOURCES.glob('*.md'))
    for name in sys.argv[1:] or available:
        if name not in available:
            raise SystemExit(f'Unknown policy source: {name}')
        render(name)
