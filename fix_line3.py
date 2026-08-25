# -*- coding: utf-8 -*-
import io

p = 'D:/QQFloatBall-ci/Tweak.xm'
with io.open(p, 'rb') as f:
    data = f.read()

BS = chr(92)  # 反斜杠字符
# C 源码文本(写入 Tweak.xm 的字节):
#   @"/\\+=\n\r"];
#   \\ -> 两个反斜杠字符 (C 转义 -> 1 个反斜杠)
#   \n -> 反斜杠+n       (C 转义 -> 换行符)
#   \r -> 反斜杠+r       (C 转义 -> 回车符)
line_text = ('    NSCharacterSet *drop = [NSCharacterSet characterSetWithCharactersInString:'
             '@"/' + BS + BS + '+=' + BS + 'n' + BS + 'r"];')
fixed_line = line_text.encode('utf-8')

lines = data.split(b'\n')
idx = None
for i, ln in enumerate(lines):
    if b'characterSetWithCharactersInString' in ln:
        idx = i
        break
print('找到行:', idx + 1)
print('修改前:', repr(lines[idx]))
new_lines = lines[:idx] + [fixed_line] + lines[idx + 1:]
out = b'\n'.join(new_lines)
with io.open(p, 'wb') as f:
    f.write(out)
print('修改后:', repr(fixed_line))
print('C 语义: 字符集 = / \\ + = 换行 回车 (\\n 是 C 转义换行)')
