#!/usr/bin/env python3
"""Run the simulator onboarding/pair/send UI flow against a real localhost peer."""
import argparse, os, shlex, subprocess, sys, tempfile, uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))
from tools.interop.run import Peer,local_uri

parser=argparse.ArgumentParser();parser.add_argument('--sim',required=True);args=parser.parse_args()
cli=ROOT/'apple/NearclipKit/.build/debug/nearclip-cli'
target=os.environ.get('RUNNER_TEMP',tempfile.gettempdir())+'/ios-tests'
base=['xcodebuild','-project',str(ROOT/'apple/Nearclip.xcodeproj'),'-scheme','NearclipiOS',
    '-configuration','Debug','-destination','platform=iOS Simulator,id='+args.sim,'-derivedDataPath',target,
    'CODE_SIGNING_ALLOWED=YES','CODE_SIGN_IDENTITY=-']
subprocess.run(base+['build-for-testing'],check=True)
harness_base=base.copy();harness_base[harness_base.index('NearclipiOS')]='NearclipShareHarness'
subprocess.run(harness_base+['build'],check=True)
subprocess.run(['xcrun','simctl','boot',args.sim],check=False)
developer=Path(os.environ.get('DEVELOPER_DIR') or subprocess.check_output(['xcode-select','-p'],text=True).strip())
simulator=next((path for path in [developer/'Applications/Simulator.app',developer/'Applications/Device Hub.app',developer/'Applications/DeviceHub.app'] if path.exists()), developer/'Applications/Simulator.app')
if simulator.exists():
    subprocess.run(['open','-a',str(simulator),'--args','-CurrentDeviceUDID',args.sim],check=True)
else:
    print('Using headless CoreSimulator; this toolchain has no Simulator.app',flush=True)
subprocess.run(['xcrun','simctl','bootstatus',args.sim,'-b'],check=True,timeout=600)
subprocess.run(['xcrun','simctl','install',args.sim,target+'/Build/Products/Debug-iphonesimulator/NearclipShareHarness.app'],check=True)
# Issue the short-lived pairing ticket only after compilation and simulator boot have completed.
peer=Peer('swift',shlex.quote(str(cli))+' --platform win','CI Windows PC')
try:
    peer.send(cmd='send_text',text='History from the paired computer')
    peer.send(cmd='ticket');link=local_uri(peer.expect('ticket',lambda e:e.get('ev')=='ticket')['uri'])
    message='Nearclip simulator send validation'
    share_url='https://nearclip.invalid/share-acceptance/'+str(uuid.uuid4())
    share_text='Text from the native share-sheet host '+str(uuid.uuid4())
    env=dict(os.environ,TEST_RUNNER_NC_PAIR_LINK=link,TEST_RUNNER_NC_SEND_TEXT=message,TEST_RUNNER_NC_LANG='en',TEST_RUNNER_NC_SHARE_URL=share_url,TEST_RUNNER_NC_SHARE_TEXT=share_text,TEST_RUNNER_NC_CI='1')
    target=os.environ.get('RUNNER_TEMP',tempfile.gettempdir())+'/ios-tests'
    command=['xcodebuild','test-without-building','-project',str(ROOT/'apple/Nearclip.xcodeproj'),'-scheme','NearclipiOS',
        '-configuration','Debug','-destination','platform=iOS Simulator,id='+args.sim,'-derivedDataPath',target,
        '-only-testing:NearclipiOSUITests/NearclipFlowTests/testOnboardingPairSyncAndSend',
        '-only-testing:NearclipiOSUITests/NearclipFlowTests/testShareFromNativeHost',
        '-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1',
        '-test-timeouts-enabled','YES','-maximum-test-execution-time-allowance','300',
        'CODE_SIGNING_ALLOWED=YES','CODE_SIGN_IDENTITY=-']
    subprocess.run(command,env=env,check=True,timeout=600)
    peer.expect('text sent from the simulator',lambda e:e.get('ev')=='clip' and e.get('text')==message,timeout=15)
    peer.expect('URL shared through UIKit',lambda e:e.get('ev')=='clip' and e.get('text')==share_url,timeout=15)
    peer.expect('text shared through UIKit',lambda e:e.get('ev')=='clip' and e.get('text')==share_text,timeout=15)
    peer.expect('image shared through UIKit',lambda e:e.get('ev')=='clip' and e.get('kind')=='image',timeout=15)
    print('PASS simulator UI, persisted per-device controls, URL/text/image share extension and real peer delivery',flush=True)
finally:
    peer.quit()
    # Extension logs contain only provider type metadata added in Debug, not clipboard payloads.
    with open('/tmp/nearclip-share-debug.log','w') as output:
        try:
            subprocess.run(['xcrun','simctl','spawn',args.sim,'log','show','--style','compact','--last','15m',
                            '--predicate','process == "NearclipShare"'],stdout=output,stderr=subprocess.STDOUT,timeout=30)
        except subprocess.TimeoutExpired:pass
