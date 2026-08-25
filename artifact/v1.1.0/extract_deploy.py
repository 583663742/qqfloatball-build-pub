# -*- coding: utf-8 -*-
"""从 v1.1.0 deb 解出部署三件套到 deploy/ 目录"""
import io, os, subprocess, tarfile

DEB = r'D:/QQFloatBall-ci/artifact/v1.1.0/packages/com.example.qqfloatball_1.1.0_iphoneos-arm64e.deb'
WORK = r'D:/QQFloatBall-ci/artifact/v1.1.0/verify_work'
OUT = r'D:/QQFloatBall-ci/artifact/v1.1.0/deploy'
os.makedirs(OUT, exist_ok=True)

# 解 data.tar.lzma
dt = tarfile.open(os.path.join(WORK, 'data.tar.lzma'), 'r:*')
dt.extractall(WORK)

src_dylib = os.path.join(WORK, 'Library/MobileSubstrate/DynamicLibraries/QQFloatBall.dylib')
src_plist = os.path.join(WORK, 'Library/MobileSubstrate/DynamicLibraries/QQFloatBall.plist')
for src, name in [(src_dylib, 'QQFloatBall.dylib'), (src_plist, 'QQFloatBall.plist')]:
    dst = os.path.join(OUT, name)
    with open(src, 'rb') as f:
        data = f.read()
    with open(dst, 'wb') as f:
        f.write(data)
    print('解出:', dst, len(data), 'bytes')
