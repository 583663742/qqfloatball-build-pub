# -*- coding: utf-8 -*-
"""把 ios-re 子目录的 md 也导入知识库"""
import sqlite3, os

DB = r'D:/AI_Agent/Hermes_Desktop/data/hermes-home/knowledge.db'
SRC = r'D:/Hermes核心迁移备份/knowledge/ios-re'

conn = sqlite3.connect(DB)
c = conn.cursor()
for fn in os.listdir(SRC):
    if not fn.endswith('.md'): continue
    with open(os.path.join(SRC, fn), 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()
    c.execute('SELECT COUNT(*) FROM entries WHERE domain=? AND title=?', ('ios-re', fn))
    if c.fetchone()[0] == 0:
        c.execute('INSERT INTO entries(domain, title, content, tags) VALUES (?,?,?,?)',
                  ('ios-re', fn, content, 'migrated'))
        print('导入: ios-re/', fn, f'({len(content)}字符)')
conn.commit()
print('总条目:', c.execute('SELECT COUNT(*) FROM entries').fetchone()[0])
conn.close()
