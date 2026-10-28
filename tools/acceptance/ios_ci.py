#!/usr/bin/env python3
"""Run the simulator onboarding/pair/send UI flow against a real localhost peer."""
import argparse, os, shlex, subprocess, sys, tempfile, http.server, threading
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
subprocess.run(['xcrun','simctl','boot',args.sim],check=False)
developer=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
subprocess.run(['open','-a',str(developer/'Applications/Simulator.app'),'--args','-CurrentDeviceUDID',args.sim],check=True)
subprocess.run(['xcrun','simctl','bootstatus',args.sim,'-b'],check=True)
# Issue the short-lived pairing ticket only after compilation and simulator boot have completed.
peer=Peer('swift',shlex.quote(str(cli)),'CI Windows PC')
try:
    peer.send(cmd='send_text',text='History from the paired computer')
    peer.send(cmd='ticket');link=local_uri(peer.expect('ticket',lambda e:e.get('ev')=='ticket')['uri'])
    message='Nearclip simulator send validation'
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),http.server.SimpleHTTPRequestHandler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    share_url='http://127.0.0.1:'+str(server.server_port)+'/website/public/privacy.html'
    env=dict(os.environ,TEST_RUNNER_NC_PAIR_LINK=link,TEST_RUNNER_NC_SEND_TEXT=message,TEST_RUNNER_NC_LANG='en',TEST_RUNNER_NC_SHARE_URL=share_url,TEST_RUNNER_NC_CI='1')
    target=os.environ.get('RUNNER_TEMP',tempfile.gettempdir())+'/ios-tests'
    command=['xcodebuild','test-without-building','-project',str(ROOT/'apple/Nearclip.xcodeproj'),'-scheme','NearclipiOS',
        '-configuration','Debug','-destination','platform=iOS Simulator,id='+args.sim,'-derivedDataPath',target,
        '-only-testing:NearclipiOSUITests/NearclipFlowTests/testOnboardingPairSyncAndSend',
        '-only-testing:NearclipiOSUITests/NearclipFlowTests/testShareFromSafari',
        '-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1',
        '-test-timeouts-enabled','YES','-maximum-test-execution-time-allowance','300',
        'CODE_SIGNING_ALLOWED=YES','CODE_SIGN_IDENTITY=-']
    subprocess.run(command,env=env,check=True)
    peer.expect('text sent from the simulator',lambda e:e.get('ev')=='clip' and e.get('text')==message,timeout=15)
    peer.expect('URL shared from Safari',lambda e:e.get('ev')=='clip' and e.get('text','').startswith(share_url),timeout=15)
    server.shutdown()
    print('PASS simulator UI, persisted per-device controls, Safari share extension and real peer delivery',flush=True)
finally:peer.quit()
