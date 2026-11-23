"""Brands the Windows runner that `flutter create` generates: AURA.exe, window title."""
import re

f = 'windows/CMakeLists.txt'
s = open(f, encoding='utf-8').read()
s = re.sub(r'set\(BINARY_NAME "[^"]*"\)', 'set(BINARY_NAME "AURA")', s, count=1)
open(f, 'w', encoding='utf-8').write(s)

f = 'windows/runner/main.cpp'
s = open(f, encoding='utf-8').read()
s = s.replace('window.Create(L"reel"', 'window.Create(L"AURA"')
open(f, 'w', encoding='utf-8').write(s)

f = 'windows/runner/Runner.rc'
s = open(f, encoding='utf-8', errors='ignore').read()
s = s.replace('"reel.exe"', '"AURA.exe"')
for key in ('FileDescription', 'InternalName', 'ProductName'):
    s = re.sub(r'(VALUE "%s", )"[^"]*"' % key, r'\1"AURA"', s)
open(f, 'w', encoding='utf-8').write(s)
print('windows patched')
