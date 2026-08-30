# BUG：注入链死锁（当前唯一卡点）

## 现象（真机日志 qqflog.txt 实证）
```
[action] 一键做任务 -> 打开等级页
[openTaskCenter] 已创建 QQWebViewController
[QQWebVC] viewDidAppear 绑定 webview=NTWKWebView tracked=YES
[QQWebVC] 拦截空URL清空（保持任务页）          ← 拦截全部命中 ✓
[WKWebView] 恢复任务页: https://ti.qq.com/qqlevel/task-center?...
[WKWebView] 拦截about:blank清空 -> 恢复任务页    ← ✓
[WKWebView] 拦截loadHTMLString清空(htmlLen=0) -> 恢复任务页  ← ✓
[WKWebView] 已有注入链运行，本次 loadRequest 不重复启动  ← 卡死在此
[WKWebView] 已有注入链运行，本次 loadRequest 不重复启动  ← 永远重复
```
**关键**：整份日志里 `[autoClaim] 第N次：...` 一行都没有——注入链启动了（injectRunning=YES），
但第一条 `evaluateJavaScript:@"location.href"` 的 completionHandler **永远没有回调**。

## 根因
`injectAutoClaimWithRetry:`（Tweak.xm ~331行）：
1. attempt==0 时置 `injectRunning=YES`
2. dispatch_after 3秒 → `[webview evaluateJavaScript:@"location.href" ...]`
3. QQ 页面被清成 about:blank 后，**NTWKWebView 的 evaluateJavaScript 回调永不触发**
   （QQ 魔改的 WKWebView 在空白页上挂起 JS 执行）
4. 没有任何超时/看门狗 → `injectRunning` 永远是 YES
5. 之后所有 loadRequest 命中 `if (![self _qqfb_injectRunning])` 的 else 分支
   → "已有注入链运行，本次 loadRequest 不重复启动" → **注入链永远无法重启**

## 修复方向（任选，改对就行）
A. **evaluateJavaScript 加超时看门狗**（推荐）：
   每次 evaluateJavaScript 前 dispatch_after 一个 5 秒超时块，若回调未到：
   - `_qqfb_setInjectRunning:NO`
   - 主动 loadRequest 恢复任务页
   - 重新 `injectAutoClaimWithRetry:attempt:0` 重启链
   （注意回调返回后要检查"已超时"标志，避免双重执行）

B. 简化：把注入改为**不依赖 evaluateJavaScript 轮询**——用 WKNavigationDelegate
   `didFinishNavigation:` 触发注入，避免 JS 回调挂起问题。

C. 最小改动：`injectAutoClaimWithRetry` 开头若 `attempt>0 && !injectRunning` 也放行
   （放弃防重入锁），配合恢复任务页逻辑自愈。

## 注意
- 拦截体系本身已全部生效（空URL/ about:blank / loadHTMLString 清空全拦住了），**不要动拦截逻辑**
- 防重入锁 `_qqfb_injectRunning`（关联对象）本身没问题，是"无超时"导致它卡死
- 改完 push 到 GitHub 自动构建，产物 arm64e dylib，装机路径 /var/jb/usr/lib/TweakInject/
