#!/usr/bin/env python3
"""Generate the development CloudKit configuration using real account identifiers."""
import argparse
import plistlib
import re
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--team', required=True)
parser.add_argument('--bundle', required=True)
parser.add_argument('--container', required=True)
args = parser.parse_args()
if not re.fullmatch(r'[A-Z0-9]{10}', args.team):
    parser.error('team must be the 10-character Apple Developer Team ID')
if not re.fullmatch(r'[A-Za-z0-9.-]+', args.bundle) or args.bundle.startswith('com.example.'):
    parser.error('supply your registered bundle identifier')
if not re.fullmatch(r'iCloud\.[A-Za-z0-9.-]+', args.container):
    parser.error('container must be a registered iCloud.* identifier')
root = Path(__file__).resolve().parent.parent
entitlements = {
    'com.apple.developer.icloud-container-identifiers': [args.container],
    'com.apple.developer.icloud-services': ['CloudKit'],
    'aps-environment': 'development',
}
(root / 'PersonalKakeibo/App/Cloud.entitlements').write_bytes(plistlib.dumps(entitlements))
text = (root / 'project.yml').read_text()
# The local project may already preserve its signing team. Replace it for the requested cloud configuration.
text = re.sub(r'^        DEVELOPMENT_TEAM:.*\n', '', text, flags=re.MULTILINE)
text = text.replace('PRODUCT_BUNDLE_IDENTIFIER: com.example.PersonalKakeibo\n', 'PRODUCT_BUNDLE_IDENTIFIER: ' + args.bundle + '\n')
text = text.replace('        TARGETED_DEVICE_FAMILY:',
    f'        DEVELOPMENT_TEAM: {args.team}\n'
    '        CODE_SIGN_ENTITLEMENTS: PersonalKakeibo/App/Cloud.entitlements\n'
    f'        INFOPLIST_KEY_KakeiboCloudContainer: {args.container}\n'
    '        INFOPLIST_KEY_UIBackgroundModes: [remote-notification]\n'
    '        TARGETED_DEVICE_FAMILY:')
(root / 'project-cloud.yml').write_text(text)
print('Generated project-cloud.yml. Run: xcodegen generate --spec project-cloud.yml')
