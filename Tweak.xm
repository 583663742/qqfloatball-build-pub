#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>

// ── 持有悬浮球窗口和按钮的强引用，防止 ARC 释放 ──
static UIWindow *_floatWindow = nil;
static UIButton *_floatBall = nil;
static UIView *_logView = nil;          // 任务日志面板
static UITextView *_logTextView = nil;  // 日志文本

// ── 抓包开关：YES=记录网络请求；NO=停止 ──
static BOOL _captureEnabled = NO;
// ── 仅抓等级关键词（keyTask）时才包装响应；全量模式只记请求不碰响应（防 Kuikly 白屏）──
static BOOL _captureOnlyTasks = NO;

// ── 一键任务执行状态 ──
static BOOL _taskRunning = NO;

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

// ── 异步写日志（不阻塞网络回调线程，防 Kuikly 加载变慢）──
static void qqlogAsync(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        qqlog(@"%@", msg);
    });
}

// ── 等级关键词判断（收窄匹配，防误伤无关请求）──
static BOOL isLevelKeyURL(NSString *url) {
    if (!url) return NO;
    static NSArray *kws = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kws = @[@"qqlevel", @"tianxuan", @"commdeliver", @"levelTask", @"ExecAct",
                @"GetUserRecord", @"openKuikly", @"benefit", @"GetBenefitsDetail",
                @"GetUserItemsByBenefits", @"aggregation", @"GetTotalReadTime", @"GetShow"];
    });
    for (NSString *kw in kws) {
        if ([url containsString:kw]) return YES;
    }
    return NO;
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

// 只有触摸悬浮球区域（或日志面板）才响应，其余一律穿透给 QQ
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (_floatBall && CGRectContainsPoint(_floatBall.frame, point)) {
        return _floatBall;
    }
    if (_logView && !_logView.hidden && CGRectContainsPoint(_logView.frame, point)) {
        return _logView;
    }
    return nil;
}

@end

// ──────────────────────────────────────────
//  网络抓包：hook NSURLSession，记录等级相关请求
//  ⚠️ 全量模式只记请求不包装 completionHandler（包装会致 Kuikly 白屏）
// ──────────────────────────────────────────
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    @try {
        if (_captureEnabled) {
            NSString *url = request.URL.absoluteString ?: @"";
            BOOL keyTask = isLevelKeyURL(url);
            if (keyTask) {
                // 等级关键词：异步记录（URL+body），数量少可包装响应
                NSString *body = request.HTTPBody ? [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding] : @"";
                qqlogAsync(@"[NSURLSession] %@ %@ body=%@", request.HTTPMethod ?: @"GET", url, body);
                if (_captureOnlyTasks) {
                    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
                        if (data && data.length > 0) {
                            NSString *respStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                            qqlogAsync(@"[resp] %@ -> %@", url, respStr.length > 2000 ? [respStr substringToIndex:2000] : respStr);
                        }
                        if (completionHandler) completionHandler(data, resp, err);
                    };
                    return %orig(request, wrapped);
                }
            } else if (_captureEnabled && !_captureOnlyTasks) {
                // 全量模式：只记 URL，不包装
                qqlogAsync(@"[NSURLSession] %@ %@", request.HTTPMethod ?: @"GET", url);
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

// ══════════════════════════════════════════
//  一键做任务：HTTP 直连执行器
//  核心接口（2026-08-19 主号 583663742 抓包实证）：
//   1. levelTask/Get  → ti.qq.com，bkn=hash33(ti域p_skey)，body {"mode":42}
//   2. ExecAct 领奖   → act.qzone.qq.com，g_tk=bkn，Cookie uin/p_uin/p_skey
//   3. 福利社领券链   → GetBenefitsDetail → ExecAct → GetUserItemsByBenefits
// ══════════════════════════════════════════

// ── hash33 算法：bkn = hash33(p_skey) ──
static int hash33(NSString *str) {
    if (!str) return 0;
    int e = 0;
    for (int i = 0; i < str.length; i++) {
        e += (e << 5) + [str characterAtIndex:i];
    }
    return 2147483647 & e;
}

// ── 直接调用 QQLoginPSKeyManager 拿指定域 p_skey（keyType=1，现取现用）──
static NSString *getPskey(NSString *domain, NSString *uin, int keyType) {
    @try {
        Class mgrCls = NSClassFromString(@"QQLoginPSKeyManager");
        if (!mgrCls) return nil;
        id mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, NSSelectorFromString(@"sharedInstance"));
        if (!mgr) return nil;
        SEL sel = NSSelectorFromString(@"getLocalKeyOfDomain:uin:keyType:");
        NSMethodSignature *sig = [mgr methodSignatureForSelector:sel];
        if (!sig) return nil;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:mgr];
        [inv setSelector:sel];
        __unsafe_unretained NSString *dArg = domain;
        __unsafe_unretained NSString *uArg = uin;
        [inv setArgument:&dArg atIndex:2];
        [inv setArgument:&uArg atIndex:3];
        NSInteger kt = keyType;
        [inv setArgument:&kt atIndex:4];
        [inv invoke];
        __unsafe_unretained id ret = nil;
        [inv getReturnValue:&ret];
        if (ret && [ret isKindOfClass:[NSString class]] && [(NSString *)ret length] > 0) {
            return ret;
        }
    } @catch (NSException *e) {}
    return nil;
}

// ── 取当前登录 uin（从 p_skey 管理器遍历已知账号）──
static NSString *getCurrentUin(void) {
    @try {
        NSArray *candidates = @[@"583663742", @"820284286", @"1172628163"];
        for (NSString *u in candidates) {
            NSString *psk = getPskey(@"ti.qq.com", u, 1);
            if (psk && psk.length > 0) return u;
        }
    } @catch (NSException *e) {}
    return @"583663742"; // 兜底主号
}

// ── 同步 POST JSON，返回解析后的字典 ──
static NSDictionary *httpPostJSON(NSString *url, NSDictionary *bodyDict, NSString *cookieHeader, int timeoutSec) {
    @try {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        if (cookieHeader) [req setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
        [req setValue:@"Dalvik/2.1.0 (Linux; U; Android 13; zh-cn; 2201123G Build/TKQ1.220829.002) V1_AND_SQ_9.2.0_10970_YYB_D QQ/9.2.0.28325" forHTTPHeaderField:@"User-Agent"];
        NSData *bodyData = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil];
        req.HTTPBody = bodyData;

        __block NSDictionary *result = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = timeoutSec;
        cfg.timeoutIntervalForResource = timeoutSec + 5;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
        [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (!err && data) {
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    result = obj;
                } else if ([obj isKindOfClass:[NSArray class]]) {
                    result = @{@"data_array": obj};
                }
            }
            dispatch_semaphore_signal(sem);
        }] resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (timeoutSec + 10) * NSEC_PER_SEC));
        [session finishTasksAndInvalidate];
        return result;
    } @catch (NSException *e) {
        qqlog(@"[http] 异常 %@", e);
    }
    return nil;
}

// ── 拉取任务列表：levelTask/Get ──
static NSArray *fetchTaskList(NSString *uin, NSString *tiPskey, int *retCodeOut) {
    @try {
        int bkn = hash33(tiPskey);
        NSString *url = [NSString stringWithFormat:@"https://ti.qq.com/qqlevel/trpc/levelTask/Get?bkn=%d", bkn];
        NSString *cookie = [NSString stringWithFormat:@"uin=o%@; p_uin=o%@; p_skey=%@", uin, uin, tiPskey];
        NSDictionary *resp = httpPostJSON(url, @{@"mode": @42}, cookie, 15);
        if (!resp) {
            if (retCodeOut) *retCodeOut = -1;
            qqlog(@"[taskList] 无响应");
            return nil;
        }
        id ret = resp[@"ret"];
        if (retCodeOut) *retCodeOut = [ret intValue];
        qqlog(@"[taskList] ret=%@", ret);
        // 响应结构：{ret:0, response:{task_list:[...]}}
        NSDictionary *response = resp[@"response"];
        if (![response isKindOfClass:[NSDictionary class]]) {
            qqlog(@"[taskList] response 非字典: %@", resp);
            return nil;
        }
        NSArray *list = response[@"task_list"];
        if (![list isKindOfClass:[NSArray class]]) {
            qqlog(@"[taskList] task_list 非数组，keys=%@", response.allKeys);
            return nil;
        }
        qqlog(@"[taskList] 共 %lu 个任务", (unsigned long)list.count);
        return list;
    } @catch (NSException *e) {
        qqlog(@"[taskList] 异常 %@", e);
    }
    return nil;
}

// ── ExecAct 领奖（act.qzone.qq.com 真身域名）──
//   普通任务 body：{SubActId, ClientPlat, Aid, EnteranceId, ActReqData}
static BOOL execActClaim(NSDictionary *task, NSString *uin, NSString *qzonePskey) {
    @try {
        NSString *awardRuleId = task[@"award_rule_id"] ?: @"";
        NSString *taskId = task[@"task_id"] ?: @"";
        NSString *businessTaskId = task[@"business_task_id"] ?: @"";
        if (!awardRuleId || awardRuleId.length == 0) {
            qqlog(@"[ExecAct] 任务无 award_rule_id，跳过: %@", task);
            return NO;
        }
        int gtk = hash33(qzonePskey);
        NSString *url = [NSString stringWithFormat:@"https://act.qzone.qq.com/v2/vip/tx/trpc/subact/ExecAct?g_tk=%d", gtk];
        NSString *cookie = [NSString stringWithFormat:@"uin=%@; p_uin=%@; p_skey=%@", uin, uin, qzonePskey];

        // ActReqData 是字符串化的 JSON
        NSDictionary *actReq = @{
            @"sub_act_id": awardRuleId,
            @"task_id": taskId,
            @"uid": uin,
            @"business_task_id": businessTaskId
        };
        NSData *reqJson = [NSJSONSerialization dataWithJSONObject:actReq options:0 error:nil];
        NSString *reqStr = [[NSString alloc] initWithData:reqJson encoding:NSUTF8StringEncoding];

        NSDictionary *body = @{
            @"SubActId": awardRuleId,
            @"ClientPlat": @1,
            @"Aid": @"",
            @"EnteranceId": @"",
            @"ActReqData": reqStr ?: @"{}"
        };
        NSDictionary *resp = httpPostJSON(url, body, cookie, 15);
        if (!resp) {
            qqlog(@"[ExecAct] %@ 无响应", awardRuleId);
            return NO;
        }
        int code = [resp[@"Code"] intValue];
        qqlog(@"[ExecAct] %@ Code=%d Msg=%@", awardRuleId, code, resp[@"Msg"] ?: @"");
        return code == 0;
    } @catch (NSException *e) {
        qqlog(@"[ExecAct] 异常 %@", e);
    }
    return NO;
}

// ── 福利社领券完整链：GetBenefitsDetail → ExecAct → GetUserItemsByBenefits ──
static BOOL benefitClaimChain(NSString *uin, NSString *vipPskey) {
    @try {
        int gtk = hash33(vipPskey);
        NSString *cookie = [NSString stringWithFormat:@"uin=%@; p_uin=%@; p_skey=%@", uin, uin, vipPskey];
        NSString *base = @"https://club.vip.qq.com/mono/api/trpc/qqva/vipopen_benefits_center_server/benefit_service/Vipopen";

        // 1. GetBenefitsDetail → 取 getSubactId
        NSString *url1 = [NSString stringWithFormat:@"%@/GetBenefitsDetail?ADTAG=level&g_tk=%d", base, gtk];
        NSDictionary *detail = httpPostJSON(url1, @{@"data": @{@"benefits_id": @47778}}, cookie, 15);
        NSString *subactId = nil;
        if (detail) {
            NSDictionary *data = detail[@"data"];
            NSArray *benefits = data[@"benefits"];
            if ([benefits isKindOfClass:[NSArray class]] && benefits.count > 0) {
                NSDictionary *first = benefits[0];
                NSDictionary *tianxuan = first[@"tianxuanAct"];
                subactId = tianxuan[@"getSubactId"];
                qqlog(@"[benefit] GetBenefitsDetail → getSubactId=%@", subactId ?: @"nil");
            } else {
                qqlog(@"[benefit] GetBenefitsDetail 响应无 benefits: %@", detail);
            }
        } else {
            qqlog(@"[benefit] GetBenefitsDetail 无响应");
        }

        // 2. ExecAct 领券
        if (subactId && subactId.length > 0) {
            int gtk2 = hash33(vipPskey);
            NSString *execUrl = [NSString stringWithFormat:@"https://act.qzone.qq.com/v2/vip/tx/trpc/subact/ExecAct?g_tk=%d", gtk2];
            NSDictionary *actReq = @{
                @"send_type": @"2",
                @"ext_recommend_source": @1,
                @"appid": @"pg_qqvip_benefit",
                @"page_id": @"pg_new_benefit_homepage",
                @"date": @"0",
                @"sub_id": @""
            };
            NSData *reqJson = [NSJSONSerialization dataWithJSONObject:actReq options:0 error:nil];
            NSString *reqStr = [[NSString alloc] initWithData:reqJson encoding:NSUTF8StringEncoding];
            NSDictionary *body = @{
                @"SubActId": subactId,
                @"ActReqData": reqStr,
                @"ReportInfo": @"{\"enteranceId\":\"level\"}"
            };
            NSDictionary *resp = httpPostJSON(execUrl, body, cookie, 15);
            int code = resp ? [resp[@"Code"] intValue] : -999;
            qqlog(@"[benefit] ExecAct Code=%d Msg=%@", code, resp[@"Msg"] ?: @"");
            if (code != 0) return NO;

            // 3. 领后确认
            NSString *url3 = [NSString stringWithFormat:@"%@/GetUserItemsByBenefits?ADTAG=level&g_tk=%d", base, gtk];
            NSDictionary *confirm = httpPostJSON(url3, @{@"data": @{@"benefits_id": @47778}}, cookie, 15);
            qqlog(@"[benefit] GetUserItemsByBenefits %@", confirm ? @"ok" : @"无响应");
            return YES;
        }
    } @catch (NSException *e) {
        qqlog(@"[benefit] 异常 %@", e);
    }
    return NO;
}

// ── 一键做任务主流程（后台队列执行，不阻塞 UI）──
static void runAutoTasks(void) {
    if (_taskRunning) {
        qqlog(@"[auto] 任务已在运行中");
        return;
    }
    _taskRunning = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            qqlog(@"\n========== 一键做任务开始 ==========");
            // 1. 取 uin + 各域 p_skey
            NSString *uin = getCurrentUin();
            NSString *tiPskey = getPskey(@"ti.qq.com", uin, 1);
            if (!tiPskey) {
                // fallback keyType=0
                tiPskey = getPskey(@"ti.qq.com", uin, 0);
            }
            if (!tiPskey) {
                qqlog(@"[auto] ✗ 拿不到 ti 域 p_skey，无法继续");
                _taskRunning = NO;
                return;
            }
            NSString *qzonePskey = getPskey(@"qzone.qq.com", uin, 1);
            NSString *vipPskey = getPskey(@"vip.qq.com", uin, 1);
            if (!qzonePskey) qzonePskey = getPskey(@"qzone.qq.com", uin, 0);
            if (!vipPskey) vipPskey = getPskey(@"vip.qq.com", uin, 0);
            qqlog(@"[auto] uin=%@ ti_p_skey_len=%lu qzone_p_skey_len=%lu vip_p_skey_len=%lu",
                  uin, (unsigned long)tiPskey.length,
                  (unsigned long)qzonePskey.length, (unsigned long)vipPskey.length);

            // 2. 拉任务列表
            int retCode = 0;
            NSArray *taskList = fetchTaskList(uin, tiPskey, &retCode);
            if (!taskList || taskList.count == 0) {
                qqlog(@"[auto] ✗ 任务列表为空 (ret=%d)", retCode);
                _taskRunning = NO;
                return;
            }

            // 3. 遍历任务执行
            int claimOK = 0, claimFail = 0, pending = 0, done = 0;
            for (NSDictionary *task in taskList) {
                if (![task isKindOfClass:[NSDictionary class]]) continue;
                NSString *title = task[@"title"] ?: task[@"task_name"] ?: @"?";
                NSNumber *statusNum = task[@"status"];
                int status = statusNum ? [statusNum intValue] : -1;
                NSString *taskId = [task[@"task_id"] description] ?: @"";
                qqlog(@"[task] id=%@ title=%@ status=%d", taskId, title, status);

                if (status == 2) {  // 可领取
                    qqlog(@"[task] 🎁 可领取 → 尝试领奖: %@", title);
                    BOOL ok = NO;
                    // 福利社任务特判
                    BOOL isBenefit = [title containsString:@"福利社"] || [title containsString:@"领券"] ||
                        ([task[@"award_rule_id"] isKindOfClass:[NSString class]] &&
                         [(NSString *)task[@"award_rule_id"] containsString:@"139705"]);
                    if (isBenefit) {
                        ok = benefitClaimChain(uin, vipPskey ?: qzonePskey);
                    } else {
                        ok = execActClaim(task, uin, qzonePskey ?: tiPskey);
                    }
                    if (ok) claimOK++; else claimFail++;
                    qqlog(@"[task] %@ %@", title, ok ? @"✅ 领奖成功" : @"❌ 领奖失败");
                } else if (status == 1) {  // 已完成未领
                    qqlog(@"[task] ⏳ 已完成未领 → 尝试领奖: %@", title);
                    BOOL ok = execActClaim(task, uin, qzonePskey ?: tiPskey);
                    if (ok) claimOK++; else claimFail++;
                    qqlog(@"[task] %@ %@", title, ok ? @"✅ 领奖成功" : @"❌ 领奖失败");
                } else if (status == 0) {  // 未完成
                    pending++;
                    qqlog(@"[task] 📋 未完成（需手动/UI 操作）: %@", title);
                } else if (status == 3) {  // 已领取
                    done++;
                    qqlog(@"[task] ✅ 已领取: %@", title);
                }
            }

            // 4. 汇总
            qqlog(@"[auto] ══ 汇总: 领奖成功=%d 失败=%d 未完成=%d 已领取=%d ══", claimOK, claimFail, pending, done);
            qqlog(@"[auto] 未完成任务需要打开等级页手动操作，完成后再次点「一键做任务」即可领奖");
        } @catch (NSException *e) {
            qqlog(@"[auto] 主流程异常: %@", e);
        }
        _taskRunning = NO;
    });
}

// ══════════════════════════════════════════
//  任务日志面板 UI（悬浮窗内嵌，不干扰 QQ）
// ══════════════════════════════════════════
static void appendLogView(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_logView) return;
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
        NSString *newText = [(_logTextView.text ?: @"") stringByAppendingString:line];
        if (newText.length > 8000) {
            newText = [newText substringFromIndex:newText.length - 8000];
        }
        _logTextView.text = newText;
        [_logTextView scrollRangeToVisible:NSMakeRange(_logTextView.text.length, 0)];
    });
}

static void showLogPanel(void) {
    if (_logView || !_floatWindow) return;
    CGRect frame = _floatWindow.bounds;
    CGFloat w = MIN(300, frame.size.width - 20);
    CGFloat h = MIN(320, frame.size.height * 0.4);
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(frame.size.width - w - 8, frame.size.height - h - 90, w, h)];
    view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
    view.layer.cornerRadius = 10;
    view.layer.masksToBounds = YES;
    view.userInteractionEnabled = YES;

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(4, 4, w - 8, h - 44)];
    tv.backgroundColor = [UIColor clearColor];
    tv.textColor = [UIColor whiteColor];
    tv.font = [UIFont systemFontOfSize:11];
    tv.editable = NO;
    tv.selectable = NO;
    tv.text = @"任务日志：\n";
    _logTextView = tv;
    [view addSubview:tv];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(w - 44, h - 36, 36, 28);
    [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [closeBtn addTarget:[UIApplication sharedApplication] action:@selector(_closeLogPanel:) forControlEvents:UIControlEventTouchUpInside];
    [view addSubview:closeBtn];

    _logView = view;
    [_floatWindow addSubview:_logView];
}

// 提前声明
@interface UIApplication (QQFloatBallLog)
- (void)_closeLogPanel:(UIButton *)sender;
@end

%hook UIApplication
%new
- (void)_closeLogPanel:(UIButton *)sender {
    if (_logView) {
        [_logView removeFromSuperview];
        _logView = nil;
        _logTextView = nil;
    }
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

// ──────────────────────────────────────────
//  点击弹窗（抓包 / 一键做任务 / 任务日志）
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
            dumpPSKeys();
        }
    }]];
    // 一键做任务：HTTP 直连领奖（不再依赖 WebView）
    [alert addAction:[UIAlertAction actionWithTitle:@"⚡ 一键做任务"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        qqlog(@"[action] 一键做任务启动");
        [self _closeLogPanel:nil];
        showLogPanel();
        appendLogView(@"⚡ 一键做任务启动…");
        runAutoTasks();
        // 日志面板轮询刷新（从任务启动时的文件偏移读起）
        NSInteger startOffset = [[[NSFileManager defaultManager] attributesOfItemAtPath:qqlogPath() error:nil][NSFileSize] longValue] ?: 0;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            NSInteger lastOffset = startOffset;
            for (int i = 0; i < 240 && _taskRunning; i++) {
                @try {
                    NSData *data = [NSData dataWithContentsOfFile:qqlogPath()];
                    if (data && data.length > lastOffset) {
                        NSString *tail = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                        NSString *newPart = [tail substringFromIndex:MIN(lastOffset, tail.length)];
                        NSArray *lines = [newPart componentsSeparatedByString:@"\n"];
                        for (NSString *ln in lines) {
                            NSString *trimmed = [ln stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                            if (trimmed.length > 0 && [trimmed containsString:@"["]) {
                                appendLogView(trimmed);
                            }
                        }
                        lastOffset = data.length;
                    }
                } @catch (NSException *e) {}
                [NSThread sleepForTimeInterval:0.5];
            }
            if (_taskRunning) {
                appendLogView(@"⏳ 任务仍在进行（可稍后再点一次）");
            } else {
                appendLogView(@"✅ 任务执行完毕");
            }
        });
    }]];
    // 打开等级页（Kuikly 原生）
    [alert addAction:[UIAlertAction actionWithTitle:@"📖 打开等级页"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        qqlog(@"[action] 打开等级页");
        // 用 QQ 深链打开等级页（走 Kuikly 原生渲染）
        NSURL *url = [NSURL URLWithString:@"mqqapi://forward/url?src_type=web&version=1&url_prefix=aHR0cHM6Ly90aS5xcS5jb20vcXFsZXZlbC9pbmRleD92ZXJzaW9uPTEmdGFiPTYmc291cmNlPTE1"];
        if (url) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"📋 任务日志"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        if (_logView) {
            [self _closeLogPanel:nil];
        } else {
            showLogPanel();
            appendLogView(@"任务日志面板已打开");
        }
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
