"""Join local acceptance, actual upload bytes and reloaded Connect evidence."""
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path


root = Path(__file__).resolve().parents[1]
read = lambda path: json.loads(path.read_text())
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
manifest_path = root / 'config/manifest.json'
manifest = read(manifest_path)
out = (manifest_path.parent / manifest['outputRoot']).resolve()
proofs = root / 'proofs'
slots = ['01-play', '02-results', '03-browser', '04-files', '05-models',
         '06-sources', '07-python', '08-skills', '09-palmi']
files = [s + '.png' for s in slots]
devices, locales = ['DI', 'Duo', 'iPad'], ['en-US', 'zh-Hans']
required = {(d, l, s) for d in devices for l in locales for s in slots}
recorded = [(e['device'], e['locale'], e['id']) for e in manifest['entries']]
assert len(recorded) == len(required) and set(recorded) == required, 'Incomplete manifest'
copy = read(root / 'metadata/store-copy.json')
receipt = {'appVersion': root.name.removesuffix('-production'), 'manifestFormat': manifest['version'],
           'checkedAt': datetime.now(timezone.utc).isoformat(),
           'placements': [], 'localizedFields': {}, 'totalScreenshots': len(required),
           'manifestSha256': sha(manifest_path), 'submitted': False}
for loc in locales:
    saved = read(proofs / f'{loc}-fields-final.json')['check']
    assert set(saved) == {'promotionalText', 'description', 'whatsNew'}
    for field, check in saved.items():
        value = (root / 'metadata' / f'{loc}-{field}.txt').read_text().rstrip('\n')
        assert value == copy[loc][field] and check['exact'] and check['length'] == len(value)
    receipt['localizedFields'][loc] = saved
    for device in devices:
        reviewed = read(proofs / f'{device}--{loc}-acceptance.json')
        reloaded = read(proofs / f'{loc}-{device}-assets-reloaded.json')
        final = read(proofs / f'{loc}-{device}-assets-final.json')
        assert reviewed['status'] == 'accepted' and not reviewed['requiredRetakes']
        for verification in (reloaded, final):
            assert verification['files'] == files and verification['count'] == len(files)
            assert verification['device'] == device and verification['locale'] == loc
        assert sorted(p.name for p in (out / device / loc).glob('*.png')) == files
        checked_files = []
        for slot in slots:
            provenance = read(root / 'provenance' / device / loc / f'{slot}.json')
            digest = sha(out / device / loc / f'{slot}.png')
            assert digest == provenance['outputSha256'], f'Output changed: {device}/{loc}/{slot}'
            checked_files.append({'file': f'{slot}.png', 'sha256': digest})
        receipt['placements'].append({'device': device, 'locale': loc, 'count': len(files),
            'deviceTab': final['deviceTab'], 'observedAfterReload': reloaded['observedAt'],
            'finalCheck': final['observedAt'], 'files': checked_files})
(proofs / 'release-receipt.json').write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + '\n')
print('Verified 54 PNG placements in six groups and six exact localized field values.')
