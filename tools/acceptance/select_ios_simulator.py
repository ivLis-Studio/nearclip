#!/usr/bin/env python3
"""Choose a conventional iPhone on the runtime matching the selected Xcode simulator SDK."""
import json,subprocess,sys
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-version'],text=True).strip()
runtime='com.apple.CoreSimulator.SimRuntime.iOS-'+sdk.replace('.','-')
devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','--json'],text=True))['devices']
# Use the oldest installed stable runtime in this SDK's major version. This is also a useful
# compatibility baseline; on this image the newest runtime stalls in Apple's CoreLocation migration.
candidates=[key for key in devices if '.iOS-'+sdk.split('.')[0]+'-' in key]
if not candidates:raise RuntimeError('No simulator runtime for selected SDK '+sdk)
runtime=min(candidates,key=lambda key:tuple(map(int,key.rsplit('.iOS-',1)[1].split('-'))))
print('Selected SDK '+sdk+'; runtime '+runtime,file=sys.stderr)
available=[device for device in devices[runtime] if device.get('isAvailable')]
for name in ['iPhone 17 Pro','iPhone 17','iPhone 16 Pro','iPhone 16']:
    for device in available:
        if device['name']==name:print(device['udid']);raise SystemExit()
raise RuntimeError('No conventional iPhone in matching runtime '+runtime)
