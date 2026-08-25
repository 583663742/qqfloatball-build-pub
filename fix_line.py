# -*- coding: utf-8 -*-
import io

p = 'D:/QQFloatBall-ci/Tweak.xm'
with io.open(p, 'rb') as f:
    data = f.read()

lines = data.split(b'\n')
# 目标: L354 + L355 -> 单行正确字符串
# 正确内容(字面反斜杠n、字面反斜杠r): @"/\+=\n\r"
fixed_line = b'    NSCharacterSet *drop = [NSCharacterSet characterSetWithCharactersInString:@"/\\+=\\n\\r"];'

# 找 L354(内容含 characterSetWithCharactersInString 且引号未闭合)
idx = None
for i, ln in enumerate(lines):
    if b'characterSetWithCharactersInString' in ln:
        idx = i
        break
print('找到行:', idx + 1)
print('L354 repr:', repr(lines[idx]))
print('L355 repr:', repr(lines[idx + 1]))

# 合并: 检查 355 是否以 \r"]; 开头
assert b'"];' in lines[idx + 1], 'L355 意外内容'

# 替换
new_lines = lines[:idx] + [fixed_line] + lines[idx + 2:]
out = b'\n'.join(new_lines)
with io.open(p, 'wb') as f:
    f.write(out)
print('已写入, 新 L%d: %r' % (idx + 1, fixed_line))
