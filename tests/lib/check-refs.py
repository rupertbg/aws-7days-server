#!/usr/bin/env python3
"""Every ${...} in instance.yml must resolve to something CloudFormation knows.

Fn::Sub fails a deployment on an unknown reference, and the most common way to
introduce one here is forgetting the ${!VAR} escape on a shell variable inside
the bootstrap - which silently turns a shell variable into a template
reference. This catches that before a stack update does.
"""
import os
import re
import sys

TEMPLATE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    'instance.yml')
# Supplied by the two-element Fn::Sub form, which declares its own variables.
SUB_LOCALS = {'BucketArn', 'Vol'}


def top_level_keys(lines, section):
    keys, inside = set(), False
    for line in lines:
        if line == section + ':':
            inside = True
            continue
        if inside and line and not line.startswith(' '):
            break
        if inside:
            m = re.match(r'^  ([A-Za-z0-9]+):\s*$', line)
            if m:
                keys.add(m.group(1))
    return keys


def main():
    lines = open(TEMPLATE).read().split('\n')
    known = (top_level_keys(lines, 'Parameters')
             | top_level_keys(lines, 'Resources') | SUB_LOCALS)
    bad = {}
    for n, line in enumerate(lines, 1):
        for m in re.finditer(r'\$\{([^}]*)\}', line):
            ref = m.group(1)
            if ref.startswith('!') or ref.startswith('AWS::'):
                continue
            if ref.split('.')[0] in known:
                continue
            bad.setdefault(ref, []).append(n)
    for ref, where in sorted(bad.items()):
        print('  FAIL ${%s} at instance.yml:%s resolves to nothing - a shell '
              'variable here needs the ${!%s} escape'
              % (ref, ','.join(map(str, where[:5])), ref))
    if bad:
        return 1
    print('  ok   every ${...} resolves to a parameter, resource or '
          'pseudo-parameter')
    return 0


if __name__ == '__main__':
    sys.exit(main())
