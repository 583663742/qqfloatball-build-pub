# -*- coding: utf-8 -*-
"""验证 v1.1.0 deb 结构: 签名/路径/postinst/版本"""
import io, os, subprocess, sys, tarfile

DEB = r'D:/QQFloatBall-ci/artifact/v1.1.0/packages/com.example.qqfloatball_1.1.0_iphoneos-arm64e.deb'
print('deb 存在:', os.path.exists(DEB), os.path.getsize(DEB), 'bytes')

# 解 ar
work = r'D:/QQFloatBall-ci/artifact/v1.1.0/verify_work'
os.makedirs(work, exist_ok=True)
if os.path.exists(work + '/control.tar.gz'):
    os.remove(work + '/control.tar.gz')
r = subprocess.run(['ar', 'x', DEB], cwd=work, capture_output=True, text=True)
print('ar x rc:', r.returncode)
for f in os.listdir(work):
    print('  ar 成员:', f, os.path.getsize(os.path.join(work, f)))

# 解 control.tar.gz 看版本
ct = tarfile.open(os.path.join(work, 'control.tar.gz'))
for m in ct.getmembers():
    print('  control 成员:', m.name)
    if m.name.endswith('control') or m.name == 'control':
        data = ct.extractfile(m).read().decode('utf-8', 'replace')
        for line in data.splitlines():
            if line.startswith(('Package', 'Version', 'Maintainer', 'Depends')):
                print('   ', line)

# 解 data.tar.lzma 看路径
dt_name = 'data.tar.lzma'
dt = tarfile.open(os.path.join(work, dt_name), 'r:*')
for m in dt.getmembers():
    print('  data 成员:', m.name, oct(m.mode), m.size)

# dylib 签名检查
dylib = os.path.join(work, 'QQFloatBall.dylib')
if not os.path.exists(dylib):
    # data 解出来
    dt.extractall(work)
    for root, dirs, files in os.walk(work):
        for f in files:
            if f.endswith('.dylib'):
                dylib = os.path.join(root, f)
                break
if os.path.exists(dylib):
    print('dylib:', dylib, os.path.getsize(dylib))
    with open(dylib, 'rb') as f:
        blob = f.read()
    print('  含 LC_CODE_SIGNATURE 标志:', b'code signature' in blob or b'\x14\x00\x00\x00' in blob)
    # 简单检查 Mach-O magic
    print('  Mach-O magic:', blob[:4].hex())
