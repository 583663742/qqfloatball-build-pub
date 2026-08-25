#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 deb 解出 QQFloatBall.dylib + plist 到指定目录"""
import io, tarfile, lzma, sys, os

deb = r"D:/QQFloatBall-ci/artifact/v1.0.9/packages/com.example.qqfloatball_1.0.9_iphoneos-arm64e.deb"
outdir = r"D:/QQFloatBall-ci/artifact/v1.0.9/deploy"

os.makedirs(outdir, exist_ok=True)

with open(deb, 'rb') as f:
    data = f.read()

off = 8
members = {}
while off < len(data):
    name = data[off:off+16].decode().strip()
    size = int(data[off+48:off+58].decode().strip())
    content = data[off+60:off+60+size]
    members[name.rstrip('/')] = content
    off = off + 60 + size + (2 if size % 2 else 0)

for mname, mcontent in members.items():
    if 'data.tar' in mname:
        # 可能是 lzma / gz / xz / zst
        raw = mcontent
        tf = None
        for fn in (lambda b: tarfile.open(fileobj=io.BytesIO(b)),
                   lambda b: tarfile.open(fileobj=io.BytesIO(lzma.decompress(b)))):
            try:
                tf = fn(raw)
                break
            except Exception:
                continue
        if not tf:
            print("无法解包:", mname)
            sys.exit(1)
        for m in tf.getmembers():
            if m.isfile() and m.name.endswith(('QQFloatBall.dylib', 'QQFloatBall.plist')):
                out = os.path.join(outdir, os.path.basename(m.name))
                with open(out, 'wb') as fo:
                    fo.write(tf.extractfile(m).read())
                os.chmod(out, 0o755 if m.name.endswith('.dylib') else 0o644)
                print("解出:", out, os.path.getsize(out), "bytes")
        tf.close()

print("完成")
