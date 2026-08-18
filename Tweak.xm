#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>

// ── 持有悬浮球窗口和按钮的强引用，防止 ARC 释放 ──
static UIWindow *_floatWindow = nil;
static UIButton *_floatBall = nil;

// ── 抓包开关：YES=记录网络请求；NO=停止 ──
static BOOL _captureEnabled = NO;

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

// ── WebView 自动领取脚本（注入式）──
static NSString *autoClaimScript(void) {
    return @"(function(){"
        "if(window._qqAutoClaimRunning)return;"
        "window._qqAutoClaimRunning=true;"
        "var clicked=0,total=0;"
        "var log=function(msg){"
        "  var d=document.createElement('div');"
        "  d.style.cssText='position:fixed;bottom:10px;left:10px;z-index:999999;background:rgba(0,0,0,0.8);color:#fff;padding:8px 12px;border-radius:6px;font-size:12px;max-width:80%;word-break:break-all;';"
        "  d.textContent='[自动任务] '+msg;"
        "  document.body.appendChild(d);"
        "  setTimeout(function(){d.remove()},3000);"
        "};"
        "var findAndClick=function(){"
        "  var btns=document.querySelectorAll('button,div,span,a,[class*=\"btn\"],[class*=\"button\"]');"
        "  var c=0;"
        "  for(var i=0;i<btns.length;i++){"
        "    var el=btns[i];"
        "    var txt=(el.textContent||el.innerText||'');"
        "    if(txt.indexOf('领取')>=0||txt.indexOf('去完成')>=0||txt.indexOf('去做')>=0){"
        "      el.click();c++;clicked++;"
        "      log('点击: '+txt.trim()+' (第'+clicked+'个)');"
        "    }"
        "  }"
        "  return c;"
        "};"
        "var run=function(){"
        "  var c=findAndClick();"
        "  if(c===0&&clicked===0){"
        "    log('未找到可领取任务，2秒后重试...');"
        "  }"
        "};"
        "log('自动领取已启动，每2秒扫描一次');"
        "run();"
        "setInterval(run,2000);"
        "})();";
}

// ── 检测 WebView 是否在等级页面──
static BOOL isTaskCenterPage(NSString *url) {
    if (!url) return NO;
    return [url containsString:@"ti.qq.com"] && [url containsString:@"qqlevel"];
}

%hook WKWebView

- (WKNavigation *)loadRequest:(NSURLRequest *)request {
    @try {
        NSString *url = request.URL.absoluteString ?: @"";
        if (_captureEnabled) {
            qqlog(@"[WKWebView] loadRequest: %@", url);
        }
        if (_captureEnabled && ([url containsString:@"ti.qq.com"] ||
            [url containsString:@"qqlevel"] ||
            [url containsString:@"tianxuan"])) {
            dumpWebKitCookies();
        }
        // 自动注入领取脚本：等级页面加载时延迟注入
        if (isTaskCenterPage(url)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self evaluateJavaScript:autoClaimScript() completionHandler:^(id _Nullable result, NSError * _Nullable error) {
                    if (error) {
                        qqlog(@"[autoClaim] 注入失败: %@", error.localizedDescription);
                    } else {
                        qqlog(@"[autoClaim] 已注入自动领取脚本");
                    }
                }];
            });
        }
    } @catch (NSException *e) {}
    return %orig(request);
}

// hook evaluateJavaScript 记录
- (void)evaluateJavaScript:(NSString *)script completionHandler:(void (^)(id, NSError *))completionHandler {
    if (_captureEnabled && [script length] > 0 && [script length] < 200) {
        qqlog(@"[WKWebView] eval: %@", [script substringToIndex:MIN(100, script.length)]);
    }
    %orig(script, completionHandler);
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

// ── hash33（bkn 计算，与前端一致）──
static NSInteger qqHash33(NSString *s) {
    NSInteger e = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        e = ((e << 5) + e + [s characterAtIndex:i]) & 0x7FFFFFFF;
    }
    return e;
}

// ── 从 QQLoginPSKeyManager 拿指定域 p_skey（keyType=1）──
static NSString *getPSKey(NSString *domain, NSString *uin) {
    Class mgrCls = NSClassFromString(@"QQLoginPSKeyManager");
    if (!mgrCls) return nil;
    id mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, NSSelectorFromString(@"sharedInstance"));
    if (!mgr) return nil;
    SEL sel = NSSelectorFromString(@"getLocalKeyOfDomain:uin:keyType:");
    NSMethodSignature *sig = [mgr methodSignatureForSelector:sel];
    if (!sig) return nil;
    __unsafe_unretained NSString *dArg = domain;
    __unsafe_unretained NSString *uArg = uin;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:mgr];
    [inv setSelector:sel];
    [inv setArgument:&dArg atIndex:2];
    [inv setArgument:&uArg atIndex:3];
    NSInteger ktV = 1;
    [inv setArgument:&ktV atIndex:4];
    [inv invoke];
    __unsafe_unretained id ret = nil;
    [inv getReturnValue:&ret];
    if (ret && [ret isKindOfClass:[NSString class]] && [(NSString *)ret length] > 0) {
        return (NSString *)ret;
    }
    return nil;
}

// ── 拼 Cookie 头（只需 ti 域 p_skey + uin/p_uin，skey 可选）──
static NSString *buildCookieHeader(NSString *uin, NSString *tiKey, NSString *skey) {
    NSMutableString *ck = [NSMutableString stringWithFormat:@"uin=o%@;p_uin=o%@", uin, uin];
    if (skey.length > 0) {
        [ck appendFormat:@";skey=%@", skey];
    }
    if (tiKey.length > 0) {
        [ck appendFormat:@";p_skey=%@", tiKey];
    }
    return ck;
}

// ── POST JSON 工具 ──
static void postJSON(NSString *urlStr, NSString *bodyJson, NSString *cookie, void (^done)(NSData *data, NSString *raw, NSError *err)) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (cookie) [req setValue:cookie forHTTPHeaderField:@"Cookie"];
    [req setValue:@"https://ti.qq.com" forHTTPHeaderField:@"Origin"];
    [req setValue:@"https://ti.qq.com/qqlevel/index" forHTTPHeaderField:@"Referer"];
    [req setValue:@"Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36 MQQBrowser/6.2 TBS/047903" forHTTPHeaderField:@"User-Agent"];
    req.HTTPBody = [bodyJson dataUsingEncoding:NSUTF8StringEncoding];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { done(nil, nil, error); return; }
        NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        done(data, raw, nil);
    }] resume];
}

// ── 一键做任务：Get 列表 → 日志 → 自动领奖可领取的 ──
static void runLevelTaskAuto(NSString *uin) {
    NSString *tiKey = getPSKey(@"ti.qq.com", uin);
    NSString *qunKey = getPSKey(@"qun.qq.com", uin);
    NSString *skey = nil;
    @try {
        Class mgrCls = NSClassFromString(@"QQLoginPSKeyManager");
        id mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, NSSelectorFromString(@"sharedInstance"));
        skey = ((id (*)(id, SEL))objc_msgSend)(mgr, NSSelectorFromString(@"getRealSig_SKEYStr"));
    } @catch (...) {}
    NSString *key = tiKey ?: qunKey;
    if (!key) { qqlog(@"[auto] ti/qun 域 p_skey 均获取失败"); return; }
    NSInteger bkn = qqHash33(key);
    NSString *cookie = buildCookieHeader(uin, key, skey);
    qqlog(@"[auto] key_type=%@ skey=%@%@", tiKey ? @"ti" : @"qun", skey ? @"有" : @"无", tiKey && qunKey ? @" 双key" : @"");

    // 1. Get 任务列表
    NSString *getUrl = [NSString stringWithFormat:@"https://ti.qq.com/qqlevel/trpc/levelTask/Get?bkn=%ld", (long)bkn];
    qqlog(@"[auto] Get 任务列表 uin=%@", uin);
    postJSON(getUrl, @"{\"mode\":42}", cookie, ^(NSData *data, NSString *raw, NSError *err) {
        if (err) { qqlog(@"[auto] Get 失败: %@", err.localizedDescription); return; }
        if (!raw) { qqlog(@"[auto] Get 空响应"); return; }
        @try {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[raw dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            NSArray *tasks = j[@"response"][@"task_list"];
            if (!tasks) { qqlog(@"[auto] Get 响应无 task_list: %@", [raw substringToIndex:MIN(300, raw.length)]); return; }
            qqlog(@"[auto] ===== 任务列表 %lu 个 =====", (unsigned long)tasks.count);
            for (NSDictionary *t in tasks) {
                NSString *tid = t[@"task_id"];
                NSNumber *st = t[@"status"];
                NSString *title = t[@"title"];
                NSString *days = t[@"accelerate_days"];
                qqlog(@"[auto] [%@] status=%@ %@ (+%@天)", tid, st, title ?: @"", days ?: @"");
            }
            // 2. 对 status=2（可领取）自动 ExecAct 领奖
            for (NSDictionary *t in tasks) {
                NSNumber *st = t[@"status"];
                if ([st intValue] == 2) {
                    NSString *ruleId = t[@"award_rule_id"];
                    NSString *uniqueId = t[@"unique_task_id"];
                    NSString *bizId = t[@"business_task_id"];
                    NSString *tid = t[@"task_id"];
                    if (!ruleId || ruleId.length == 0) {
                        qqlog(@"[auto] 任务%@ status=2 但无 award_rule_id，跳过", tid);
                        continue;
                    }
                    NSString *actReq = [NSString stringWithFormat:@"{\"sub_act_id\":\"%@\",\"task_id\":\"%@\",\"uid\":\"%@\",\"business_task_id\":\"%@\"}", ruleId, uniqueId, uin, bizId];
                    NSString *actBody = [NSString stringWithFormat:@"{\"SubActId\":\"%@\",\"ClientPlat\":\"h5\",\"Aid\":\"\",\"EnteranceId\":\"\",\"ActReqData\":\"%@\"}", ruleId, [actReq stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
                    NSString *execUrl = [NSString stringWithFormat:@"https://ti.qq.com/qqlevel/tianxuan/trpc/access/ExecAct?bkn=%ld", (long)bkn];
                    qqlog(@"[auto] 领奖 任务%@ rule=%@ unique=%@", tid, ruleId, uniqueId);
                    postJSON(execUrl, actBody, cookie, ^(NSData *d2, NSString *r2, NSError *e2) {
                        if (e2) { qqlog(@"[auto] ExecAct %@ 失败: %@", tid, e2.localizedDescription); return; }
                        qqlog(@"[auto] ExecAct %@ 响应: %@", tid, r2 ? [r2 substringToIndex:MIN(200, r2.length)] : @"nil");
                    });
                }
            }
        } @catch (NSException *e) {
            qqlog(@"[auto] 解析异常: %@", e);
        }
    });
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
    floatWindow.hidden = NO;
}

// ── 打开等级页面 WebView（带自动注入领取脚本）──
static void openTaskCenterWebView(void) {
    @try {
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        config.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
        WKWebView *webView = [[WKWebView alloc] initWithFrame:[UIScreen mainScreen].bounds configuration:config];

        UIViewController *vc = [[UIViewController alloc] init];
        vc.view = webView;
        vc.title = @"QQ等级任务中心";

        // 加载等级页（带参数避免重定向）
        NSURL *url = [NSURL URLWithString:@"https://ti.qq.com/qqlevel/task-center?version=1&tab=1&source=38"];
        NSURLRequest *req = [NSURLRequest requestWithURL:url];
        [webView loadRequest:req];
        qqlog(@"[openTaskCenter] 加载等级页: %@", url.absoluteString);

        // 呈现模态导航
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        UIViewController *presenter = _floatWindow.rootViewController;
        if (presenter && !presenter.presentedViewController) {
            [presenter presentViewController:nav animated:YES completion:nil];
        } else {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *ws = (UIWindowScene *)scene;
                    if (ws.activationState == UISceneActivationStateForegroundActive) {
                        UIViewController *rootVC = ws.windows.firstObject.rootViewController;
                        if (rootVC) {
                            [rootVC presentViewController:nav animated:YES completion:nil];
                            break;
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {
        qqlog(@"[openTaskCenter] 异常: %@", e);
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
    // 循环重试：QQ 冷启动时 scene 可能几秒内还没就绪
    dispatch_async(dispatch_get_main_queue(), ^{
        for (int i = 0; i < 15; i++) {
            UIApplication *app = [UIApplication sharedApplication];
            if (!app) break;
            [app _setupFloatBall];
            if (_floatBall) break;  // 球建好就停
            // 在主队列等 2 秒再试
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.0]];
        }
    });
}
