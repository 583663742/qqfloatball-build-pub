# -*- coding: utf-8 -*-
"""建本地知识库 SQLite: D:/AI_Agent/Hermes_Desktop/data/hermes-home/knowledge.db
表 entries: id, 领域(domain), 标题(title), 内容(content), 标签(tags), 日期(created)
用途: 经验/错误/接口细节等长内容放这里, 记忆只留索引, 不再挤爆 memory
"""
import sqlite3, os, datetime

DB = r'D:/AI_Agent/Hermes_Desktop/data/hermes-home/knowledge.db'
os.makedirs(os.path.dirname(DB), exist_ok=True)

conn = sqlite3.connect(DB)
c = conn.cursor()
c.execute('''CREATE TABLE IF NOT EXISTS entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    domain TEXT NOT NULL,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    tags TEXT DEFAULT '',
    created TEXT DEFAULT (datetime('now','localtime'))
)''')
c.execute('CREATE INDEX IF NOT EXISTS idx_domain ON entries(domain)')
c.execute('CREATE INDEX IF NOT EXISTS idx_tags ON entries(tags)')
conn.commit()

# 迁移记忆中的详细档案(从备份 knowledge/*.md 读入)
KB_SRC = r'D:/Hermes核心迁移备份/knowledge'
if os.path.isdir(KB_SRC):
    for fn in os.listdir(KB_SRC):
        if not fn.endswith('.md'): continue
        p = os.path.join(KB_SRC, fn)
        with open(p, 'r', encoding='utf-8', errors='replace') as f:
            content = f.read()
        domain = fn[:-3]  # 文件名当领域
        # 防重复: 同 domain+title 不重复插
        c.execute('SELECT COUNT(*) FROM entries WHERE domain=? AND title=?', (domain, fn))
        if c.fetchone()[0] == 0:
            c.execute('INSERT INTO entries(domain, title, content, tags) VALUES (?,?,?,?)',
                      (domain, fn, content, 'migrated'))
            print('导入:', domain, '/', fn, f'({len(content)}字符)')
conn.commit()
print('=== 当前条目数:', c.execute('SELECT COUNT(*) FROM entries').fetchone()[0])
conn.close()
