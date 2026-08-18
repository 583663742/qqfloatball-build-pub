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
            qqlog(@"[NSURLSession] %@ %@", request.HTTPMethod ?: @"GET", request.URL.absoluteString ?: @"");
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
// 只放行 ti.qq.com/qqlevel 域 + ptlogin/check_sig 登录链；等级页相关跳转（Kuikly/mqqapi 深链）一律拦
// ⚠️ 收窄条件：仅拦含 qqlevel 上下文的跳转，避免影响 QQ 其他 WebView 功能
static BOOL shouldBlockNav(NSString *url) {
    if (!url || url.length == 0) return NO;
    // 登录链放行
    if ([url containsString:@"ptlogin"] || [url containsString:@"check_sig"]) return NO;
    // 等级页本身放行
    if ([url containsString:@"ti.qq.com"] && [url containsString:@"qqlevel"]) return NO;
    // Kuikly 任务页跳转（club.vip.qq.com/openKuikly + qqlevel 上下文）拦截
    if ([url containsString:@"openKuikly"]) return YES;
    // mqqapi:// 深链（含 qqlevel 上下文）拦截，防止页面跳走
    if ([url hasPrefix:@"mqqapi://"] && [url containsString:@"qqlevel"]) return YES;
    // 其他含 qqlevel 的跳转（如 qzone/vip 域任务落地页）拦截
    if ([url containsString:@"qqlevel"]) return YES;
    return NO;
}

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

// 自动注入领奖脚本：延迟后注入，页面未就绪（about:blank/加载中）则重试
// Qsped 模拟器方案：页面停留网页版后，页面内 JS 同源 fetch TRPC（levelTask/Get + ExecAct），
// cookie 自动带、无插件进程 -3000 死路
%new
- (void)injectAutoClaimWithRetry:(__weak WKWebView *)weakSelf attempt:(int)attempt {
    // attempt==0 表示由外部启动新链；>0 是同一条链的后续重试
    if (attempt == 0) {
        if ([self _qqfb_injectRunning]) {
            qqlog(@"[autoClaim] 已有注入链在跑，跳过重复启动");
            return;
        }
        [self _qqfb_setInjectRunning:YES];
    }
    if (attempt >= 8) {
        qqlog(@"[autoClaim] 重试%d次仍失败，放弃", attempt);
        [self _qqfb_setInjectRunning:NO];
        return;
    }
    int64_t delaySec = (attempt == 0) ? 3.0 : 2.5;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WKWebView *strongSelf = weakSelf;
        if (!strongSelf) {
            qqlog(@"[autoClaim] webview 已释放，终止重试");
            // 注意：此处 self 已释放，关联对象自动清，无需手动 setInjectRunning:NO
            return;
        }
        // 先查当前 URL 是否已就绪（页面停留网页版而非 about:blank）
        [strongSelf evaluateJavaScript:@"location.href" completionHandler:^(id _Nullable r, NSError * _Nullable e) {
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
                // 标记追踪，保证恢复前的清空被拦截
                [ss _qqfb_setTracked:YES];
                // 先恢复，恢复完成后的下一个周期再注入（避免立即重试抢时序）
                NSString *last = [ss _qqfb_lastGoodURL];
                if (!last) last = @"https://ti.qq.com/qqlevel/task-center?version=1&tab=1&source=38";
                [ss loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:last]]];
                // 恢复 + 等待页面加载需要更久，直接 schedule 下一次（保持同一条注入链）
                [ss injectAutoClaimWithRetry:ss attempt:attempt + 1];
                return;
            }
            // 检查是否已在任务页，不是的话标记为未追踪
            if (!isTaskCenterPage(cur)) {
                qqlog(@"[autoClaim] 第%d次：URL非任务页: %@", attempt + 1,
                      cur.length > 120 ? [cur substringToIndex:120] : cur);
                [ss injectAutoClaimWithRetry:ss attempt:attempt + 1];
                return;
            }
            // URL 正常，再看 DOM readyState
            [ss evaluateJavaScript:@"document.readyState" completionHandler:^(id _Nullable rs, NSError * _Nullable rse) {
                WKWebView *ss2 = ss;
                if (!ss2) { [ss _qqfb_setInjectRunning:NO]; return; }
                NSString *ready = [rs isKindOfClass:[NSString class]] ? rs : nil;
                if (!ready || (![ready isEqualToString:@"interactive"] && ![ready isEqualToString:@"complete"])) {
                    qqlog(@"[autoClaim] 第%d次：DOM未就绪 readyState=%@，重试", attempt + 1, ready ?: @"nil");
                    [ss2 injectAutoClaimWithRetry:ss2 attempt:attempt + 1];
                    return;
                }
                [ss2 evaluateJavaScript:autoClaimScript() completionHandler:^(id _Nullable result, NSError * _Nullable error) {
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
                        // 若脚本报 not_level_page（页面又跳走了）或 api_fail，再重试
                        if ([res containsString:@"not_level_page"] || [res containsString:@"api_fail"]) {
                            [ss3 injectAutoClaimWithRetry:ss3 attempt:attempt + 1];
                        } else {
                            // 成功（或脚本执行完毕且未要求重试）→ 结束注入链
                            qqlog(@"[autoClaim] 注入链正常结束");
                            [ss3 _qqfb_setInjectRunning:NO];
                        }
                    }
                }];
            }];
        }];
    });
}

// ── 核心拦截：loadRequest ──
- (WKNavigation *)loadRequest:(NSURLRequest *)request {
    @try {
        NSString *url = request.URL.absoluteString ?: @"";
        BOOL tracked = [self _qqfb_isTracked] || _inTaskCenter;
        if (_captureEnabled) {
            qqlog(@"[WKWebView] loadRequest (tracked=%d): %@", tracked, url);
        }

        // ── 拦截跳转：Kuikly/mqqapi/其他离开等级页的跳转 ──
        if (shouldBlockNav(url)) {
            qqlog(@"[WKWebView] 拦截跳转: %@", url);
            // 不直接 return nil：QQ 内部可能因 nil 导航而状态错乱；改为允许 orig 后立即恢复
            // 但先尝试直接 return nil，若 QQ 有意见再换策略
            if (tracked) {
                // 追踪中的 webview：立即触发恢复，不调用 orig
                [self _qqfb_restoreIfCleared];
                return nil;
            }
        }

        // ── 拦截 about:blank / 空 URL 清空 ──
        BOOL isBlank = (url.length == 0
                        || [url isEqualToString:@"about:blank"]
                        || [url isEqualToString:@"about:blank#"]
                        || [url hasPrefix:@"about:blank?"]);
        if (isBlank && tracked) {
            qqlog(@"[WKWebView] 拦截about:blank清空 -> 恢复任务页");
            // 只在追踪中拦截，避免影响 QQ 其他 webview 的正常空白页
            [self _qqfb_restoreIfCleared];
            return nil;
        }

        // ── 正常请求 → 如果是任务页，打标、记 good URL、启动注入 ──
        if (isTaskCenterPage(url)) {
            [self _qqfb_setTracked:YES];
            [self _qqfb_setLastGoodURL:url];
            _inTaskCenter = YES;
            // 只有当前没有注入链在跑时，才启动新的一条（恢复后的 loadRequest 不会重复启动）
            if (![self _qqfb_injectRunning]) {
                __weak WKWebView *weakSelf = self;
                [self injectAutoClaimWithRetry:weakSelf attempt:0];
            } else {
                qqlog(@"[WKWebView] 已有注入链运行，本次 loadRequest 不重复启动");
            }
            qqlogUI(@"正在打开等级页…");
            if (_logLabel) _logLabel.hidden = NO;
        } else if (tracked && url.length > 0 && ![url hasPrefix:@"about:"]) {
            // 追踪中但跳走了非 blank 页面 → 如果是 qqlevel 域下，仍记 good URL；否则退出追踪
            if ([url containsString:@"qqlevel"]) {
                [self _qqfb_setLastGoodURL:url];
            } else {
                qqlog(@"[WKWebView] 离开任务页，取消追踪: %@", url.length > 120 ? [url substringToIndex:120] : url);
                [self _qqfb_setTracked:NO];
                _inTaskCenter = NO;
            }
        }

        if (_captureEnabled && ([url containsString:@"ti.qq.com"] ||
            [url containsString:@"qqlevel"] ||
            [url containsString:@"tianxuan"])) {
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
        WKWebView *wv = findWKWebViewInView(self.view);
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
            WKWebView *wv = findWKWebViewInView(self.view);
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
            WKWebView *wv = findWKWebViewInView(self.view);
            if (wv) {
                [wv _qqfb_setTracked:YES];
                [wv _qqfb_setLastGoodURL:u];
            }
        } else if (u.length > 0 && ![u containsString:@"qqlevel"]) {
            _inTaskCenter = NO;
            WKWebView *wv = findWKWebViewInView(self.view);
            if (wv) [wv _qqfb_setTracked:NO];
        }
        // 拦截 Kuikly 自动跳转：让页面停留在 ti.qq.com 网页版任务中心（DOM 有按钮，JS 可点）
        // Kuikly 是原生渲染框架，跳转后 webview 变 about:blank，注入脚本永远点不到按钮
        if ([u containsString:@"openKuikly"]) {
            qqlog(@"[QQWebVC] 拦截 Kuikly 跳转: %@", u);
            // 同步让内部 webview 触发恢复
            WKWebView *wv = findWKWebViewInView(self.view);
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
            WKWebView *wv = findWKWebViewInView(self.view);
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
    } @catch (NSException *e) {
        qqlog(@"[pskey] SKEY 异常 %@", e);
    }
}

// ── hook Kuikly 请求模型：抓等级页真实请求 URL/cmd（只读日志）──
%hook QQKuiklyHTTPRequestItem
- (void)setUrl:(NSString *)url {
    if (_captureEnabled) {
        qqlog(@"[kuikly] HTTPRequest url=%@", url);
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
    NSString *status = _captureEnabled ? @"● 抓包中" : @"○ 未抓包";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"悬浮球"
                                                                   message:[NSString stringWithFormat:@"当前状态：%@\n开始后记录网络请求，点球随时停止", status]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    NSString *actionTitle = _captureEnabled ? @"停止抓包" : @"开始抓包";
    [alert addAction:[UIAlertAction actionWithTitle:actionTitle
                                              style:_captureEnabled ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        _captureEnabled = !_captureEnabled;
        qqlog(@"[action] 抓包%@", _captureEnabled ? @"开始" : @"停止");
        if (_captureEnabled) {
            dumpObjCClasses();
            dumpWebKitCookies();
            dumpKeyClassMethods();
            dumpPSKeys();
        }
    }]];
    // 一键做任务：打开等级页 WebView，自动注入领取
    [alert addAction:[UIAlertAction actionWithTitle:@"⚡ 一键做任务"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        qqlog(@"[action] 一键做任务 -> 打开等级页");
        openTaskCenterWebView();
    }]];
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
