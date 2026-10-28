#!/usr/bin/env python3
"""Generate a source from a public GitHub release, including the IPA's actual bundle metadata."""
import argparse, hashlib, io, json, plistlib, struct, urllib.request, zipfile
from pathlib import Path

REPO = 'ivLis-Studio/nearclip'
BASE = 'https://ivlis-studio.github.io/nearclip'
def entitlements(binary):
    # iOS release binaries are arm64 Mach-O. Read their embedded XML code-signature entitlement slot.
    if binary[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('expected an arm64 Mach-O executable')
    count = struct.unpack_from('<I', binary, 16)[0]
    offset = 32
    for _ in range(count):
        command, size = struct.unpack_from('<II', binary, offset)
        assert size >= 8 and offset + size <= len(binary), 'invalid Mach-O load command'
        if command == 0x1d:
            start, length = struct.unpack_from('<II', binary, offset + 8)
            blob = binary[start:start + length]
            magic, _, slots = struct.unpack_from('>III', blob)
            assert magic == 0xfade0cc0, 'invalid signature superblob'
            for index in range(slots):
                kind, at = struct.unpack_from('>II', blob, 12 + index * 8)
                if kind == 5:
                    marker, size = struct.unpack_from('>II', blob, at)
                    assert marker == 0xfade7171, 'invalid entitlement slot'
                    return plistlib.loads(blob[at+8:at+size])
            return {}
        offset += size
    return {}

def generate(release, ipa):
    assert not release.get('draft') and not release.get('prerelease'), 'source requires a stable public release'
    asset = next(a for a in release['assets'] if a['name'] == 'Nearclip-iOS.ipa')
    assert len(ipa) == asset['size'], 'IPA size differs from release asset'
    if asset.get('digest'):
        assert asset['digest'] == 'sha256:' + hashlib.sha256(ipa).hexdigest(), 'IPA digest differs from release asset'
    with zipfile.ZipFile(io.BytesIO(ipa)) as z:
        info = plistlib.loads(z.read('Payload/Nearclip.app/Info.plist'))
        permissions = set()
        privacy = {}
        bundle_infos = ['Payload/Nearclip.app/Info.plist'] + [name for name in z.namelist() if '/PlugIns/' in name and name.endswith('.appex/Info.plist')]
        for name in bundle_infos:
            bundle = plistlib.loads(z.read(name))
            executable = name.rsplit('/',1)[0] + '/' + bundle['CFBundleExecutable']
            permissions.update(entitlements(z.read(executable)))
            for key,value in bundle.items():
                if key.startswith('NS') and key.endswith('UsageDescription'): privacy.setdefault(key,value)
        permissions.difference_update({'application-identifier','com.apple.developer.team-identifier'})
    assert info['CFBundleIdentifier'] == 'studio.ivlis.nearclip', 'wrong app bundle'
    version = info['CFBundleShortVersionString']
    assert release['tag_name'].removeprefix('v') == version, 'release and app version differ'
    url = f'https://github.com/{REPO}/releases/download/{release["tag_name"]}/Nearclip-iOS.ipa'
    return {'name':'Nearclip by ivLis Studio', 'identifier':'studio.ivlis.nearclip.source',
        'sourceURL':BASE+'/altstore.json', 'website':BASE+'/', 'tintColor':'4C5BF5',
        'apps':[{'name':'Nearclip','bundleIdentifier':info['CFBundleIdentifier'],'developerName':'ivLis Studio',
          'localizedDescription':'One clipboard for Mac, Windows, Android, iPhone and iPad. Native apps, direct device-to-device sync and end-to-end encryption.',
          'iconURL':BASE+'/assets/media/icon-512.png','category':'utilities',
          'appPermissions':{'entitlements':sorted(permissions),'privacy':privacy},
          'versions':[{'version':version,'buildVersion':str(info['CFBundleVersion']),
           'date':release['published_at'],'downloadURL':url,'size':len(ipa),
           'sha256':hashlib.sha256(ipa).hexdigest(),'minOSVersion':info.get('MinimumOSVersion','17.0')}]}], 'news':[]}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--release-json');parser.add_argument('--ipa');parser.add_argument('--output', default='website/public/altstore.json');args=parser.parse_args()
    release=json.loads(Path(args.release_json).read_text()) if args.release_json else json.load(urllib.request.urlopen(urllib.request.Request(f'https://api.github.com/repos/{REPO}/releases/latest',headers={'Accept':'application/vnd.github+json','User-Agent':'Nearclip-release'})))
    ipa=Path(args.ipa).read_bytes() if args.ipa else urllib.request.urlopen(next(a['browser_download_url'] for a in release['assets'] if a['name']=='Nearclip-iOS.ipa')).read()
    Path(args.output).write_text(json.dumps(generate(release,ipa),ensure_ascii=False,indent=2)+'\n')
if __name__=='__main__': main()
