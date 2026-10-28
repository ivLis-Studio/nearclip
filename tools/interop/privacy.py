#!/usr/bin/env python3
"""Privacy regression tests over real Swift/Kotlin/C# TCP peers. No device clipboard is touched."""
import argparse, itertools, os, shlex, tempfile, time, shutil
from run import Peer, detect, pair_qr


def history(peer):
    peer.mark();peer.send(cmd='list')
    return peer.expect('history',lambda e:e.get('ev')=='history')['clips']

def has(peer,ident):return any(c.get('id')==ident for c in history(peer))
def policy(peer,target,**settings):
    peer.mark();peer.send(cmd='policy',peer=target.id,**settings)
    peer.expect('policy saved',lambda e:e.get('ev')=='policy' and e.get('peer')==target.id)

def privacy_case(implementations, offline=False):
    peers=[Peer(impl,cmd,'Privacy'+str(i)) for i,(impl,cmd) in enumerate(implementations)]
    a,b,c=peers
    try:
        pair_qr(a,b);pair_qr(a,c)
        policy(a,b,send=False)
        a.send(cmd='send_text',text='only the permitted peer may receive this')
        copied=c.expect('allowed live clip',lambda e:e.get('ev')=='clip' and e.get('text')=='only the permitted peer may receive this')
        ident=copied['id'];time.sleep(.35)
        assert not has(b,ident),'restricted clip leaked through relay'
        b.restart();b.send(cmd='connect',host='127.0.0.1',port=c.port);time.sleep(.35)
        assert not has(b,ident),'restricted clip leaked through catch-up'
        policy(a,b,send=True)
        # An isolated iOS extension uses its phone's identity and a separate temporary store.
        # After it exits, the main app (same device id) must catch up the selected share.
        import shutil
        a.quit()
        extension_state=tempfile.mkdtemp(prefix='nearclip-share-engine-')
        for name in ['state.json','history-key']:
            path=os.path.join(a.state,name)
            if os.path.exists(path):shutil.copy2(path,os.path.join(extension_state,name))
        for name in ['secrets']:
            path=os.path.join(a.state,name)
            if os.path.exists(path):shutil.copytree(path,os.path.join(extension_state,name))
        extension=Peer(a.impl,a.cmd,'Share engine',state=extension_state)
        try:
            policy(extension,b,send=False)
            extension.send(cmd='connect',host='127.0.0.1',port=c.port)
            extension.expect('extension connected',lambda e:e.get('ev')=='peer_up' and e.get('id')==c.id)
            extension.send(cmd='send_text',text='shared from the temporary extension')
            shared=c.expect('extension share received',lambda e:e.get('ev')=='clip' and e.get('text')=='shared from the temporary extension')
        finally:
            extension.quit();shutil.rmtree(extension_state,ignore_errors=True)
        a.restart();a.send(cmd='connect',host='127.0.0.1',port=c.port)
        a.expect('main app catches up its extension clip',lambda e:e.get('ev')=='clip' and e.get('id')==shared['id'])
        assert not has(b,shared['id']),'extension share leaked to the excluded peer'
        policy(b,a,codes=False)
        a.send(cmd='send_text',text='482915',otp=True)
        code=c.expect('code allowed',lambda e:e.get('ev')=='clip' and e.get('text')=='482915')
        assert code.get('apply') is False,'code was applied automatically or test output lacks apply'
        time.sleep(.35);assert not has(b,code['id']),'code receive policy ignored'
        # Removing one online peer rotates the key on the remaining peer and reconnects automatically.
        if offline: b.quit()
        a.mark();c.mark();a.send(cmd='remove',peer=b.id)
        if not offline: b.expect('removed device left',lambda e:e.get('ev')=='left')
        c.expect('remaining peer reconnected',lambda e:e.get('ev')=='peer_up' and e.get('id')==a.id,timeout=30)
        if offline:
            b.restart();b.send(cmd='connect',host='127.0.0.1',port=a.port);b.send(cmd='connect',host='127.0.0.1',port=c.port)
        a.send(cmd='send_text',text='works after key rotation')
        c.expect('new-key clip',lambda e:e.get('ev')=='clip' and e.get('text')=='works after key rotation')
        time.sleep(.35)
        assert not any(x.get('text')=='works after key rotation' for x in history(b))
        if offline:
            pair_qr(a,b)
            a.send(cmd='send_text',text='re-pairing restores access')
            b.expect('re-paired clip',lambda e:e.get('ev')=='clip' and e.get('text')=='re-pairing restores access')
    finally:
        for p in peers:p.quit()
        for p in peers:shutil.rmtree(p.state,ignore_errors=True)

def expiry_case(implementations):
    peers=[Peer(impl,cmd,'Expiry'+str(i)) for i,(impl,cmd) in enumerate(implementations)]
    a,b,c=peers
    try:
        pair_qr(a,b);pair_qr(a,c)
        a.send(cmd='send_text',text='ordinary content stays')
        for p in [b,c]:p.expect('normal clip',lambda e:e.get('ev')=='clip' and e.get('text')=='ordinary content stays')
        a.send(cmd='send_text',text='739251',otp=True)
        received=[p.expect('live code',lambda e:e.get('ev')=='clip' and e.get('text')=='739251') for p in [b,c]]
        for e in received:assert e.get('apply') is False
        code_id=received[0]['id']
        for waited in range(0,190,10):
            print(f'OTP expiration: {waited}/190 seconds',flush=True);time.sleep(10)
        for p in peers:
            clips=history(p)
            assert not any(c.get('id')==code_id for c in clips),p.impl+' retained expired code'
            assert any(c.get('text')=='ordinary content stays' for c in clips)
        b.restart();b.send(cmd='connect',host='127.0.0.1',port=a.port);time.sleep(.5)
        assert not has(b,code_id),'expired code resurrected on restart'
        print('PASS real-time 3-minute code expiry, normal-history preservation and restart',flush=True)
    finally:
        for p in peers:p.quit()
        for p in peers:shutil.rmtree(p.state,ignore_errors=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--swift');parser.add_argument('--expiry',action='store_true');args=parser.parse_args()
    impls=detect()
    if args.swift:impls['swift']=args.swift
    names=[(name,impls[name]) for name in ['swift','kotlin','dotnet']]
    if args.expiry:expiry_case(names)
    else:
        for permutation in itertools.permutations(names):
            for offline in [False,True]:
                privacy_case(permutation,offline=offline);print('PASS policy + '+('offline ' if offline else 'online ')+'rekey: '+' -> '.join(n for n,c in permutation),flush=True)
