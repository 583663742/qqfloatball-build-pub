# -*- coding: utf-8 -*-
import io

p = 'D:/QQFloatBall-ci/Tweak.xm'
with io.open(p, 'r', encoding='utf-8', newline='') as f:
    lines = f.readlines()
print('总行数:', len(lines))
bad = []
for i, ln in enumerate(lines, 1):
    s = ln.rstrip('\r\n')
    quotes = 0
    j = 0
    while j < len(s):
        ch = s[j]
        if ch == '\\':
            j += 2
            continue
        if ch == '"':
            quotes += 1
        j += 1
    if quotes % 2 != 0:
        bad.append((i, s[:100]))
if bad:
    print('WARN 奇数引号行(可能跨行字符串):')
    for i, s in bad[:20]:
        print('  L%d: %s' % (i, s))
else:
    print('OK 所有行引号配对正常')
src = ''.join(lines)
for name in ['showTaskPanel', 'renderTaskRows', 'refreshTaskListUI', 'execTaskByTitle',
             'runTestFriendTask', 'runDailySignTask', 'runAddFriendTask', 'runRemoveFriendTask',
             'runCoinExchangeTask', 'runShuoshuoTask', 'runLikeTask', 'zzcSign',
             'httpPostText', 'getSkey', 'levelCookie',
             '_taskCheckTapped', '_taskRefreshTapped', '_taskCloseTapped',
             '_taskTestFriendTapped', '_taskExecCheckedTapped',
             'taskStatusText', 'taskDaysText', 'appendLogView']:
    cnt = src.count(name)
    print('  %s: %d' % (name, cnt))
