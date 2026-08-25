import struct, tarfile, io, os, sys

path = r'D:\QQFloatBall-ci\artifact\v1.0.9\packages\com.example.qqfloatball_1.0.9_iphoneos-arm64e.deb'
os.makedirs(r'D:\QQFloatBall-ci\artifact\v1.0.9\extract', exist_ok=True)
with open(path, 'rb') as f:
    f.read(8)
    members = {}
    while True:
        header = f.read(60)
        if len(header) < 60:
            break
        name = header[0:16].decode().strip()
        size = int(header[48:58].decode().strip())
        data = f.read(size)
        members[name] = data
        f.seek(1 if size % 2 else 0, 1)
print('members:', list(members.keys()))
tf = tarfile.open(fileobj=io.BytesIO(members['data.tar.lzma']), mode='r:*')
for m in tf.getmembers():
    print('file:', m.name, m.size)
    if m.isfile() and (m.name.endswith('.dylib') or m.name.endswith('.plist')):
        content = tf.extractfile(m).read()
        out = os.path.join(r'D:\QQFloatBall-ci\artifact\v1.0.9\extract', os.path.basename(m.name))
        with open(out, 'wb') as w:
            w.write(content)
        print('  ->', out, len(content), 'bytes')
print('DONE')
