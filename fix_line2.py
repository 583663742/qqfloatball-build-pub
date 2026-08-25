# -*- coding: utf-8 -*-
import io

p = 'D:/QQFloatBall-ci/Tweak.xm'
with io.open(p, 'rb') as f:
    data = f.read()

# C 源码需要的字节: @"/\\+=\n\r"];
#   \\ -> 2 个反斜杠字符(C 转义为 1 反斜杠)
#   \n -> 反斜杠+n(C 转义为换行)
#   \r -> 反斜杠+r(C 转义为回车)
fixed_line = b'    NSCharacterSet *drop = [NSCharacterSet characterSetWithCharactersInString:@"/\\\\+=\\n\\r"];'

lines = data.split(b'\n')
idx = None
for i, ln in enumerate(lines):
    if b'characterSetWithCharactersInString' in ln:
        idx = i
        break
print('找到行:', idx + 1)
print('L354 前:', repr(lines[idx]))
new_lines = lines[:idx] + [fixed_line] + lines[idx + 1:]
out = b'\n'.join(new_lines)
with io.open(p, 'wb') as f:
    f.write(out)
print('L354 后:', repr(fixed_line))
