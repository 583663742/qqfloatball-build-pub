#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证 QQFloatBall v1.0.9 deb 包结构 + dylib 签名"""
import io, tarfile, struct, sys

deb = r"D:/QQFloatBall-ci/artifact/v1.0.9/packages/com.example.qqfloatball_1.0.9_iphoneos-arm64e.deb"

with open(deb, 'rb') as f:
    data = f.read()

assert data[:8] == b'!<arch>\n', "不是 ar 归档"
off = 8
members = {}
while off < len(data):
    name = data[off:off+16].decode().strip()
    size = int(data[off+48:off+58].decode().strip())
    content = data[off+60:off+60+size]
    members[name.rstrip('/')] = content
    off = off + 60 + size + (2 if size % 2 else 0)

print("ar members:", list(members.keys()))

for mname, mcontent in members.items():
    if 'data.tar' in mname:
        tf = tarfile.open(fileobj=io.BytesIO(mcontent))
        print(f"\n=== {mname} ===")
        for m in tf.getmembers():
            print(f"{m.mode:o} {m.size:8d} {m.name}")
        tf.close()
    if 'control.tar' in mname:
        tf = tarfile.open(fileobj=io.BytesIO(mcontent))
        print(f"\n=== {mname} ===")
        for m in tf.getmembers():
            print(f"{m.mode:o} {m.size:8d} {m.name}")
            if 'postinst' in m.name or 'control' == m.name.rsplit('/',1)[-1]:
                f = tf.extractfile(m)
                print(f"--- {m.name} ---")
                print(f.read().decode(errors='replace')[:1200])
        tf.close()

# dylib 签名检查
dylib = None
for mname, mcontent in members.items():
    if 'data.tar' in mname:
        tf = tarfile.open(fileobj=io.BytesIO(mcontent))
        for m in tf.getmembers():
            if m.name.endswith('QQFloatBall.dylib'):
                dylib = tf.extractfile(m).read()
        tf.close()

if dylib:
    magic = struct.unpack('<I', dylib[:4])[0]
    print(f"\n=== dylib magic=0x{magic:x} size={len(dylib)} ===")
    if magic == 0xfeedfacf:
        ncmds, sizeofcmds = struct.unpack('<II', dylib[16:24])
        off = 32
        has_sig = False
        cmds = []
        for i in range(ncmds):
            cmd, cmdsize = struct.unpack('<II', dylib[off:off+8])
            cmds.append(hex(cmd))
            if cmd == 0x1d:
                has_sig = True
            off += cmdsize
        print(f"  LC_CODE_SIGNATURE: {'YES' if has_sig else 'NO'}")
        print(f"  load commands: {cmds[:30]}")
    else:
        print("  非 64 位小端 Mach-O")
