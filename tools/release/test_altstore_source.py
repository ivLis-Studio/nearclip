import hashlib, io, plistlib, struct, unittest, zipfile
from altstore_source import generate, entitlements


def executable(permissions):
    xml=plistlib.dumps(permissions)
    entry=struct.pack('>II',0xfade7171,len(xml)+8)+xml
    blob=struct.pack('>III',0xfade0cc0,20+len(entry),1)+struct.pack('>II',5,20)+entry
    header=struct.pack('<IIIIIIII',0xfeedfacf,0x100000c,0,2,1,16,0,0)
    return header+struct.pack('<IIII',0x1d,16,48,len(blob))+blob


def fixture(version='1.2.0',extension=True):
    info={'CFBundleExecutable':'Nearclip','CFBundleIdentifier':'studio.ivlis.nearclip','CFBundleShortVersionString':version,
          'CFBundleVersion':'3','MinimumOSVersion':'17.0','NSCameraUsageDescription':'Scan a QR code.'}
    stream=io.BytesIO()
    with zipfile.ZipFile(stream,'w') as z:
        z.writestr('Payload/Nearclip.app/Info.plist',plistlib.dumps(info))
        z.writestr('Payload/Nearclip.app/Nearclip',executable({'keychain-access-groups':['TEAM.studio.ivlis.nearclip'],'application-identifier':'TEAM.studio.ivlis.nearclip'}))
        if extension:
            z.writestr('Payload/Nearclip.app/PlugIns/NearclipShare.appex/Info.plist',plistlib.dumps({'CFBundleExecutable':'Share','NSLocalNetworkUsageDescription':'Connect to a paired device.'}))
            z.writestr('Payload/Nearclip.app/PlugIns/NearclipShare.appex/Share',executable({'keychain-access-groups':['TEAM.studio.ivlis.nearclip']}))
    ipa=stream.getvalue()
    release={'tag_name':'v1.2.0','published_at':'2026-10-28T00:00:00Z','assets':[{'name':'Nearclip-iOS.ipa','size':len(ipa)}]}
    return release,ipa

class SourceTests(unittest.TestCase):
    def test_reads_executable_entitlements(self):
        self.assertEqual(entitlements(executable({'keychain-access-groups':['x']})),{'keychain-access-groups':['x']})
    def test_source_uses_real_bundle_version_and_digest(self):
        release,ipa=fixture();app=generate(release,ipa)['apps'][0];version=app['versions'][0]
        self.assertEqual(version['version'],'1.2.0');self.assertEqual(version['buildVersion'],'3')
        self.assertEqual(version['sha256'],hashlib.sha256(ipa).hexdigest());self.assertEqual(version['size'],len(ipa))
        self.assertEqual(app['appPermissions']['entitlements'],['keychain-access-groups'])
        self.assertIn('NSLocalNetworkUsageDescription',app['appPermissions']['privacy'])
        self.assertIn('NSCameraUsageDescription',app['appPermissions']['privacy'])
    def test_rejects_mismatched_release_version(self):
        release,ipa=fixture('1.1.0')
        with self.assertRaises(AssertionError):generate(release,ipa)
    def test_rejects_mismatched_size(self):
        release,ipa=fixture();release['assets'][0]['size']+=1
        with self.assertRaises(AssertionError):generate(release,ipa)
    def test_rejects_wrong_digest_and_prerelease(self):
        release,ipa=fixture();release['assets'][0]['digest']='sha256:'+'0'*64
        with self.assertRaises(AssertionError):generate(release,ipa)
        release,ipa=fixture();release['prerelease']=True
        with self.assertRaises(AssertionError):generate(release,ipa)
    def test_no_extension_is_supported(self):
        release,ipa=fixture(extension=False);self.assertEqual(generate(release,ipa)['apps'][0]['versions'][0]['minOSVersion'],'17.0')

if __name__=='__main__':unittest.main()
