# -*- coding: utf-8 -*-
import io

p = 'D:/QQFloatBall-ci/Tweak.xm'
with io.open(p, 'rb') as f:
    data = f.read()
lines = data.split(b'\n')
print('=== L352-L360 原始字节 repr ===')
for i in range(351, min(361, len(lines))):
    print('L%d: %r' % (i + 1, lines[i]))
