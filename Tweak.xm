#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// ── 持有悬浮球窗口和按钮的强引用，防止 ARC 释放 ──
static UIWindow *_floatWindow = nil;
static UIButton *_floatBall = nil;
static UILabel *_logLabel = nil;        // 悬浮球旁的任务日志面板
static NSMutableArray *_logLines = nil; // 最近日志行（UI 显示用）

// ── UI 日志面板：主线程更新悬浮球旁的小黑条 ──
static void qqlogUI(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_logLines) _logLines = [NSMutableArray array];
        [_logLines addObject:msg];
        if (_logLines.count > 6) [_logLines removeObjectAtIndex:0];
        if (_logLabel) {
            _logLabel.text = [_logLines componentsJoinedByString:@"\n"];
        }
    });
}

// ── 抓包开关：YES=记录网络请求；NO=停止 ──
static BOOL _captureEnabled = NO;
// ── 抓包模式：YES=只抓等级/任务关键词；NO=全量抓（排除打点/图片噪声）──
static BOOL _captureOnlyTasks = YES;
// ── 一键任务停止标记：YES=停止当前任务循环；NO=继续 ──
static BOOL _autoStop = NO;
// 标记当前 QQWebViewController 是否停留在等级任务中心页（用于拦截清空/跳走）
static BOOL _inTaskCenter = NO;
// 记录当前任务中心对应的 WKWebView（弱引用指针值，用关联对象更稳妥）
static void *kQQFBTrackedKey = &kQQFBTrackedKey;
static void *kQQFBLastGoodURLKey = &kQQFBLastGoodURLKey;
static void *kQQFBInjectRunningKey = &kQQFBInjectRunningKey;

// ── 网络抓包日志（写入 app 沙盒 Documents，SSH 可读）──
static NSString *qqlogPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/qqflog.txt"];
}

static void qqlog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:qqlogPath()];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:qqlogPath() contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:qqlogPath()];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// ── 异步日志（抓包用）：不阻塞调用线程（NSURLSession 回调/主线程都可能调用）──
static void qqlogAsync(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    // 串行队列保证文件写不竞争（NSFileHandle 非线程安全）
    static dispatch_queue_t logQ = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logQ = dispatch_queue_create("com.qqfloatball.log", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(logQ, ^{
        @try {
            // 日志上限 5MB：超了自动停止抓包（防止日志爆炸拖慢系统）
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:qqlogPath() error:nil];
            NSNumber *sz = attrs[NSFileSize];
            if (sz.longLongValue > 5 * 1024 * 1024) {
                _captureEnabled = NO;
                return;
            }
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:qqlogPath()];
            if (!fh) {
                [[NSFileManager defaultManager] createFileAtPath:qqlogPath() contents:nil attributes:nil];
                fh = [NSFileHandle fileHandleForWritingAtPath:qqlogPath()];
            }
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:[[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
        } @catch (NSException *e) {}
    });
}

// ── 提前声明 %new 方法，供 dispatch_once block 内调用 ──
@interface UIApplication (QQFloatBall)
- (void)_setupFloatBall;
- (void)_floatBallTapped:(UIButton *)sender;
- (void)_floatBallPanned:(UIPanGestureRecognizer *)pan;
@end

%hook UIApplication
- (BOOL)setDelegate:(id)delegate {
    BOOL result = %orig(delegate);

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 等 App 启动完成后再创建悬浮球
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [self _setupFloatBall];
        }];
    });

    return result;
}
%end

// ──────────────────────────────────────────
//  独立悬浮窗口：透明、置顶、只响应球体区域
// ──────────────────────────────────────────
@interface QQFloatBallWindow : UIWindow
@end

@implementation QQFloatBallWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelStatusBar + 1;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.hidden = NO;
    }
    return self;
}

// 只有触摸悬浮球区域才响应，其余一律穿透给 QQ
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (_floatBall && CGRectContainsPoint(_floatBall.frame, point)) {
        return _floatBall;
    }
    return nil;
}

@end

// ──────────────────────────────────────────
//  网络抓包：hook NSURLSession，记录所有请求到日志
// ──────────────────────────────────────────
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    @try {
        if (_captureEnabled) {
            NSString *url = request.URL.absoluteString ?: @"";
            // 抓包 v3：全请求记录（排除打点/静态资源噪声），异步日志不卡界面
            // 噪声排除：report/action 打点、图片/字体/JS/CSS 静态资源、统计上报
            BOOL noise = ([url containsString:@"/report/action"]
                       || [url containsString:@"reportData"]
                       || [url containsString:@"monitor"]
                       || [url containsString:@"mta.qq.com"]
                       || [url containsString:@"beacon.qq.com"]
                       || [url hasSuffix:@".png"] || [url hasSuffix:@".jpg"] || [url hasSuffix:@".jpeg"]
                       || [url hasSuffix:@".gif"] || [url hasSuffix:@".webp"] || [url hasSuffix:@".css"]
                       || [url hasSuffix:@".js"] || [url hasSuffix:@".woff"] || [url hasSuffix:@".woff2"]
                       || [url hasSuffix:@".ttf"] || [url hasSuffix:@".ico"] || [url hasSuffix:@".mp4"]);
            // 等级/任务相关关键词：记录请求+响应（重点）
            BOOL keyTask = ([url containsString:@"qqlevel"]
                          || [url containsString:@"tianxuan"]
                          || [url containsString:@"commdeliver"]
                          || [url containsString:@"levelTask"]
                          || [url containsString:@"ExecAct"]
                          || [url containsString:@"GetUserRecord"]
                          || [url containsString:@"openKuikly"]
                          || [url containsString:@"dengji_task"]
                          || [url containsString:@"task-center"]
                          || [url containsString:@"signin"]);
            if (!noise && (keyTask || !_captureOnlyTasks)) {
                NSString *body = @"";
                if (request.HTTPBody.length > 0) {
                    body = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
                    if (!body) body = [request.HTTPBody description];
                    if (body.length > 500) body = [body substringToIndex:500];
                }
                qqlogAsync(@"[NSURLSession] %@ %@ body=%@", request.HTTPMethod ?: @"GET", url, body);
                // 记录响应：先立即调原 handler（零延迟！），日志异步后台做
                void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
                    if (completionHandler) completionHandler(data, resp, err);  // ← 立即放行，不阻塞页面
                    NSString *u = [url copy];
                    NSData *d = [data copy];
                    NSError *e = err;
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                        @try {
                            if (d.length > 0) {
                                NSString *respStr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                                if (respStr.length > 1000) respStr = [respStr substringToIndex:1000];
                                qqlogAsync(@"[NSURLSession]  ← RESP %@ : %@", u.length > 100 ? [u substringToIndex:100] : u, respStr);
                            } else if (e) {
                                qqlogAsync(@"[NSURLSession]  ← ERR %@ : %@", u.length > 100 ? [u substringToIndex:100] : u, e.localizedDescription);
                            }
                        } @catch (NSException *ex) {}
                    });
                };
                return %orig(request, wrapped);
            }
        }
    } @catch (NSException *e) {}
    return %orig(request, completionHandler);
}

%end

// ── Cookie 枚举：读 WKWebView 的 cookie store（含 httpOnly p_skey）──
static void dumpWebKitCookies(void) {
    @try {
        Class wdsClass = NSClassFromString(@"WKWebsiteDataStore");
        if (!wdsClass) { qqlog(@"[wkCookie] WKWebsiteDataStore 不存在"); return; }
        id defaultStore = ((id (*)(id, SEL))objc_msgSend)(wdsClass, NSSelectorFromString(@"defaultDataStore"));
        if (!defaultStore) { qqlog(@"[wkCookie] defaultDataStore 为空"); return; }
        id cookieStore = ((id (*)(id, SEL))objc_msgSend)(defaultStore, NSSelectorFromString(@"httpCookieStore"));
        if (!cookieStore) { qqlog(@"[wkCookie] httpCookieStore 为空"); return; }
        SEL getAllSel = NSSelectorFromString(@"getAllCookies:");
        void (^handler)(NSArray *) = ^(NSArray *cookies) {
            qqlog(@"[wkCookie] 共 %lu 个 cookie", (unsigned long)cookies.count);
            for (NSHTTPCookie *ck in cookies) {
                NSString *dom = ck.domain ?: @"";
                if ([dom containsString:@"qq.com"] || [dom containsString:@"tencent.com"]) {
                    qqlog(@"[wkCookie] %@  %@=%@", dom, ck.name, ck.value);
                }
            }
        };
        ((void (*)(id, SEL, id))objc_msgSend)(cookieStore, getAllSel, handler);
    } @catch (NSException *e) {
        qqlog(@"[wkCookie] 异常: %@", e);
    }
}

// ── WebView 自动领取脚本（注入式，返回诊断 JSON）──
static NSString *autoClaimScript(void) {
    return @"(function(){"
        "var diag={url:location.href||'',host:location.host||'',path:location.pathname||''};"
        "var inLevelPage=function(){"
        "  var h=location.host||'';var p=location.pathname||'';"
        "  if(h.indexOf('ti.qq.com')>=0&&p.indexOf('qqlevel')>=0)return true;"
        "  if(h.indexOf('club.vip.qq.com')>=0&&p.indexOf('qqlevel')>=0)return true;"
        "  if(p.indexOf('openKuikly')>=0&&diag.url.indexOf('qqlevel')>=0)return true;"
        "  return false;"
        "};"
        "if(!inLevelPage()){"
        "  diag.result='not_level_page';"
        "  return JSON.stringify(diag);"
        "}"
        "if(window._qqAutoClaimRunning){diag.result='already_running';return JSON.stringify(diag);}"
        "window._qqAutoClaimRunning=true;"
        "var api=function(path,data){"
        "  var r=null;"
        "  try{"
        "    r=new XMLHttpRequest();"
        "    r.open('POST','//'+location.host+path,false);"  // 同步同源请求，cookie 自动带
        "    r.setRequestHeader('Content-Type','application/json');"
        "    r.send(JSON.stringify(data));"
        "    return r.status===200&&r.responseText?JSON.parse(r.responseText):null;"
        "  }catch(e){diag.api_err=(diag.api_err||'')+e.message+';';return null;}"
        "};"
        // 1. 拉任务列表（模拟器 Qsped 方案：页面内 fetch TRPC，同源 cookie 无 -3000）
        "var j=api('/qqlevel/trpc/levelTask/Get',{mode:42});"
        "if(!j){diag.result='api_fail';return JSON.stringify(diag);}"
        "var tasks=(j.response&&j.response.task_list)||j.task_list||[];"
        "diag.total=tasks.length;diag.result='started';diag.clicked=0;"
        "var log=function(msg){"
        "  try{"
        "    var d=document.createElement('div');"
        "    d.style.cssText='position:fixed;bottom:10px;left:10px;z-index:999999;background:rgba(0,0,0,0.8);color:#fff;padding:8px 12px;border-radius:6px;font-size:12px;max-width:80%;word-break:break-all;';"
        "    d.textContent='[自动任务] '+msg;"
        "    document.body.appendChild(d);"
        "    setTimeout(function(){try{d.remove()}catch(e){}},3000);"
        "  }catch(e){}"
        "};"
        "log('任务数: '+tasks.length);"
        // 2. 诊断：记录每个任务状态
        "diag.list=[];"
        "for(var i=0;i<tasks.length;i++){"
        "  var t=tasks[i];"
        "  diag.list.push({id:t.task_id,st:t.status,btn:t.button_text||'',award:t.award_rule_id||'',title:(t.title||'').substring(0,12)});"
        "}"
        // 3. status=2 可领取 → ExecAct 领奖（同源 fetch TRPC，页面自身请求不会被拒）
        "var claimed=0,errs=0;"
        "for(var i=0;i<tasks.length;i++){"
        "  var t=tasks[i];"
        "  if(t.status===2&&t.award_rule_id){"
        "    var req=JSON.stringify({sub_act_id:t.award_rule_id,task_id:t.unique_task_id||t.task_id,uid:(window.mqq&&mqq.user&&mqq.user.getUin?String(mqq.user.getUin()):''),business_task_id:t.business_task_id||''});"
        "    var body={SubActId:t.award_rule_id,ClientPlat:'h5',Aid:'',EnteranceId:'',ActReqData:req};"
        "    var rr=api('/qqlevel/tianxuan/trpc/access/ExecAct',body);"
        "    if(rr&&rr.code===0){claimed++;log('已领奖: '+t.title);}"
        "    else{errs++;log('领奖失败: '+t.title+' code='+(rr&&rr.code));}"
        "  }"
        "}"
        "diag.claimed=claimed;diag.errs=errs;"
        // 点击 status=0 待完成任务页面上的『去完成/去打卡/去添加』按钮
        // iOS 任务全是 status=0（button_text: 去完成/去打卡/去添加），按钮在网页版 DOM 里
        "var clicked=0;"
        "var btnKeys=['去完成','去打卡','去添加','去领取','立即领取','领取'];"
        "var all=document.querySelectorAll('button,div,span,a,[class*=\"btn\"],[class*=\"button\"],li');"
        "for(var i=0;i<all.length;i++){"
        "  var el=all[i];"
        "  try{"
        "    var txt=(el.textContent||el.innerText||'').trim();"
        "    for(var k=0;k<btnKeys.length;k++){"
        "      if(txt===btnKeys[k]||txt.indexOf(btnKeys[k])===0){"
        "        el.click();clicked++;"
        "        log('点击按钮: '+txt.substring(0,20));"
        "        break;"
        "      }"
        "    }"
        "  }catch(e){}"
        "}"
        "diag.clicked=clicked;"
        "log('点击 '+clicked+' 个按钮');"
        "diag.final='done';"
        "return JSON.stringify(diag);"
        "})();";
}

// ── 检测 WebView 是否在等级页面（task-center 或 Kuikly 任务页）──
static BOOL isTaskCenterPage(NSString *url) {
    if (!url) return NO;
    // ti.qq.com/qqlevel 是原始等级页；club.vip.qq.com/openKuikly 是自动跳转后的 Kuikly 任务页
    if ([url containsString:@"ti.qq.com"] && [url containsString:@"qqlevel"]) return YES;
    if ([url containsString:@"club.vip.qq.com"] && [url containsString:@"qqlevel"]) return YES;
    if ([url containsString:@"openKuikly"] && [url containsString:@"qqlevel"]) return YES;
    return NO;
}

// 是否该拦截的跳转（模拟器 Qsped 方案：拦截一切离开 task-center 网页版的跳转）
// 阶段2：不再拦截跳转（等级页 = Kuikly 渲染，拦截导致白屏）
// 原 shouldBlockNav 已删除——放行所有导航，让 QQ 自由渲染等级页

// 声明接口让编译器可见（%new 实现只在 runtime 添加，编译期需要 category 声明；必须放 %hook 块外）
@interface WKWebView (QQFBAutoClaim)
- (void)injectAutoClaimWithRetry:(WKWebView *)weakSelf attempt:(int)attempt;
- (BOOL)_qqfb_isTracked;
- (void)_qqfb_setTracked:(BOOL)flag;
- (NSString *)_qqfb_lastGoodURL;
- (void)_qqfb_setLastGoodURL:(NSString *)url;
- (void)_qqfb_restoreIfCleared;
- (BOOL)_qqfb_injectRunning;
- (void)_qqfb_setInjectRunning:(BOOL)flag;
@end

%hook WKWebView

// ── 关联对象辅助：每个 WKWebView 独立追踪自己的状态，避免多 WebView 串扰 ──
%new
- (BOOL)_qqfb_isTracked {
    NSNumber *n = objc_getAssociatedObject(self, kQQFBTrackedKey);
    return n ? n.boolValue : NO;
}
%new
- (void)_qqfb_setTracked:(BOOL)flag {
    objc_setAssociatedObject(self, kQQFBTrackedKey, @(flag), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%new
- (NSString *)_qqfb_lastGoodURL {
    return objc_getAssociatedObject(self, kQQFBLastGoodURLKey);
}
%new
- (void)_qqfb_setLastGoodURL:(NSString *)url {
    objc_setAssociatedObject(self, kQQFBLastGoodURLKey, url, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

// 被追踪的任务页 WebView 若被清空成 about:blank/空 → 异步恢复到上次好的 URL
%new
- (void)_qqfb_restoreIfCleared {
    NSString *last = [self _qqfb_lastGoodURL];
    if (!last || last.length == 0) {
        last = @"https://ti.qq.com/qqlevel/task-center?version=1&tab=1&source=38";
    }
    qqlog(@"[WKWebView] 恢复任务页: %@", last);
    // 异步恢复，避免在当前 load/set 的调用栈里递归触发
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [self loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:last]]];
        } @catch (NSException *e) {
            qqlog(@"[WKWebView] 恢复失败: %@", e);
        }
    });
}

// ── 防重入：每个 WKWebView 同一时刻只跑一条注入重试链 ──
%new
- (BOOL)_qqfb_injectRunning {
    NSNumber *n = objc_getAssociatedObject(self, kQQFBInjectRunningKey);
    return n ? n.boolValue : NO;
}
%new
- (void)_qqfb_setInjectRunning:(BOOL)flag {
    objc_setAssociatedObject(self, kQQFBInjectRunningKey, @(flag), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ═══════════════════════════════════════════════════════════════════
//  【注入链死锁问题 · 完整记录】
//
//  ▸ 现象日志（沙盒 Documents/qqflog.txt 真实出现过）:
//    [WKWebView] 拦截about:blank清空 -> 恢复任务页
//    [WKWebView] 恢复任务页: https://ti.qq.com/qqlevel/task-center?...
//    —— 此后 [autoClaim] 一行都没有，注入链"消失"了。
//    再次点"⚡ 一键做任务" → 日志 [autoClaim] 已有注入链在跑，跳过重复启动
//    结论：injectRunning=YES 死锁，evaluateJavaScript completion 永不回调。
//
//  ▸ 根因分析:
//    QQ 把 WebView 清成 about:blank 有两条路径：① 同步 loadRequest:about:blank（
//    已拦截）；② 先 kill 掉 WebContent 进程 / 重建内部 BackForwardList / 直接
//    走  loadHTMLString:@"" / 或 更底层 _setDocumentURL 等 私有 API。此时
//    WKWebView 对外壳看起来"活着"，但 JS 引擎侧已经失联，evaluateJavaScript 的
//    completion block 既不 success 也不 error，就**永远挂着**。我们的 unlock 逻
//    辑只在 completion 里，于是 injectRunning 关联对象**永久卡死在 YES**。
//
//  ▸ 3 个可选修复方向:
//    ①【本方案采用 · 最轻量】给每层 evaluateJavaScript 加 5s 看门狗（dispatch_after）。
//      看门狗先于 completion 触发就判为"completion 挂死"，强制解锁 + 恢复 + 重启链。
//      为避免"看门狗触发后 completion 又姗姗来迟"的双跑，用 __block BOOL fired 做
//      CAS 式抢占，谁先把 fired=YES 谁就握有推进权。
//    ②【更可靠，但改动大】hook WKWebView setNavigationDelegate: 包一层中间代理，
//      靠 didFinishNavigation / didFailNavigation 来触发注入，天然避开"JS死等"。
//      缺点是 QQ 可能在多个时机换 delegate、自定义子类 QQWKWebView 可能不走通用 setter。
//    ③【兜底补充】在"一键做任务"按钮 handler 加检测：若 injectRunning=YES 但 15s
//      内没任何 [autoClaim] 日志推进，则强制 reset injectRunning=NO（暴力解锁）。
//      实现简单但无法根因修复，只是给用户手点的逃生通道。
//
//  ▸ 注意事项（严格遵守）:
//    ❌ 别改动 WKWebView 层已有的 about:blank / Kuikly / loadHTMLString / loadData
//       拦截逻辑——日志已确认它们命中有效。
//    ❌ 别把 attempt 重启写成 attempt:0 新开链；超时是同一条链内部的"伪推进"，必
//       须走 attempt+1，否则 injectRunning 防重入会被绕开。
//    ✅ 每次超时必须：[1] 解锁 injectRunning=NO [2] setTracked=YES（保证恢复路
//       径拦截生效）[3] _qqfb_restoreIfCleared（或 loadRequest 任务页）[4] 调
//       injectAutoClaimWithRetry: attempt+1（注意必须先解锁，否则 attempt+1 内的
//       上层检查不会新开——但 attempt>0 不走 attempt==0 分支所以没事，安全）。
// ═══════════════════════════════════════════════════════════════════
//  Qsped 模拟器方案：页面停留网页版后，页面内 JS 同源 fetch TRPC（levelTask/Get +
//  ExecAct），cookie 自动带、无插件进程 -3000 死路。
%new
- (void)injectAutoClaimWithRetry:(__weak WKWebView *)weakSelf attempt:(int)attempt {
    // attempt==0 表示由外部启动新链；>0 是同一条链的后续重试
    if (attempt == 0) {
        if ([self _qqfb_injectRunning]) {
            qqlog(@"[autoClaim] 已有注入链在跑，跳过重复启动（若卡死请看门狗/手点按钮重置）");
            return;
        }
        [self _qqfb_setInjectRunning:YES];
    }
    if (attempt >= 10) {
        qqlog(@"[autoClaim] 重试%d次仍失败（看门狗可能已救过多次），彻底放弃", attempt);
        [self _qqfb_setInjectRunning:NO];
        return;
    }
    int64_t delaySec = (attempt == 0) ? 3 : 2;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WKWebView *strongSelf = weakSelf;
        if (!strongSelf) {
            qqlog(@"[autoClaim] webview 已释放，终止重试");
            [weakSelf _qqfb_setInjectRunning:NO];
            return;
        }

        // ───────────────────────────────────────────────────
        //  第 1 层：查 location.href （带 5s 看门狗）
        // ───────────────────────────────────────────────────
        @autoreleasepool {
            __block BOOL fired1 = NO;
            void (^timeout1)(void) = ^{
                if (fired1) return;
                fired1 = YES;  // 看门狗抢到推进权
                qqlog(@"[autoClaim] 第%d次：⚡看门狗超时！第1层location.href回调永不触发，强制解锁+恢复+重启", attempt + 1);
                [strongSelf _qqfb_setInjectRunning:NO];
                [strongSelf _qqfb_setTracked:YES];
                NSString *last = [strongSelf _qqfb_lastGoodURL];
                if (!last) last = @"https://ti.qq.com/qqlevel/task-center?version=1&tab=1&source=38";
                @try {
                    [strongSelf loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:last]]];
                } @catch (NSException *ee) {}
                // 同一条链内部推进：attempt+1
                [strongSelf injectAutoClaimWithRetry:strongSelf attempt:attempt + 1];
            };
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), timeout1);

            [strongSelf evaluateJavaScript:@"location.href" completionHandler:^(id _Nullable r, NSError * _Nullable e) {
                if (fired1) return;  // 看门狗先抢了，别再双跑
                fired1 = YES;
                WKWebView *ss = strongSelf;
                if (!ss) { [weakSelf _qqfb_setInjectRunning:NO]; return; }

                if (e || ![r isKindOfClass:[NSString class]] || [(NSString *)r length] == 0) {
                    qqlog(@"[autoClaim] 第%d次：页面未就绪（%@），重试", attempt + 1, e ? e.localizedDescription : @"空URL");
                    [ss injectAutoClaimWithRetry:ss attempt:attempt + 1];
                    return;
                }
                NSString *cur = (NSString *)r;
                if ([cur isEqualToString:@"about:blank"] || [cur hasPrefix:@"about:"]) {
                    qqlog(@"[autoClaim] 第%d次：about:blank，主动恢复任务页", attempt + 1);
                    [ss _qqfb_setTracked:YES];
                    NSString *last = [ss _qqfb_lastGoodURL];
                    if (!last) last = @"https://ti.qq.com/qqlevel/task-center?version=1&tab=1&source=38";
                    @try {
                        [ss loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:last]]];
                    } @catch (NSException *ee) {}
                    [ss injectAutoClaimWithRetry:ss attempt:attempt + 1];
                    return;
                }
                if (!isTaskCenterPage(cur)) {
                    qqlog(@"[autoClaim] 第%d次：URL非任务页: %@", attempt + 1,
                          cur.length > 120 ? [cur substringToIndex:120] : cur);
                    [ss injectAutoClaimWithRetry:ss attempt:attempt + 1];
                    return;
                }

                // ───────────────────────────────────────────────────
                //  第 2 层：查 document.readyState （带 5s 看门狗）
                // ───────────────────────────────────────────────────
                @autoreleasepool {
                    __block BOOL fired2 = NO;
                    void (^timeout2)(void) = ^{
                        if (fired2) return;
                        fired2 = YES;
                        qqlog(@"[autoClaim] 第%d次：⚡看门狗超时！第2层readyState回调永不触发，强制解锁+恢复+重启", attempt + 1);
                        [ss _qqfb_setInjectRunning:NO];
                        [ss _qqfb_setTracked:YES];
                        NSString *last = [ss _qqfb_lastGoodURL];
                        if (!last) last = @"https://ti.qq.com/qqlevel/task-center?version=1&tab=1&source=38";
                        @try {
                            [ss loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:last]]];
                        } @catch (NSException *ee) {}
                        [ss injectAutoClaimWithRetry:ss attempt:attempt + 1];
                    };
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), timeout2);

                    [ss evaluateJavaScript:@"document.readyState" completionHandler:^(id _Nullable rs, NSError * _Nullable rse) {
                        if (fired2) return;
                        fired2 = YES;
                        WKWebView *ss2 = ss;
                        if (!ss2) { [ss _qqfb_setInjectRunning:NO]; return; }
                        NSString *ready = [rs isKindOfClass:[NSString class]] ? rs : nil;
                        if (!ready || (![ready isEqualToString:@"interactive"] && ![ready isEqualToString:@"complete"])) {
                            qqlog(@"[autoClaim] 第%d次：DOM未就绪 readyState=%@，重试", attempt + 1, ready ?: @"nil");
                            [ss2 injectAutoClaimWithRetry:ss2 attempt:attempt + 1];
                            return;
                        }

                        // ───────────────────────────────────────────────────
                        //  第 3 层：真正注入 autoClaimScript() （带 20s 看门狗）
                        //  脚本内有同步 XHR fetch TRPC 可能耗时稍长，给足 20s
                        // ───────────────────────────────────────────────────
                        @autoreleasepool {
                            __block BOOL fired3 = NO;
                            void (^timeout3)(void) = ^{
                                if (fired3) return;
                                fired3 = YES;
                                qqlog(@"[autoClaim] 第%d次：⚡看门狗超时！第3层领奖脚本执行永不回调（20s），强制解锁+恢复+重启", attempt + 1);
                                [ss2 _qqfb_setInjectRunning:NO];
                                [ss2 _qqfb_setTracked:YES];
                                NSString *last = [ss2 _qqfb_lastGoodURL];
                                if (!last) last = @"https://ti.qq.com/qqlevel/task-center?version=1&tab=1&source=38";
                                @try {
                                    [ss2 loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:last]]];
                                } @catch (NSException *ee) {}
                                [ss2 injectAutoClaimWithRetry:ss2 attempt:attempt + 1];
                            };
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), timeout3);

                            [ss2 evaluateJavaScript:autoClaimScript() completionHandler:^(id _Nullable result, NSError * _Nullable error) {
                                if (fired3) return;
                                fired3 = YES;
                                WKWebView *ss3 = ss2;
                                if (!ss3) { return; }
                                if (error) {
                                    qqlog(@"[autoClaim] 注入失败: %@", error.localizedDescription);
                                    qqlogUI([NSString stringWithFormat:@"注入失败: %@", error.localizedDescription]);
                                    [ss3 injectAutoClaimWithRetry:ss3 attempt:attempt + 1];
                                } else {
                                    NSString *res = result ?: @"";
                                    qqlog(@"[autoClaim] 注入结果: %@", res.length > 500 ? [res substringToIndex:500] : res);
                                    qqlogUI([NSString stringWithFormat:@"自动任务: %@", res.length > 180 ? [res substringToIndex:180] : res]);
                                    if ([res containsString:@"not_level_page"] || [res containsString:@"api_fail"]) {
                                        [ss3 injectAutoClaimWithRetry:ss3 attempt:attempt + 1];
                                    } else {
                                        qqlog(@"[autoClaim] 注入链正常结束");
                                        [ss3 _qqfb_setInjectRunning:NO];
                                    }
                                }
                            }];
                        }
                    }];
                }
            }];
        }
    });
}

// ── 核心拦截：loadRequest（阶段2：放行 Kuikly，不再拦截跳转）──
- (WKNavigation *)loadRequest:(NSURLRequest *)request {
    @try {
        NSString *url = request.URL.absoluteString ?: @"";
        BOOL tracked = [self _qqfb_isTracked] || _inTaskCenter;
        if (_captureEnabled) {
            qqlog(@"[WKWebView] loadRequest (tracked=%d): %@", tracked, url);
        }

        // ── 阶段2：放行所有跳转（Kuikly 正常渲染等级页）──
        // 等级页 = Kuikly 原生渲染，拦截会导致白屏。让 QQ 自由导航，
        // 我们只做追踪标记 + 抓包观察。

        // ── 正常请求 → 如果是任务页/Kuikly 等级页，打标追踪 ──
        BOOL isLevel = isTaskCenterPage(url)
                    || [url containsString:@"qqlevel"]
                    || ([url containsString:@"openKuikly"] && [url containsString:@"qqlevel"])
                    || ([url containsString:@"openKuikly"] && [url containsString:@"vas_qqvip_account_info_host"]);
        if (isLevel) {
            [self _qqfb_setTracked:YES];
            [self _qqfb_setLastGoodURL:url];
            _inTaskCenter = YES;
            qqlogUI(@"正在打开等级页…");
            if (_logLabel) _logLabel.hidden = NO;
        } else if (tracked && url.length > 0 && ![url hasPrefix:@"about:"]) {
            // 追踪中但跳走了 → 退出追踪（放行）
            qqlog(@"[WKWebView] 离开等级页，取消追踪: %@", url.length > 120 ? [url substringToIndex:120] : url);
            [self _qqfb_setTracked:NO];
            _inTaskCenter = NO;
        }

        if (_captureEnabled && ([url containsString:@"ti.qq.com"] ||
            [url containsString:@"qqlevel"] ||
            [url containsString:@"tianxuan"] ||
            [url containsString:@"openKuikly"])) {
            dumpWebKitCookies();
        }
    } @catch (NSException *e) {
        qqlog(@"[WKWebView] loadRequest 异常: %@", e);
    }
    return %orig(request);
}

// ── 额外拦截 1：loadHTMLString（QQ 可能直接塞空 HTML 清空页面）──
- (WKNavigation *)loadHTMLString:(NSString *)string baseURL:(NSURL *)baseURL {
    @try {
        BOOL tracked = [self _qqfb_isTracked] || _inTaskCenter;
        NSString *b = baseURL.absoluteString ?: @"";
        if (tracked) {
            BOOL isEmptyClear = (string.length == 0
                                 || [string isEqualToString:@""]
                                 || [string isEqualToString:@"<html></html>"]
                                 || [string isEqualToString:@"<html><head></head><body></body></html>"]
                                 || (string.length < 50 && [string containsString:@"about:blank"]));
            // baseURL 是 about:blank/空 也视为清空
            BOOL baseIsBlank = (b.length == 0 || [b isEqualToString:@"about:blank"]);
            if (isEmptyClear || baseIsBlank) {
                qqlog(@"[WKWebView] 拦截loadHTMLString清空(htmlLen=%lu base=%@) -> 恢复任务页",
                      (unsigned long)string.length, b.length > 80 ? [b substringToIndex:80] : b);
                [self _qqfb_restoreIfCleared];
                return nil;
            }
            qqlog(@"[WKWebView] loadHTMLString (追踪中，放行): htmlLen=%lu base=%@",
                  (unsigned long)string.length, b.length > 80 ? [b substringToIndex:80] : b);
        } else if (_captureEnabled) {
            qqlog(@"[WKWebView] loadHTMLString: htmlLen=%lu base=%@",
                  (unsigned long)string.length, b.length > 80 ? [b substringToIndex:80] : b);
        }
    } @catch (NSException *e) {}
    return %orig(string, baseURL);
}

// ── 额外拦截 2：loadData（QQ 若直接塞空 data 清空页面）──
- (WKNavigation *)loadData:(NSData *)data
                  MIMEType:(NSString *)MIMEType
    characterEncodingName:(NSString *)characterEncodingName
                  baseURL:(NSURL *)baseURL {
    @try {
        BOOL tracked = [self _qqfb_isTracked] || _inTaskCenter;
        NSString *b = baseURL.absoluteString ?: @"";
        if (tracked) {
            BOOL baseIsBlank = (b.length == 0 || [b isEqualToString:@"about:blank"]);
            BOOL emptyData = (data.length == 0 || data.length < 4);
            if (emptyData || baseIsBlank) {
                qqlog(@"[WKWebView] 拦截loadData清空(dataLen=%lu base=%@) -> 恢复任务页",
                      (unsigned long)data.length, b.length > 80 ? [b substringToIndex:80] : b);
                [self _qqfb_restoreIfCleared];
                return nil;
            }
            qqlog(@"[WKWebView] loadData (追踪中，放行): dataLen=%lu mime=%@ base=%@",
                  (unsigned long)data.length, MIMEType, b.length > 80 ? [b substringToIndex:80] : b);
        } else if (_captureEnabled) {
            qqlog(@"[WKWebView] loadData: dataLen=%lu mime=%@ base=%@",
                  (unsigned long)data.length, MIMEType, b.length > 80 ? [b substringToIndex:80] : b);
        }
    } @catch (NSException *e) {}
    return %orig(data, MIMEType, characterEncodingName, baseURL);
}

// hook evaluateJavaScript 记录
- (void)evaluateJavaScript:(NSString *)script completionHandler:(void (^)(id, NSError *))completionHandler {
    @try {
        if (_captureEnabled && [script length] > 0 && [script length] < 200) {
            qqlog(@"[WKWebView] eval: %@", [script substringToIndex:MIN(100, script.length)]);
        }
    } @catch (NSException *e) {}
    return %orig(script, completionHandler);
}

%end

// 递归在 view 树里找 WKWebView（含 QQ 自定义子类 QQWKWebView 等）
static WKWebView *findWKWebViewInView(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:[WKWebView class]]) return (WKWebView *)v;
    for (UIView *sv in v.subviews) {
        WKWebView *found = findWKWebViewInView(sv);
        if (found) return found;
    }
    return nil;
}

// ── 复用 QQ 内置浏览器：QQWebViewController hook ──
%hook QQWebViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    @try {
        // viewDidAppear 时 view 树已建立，此时找 webview 打标最可靠
        WKWebView *wv = findWKWebViewInView([(id)self valueForKey:@"view"]);
        if (wv && _inTaskCenter) {
            [wv _qqfb_setTracked:YES];
            if (![wv _qqfb_lastGoodURL]) {
                [wv _qqfb_setLastGoodURL:@"https://ti.qq.com/qqlevel/task-center?version=1&tab=1&source=38"];
            }
            qqlog(@"[QQWebVC] viewDidAppear 绑定 webview=%@ tracked=YES", NSStringFromClass([wv class]));
        }
    } @catch (NSException *e) {
        qqlog(@"[QQWebVC] viewDidAppear 异常: %@", e);
    }
}

- (void)loadRequest:(NSURLRequest *)request {
    @try {
        NSString *url = request.URL.absoluteString ?: @"";
        qqlog(@"[QQWebVC] loadRequest: %@", url);
        // 如果是任务页 URL，提前尝试找内部 webview 打标
        if (isTaskCenterPage(url)) {
            _inTaskCenter = YES;
            WKWebView *wv = findWKWebViewInView([(id)self valueForKey:@"view"]);
            if (wv) {
                [wv _qqfb_setTracked:YES];
                [wv _qqfb_setLastGoodURL:url];
                qqlog(@"[QQWebVC] loadRequest 提前绑定 webview=%@", NSStringFromClass([wv class]));
            }
        }
        // 注意：不在 loadRequest 里注入脚本！
        // 页面跳转到 Kuikly 页/控制器释放后 dispatch_after 里的 self 会悬垂 → 闪退
        // 注入统一走 WKWebView loadRequest hook（自动注入）
    } @catch (NSException *e) {}
    %orig(request);
}

- (void)setUrl:(NSString *)url {
    @try {
        NSString *u = url ?: @"";
        // 更新任务页状态：加载 task-center 时置 YES，跳走到别的页面时置 NO
        if (isTaskCenterPage(u)) {
            _inTaskCenter = YES;
            // 同步内部 webview 打标
            WKWebView *wv = findWKWebViewInView([(id)self valueForKey:@"view"]);
            if (wv) {
                [wv _qqfb_setTracked:YES];
                [wv _qqfb_setLastGoodURL:u];
            }
        } else if (u.length > 0 && ![u containsString:@"qqlevel"]) {
            _inTaskCenter = NO;
            WKWebView *wv = findWKWebViewInView([(id)self valueForKey:@"view"]);
            if (wv) [wv _qqfb_setTracked:NO];
        }
        // 拦截 Kuikly 自动跳转：让页面停留在 ti.qq.com 网页版任务中心（DOM 有按钮，JS 可点）
        // Kuikly 是原生渲染框架，跳转后 webview 变 about:blank，注入脚本永远点不到按钮
        if ([u containsString:@"openKuikly"]) {
            qqlog(@"[QQWebVC] 拦截 Kuikly 跳转: %@", u);
            // 同步让内部 webview 触发恢复
            WKWebView *wv = findWKWebViewInView([(id)self valueForKey:@"view"]);
            if (wv) {
                [wv _qqfb_setTracked:YES];
                [wv _qqfb_restoreIfCleared];
            }
            return;
        }
        // 拦截空 URL 清空：QQ 跳转 Kuikly 前先把页面 setUrl 成空串清空 → 变 about:blank
        // 当前在任务页时，任何清空动作都拦截，保持网页版任务中心
        if (u.length == 0 && _inTaskCenter) {
            qqlog(@"[QQWebVC] 拦截空URL清空（保持任务页）");
            WKWebView *wv = findWKWebViewInView([(id)self valueForKey:@"view"]);
            if (wv) {
                [wv _qqfb_setTracked:YES];
                [wv _qqfb_restoreIfCleared];
            }
            return;
        }
        qqlog(@"[QQWebVC] setUrl: %@", u);
    } @catch (NSException *e) {}
    return %orig(url);
}

%end

// ── 枚举 ObjC 类（找网络桥接类，只读安全）──
static void dumpObjCClasses(void) {
    @try {
        int total = objc_getClassList(NULL, 0);
        Class *classes = (Class *)malloc(sizeof(Class) * total);
        objc_getClassList(classes, total);
        NSMutableArray *hits = [NSMutableArray array];
        NSArray *keywords = @[@"http", @"Http", @"HTTP", @"Network", @"network", @"Request", @"request", @"Kuikly", @"kuikly", @"KRView", @"TBS", @"WebView", @"Cookie", @"cookie", @"Login", @"login", @"Session", @"session", @"Wup", @"wup", @"tiqq", @"levelTask", @"Level"];
        for (int i = 0; i < total; i++) {
            const char *name = class_getName(classes[i]);
            if (!name) continue;
            NSString *ns = [NSString stringWithUTF8String:name];
            for (NSString *kw in keywords) {
                if ([ns containsString:kw]) {
                    [hits addObject:ns];
                    break;
                }
            }
        }
        free(classes);
        qqlog(@"[classes] 总类数 %d, 命中 %lu", total, (unsigned long)hits.count);
        [hits sortUsingSelector:@selector(compare:)];
        for (NSString *h in hits) {
            qqlog(@"[class] %@", h);
        }
    } @catch (NSException *e) {
        qqlog(@"[classes] 异常: %@", e);
    }
}

// ── 直接调用 QQLoginPSKeyManager 拿 p_skey（免登录核心）──
static void dumpPSKeys(void) {
    Class mgrCls = NSClassFromString(@"QQLoginPSKeyManager");
    if (!mgrCls) { qqlog(@"[pskey] QQLoginPSKeyManager 不存在"); return; }
    id mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, NSSelectorFromString(@"sharedInstance"));
    if (!mgr) { qqlog(@"[pskey] sharedInstance 为空"); return; }

    NSArray *domains = @[@"ti.qq.com", @"qun.qq.com", @"vip.qq.com", @"qzone.qq.com"];
    NSArray *uins = @[@"583663742", @"820284286", @"1172628163"];

    SEL sel = NSSelectorFromString(@"getLocalKeyOfDomain:uin:keyType:");
    NSMethodSignature *sig = [mgr methodSignatureForSelector:sel];
    if (!sig) { qqlog(@"[pskey] 无 getLocalKeyOfDomain:uin:keyType: 签名"); return; }

    for (NSString *d in domains) {
        for (NSString *u in uins) {
            for (int kt = 0; kt <= 2; kt++) {
                @try {
                    __unsafe_unretained NSString *dArg = d;
                    __unsafe_unretained NSString *uArg = u;
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:mgr];
                    [inv setSelector:sel];
                    [inv setArgument:&dArg atIndex:2];
                    [inv setArgument:&uArg atIndex:3];
                    NSInteger ktV = kt;
                    [inv setArgument:&ktV atIndex:4];
                    [inv invoke];
                    __unsafe_unretained id ret = nil;
                    [inv getReturnValue:&ret];
                    if (ret) {
                        qqlog(@"[pskey] domain=%@ uin=%@ keyType=%d -> %@", d, u, kt, ret);
                    }
                } @catch (NSException *e) {
                    qqlog(@"[pskey] %@ uin%@ kt%d 异常 %@", d, u, kt, e);
                }
            }
        }
    }

    // skey
    @try {
        id skey = ((id (*)(id, SEL))objc_msgSend)(mgr, NSSelectorFromString(@"getRealSig_SKEYStr"));
        if (skey) qqlog(@"[pskey] SKEY = %@", skey);

        // ── bkn 计算（标准算法：skey 逐字符 hash）──
        // 只有 skey 非空才计算，否则无意义
        NSString *s = [skey isKindOfClass:[NSString class]] ? skey : nil;
        if (s.length > 0) {
            unsigned int hashV = 5381;
            for (NSUInteger i = 0; i < s.length; i++) {
                hashV = hashV + ((hashV << 5) & 0x7FFFFFFF) + [s characterAtIndex:i];
            }
            int bkn = hashV & 0x7FFFFFFF;
            qqlog(@"[pskey] BKN = %d (skey长度=%lu)", bkn, (unsigned long)s.length);
        } else {
            qqlog(@"[pskey] SKEY 为空，跳过 bkn 计算");
        }
    } @catch (NSException *e) {
        qqlog(@"[pskey] SKEY 异常 %@", e);
    }
}

// ── hook Kuikly 请求模型：抓等级页真实请求 URL/cmd/body（只读日志）──
%hook QQKuiklyHTTPRequestItem
- (void)setUrl:(NSString *)url {
    if (_captureEnabled) {
        // 也读 body（QQKuiklyBaseRequestItem 的属性，forward declaration 用 objc_msgSend 避免编译错误）
        NSString *body = @"";
        @try {
            id b = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"body"));
            if ([b isKindOfClass:[NSString class]]) body = (NSString *)b;
            else if ([b isKindOfClass:[NSDictionary class]]) {
                NSData *jd = [NSJSONSerialization dataWithJSONObject:b options:0 error:nil];
                if (jd) body = [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding];
            }
            if (body.length > 300) body = [body substringToIndex:300];
        } @catch (NSException *e) {}
        qqlog(@"[kuikly] HTTPRequest url=%@ body=%@", url, body);
    }
    %orig;
}
%end

%hook QQKuiklySSORequestItem
- (void)setCmd:(NSString *)cmd {
    if (_captureEnabled) {
        qqlog(@"[kuikly] SSORequest cmd=%@", cmd);
    }
    %orig;
}
%end


static void dumpKeyClassMethods(void) {
    NSArray *keyClasses = @[
        @"QQLoginPSKeyManager", @"QQLoginPSKeyDataSource", @"QQLoginPSKeyRefreshItem",
        @"QQKuiklyHTTPRequestItem", @"QQKuiklySSORequestItem", @"QQKuiklyBaseRequestItem",
        @"QQWebSSoSession", @"QQHttpClient", @"QQHttpClientSession", @"QQHttpClientSessionWrapper",
        @"QQNetworkEngine", @"QQCRHttpRequest", @"QQWTLogin", @"QQLoginAccountKeyChainModel",
        @"QQModelObject_tencent_im_oidb_lib_LoginSig", @"QQNetworkCommonImp",
        @"QQWebViewController", @"QQWebView", @"QQWKWebView", @"QQWebViewUtils", @"QQWebViewPool",
        @"QQWebViewPluginBase", @"QQWebViewBussinessPluginBase",
    ];
    for (NSString *cn in keyClasses) {
        Class cls = NSClassFromString(cn);
        if (!cls) {
            qqlog(@"[method] %@ 不存在", cn);
            continue;
        }
        qqlog(@"[method] ==== %@ ====", cn);
        // 类方法
        unsigned int mc = 0;
        Method *mets = class_copyMethodList(object_getClass(cls), &mc);
        for (unsigned int i = 0; i < mc; i++) {
            qqlog(@"[method] +[%@ %@]", cn, NSStringFromSelector(method_getName(mets[i])));
        }
        free(mets);
        // 实例方法
        unsigned int ic = 0;
        Method *imets = class_copyMethodList(cls, &ic);
        for (unsigned int i = 0; i < ic; i++) {
            qqlog(@"[method] -[%@ %@]", cn, NSStringFromSelector(method_getName(imets[i])));
        }
        free(imets);
    }
}

%hook UIApplication

// ──────────────────────────────────────────
//  创建悬浮球
// ──────────────────────────────────────────
%new
- (void)_setupFloatBall {
    // 避免重复创建
    if (_floatBall) return;

    // ── 找活跃的 windowScene ──
    UIWindowScene *targetScene = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState == UISceneActivationStateForegroundActive) {
                targetScene = ws;
                break;
            }
        }
    }
    if (!targetScene) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                targetScene = (UIWindowScene *)scene;
                break;
            }
        }
    }
    if (!targetScene) return;

    // ── 创建独立窗口（强引用持有，避免被释放）──
    CGRect screenBounds = targetScene.screen.bounds;
    QQFloatBallWindow *floatWindow = [[QQFloatBallWindow alloc] initWithFrame:screenBounds];
    floatWindow.rootViewController = [UIViewController new];

    // ── 悬浮按钮 ──
    CGFloat ballSize = 45.0;
    UIButton *ball = [UIButton buttonWithType:UIButtonTypeCustom];
    ball.frame = CGRectMake(screenBounds.size.width - ballSize - 8,
                             screenBounds.size.height / 2.0 - ballSize / 2.0,
                             ballSize, ballSize);
    ball.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    ball.layer.cornerRadius = ballSize / 2.0;
    ball.layer.masksToBounds = YES;
    ball.alpha = 0.85;
    [ball setTitle:@"球" forState:UIControlStateNormal];
    ball.titleLabel.font = [UIFont systemFontOfSize:14];
    [ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    // 保持强引用（static 变量持有）
    _floatBall = ball;
    _floatWindow = floatWindow;

    // ── 点击 → 弹窗 ──
    [ball addTarget:self
             action:@selector(_floatBallTapped:)
   forControlEvents:UIControlEventTouchUpInside];

    // ── 拖拽 ──
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(_floatBallPanned:)];
    [ball addGestureRecognizer:pan];

    [floatWindow addSubview:ball];

    // ── 任务日志面板（悬浮球下方小黑条，实时显示任务进度）──
    UILabel *logLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, screenBounds.size.height - 140, screenBounds.size.width - 16, 120)];
    logLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    logLabel.textColor = [UIColor whiteColor];
    logLabel.font = [UIFont systemFontOfSize:11];
    logLabel.numberOfLines = 0;
    logLabel.textAlignment = NSTextAlignmentLeft;
    logLabel.layer.cornerRadius = 8;
    logLabel.layer.masksToBounds = YES;
    logLabel.hidden = YES;  // 默认隐藏，做任务时显示
    _logLabel = logLabel;
    [floatWindow addSubview:logLabel];

    floatWindow.hidden = NO;
}

// ── 打开等级页面 WebView（带自动注入领取脚本）──
static void openTaskCenterWebView(void) {
    @try {
        // 提前打标，保证打开流程中任何 QQ 内部清空/跳转都能被及时拦截
        _inTaskCenter = YES;
        qqlogUI(@"正在打开等级页…");
        if (_logLabel) _logLabel.hidden = NO;

        Class cls = NSClassFromString(@"QQWebViewController");
        if (!cls) { qqlog(@"[openTaskCenter] QQWebViewController 不存在"); _inTaskCenter = NO; return; }
        NSString *urlStr = @"https://ti.qq.com/qqlevel/task-center?version=1&tab=1&source=38";

        id vc = nil;
        // 方案1：initWith:forStyle:
        SEL initSel = NSSelectorFromString(@"initWith:forStyle:");
        NSMethodSignature *sig = [cls instanceMethodSignatureForSelector:initSel];
        if (sig && [sig numberOfArguments] >= 4) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            id alloc = [cls alloc];
            [inv setTarget:alloc];
            [inv setSelector:initSel];
            __unsafe_unretained NSString *urlArg = urlStr;
            [inv setArgument:&urlArg atIndex:2];
            const char *t3 = [sig getArgumentTypeAtIndex:3];
            qqlog(@"[openTaskCenter] initWith:forStyle: arg3 type=%s", t3);
            if (t3[0] == '@') {
                __unsafe_unretained id styleArg = @(0);
                [inv setArgument:&styleArg atIndex:3];
            } else {
                NSInteger style = 0;
                [inv setArgument:&style atIndex:3];
            }
            [inv invoke];
            __unsafe_unretained id ret = nil;
            [inv getReturnValue:&ret];
            vc = ret;
        }
        // 方案2：兜底尝试 initWithURL: 或通用 init + setUrl
        if (!vc) {
            SEL altSel = NSSelectorFromString(@"initWithURL:");
            NSMethodSignature *altSig = [cls instanceMethodSignatureForSelector:altSel];
            if (altSig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:altSig];
                id alloc = [cls alloc];
                [inv setTarget:alloc];
                [inv setSelector:altSel];
                __unsafe_unretained NSString *urlArg = urlStr;
                [inv setArgument:&urlArg atIndex:2];
                [inv invoke];
                __unsafe_unretained id ret = nil;
                [inv getReturnValue:&ret];
                vc = ret;
                qqlog(@"[openTaskCenter] 兜底 initWithURL: 创建%@", vc ? @"成功" : @"失败");
            }
        }
        if (!vc) {
            qqlog(@"[openTaskCenter] 创建 QQWebViewController 失败");
            _inTaskCenter = NO;
            return;
        }
        qqlog(@"[openTaskCenter] 已创建 QQWebViewController: %@", vc);

        // push 到 QQ 根导航（QQ 的 tabBar 内）
        BOOL pushed = NO;
        SEL rootSel = NSSelectorFromString(@"rootTabBarController");
        if ([cls respondsToSelector:rootSel]) {
            @try {
                id tabBar = ((id (*)(id, SEL))objc_msgSend)(cls, rootSel);
                if ([tabBar respondsToSelector:NSSelectorFromString(@"selectedViewController")]) {
                    id selVC = [tabBar selectedViewController];
                    if ([selVC isKindOfClass:[UINavigationController class]]) {
                        [(UINavigationController *)selVC pushViewController:(UIViewController *)vc animated:YES];
                        qqlog(@"[openTaskCenter] push 到 QQ 导航成功");
                        pushed = YES;
                    }
                }
            } @catch (NSException *e2) {
                qqlog(@"[openTaskCenter] rootTabBarController push 异常: %@", e2);
            }
        }
        if (!pushed) {
            // 兜底：悬浮窗 present
            UIViewController *presenter = _floatWindow.rootViewController;
            if (presenter) {
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:(UIViewController *)vc];
                [presenter presentViewController:nav animated:YES completion:^{
                    qqlog(@"[openTaskCenter] present 兜底完成");
                }];
                pushed = YES;
            }
        }
        if (!pushed) {
            // 最后兜底：找活跃 scene 的最顶层 VC present
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *ws = (UIWindowScene *)scene;
                    if (ws.activationState == UISceneActivationStateForegroundActive) {
                        UIViewController *topVC = ws.windows.firstObject.rootViewController;
                        while (topVC.presentedViewController) topVC = topVC.presentedViewController;
                        if (topVC) {
                            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:(UIViewController *)vc];
                            [topVC presentViewController:nav animated:YES completion:nil];
                            qqlog(@"[openTaskCenter] scene 顶层 VC present 兜底");
                            pushed = YES;
                            break;
                        }
                    }
                }
            }
        }
        if (!pushed) {
            qqlog(@"[openTaskCenter] 所有 push/present 方案失败");
            _inTaskCenter = NO;
        }
    } @catch (NSException *e) {
        qqlog(@"[openTaskCenter] 异常: %@", e);
        _inTaskCenter = NO;
    }
}

// ──────────────────────────────────────────
//  点击弹窗（开始/停止抓包入口）
// ──────────────────────────────────────────
%new
- (void)_floatBallTapped:(UIButton *)sender {
    NSString *status = @"○ 未抓包";
    if (_captureEnabled && !_captureOnlyTasks) status = @"● 全量抓包中";
    else if (_captureEnabled && _captureOnlyTasks) status = @"● 等级抓包中";
    // ── 扫描所有 scene/window 找任意 webview 的锁状态，给用户直观提示 ──
    NSMutableString *lockedInfo = [NSMutableString string];
    NSInteger lockedCount = 0;
    @try {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in [(UIWindowScene *)scene windows]) {
                WKWebView *wvFound = findWKWebViewInView(win);
                if (wvFound && [wvFound _qqfb_injectRunning]) {
                    lockedCount++;
                    [lockedInfo appendFormat:@"  · %@ 锁死\n", NSStringFromClass([wvFound class])];
                }
            }
        }
    } @catch (NSException *e) {}
    NSString *msg;
    if (lockedCount > 0) {
        msg = [NSString stringWithFormat:@"当前状态：%@\n开始后记录网络请求，点球随时停止\n\n⚠️ 检测到 %ld 个 WebView 注入死锁！\n%@点 🔧 强制解锁 可恢复",
               status, (long)lockedCount, lockedInfo];
    } else {
        msg = [NSString stringWithFormat:@"当前状态：%@\n开始后记录网络请求，点球随时停止", status];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"悬浮球"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    // ── 抓包双按钮：全量抓包 / 等级抓包（点同一按钮 = 开启/停止，标题实时显示状态）──
    NSString *fullTitle = _captureEnabled && !_captureOnlyTasks ? @"📡 全量抓包（进行中）" : @"📡 全量抓包";
    NSString *taskTitle = _captureEnabled && _captureOnlyTasks ? @"🎯 等级抓包（进行中）" : @"🎯 等级抓包";
    [alert addAction:[UIAlertAction actionWithTitle:fullTitle
                                              style:(_captureEnabled && !_captureOnlyTasks) ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        if (_captureEnabled && !_captureOnlyTasks) {
            // 已是全量抓包中 → 停止
            _captureEnabled = NO;
            qqlog(@"[action] 全量抓包 停止");
            qqlogUI(@"已停止全量抓包");
        } else {
            // 开启全量抓包
            _captureEnabled = YES;
            _captureOnlyTasks = NO;
            qqlog(@"[action] 全量抓包 开始");
            qqlogUI(@"已开启全量抓包（做任务的所有请求都会记录）");
            if (_captureEnabled) {
                dumpObjCClasses();
                dumpWebKitCookies();
                dumpKeyClassMethods();
                dumpPSKeys();
            }
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:taskTitle
                                              style:(_captureEnabled && _captureOnlyTasks) ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        if (_captureEnabled && _captureOnlyTasks) {
            // 已是等级抓包中 → 停止
            _captureEnabled = NO;
            qqlog(@"[action] 等级抓包 停止");
            qqlogUI(@"已停止等级抓包");
        } else {
            // 开启等级抓包
            _captureEnabled = YES;
            _captureOnlyTasks = YES;
            qqlog(@"[action] 等级抓包 开始");
            qqlogUI(@"已开启等级抓包（只记录等级任务相关请求）");
            if (_captureEnabled) {
                dumpObjCClasses();
                dumpWebKitCookies();
                dumpKeyClassMethods();
                dumpPSKeys();
            }
        }
    }]];
    // 一键做任务（阶段1：先探测三件套，再走原 WebView 逻辑）
    [alert addAction:[UIAlertAction actionWithTitle:@"⚡ 一键做任务"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        qqlog(@"[action] 一键做任务 -> 探测三件套 + 打开等级页");
        _autoStop = NO;
        dumpPSKeys();
        openTaskCenterWebView();
    }]];
    // 停止任务（阶段2：置停止标记，任务循环检测到后立即停止）
    [alert addAction:[UIAlertAction actionWithTitle:@"⏹ 停止任务"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        _autoStop = YES;
        qqlog(@"[action] ⏹ 停止任务（标记已置位，任务循环将在下一轮检测到并停止）");
        qqlogUI(@"已请求停止任务…");
    }]];
    // 手动兜底：方向③ —— 暴力解锁所有 WKWebView 的 injectRunning / Tracked 以及全局状态
    if (lockedCount > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:@"🔧 强制解锁死锁"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *action) {
            NSInteger unlocked = 0;
            @try {
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                    for (UIWindow *win in [(UIWindowScene *)scene windows]) {
                        // 递归扫整个 window 视图树（含 present 的 VC.view）
                        WKWebView *wv = nil;
                        NSMutableArray *queue = [NSMutableArray arrayWithObject:win];
                        while (queue.count > 0 && !wv) {
                            UIView *cur = queue.firstObject;
                            [queue removeObjectAtIndex:0];
                            if ([cur isKindOfClass:[WKWebView class]]) {
                                wv = (WKWebView *)cur;
                            } else {
                                [queue addObjectsFromArray:cur.subviews];
                            }
                        }
                        // 也扫描 presented VC 的 view
                        UIViewController *topVC = win.rootViewController;
                        while (topVC.presentedViewController) topVC = topVC.presentedViewController;
                        if (!wv && topVC.view) wv = findWKWebViewInView(topVC.view);

                        if (wv) {
                            if ([wv _qqfb_injectRunning]) unlocked++;
                            [wv _qqfb_setInjectRunning:NO];
                            [wv _qqfb_setTracked:NO];
                        }
                    }
                }
            } @catch (NSException *e) {
                qqlog(@"[action] 强制解锁异常: %@", e);
            }
            _inTaskCenter = NO;
            qqlog(@"[action] 🔧 强制解锁完成，共解锁 %ld 个死锁 webview", (long)unlocked);
            qqlogUI([NSString stringWithFormat:@"已解锁 %ld 个死锁，可重试一键任务", (long)unlocked]);
            if (_logLabel) _logLabel.hidden = NO;
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // 优先从悬浮窗自己的 rootViewController 弹出（不干扰 QQ 页面）
    UIViewController *presenter = _floatWindow.rootViewController;
    if (presenter && !presenter.presentedViewController) {
        [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }

    // 兜底：取活跃 scene 的 rootVC
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState == UISceneActivationStateForegroundActive) {
                UIViewController *rootVC = ws.windows.firstObject.rootViewController;
                if (rootVC) {
                    [rootVC presentViewController:alert animated:YES completion:nil];
                    return;
                }
            }
        }
    }
}

// ──────────────────────────────────────────
//  拖拽（限制不超出屏幕）
// ──────────────────────────────────────────
%new
- (void)_floatBallPanned:(UIPanGestureRecognizer *)pan {
    UIView *ball = pan.view;
    CGPoint translation = [pan translationInView:ball.superview];
    CGPoint center = ball.center;

    if (pan.state == UIGestureRecognizerStateChanged) {
        CGFloat newX = center.x + translation.x;
        CGFloat newY = center.y + translation.y;

        CGFloat halfW = ball.bounds.size.width  / 2.0;
        CGFloat halfH = ball.bounds.size.height / 2.0;
        CGFloat minX = halfW;
        CGFloat maxX = ball.superview.bounds.size.width  - halfW;
        CGFloat minY = halfH;
        CGFloat maxY = ball.superview.bounds.size.height - halfH;

        newX = MAX(minX, MIN(maxX, newX));
        newY = MAX(minY, MIN(maxY, newY));

        ball.center = CGPointMake(newX, newY);
        [pan setTranslation:CGPointZero inView:ball.superview];
    }
}
%end

// ── 构造器：dylib 加载即重试创建悬浮球（不依赖 setDelegate hook）──
__attribute__((constructor))
static void qqfloatball_ctor(void) {
    // GCD 异步重试：QQ 冷启动时 scene 可能几秒内还没就绪，绝不阻塞主线程
    __block int remaining = 15;
    void (^ __block trySetup)(void);
    trySetup = [^void(void) {
        @autoreleasepool {
            if (_floatBall || remaining <= 0) {
                trySetup = nil;
                return;
            }
            remaining--;
            UIApplication *app = [UIApplication sharedApplication];
            if (app && [app respondsToSelector:@selector(_setupFloatBall)]) {
                [app _setupFloatBall];
            }
            if (!_floatBall && remaining > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (trySetup) trySetup();
                });
            } else {
                trySetup = nil;
            }
        }
    } copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        trySetup();
    });
}
