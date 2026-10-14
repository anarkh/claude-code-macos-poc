#!/usr/bin/python3
"""Derive the dedicated browser layout from the installed Openbox defaults."""
import argparse
import hashlib
import os
from pathlib import Path
import sys
import tempfile
import xml.etree.ElementTree as ET

NAMESPACE = 'http://openbox.org/3.4/rc'
TAG = '{' + NAMESPACE + '}'
ET.register_namespace('', NAMESPACE)


def build_config(content):
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    root = ET.fromstring(content, parser=parser)
    if root.tag != TAG + 'openbox_config':
        raise ValueError('openbox_vendor_namespace_invalid')
    desktops = root.find(TAG + 'desktops')
    mouse = root.find(TAG + 'mouse')
    applications = root.find(TAG + 'applications')
    if any(element is None for element in (desktops, mouse, applications)):
        raise ValueError('openbox_vendor_sections_missing')
    for name in ('number', 'firstdesk'):
        element = desktops.find(TAG + name)
        if element is None:
            raise ValueError('openbox_vendor_desktops_missing')
        element.text = '1'
    removed = {'Desktop': 0, 'Titlebar': 0}
    for context in mouse.findall(TAG + 'context'):
        name = context.get('name')
        if name not in removed:
            continue
        buttons = ({'Up', 'Down', 'A-Up', 'A-Down', 'C-A-Up', 'C-A-Down'}
                   if name == 'Desktop' else {'Up', 'Down'})
        for binding in list(context.findall(TAG + 'mousebind')):
            if binding.get('button') in buttons:
                context.remove(binding)
                removed[name] += 1
    if removed != {'Desktop': 6, 'Titlebar': 2}:
        raise ValueError('openbox_vendor_wheel_bindings_unexpected')
    firefox = ET.SubElement(applications, TAG + 'application', {'class': 'firefox', 'type': 'normal'})
    ET.SubElement(firefox, TAG + 'desktop').text = '1'
    ET.SubElement(firefox, TAG + 'maximized').text = 'yes'
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path('/'))
    arguments = parser.parse_args()
    source = arguments.root / 'etc/xdg/openbox/rc.xml'
    target = arguments.root / 'opt/browser/openbox.xml'
    content = build_config(source.read_bytes())
    with tempfile.NamedTemporaryFile(dir=target.parent, prefix='.openbox-', delete=False) as file:
        temporary = Path(file.name)
        file.write(content)
    os.chmod(temporary, 0o644)
    temporary.replace(target)
    print('BROWSER_OPENBOX_CONFIG_READY', flush=True)
    print('BROWSER_OPENBOX_CONFIG_SHA256=' + hashlib.sha256(content).hexdigest(), flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        code = str(error) if type(error) is ValueError else type(error).__name__
        print('BROWSER_OPENBOX_CONFIG_FAILED:' + code, file=sys.stderr)
        raise SystemExit(1)
