#!/usr/bin/env python3
"""Build and launch an isolated BB Public simulator prototype with Xcode."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('environment', choices=['production', 'staging'])
parser.add_argument('--device', required=True, help='Explicit simulator UDID; never erases it')
parser.add_argument('--relay-auth', choices=['true', 'false'], default='false',
                    help='Enable only when backend assertion issuance is supported')
parser.add_argument('--output', type=Path, required=True, help='Local build/log directory')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
output = args.output.expanduser().resolve()
output.mkdir(parents=True, exist_ok=True)
config = {
    'production': ('https://app.builderlab.xyz', 'communities.buzz.xyz'),
    'staging': ('https://app.builderlabstaging.xyz', 'communities.public.builderlabstaging.xyz'),
}[args.environment]
origin, domains = config
bundle = f'xyz.block.buzz.dev.publicproof.{args.environment}'
values = {'BUZZ_BUILDERLAB_URL': origin, 'BUZZ_AUTH_DOMAINS': domains,
          'BUZZ_HOSTED_RELAY_AUTH': args.relay_auth,
          'BUZZ_DEBUG_PRIVATE_LOGIN': 'true'}
defines = ','.join(base64.b64encode(f'{k}={v}'.encode()).decode() for k, v in values.items())
env = dict(os.environ)
env.setdefault('DEVELOPER_DIR', '/Applications/Xcode-27.0.0.app/Contents/Developer')

def run(command, **kwargs):
    return subprocess.run(command, env=env, cwd=root, check=True, **kwargs)

inventory = json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j'], capture_output=True, text=True).stdout)
devices = [d for ds in inventory['devices'].values() for d in ds if d['udid'] == args.device]
if len(devices) != 1 or not devices[0].get('isAvailable'):
    parser.error('Choose an available simulator UDID from xcrun simctl list devices')
if devices[0]['state'] == 'Shutdown':
    run(['xcrun', 'simctl', 'boot', args.device])
run(['xcrun', 'simctl', 'bootstatus', args.device, '-b'])
command = ['xcodebuild', '-workspace', 'mobile/ios/Runner.xcworkspace', '-scheme', 'Runner',
           '-configuration', 'Debug', '-sdk', 'iphonesimulator', '-destination', f'id={args.device}',
           '-derivedDataPath', str(output / 'build'), f'BUNDLE_IDENTIFIER={bundle}',
           f'APP_DISPLAY_NAME=Buzz Public {args.environment.title()}',
           'FLUTTER_TARGET=lib/main_prototype.dart', 'CODE_SIGNING_ALLOWED=YES',
           'CODE_SIGN_IDENTITY=-', f'DART_DEFINES={defines}', 'build']
with (output / 'build.log').open('w') as log:
    run(command, stdout=log, stderr=subprocess.STDOUT)
app = output / 'build/Build/Products/Debug-iphonesimulator/Buzz.app'
run(['codesign', '--verify', '--deep', '--strict', str(app)])
run(['xcrun', 'simctl', 'install', args.device, str(app)])
run(['xcrun', 'simctl', 'launch', args.device, bundle])
metadata = {'environment': args.environment, 'origin': origin, 'auth_domains': domains,
            'relay_auth': args.relay_auth, 'device': args.device, 'bundle': bundle,
            'app': str(app), 'authentication': 'ASWebAuthenticationSession', 'private_login': True}
(output / 'build-info.json').write_text(json.dumps(metadata, indent=2) + '\n')
print(json.dumps(metadata, indent=2))
