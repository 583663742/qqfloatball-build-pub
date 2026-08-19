# 任务说明（给 AI 编辑器的 README）

## 项目
iOS 越狱插件（theos/Logos，arm64e，注入 QQ com.tencent.mqq）。
悬浮球已正常，卡在「一键做任务」环节。

## 当前问题
点击悬浮球 → 创建 `QQWebViewController` 打开
`https://ti.qq.com/qqlevel/task-center?version=1&tab=1&source=38`
（QQ等级任务中心网页版）→ 页面加载后 **QQ 自动跳转 Kuikly 原生页**
（`club.vip.qq.com/openKuikly/vas_qqvip_account_info_host?enteranceId=qqlevel_task`），
同时把 WebView 清空成 `about:blank`。

## 已 hook（当前代码里已实现，日志确认拦截命中）
- `QQWebViewController setUrl:` —— 拦截 openKuikly 跳转 + 拦截空值清空
- `WKWebView loadRequest:` —— 拦截 about:blank
- `injectAutoClaimWithRetry:` —— 检测到 about:blank 时主动 reload 任务页

**但 WebView 的 `location.href` 仍变成 about:blank，自动领奖 JS 注入不进去。**

## 沙盒日志关键行（Documents/qqflog.txt）
```
[QQWebVC] 拦截 Kuikly 跳转: club.vip.qq.com/openKuikly/vas_qqvip_account_info_host?...
[QQWebVC] 拦截空URL清空（保持任务页）
[autoClaim] 第1次：about:blank，等待页面加载
```

## 已排查方向（不要重复试）
setUrl/loadRequest 都拦了还变 about:blank，怀疑清空走的是**其他路径**：
`loadHTMLString:` / `loadData:` / `_setURL:` / webView 重建 / KVC 等。

## 建议方向
1. 继续找清空入口：hook 更多 WKWebView 方法（loadHTMLString:/loadData:/私有 _setURL: 等），
   或观察 QQWebViewController 内部是否重建了 WKWebView
2. **换思路（备选）**：不依赖 QQ 内置浏览器，自建 WKWebView + 手动注入 cookie：
   - `QQLoginPSKeyManager getLocalKeyOfDomain:uin:keyType:`（keyType=1）可拿 ti 域真实 p_skey
   - TRPC 接口：同源 fetch `levelTask/Get` + `ExecAct` 可领奖
   - 参考实现：拦截离开 ti.qq.com/qqlevel/task-center 的跳转；重试 5 次×3 秒；
     status=2 领奖、status=0 自动点按钮

## 构建约束（勿动这些文件）
- `Makefile`、`QQFloatBall.plist`、`.github/workflows/build.yml`、`sdk/` 不要改
- 只改 `Tweak.xm`
- 构建走 GitHub Actions（macOS theos），push main 分支即自动构建，产物是 arm64e dylib
