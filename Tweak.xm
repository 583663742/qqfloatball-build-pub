#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonCrypto.h>

// v1.2.22: _Block_signature 探测 block 真实签名（只读，不调用）
// 声明在 libffi/Block.h 内（BlocksRuntime 提供），需显式声明供本文件使用
#ifdef __cplusplus
extern "C" {
#endif
const char *_Block_signature(const void *aBlock);
#ifdef __cplusplus
}
#endif

// ── QQ 9.3.35 顶层悬浮窗管理器私有接口（头文件 032238 实锤）──
//    声明后编译器认识这些 selector（ObjC++ 下向 id 调未声明 selector 会报 error）
@interface QQFloatingWindowTopLevelWindowManager : NSObject
+ (id)sharedManager;
+ (id)topLevelWindow;
+ (void)acquireTopLevelWindowHighLevel:(id)arg1;
+ (void)releaseTopLevelWindowHighLevel:(id)arg1;
@end

// QQFloatingBallUtil（头文件 032242）：topMostViewController 检测当前页面
@interface QQFloatingBallUtil : NSObject
+ (id)topMostViewController;
@end

// ── 持有悬浮球窗口和按钮的强引用，防止 ARC 释放 ──
static UIWindow *_floatWindow = nil;
static UIButton *_floatBall = nil;
static UIView *_logView = nil;          // 任务日志面板
static UITextView *_logTextView = nil;  // 日志文本
static UIView *_taskPanel = nil;        // 任务列表面板（v1.1.0 新 UI）
static UIScrollView *_taskScroll = nil; // 任务列表滚动区
static NSArray *_taskListCache = nil;   // 最近一次拉取的任务列表缓存
static NSMutableSet *_checkedTaskIds = nil; // 勾选的任务 task_id 集合
static NSString *_friendRobotUin = @"10001"; // 加好友测试机器人号（qsped 模式，待实测确认）

// ── 客户端原生请求捕获的全量任务列表（v1.2.2：hook QQ 自己发的 levelTask/Get 响应）──
//   QQ 客户端带 skey 全凭证请求，服务端返回全量任务；我们拦截响应存这里，供面板展示
static NSArray *_capturedTaskList = nil;
static BOOL _capturedListDirty = NO;
// ── 客户端原生请求捕获的 qun 域真实 p_skey（v1.2.2 修复加好友 csrf error）──
static NSString *_capturedQunPskey = nil;

// ── 抓包开关：YES=记录网络请求；NO=停止 ──
// v1.1.0 起不再有抓包入口（防封防检测），代码保留但默认关
static BOOL _captureEnabled = NO;
// ── 仅抓等级关键词（keyTask）时才包装响应；全量模式只记请求不碰响应（防 Kuikly 白屏）──
static BOOL _captureOnlyTasks = NO;
// ── v1.2.9: 点击「额外活跃」后 5 秒内无条件记录所有请求 URL+body（锁定33任务真实接口）──
// v1.2.11: 打开等级页后立即开启 8 秒 DUMP（等级页一打开就拉取全量任务，不需点额外活跃）
static BOOL _dumpAllRequests = NO;

// ── v1.2.11: AI 对话分析（参考微信插件 wxresearch 对话模式）──
static NSMutableArray *_aiHistory = nil;   // AI 对话历史（system + user + assistant）
static BOOL _aiBusy = NO;                  // AI 请求进行中（防连点）
#define QQFB_AI_KEY_UD @"qqfb_ai_key"      // NSUserDefaults 存 key（留空用户自己填）
#define QQFB_AI_MODEL @"deepseek-chat"

// ── 一键任务执行状态 ──
static BOOL _taskRunning = NO;
// ── v1.2.8: 自动流程运行中标志(防止重复触发 + 流程期间临时隐藏悬浮球) ──
static BOOL _autoFlowRunning = NO;

// ── 网络抓包日志（写入 app 沙盒 Documents，SSH 可读）──
static NSString *qqlogPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/qqflog.txt"];
}

// 前置声明：qqlog 同时追加到面板日志区（定义在任务面板 UI 部分）
static void appendLogView(NSString *msg);

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
    // 面板日志区实时同步（主线程刷新 UI）
    dispatch_async(dispatch_get_main_queue(), ^{
        appendLogView(msg);
    });
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
                @"GetUserItemsByBenefits", @"aggregation", @"GetTotalReadTime", @"GetShow",
                // v1.2.22: 等级页真实数据域（实测 2026-08-25 实机抓包）
                @"club.vip.qq.com", @"h5.vip.qq.com", @"getInitialTaskMaterial",
                @"GetScore", @"GetAds", @"getMedalUrl", @"clm-logic", @"vip_score_server",
                @"GetUserRecord", @"kuiklysso", @"gotrpc"];
    });
    for (NSString *kw in kws) {
        if ([url containsString:kw]) return YES;
    }
    return NO;
}

// ── v1.2.22: 抓包自动停止 —— 抓到关键响应后 8 秒无新数据自动停（不再固定 30 秒）──
static BOOL _autoStopScheduled = NO;
static void qqfbScheduleAutoStop(void) {
    // 每次关键响应到达时重置 8 秒窗口；窗口内无新响应则自动停
    static dispatch_source_t timer = NULL;
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
    if (timer) dispatch_source_cancel(timer);
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 1.0);
    dispatch_source_set_event_handler(timer, ^{
        if (_dumpAllRequests) {
            _dumpAllRequests = NO;
            _autoStopScheduled = NO;
            qqlog(@"[iOS抓取] 8 秒无新响应，自动停止抓包");
            dispatch_async(dispatch_get_main_queue(), ^{
                appendLogView(@"[iOS抓取] 自动停止");
            });
        }
        dispatch_source_cancel(timer);
        timer = NULL;
    });
    _autoStopScheduled = YES;
    dispatch_resume(timer);
}

// ── 提前声明 %new 方法，供 dispatch_once block 内调用 ──
@interface UIApplication (QQFloatBall)
- (void)_setupFloatBall;
- (void)_floatBallTapped:(UIButton *)sender;
- (void)_floatBallPanned:(UIPanGestureRecognizer *)pan;
- (void)_taskPanelPanned:(UIPanGestureRecognizer *)pan;
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
        // ⚠️ 层级必须足够高：QQ 9.3.35 有高浮层窗口（来电/游戏浮窗等），statusBar+1 会被盖住点不到
        // 用 statusBar+10，仍低于系统 alert（2000），不会挡住系统弹窗
        self.windowLevel = UIWindowLevelStatusBar + 10;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.hidden = NO;
    }
    return self;
}

// 只有触摸悬浮球区域（或日志面板及其子控件）才响应，其余一律穿透给 QQ
// ⚠️ 必须返回真正的子视图：日志面板内的关闭按钮是 _logView 的子视图，
//    若直接 return _logView（父视图），按钮永远收不到 touch（点了没反应）
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (_floatBall && CGRectContainsPoint(_floatBall.frame, point)) {
        return _floatBall;
    }
    if (_logView && !_logView.hidden && CGRectContainsPoint(_logView.frame, point)) {
        // 走 super 递归找出最深的命中的子视图（关闭按钮/文本框），保证按钮可点
        return [super hitTest:point withEvent:event];
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
        NSString *url = request.URL.absoluteString ?: @"";
        BOOL isLevelGet = [url containsString:@"levelTask/Get"];
        // v1.2.9: 点击「额外活跃」后的 5 秒内，无条件记录所有请求 URL+body（锁定33任务真实接口）
        if (_dumpAllRequests && !isLevelGet) {
            NSString *body = request.HTTPBody ? [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding] : @"";
            qqlogAsync(@"[DUMP] %@ %@ body=%@", request.HTTPMethod ?: @"GET", url,
                       body.length > 400 ? [body substringToIndex:400] : body);
        }
        // v1.2.2: 无论抓包开关，只要 URL 是 levelTask/Get 就拦截响应存全量任务列表
        //（QQ 客户端自己带 skey 全凭证请求，服务端返回的就是完整任务；我们只读不改）
        if (isLevelGet) {
            // v1.2.10: 先打印请求 URL+body——客户端点「额外活跃」时发的 mode 参数决定返回哪些任务
            //          （10 vs 33 之谜的关键：mode=42/all 返回不同集合）
            NSString *reqBody = request.HTTPBody ? [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding] : @"";
            if (reqBody.length > 0) {
                qqlog(@"[捕获] levelTask/Get 请求 body=%@", reqBody.length > 500 ? [reqBody substringToIndex:500] : reqBody);
            }
            void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
                if (data && data.length > 0) {
                    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if ([obj isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *response = obj[@"response"];
                        NSArray *list = [response isKindOfClass:[NSDictionary class]] ? response[@"task_list"] : nil;
                        if ([list isKindOfClass:[NSArray class]] && list.count > 0) {
                            _capturedTaskList = list;
                            _capturedListDirty = YES;
                            qqlog(@"[捕获] 客户端原生 levelTask/Get → %lu 个任务", (unsigned long)list.count);
                            // v1.2.10: 打印每个任务的 title，确认是否额外活跃任务集合
                            for (NSDictionary *t in list) {
                                if ([t isKindOfClass:[NSDictionary class]]) {
                                    qqlog(@"[任务] %@ | %@ | days=%@", t[@"task_id"] ?: @"?", t[@"title"] ?: @"?", t[@"accelerate_days"] ?: @"?");
                                }
                            }
                        }
                    }
                }
                if (completionHandler) completionHandler(data, resp, err);
            };
            return %orig(request, wrapped);
        }
        // iOS QQ 等级页走 Kuikly / CLM，不走安卓的 levelTask/Get。
        // 只读抓取页面实际返回的任务材料和用户记录；绝不改请求、绝不触发页面动作。
        // v1.2.22: 覆盖全部等级域（club.vip.qq.com / h5.vip.qq.com / gotrpc 等），
        //          响应抓全 + 每次响应重置 8 秒自动停止计时器
        BOOL isIOSLevelMaterial = isLevelKeyURL(url);
        if (isIOSLevelMaterial && _dumpAllRequests) {
            void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
                if (data && data.length > 0) {
                    NSString *responseText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    if (responseText.length > 0) {
                        qqlog(@"[iOS等级页响应] %@\n%@", url, responseText.length > 6000 ? [responseText substringToIndex:6000] : responseText);
                    } else {
                        qqlog(@"[iOS等级页响应] %@ (非UTF-8, %lu bytes)", url, (unsigned long)data.length);
                    }
                } else {
                    qqlog(@"[iOS等级页响应] %@ (empty, err=%@)", url, err);
                }
                // 响应到达 → 重置自动停止窗口
                if (_dumpAllRequests) qqfbScheduleAutoStop();
                if (completionHandler) completionHandler(data, resp, err);
            };
            return %orig(request, wrapped);
        }
        // v1.2.2: 顺带捕获 qun 域真实 p_skey（客户端访问群/好友页时带真实凭证，修复加好友 csrf error）
        if ([url containsString:@"qun.qq.com"] && request.allHTTPHeaderFields[@"Cookie"]) {
            NSString *ck = request.allHTTPHeaderFields[@"Cookie"];
            NSArray *parts = [ck componentsSeparatedByString:@";"];
            for (NSString *part in parts) {
                NSString *trim = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([trim hasPrefix:@"p_skey="]) {
                    NSString *val = [trim substringFromIndex:7];
                    if (val.length >= 20) {
                        _capturedQunPskey = val;
                        qqlog(@"[捕获] qun 域真实 p_skey 已缓存 (len=%lu)", (unsigned long)val.length);
                    }
                }
            }
        }
        // v1.2.3: qqlevel 相关无条件记录 URL（找"额外活跃"33任务的真实接口，级别Get已在上方拦截）
        if ([url containsString:@"qqlevel"] && !isLevelGet) {
            NSString *body = request.HTTPBody ? [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding] : @"";
            qqlogAsync(@"[NSURLSession] %@ %@ body=%@", request.HTTPMethod ?: @"GET", url,
                       body.length > 400 ? [body substringToIndex:400] : body);
        }
        if (_captureEnabled) {
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

// ──────────────────────────────────────────
//  网络抓包补全（2026-08-19）：原来只 hook 了 dataTaskWithRequest:completionHandler:
//  一个方法，QQ 9.3.35 大量请求走其它入口（Kuikly 的 KRHttpRequestTool、
//  QQ 自研 QQCRHttpRequest、NSURLSession 无 handler 变体、uploadTask 等）→ 抓包不全。
//  补全后：NSURLSession 3 个变体 + KRHttpRequestTool + QQCRHttpRequest setRequestUrl
// ──────────────────────────────────────────
%hook NSURLSession

// 无 completionHandler 变体（GET 常见）
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    @try {
        if (_captureEnabled) {
            NSString *url = request.URL.absoluteString ?: @"";
            if (isLevelKeyURL(url)) {
                qqlogAsync(@"[NSURLSession] %@ %@", request.HTTPMethod ?: @"GET", url);
            } else if (!_captureOnlyTasks) {
                qqlogAsync(@"[NSURLSession] %@ %@", request.HTTPMethod ?: @"GET", url);
            }
        }
    } @catch (NSException *e) {}
    return %orig(request);
}

// URL 直接变体
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    @try {
        if (_captureEnabled) {
            NSString *u = url.absoluteString ?: @"";
            if (isLevelKeyURL(u)) {
                qqlogAsync(@"[NSURLSession] GET %@", u);
            } else if (!_captureOnlyTasks) {
                qqlogAsync(@"[NSURLSession] GET %@", u);
            }
        }
    } @catch (NSException *e) {}
    return %orig(url, completionHandler);
}

// uploadTask 变体（POST body）
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    @try {
        if (_captureEnabled) {
            NSString *url = request.URL.absoluteString ?: @"";
            if (isLevelKeyURL(url)) {
                NSString *body = bodyData ? [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding] : @"";
                qqlogAsync(@"[NSURLSession] upload %@ %@ body=%@", request.HTTPMethod ?: @"POST", url, body);
            } else if (!_captureOnlyTasks) {
                qqlogAsync(@"[NSURLSession] upload %@ %@", request.HTTPMethod ?: @"POST", url);
            }
        }
    } @catch (NSException *e) {}
    return %orig(request, bodyData, completionHandler);
}

%end

// Kuikly 网络请求工具（头文件 019328_KRHttpRequestTool.h 实锤：等级页/福利页 Kuikly 渲染走这里）
%hook KRHttpRequestTool

+ (void)requestWithMethod:(id)method url:(id)url param:(id)param headers:(id)headers timeout:(float)timeout cookie:(id)cookie responseBlock:(id)responseBlock {
    @try {
        NSString *u = [url isKindOfClass:[NSString class]] ? url : @"";
        // v1.2.9: 点击「额外活跃」后的 5 秒内，无条件记录所有 Kuikly 请求（锁定33任务真实接口）
        if (_dumpAllRequests) {
            NSString *m9 = [method isKindOfClass:[NSString class]] ? method : @"GET";
            NSString *p9 = param ? [NSString stringWithFormat:@"%@", param] : @"";
            qqlogAsync(@"[DUMP-K] %@ %@ param=%@", m9, u, p9.length > 500 ? [p9 substringToIndex:500] : p9);
        }
        // v1.2.3: qqlevel 相关无条件记录（找"额外活跃"33任务的真实接口），其余按抓包开关
        if ([u containsString:@"qqlevel"] || [u containsString:@"levelTask"] || [u containsString:@"GetUserRecord"]) {
            NSString *m = [method isKindOfClass:[NSString class]] ? method : @"GET";
            NSString *p = param ? [NSString stringWithFormat:@"%@", param] : @"";
            qqlogAsync(@"[KRHttp] %@ %@ param=%@", m, u, p.length > 600 ? [p substringToIndex:600] : p);
        } else if (_captureEnabled) {
            NSString *m2 = [method isKindOfClass:[NSString class]] ? method : @"GET";
            NSString *p2 = param ? [NSString stringWithFormat:@"%@", param] : @"";
            if (isLevelKeyURL(u)) {
                qqlogAsync(@"[KRHttp] %@ %@ param=%@", m2, u, p2.length > 500 ? [p2 substringToIndex:500] : p2);
            } else if (!_captureOnlyTasks) {
                qqlogAsync(@"[KRHttp] %@ %@", method ?: @"GET", u);
            }
        }
    } @catch (NSException *e) {}
    %orig;
}

%end

// QQ 自研 CR 网络栈（头文件 023306_QQCRHttpRequest.h：requestUrl/requestType/requestBody 属性）
%hook QQCRHttpRequest

- (void)setRequestUrl:(NSString *)requestUrl {
    @try {
        NSString *u = requestUrl ?: @"";
        // v1.2.9: 点击「额外活跃」后的 5 秒内，无条件记录所有 QQCR 请求（锁定33任务真实接口）
        if (_dumpAllRequests) {
            qqlogAsync(@"[DUMP-C] setRequestUrl=%@", u);
        }
        // v1.2.3: qqlevel 相关无条件记录（找"额外活跃"33任务的真实接口）
        if ([u containsString:@"qqlevel"] || [u containsString:@"levelTask"] || [u containsString:@"GetUserRecord"]) {
            qqlogAsync(@"[QQCR] setRequestUrl=%@", u);
        } else if (_captureEnabled) {
            if (isLevelKeyURL(u)) {
                qqlogAsync(@"[QQCR] setRequestUrl=%@", u);
            } else if (!_captureOnlyTasks) {
                qqlogAsync(@"[QQCR] setRequestUrl=%@", u);
            }
        }
    } @catch (NSException *e) {}
    %orig;
}

%end

// ──────────────────────────────────────────
//  SSO/protobuf 层抓取（v1.2.18，依据 QQ 9.3.35 头文件实锤）：
//  等级页任务数据走 Kuikly SSO protobuf（trpc.metaverse.common.* 系列，
//  头文件 104742_trpc_metaverse_common_TaskInfo / 104980_QuestInfo 等），
//  NSURLSession/KRHttp 层看不到正文。回包汇聚在 NT wrapper 的
//  onSendSSOReply/onSendOidbReply（rspInfo=OCMsfRspInfo 含 pbBuffer），
//  本层只读记录 cmd+pb，绝不拦截/修改任何请求与响应。
// ──────────────────────────────────────────

__attribute__((unused)) static NSString *qqfbHex(NSData *data, NSUInteger maxLen) {
    if (!data || data.length == 0) return @"";
    NSUInteger len = MIN(data.length, maxLen);
    NSMutableString *s = [NSMutableString stringWithCapacity:len * 2 + 24];
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    for (NSUInteger i = 0; i < len; i++) {
        [s appendFormat:@"%02x", bytes[i]];
    }
    if (data.length > maxLen) {
        [s appendFormat:@"...(%luB)", (unsigned long)data.length];
    }
    return s;
}

static void qqfbLogSSOReply(NSString *channel, id cmd, int result, id errMsg, id rspInfo) {
    @try {
        NSString *cmdStr = [cmd isKindOfClass:[NSString class]] ? cmd
                          : (cmd ? [NSString stringWithFormat:@"%@", cmd] : @"?");
        if (!_dumpAllRequests) {
            if ([cmdStr rangeOfString:@"metaverse"].location == NSNotFound &&
                [cmdStr rangeOfString:@"Task"].location == NSNotFound &&
                [cmdStr rangeOfString:@"Quest"].location == NSNotFound &&
                [cmdStr rangeOfString:@"qqlevel"].location == NSNotFound &&
                [cmdStr rangeOfString:@"Score"].location == NSNotFound) {
                return;
            }
        }
        NSData *pb = nil;
        if (rspInfo && [rspInfo respondsToSelector:@selector(pbBuffer)]) {
            pb = [rspInfo valueForKey:@"pbBuffer"];
        }
        if (![pb isKindOfClass:[NSData class]]) pb = nil;
        qqlog(@"[SSO-RSP] %@ cmd=%@ result=%d err=%@ pbLen=%lu",
              channel, cmdStr, result, errMsg ?: @"", (unsigned long)pb.length);
        if (pb.length > 0) {
            qqlog(@"[SSO-PB] %@", qqfbHex(pb, 2000));
        }
    } @catch (NSException *e) {}
}

%hook OCIQQNTWrapperSession

- (void)onSendSSOReply:(long long)arg1 ssoCmd:(id)arg2 result:(int)arg3 errMsg:(id)arg4 rspInfo:(id)arg5 {
    qqfbLogSSOReply(@"SSO", arg2, arg3, arg4, arg5);
    %orig;
}

- (void)onSendOidbReply:(long long)arg1 cmd:(int)arg2 result:(int)arg3 errMsg:(id)arg4 rspInfo:(id)arg5 {
    qqfbLogSSOReply(@"OIDB", [NSString stringWithFormat:@"0x%x", arg2], arg3, arg4, arg5);
    %orig;
}

- (void)onDispatchRequestReply:(long long)arg1 cmd:(int)arg2 pbBuffer:(id)pbBuffer {
    @try {
        if (_dumpAllRequests) {
            NSData *pb = [pbBuffer isKindOfClass:[NSData class]] ? pbBuffer : nil;
            qqlog(@"[SSO-DISPATCH] cmd=0x%x pbLen=%lu", (unsigned int)arg2, (unsigned long)pb.length);
            if (pb.length > 0) qqlog(@"[SSO-PB] %@", qqfbHex(pb, 2000));
        }
    } @catch (NSException *e) {}
    %orig;
}

%end

%hook OCIQQNTWrapperEngine

- (void)onSendSSOReply:(long long)arg1 ssoCmd:(id)arg2 result:(int)arg3 errMsg:(id)arg4 rspInfo:(id)arg5 {
    qqfbLogSSOReply(@"SSO-E", arg2, arg3, arg4, arg5);
    %orig;
}

%end

// Kuikly 预请求管理器：请求侧记录 cmd（QQKuiklySSORequestItem 带 cmd/uniqueId）
%hook QQKuiklyPreRequestManager

- (id)requestBySSO:(id)request completion:(id)completion {
    @try {
        if (_dumpAllRequests && request) {
            NSString *cmd = [request respondsToSelector:@selector(cmd)] ? [request valueForKey:@"cmd"] : nil;
            NSString *uid = [request respondsToSelector:@selector(uniqueId)] ? [request valueForKey:@"uniqueId"] : nil;
            qqlog(@"[SSO-REQ] cmd=%@ uniqueId=%@", cmd ?: @"?", uid ?: @"?");
        }
    } @catch (NSException *e) {}
    return %orig;
}

// v1.2.19：等级页任务请求实走 HTTP 桥（kuiklysso.vip.qq.com/sso-0x95a8），
// 回包走 handleHTTPResponse，不走 handleSSOResponse —— 补上整条 HTTP 链路
- (id)requestByHTTP:(id)request completion:(id)completion {
    @try {
        if (_dumpAllRequests && request) {
            NSString *cmd = [request respondsToSelector:@selector(cmd)] ? [request valueForKey:@"cmd"] : nil;
            NSString *uid = [request respondsToSelector:@selector(uniqueId)] ? [request valueForKey:@"uniqueId"] : nil;
            NSString *url = [request respondsToSelector:@selector(url)] ? [request valueForKey:@"url"] : nil;
            qqlog(@"[HTTP-REQ] cmd=%@ uniqueId=%@ url=%@", cmd ?: @"?", uid ?: @"?", url ?: @"?");
        }
    } @catch (NSException *e) {}
    return %orig;
}

- (void)performHTTPRequest:(id)arg1 body:(id)body pskey:(id)pskey completion:(id)completion {
    @try {
        if (_dumpAllRequests) {
            NSString *url = [arg1 isKindOfClass:[NSString class]] ? arg1 : [NSString stringWithFormat:@"%@", arg1 ?: @"?"];
            NSData *bd = [body isKindOfClass:[NSData class]] ? body : nil;
            NSString *bodyStr = bd ? qqfbHex(bd, 1500) : ([body isKindOfClass:[NSString class]] ? body : [NSString stringWithFormat:@"%@", body ?: @""]);
            qqlog(@"[HTTP-SEND] url=%@ pskey=%d body=%@", url, (int)([pskey length]), bodyStr);
        }
    } @catch (NSException *e) {}
    %orig;
}

- (void)handleHTTPResponse:(id)response result:(id)result error:(id)error {
    @try {
        if (_dumpAllRequests) {
            NSString *respDesc = @"";
            if ([result isKindOfClass:[NSData class]]) {
                respDesc = qqfbHex(result, 2000);
            } else if (result) {
                respDesc = [NSString stringWithFormat:@"%@", result];
                if (respDesc.length > 1500) respDesc = [respDesc substringToIndex:1500];
            }
            qqlog(@"[HTTP-RSP] result=%@ err=%@", respDesc ?: @"?", error ?: @"nil");
        }
    } @catch (NSException *e) {}
    %orig;
}

- (void)saveResponseData:(id)response rspData:(id)rspData {
    @try {
        if (_dumpAllRequests) {
            NSString *d = @"";
            if ([rspData isKindOfClass:[NSData class]]) {
                d = qqfbHex(rspData, 2000);
            } else if (rspData) {
                d = [NSString stringWithFormat:@"%@", rspData];
                if (d.length > 1500) d = [d substringToIndex:1500];
            }
            qqlog(@"[HTTP-SAVE] rspData=%@", d ?: @"?");
        }
    } @catch (NSException *e) {}
    %orig;
}

- (void)handleSSOResponse:(id)response result:(id)result {
    @try {
        if (_dumpAllRequests) {
            qqlog(@"[SSO-HANDLE] response=%@ result=%@", response ?: @"?", result ?: @"?");
        }
    } @catch (NSException *e) {}
    %orig;
}

%end

// Kuikly 平台 API：sendPbRequest 是 JS 侧发 protobuf 请求的入口
// v1.2.21: 不再包装 callback block（v1.2.20 猜签名导致闪退），只记录请求；
// 响应改由下方 RohanaSwiftHook / AIRequestModule 签名确定的方法捕获
%hook QQKuiklyPlatformApi

// v1.2.23: 完整记录请求 + 安全包装 callback block 捕获响应
// v1.2.22 实测 callback 签名 v16@?0@8 = void(^)(id)（单参数，_Block_signature 实锤）
// v1.2.20 闪退根因 = 猜了多参数签名；现在签名已实锤，只对匹配签名的 block 包装
- (void)sendPbRequest:(id)arg1 {
    @try {
        if (_dumpAllRequests && arg1) {
            NSString *desc = [NSString stringWithFormat:@"%@", arg1];
            qqlog(@"[KUILKY-PB] %@", desc.length > 800 ? [desc substringToIndex:800] : desc);
            @try {
                id params = nil;
                if ([arg1 isKindOfClass:[NSDictionary class]]) params = [(NSDictionary *)arg1 objectForKey:@"param"];
                if ([arg1 respondsToSelector:@selector(objectForKey:)]) params = [arg1 objectForKey:@"param"];
                if ([params isKindOfClass:[NSArray class]] && [(NSArray *)params count] > 0) {
                    NSArray *pa = params;
                    NSString *cmd = pa[0];
                    // param[1] 是 protobuf body（NSData），完整 hex 记录
                    NSData *pbBody = ([pa count] > 1 && [pa[1] isKindOfClass:[NSData class]]) ? pa[1] : nil;
                    qqlog(@"[KUILKY-PB-REQ] cmd=%@ paramCount=%lu bodyLen=%lu bodyHex=%@",
                          cmd, (unsigned long)[pa count],
                          (unsigned long)pbBody.length,
                          pbBody ? qqfbHex(pbBody, 8000) : @"nil");
                    // 响应捕获：callback block 签名 v16@?0@8 = void(^)(id) 单参数 → 安全包装
                    if ([arg1 isKindOfClass:[NSDictionary class]]) {
                        id cb = [(NSDictionary *)arg1 objectForKey:@"callback"];
                        if (cb) {
                            @try {
                                const char *sig = _Block_signature((__bridge const void *)cb);
                                qqlog(@"[KUILKY-PB-CB] cmd=%@ callback=%@ sig=%s", cmd, cb, sig ?: "(nil)");
                                if (sig && strcmp(sig, "v16@?0@8") == 0) {
                                    // 签名实锤单参数 id → 包装：记录响应 → 调原 block
                                    void (^origBlock)(id) = cb;
                                    __block NSString *bCmd = cmd;
                                    void (^wrapBlock)(id) = ^(id result) {
                                        @try {
                                            if (_dumpAllRequests) {
                                                if ([result isKindOfClass:[NSData class]]) {
                                                    qqlog(@"[KUILKY-PB-RSP] cmd=%@ dataLen=%lu dataHex=%@",
                                                          bCmd, (unsigned long)[(NSData *)result length],
                                                          qqfbHex((NSData *)result, 8000));
                                                } else {
                                                    NSString *rd = [NSString stringWithFormat:@"%@", result];
                                                    qqlog(@"[KUILKY-PB-RSP] cmd=%@ result=%@",
                                                          bCmd, rd.length > 2000 ? [rd substringToIndex:2000] : rd);
                                                }
                                                qqfbScheduleAutoStop();
                                            }
                                        } @catch (NSException *e) {
                                            qqlog(@"[KUILKY-PB-RSP] 记录异常 %@", e);
                                        }
                                        if (origBlock) origBlock(result);
                                    };
                                    // 替换 arg1 字典里的 callback 为包装版
                                    NSMutableDictionary *md = [arg1 mutableCopy];
                                    md[@"callback"] = wrapBlock;
                                    arg1 = md;
                                    qqlog(@"[KUILKY-PB-WRAP] cmd=%@ 已包装 callback 捕获响应", cmd);
                                }
                            } @catch (NSException *e2) {
                                qqlog(@"[KUILKY-PB-CB] 探测异常 %@", e2);
                            }
                        }
                    }
                }
            } @catch (NSException *e) {}
            // 响应到达自动续期自动停止窗口
            if (_dumpAllRequests) qqfbScheduleAutoStop();
        }
    } @catch (NSException *e) {}
    %orig(arg1);
}

%end

// ── v1.2.21: RohanaSwiftHook —— QQ 自带 Kuikly PB 请求/响应配对框架（头文件 027945 实锤）──
//    全部签名确定，安全只读记录，不修改任何请求/响应
%hook RohanaSwiftHook

- (void)handleSSOResponseWithRequestId:(long long)requestId ssoCmd:(id)ssoCmd result:(int)result errMsg:(id)errMsg rspInfo:(id)rspInfo {
    @try {
        if (_dumpAllRequests) {
            qqfbLogSSOReply(@"ROHANA-SSO", ssoCmd, result, errMsg, rspInfo);
        }
    } @catch (NSException *e) {}
    %orig;
}

- (void)handleOidbResponseWithRequestId:(long long)requestId cmd:(int)cmd result:(int)result errMsg:(id)errMsg rspInfo:(id)rspInfo {
    @try {
        if (_dumpAllRequests) {
            qqfbLogSSOReply(@"ROHANA-OIDB", [NSString stringWithFormat:@"0x%x", cmd], result, errMsg, rspInfo);
        }
    } @catch (NSException *e) {}
    %orig;
}

- (id)kuiklyResponseFromCallbackResult:(id)result {
    @try {
        if (_dumpAllRequests && result) {
            NSString *out = [NSString stringWithFormat:@"%@", result];
            if (out.length > 2000) out = [out substringToIndex:2000];
            qqlog(@"[ROHANA-CB] result=%@", out);
            if ([result isKindOfClass:[NSData class]]) qqlog(@"[ROHANA-CB-HEX] %@", qqfbHex(result, 4000));
        }
    } @catch (NSException *e) {}
    return %orig;
}

- (id)overrideResponseForCmd:(id)cmd {
    @try {
        if (_dumpAllRequests && cmd) qqlog(@"[ROHANA-OVR] cmd=%@", cmd);
    } @catch (NSException *e) {}
    return %orig;
}

%end

// ── v1.2.21: AIRequestModule —— Kuikly JS 桥的 OIDB 请求/响应分发（头文件 110199 实锤）──
%hook AIRequestModule

- (void)sendOIDBRequestV2:(id)arg1 {
    @try {
        if (_dumpAllRequests && arg1) {
            NSString *desc = [NSString stringWithFormat:@"%@", arg1];
            qqlog(@"[AI-OIDB-REQ] %@", desc.length > 800 ? [desc substringToIndex:800] : desc);
        }
    } @catch (NSException *e) {}
    %orig;
}

- (void)handleOIDBResponse:(id)arg1 cmd:(id)cmd tag:(id)tag schemaTokens:(id)schemaTokens callback:(id)callback {
    @try {
        if (_dumpAllRequests) {
            NSString *out = arg1 ? [NSString stringWithFormat:@"%@", arg1] : @"nil";
            if (out.length > 2000) out = [out substringToIndex:2000];
            qqlog(@"[AI-OIDB-RSP] cmd=%@ tag=%@ response=%@", cmd ?: @"?", tag ?: @"?", out);
            if ([arg1 isKindOfClass:[NSData class]]) qqlog(@"[AI-OIDB-RSP-HEX] %@", qqfbHex(arg1, 4000));
        }
    } @catch (NSException *e) {}
    %orig;
}

%end

__attribute__((unused)) static void dumpWebKitCookies(void) {
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

// ── hash33 算法：bkn = hash33(p_skey)（经典版，已在 iOS 实锤可用）──
static int hash33(NSString *str) {
    if (!str) return 0;
    int e = 0;
    for (NSUInteger i = 0; i < str.length; i++) {
        e += (e << 5) + [str characterAtIndex:i];
    }
    return 2147483647 & e;
}

// ── ZZC sign（QQ音乐 musics.fcg 请求签名，qsped_chain.py 同源 16/16 验证）──
static NSString *zzcSign(NSString *payload) {
    if (!payload) return @"";
    // SHA-1
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    NSData *payloadData = [payload dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA1(payloadData.bytes, (CC_LONG)payloadData.length, digest);
    // hex
    char hex[41];
    for (int i = 0; i < 20; i++) sprintf(hex + i * 2, "%02x", digest[i]);
    hex[40] = 0;
    NSString *s1 = [NSString stringWithUTF8String:hex]; // 40 字符 hex
    // 索引表（与 qsped_chain.py 一致）
    int ka[] = {23, 14, 6, 36, 16, 7, 19};
    int kb[] = {16, 1, 32, 12, 19, 27, 8, 5};
    int kc[] = {89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133, 143, 161, 121, 179};
    NSMutableString *t1 = [NSMutableString string];
    for (int i = 0; i < 7; i++) [t1 appendFormat:@"%C", [s1 characterAtIndex:ka[i]]];
    NSMutableString *t2 = [NSMutableString string];
    for (int i = 0; i < 8; i++) [t2 appendFormat:@"%C", [s1 characterAtIndex:kb[i]]];
    // XOR 20 字节 → base64
    unsigned char bx[20];
    for (int i = 0; i < 20; i++) {
        NSString *pair = [s1 substringWithRange:NSMakeRange(i * 2, 2)];
        unsigned int byteVal = 0;
        [[NSScanner scannerWithString:pair] scanHexInt:&byteVal];
        bx[i] = (unsigned char)(byteVal ^ kc[i]);
    }
    NSString *b64 = [[NSData dataWithBytes:bx length:20] base64EncodedStringWithOptions:0];
    NSCharacterSet *drop = [NSCharacterSet characterSetWithCharactersInString:@"/\\+=\n\r"];
    NSString *b64clean = [[b64 componentsSeparatedByCharactersInSet:drop] componentsJoinedByString:@""];
    NSString *result = [NSString stringWithFormat:@"zzc%@%@%@", t1, b64clean, t2];
    return result.lowercaseString;
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

// ── 拿 qun.qq.com 域 p_skey（加好友/删好友专用，qsped 抓包里带 * 的特殊 key）──
//   多 keyType 尝试：qsped 抓包显示 qun 域 p_skey 与 ti 域不同（7AphPTUZBJ*... 带星号）
static NSString *getQunPskey(NSString *uin) {
    // v1.2.2: 优先用客户端原生请求捕获的真实 qun 域 p_skey（带星号，算 bkn 才正确）
    if (_capturedQunPskey && _capturedQunPskey.length > 0) {
        qqlog(@"[pskey] 用客户端捕获 qun 域 key (len=%lu)", (unsigned long)_capturedQunPskey.length);
        return _capturedQunPskey;
    }
    NSString *fallback = nil;
    for (NSString *domain in @[@"qun.qq.com", @"web.qun.qq.com", @"qunapp.qq.com"]) {
        for (int kt = 0; kt <= 3; kt++) {
            NSString *key = getPskey(domain, uin, kt);
            if (key && key.length > 0) {
                // 打码诊断：只露前3后3
                NSString *mask = key.length > 8 ? [NSString stringWithFormat:@"%@…%@", [key substringToIndex:3], [key substringFromIndex:key.length - 3]] : key;
                qqlog(@"[pskey] qun域 key: domain=%@ kt=%d len=%lu mask=%@", domain, kt, (unsigned long)key.length, mask);
                // qsped 抓包 p_skey 带 *，优先带 * 的（星号是 qun 域特有标记）
                if ([key containsString:@"*"]) return key;
                if (!fallback) fallback = key;
            }
        }
    }
    if (fallback) qqlog(@"[pskey] qun域 无带*key，用 fallback");
    return fallback;
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

// ── 同步 POST JSON + 自定义额外 header（v1.2.1 拉全量任务用）──
static NSDictionary *httpPostJSONEx(NSString *url, NSDictionary *bodyDict, NSString *cookieHeader,
                                    int timeoutSec, NSDictionary *extraHeaders) {
    @try {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        if (cookieHeader) [req setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
        for (NSString *k in extraHeaders.allKeys) {
            NSString *v = extraHeaders[k];
            if (v) [req setValue:v forHTTPHeaderField:k];
        }
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

// ── 同步 POST 原始文本（支持任意 body 字符串 + 额外 header），返回完整响应文本 ──
static NSString *httpPostText(NSString *url, NSString *bodyString, NSString *contentType,
                              NSString *cookieHeader, NSDictionary *extraHeaders, int timeoutSec) {
    @try {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        req.HTTPMethod = @"POST";
        [req setValue:(contentType ?: @"application/json") forHTTPHeaderField:@"Content-Type"];
        if (cookieHeader) [req setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
        [req setValue:@"Mozilla/5.0 (Linux; Android 13; M2105K81AC Build/TKQ1.221013.002; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/121.0.6167.71 MQQBrowser/6.2 TBS/047903 Mobile Safari/537.36" forHTTPHeaderField:@"User-Agent"];
        [req setValue:@"https://ti.qq.com/qqlevel/index" forHTTPHeaderField:@"Referer"];
        for (NSString *k in extraHeaders.allKeys) {
            NSString *v = extraHeaders[k];
            if (v) [req setValue:v forHTTPHeaderField:k];
        }
        req.HTTPBody = [bodyString dataUsingEncoding:NSUTF8StringEncoding];

        __block NSString *result = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = timeoutSec;
        cfg.timeoutIntervalForResource = timeoutSec + 5;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
        [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (!err && data) {
                result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (!result) result = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
            } else if (err) {
                result = [NSString stringWithFormat:@"__ERR__%@", err.localizedDescription ?: @""];
            }
            dispatch_semaphore_signal(sem);
        }] resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (timeoutSec + 10) * NSEC_PER_SEC));
        [session finishTasksAndInvalidate];
        return result;
    } @catch (NSException *e) {
        qqlog(@"[httpText] 异常 %@", e);
    }
    return nil;
}

// ── 取 skey（QQLoginPSKeyManager keyType=0 通常是 skey 域；失败回退从 cookie 拿）──
static NSString *getSkey(NSString *uin) {
    @try {
        for (NSString *domain in @[@"qq.com", @"", @"web.qun.qq.com"]) {
            NSString *sk = getPskey(domain, uin, 0);
            if (sk && sk.length > 0) return sk;
        }
    } @catch (NSException *e) {}
    return nil;
}

// ── 拉取任务列表：levelTask/Get ──
//  v1.2.1: mode 用 "all"(安卓实锤) 而非 42，避免 iOS 审核过滤只回 10 个任务；
//          UA 用安卓 MQQBrowser(与 qsped 安卓端一致)，服务端按平台/模式决定 is_ios_review_hide
static NSArray *fetchTaskList(NSString *uin, NSString *tiPskey, int *retCodeOut) {
    @try {
        int bkn = hash33(tiPskey);
        NSString *url = [NSString stringWithFormat:@"https://ti.qq.com/qqlevel/trpc/levelTask/Get?bkn=%d", bkn];
        NSString *cookie = [NSString stringWithFormat:@"uin=o%@; p_uin=o%@; p_skey=%@", uin, uin, tiPskey];
        NSDictionary *resp = httpPostJSONEx(url, @{@"mode": @"all"}, cookie, 15,
            @{@"User-Agent": @"MQQBrowser/6.2 TBS/046905 QQ/9.0.0 V1_AND_SQ_9.0.0_0_YYB_A",
              @"Origin": @"https://ti.qq.com",
              @"Referer": @"https://ti.qq.com/qqlevel/task-center?version=2"});
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
//   2026-08-19 用户定案：任务满足条件自动完成，无需点击领取 → 本函数暂不调用（保留供后续"怎么做"）
//   普通任务 body：{SubActId, ClientPlat, Aid, EnteranceId, ActReqData}
__attribute__((unused)) static BOOL execActClaim(NSDictionary *task, NSString *uin, NSString *qzonePskey) {
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
//   2026-08-19 用户定案：任务满足条件自动完成 → 本函数暂不调用（保留供后续"怎么做"）
__attribute__((unused)) static BOOL benefitClaimChain(NSString *uin, NSString *vipPskey) {
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

// ── 跳转任务页（jump_schema 可能是 mqqapi:// 深链 或 https:// h5 链接）──
static void openJumpSchema(NSString *jump) {
    if (!jump || jump.length == 0) return;
    NSURL *url = nil;
    if ([jump hasPrefix:@"https://"] || [jump hasPrefix:@"http://"]) {
        // h5 链接必须用 mqqapi 容器打开（直接 openURL 会被 QQ 外部浏览器接管）
        NSData *b64 = [[jump dataUsingEncoding:NSUTF8StringEncoding] base64EncodedDataWithOptions:0];
        NSString *b64Str = [[NSString alloc] initWithData:b64 encoding:NSUTF8StringEncoding];
        NSString *wrapped = [NSString stringWithFormat:@"mqqapi://forward/url?src_type=web&version=1&url_prefix=%@", b64Str];
        url = [NSURL URLWithString:wrapped];
    } else {
        url = [NSURL URLWithString:jump];
    }
    if (url) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

// ── 打开等级页（Kuikly 原生，tab=6 任务页）──
static void openLevelPage(void) {
    NSURL *url = [NSURL URLWithString:@"mqqapi://forward/url?src_type=web&version=1&url_prefix=aHR0cHM6Ly90aS5xcS5jb20vcXFsZXZlbC9pbmRleD92ZXJzaW9uPTEmdGFiPTYmc291cmNlPTE1"];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

// ── 在任务列表里按标题找任务状态（-1=不存在）──
static int findTaskStatusByTitle(NSArray *taskList, NSString *title) {
    for (NSDictionary *task in taskList) {
        if (![task isKindOfClass:[NSDictionary class]]) continue;
        NSString *t = task[@"title"] ?: @"";
        if ([t isEqualToString:title]) {
            NSNumber *s = task[@"status"];
            return s ? [s intValue] : -1;
        }
    }
    return -1;
}

// ── 提前声明：runAutoTasks 里调用（定义在其后）──
static void autoTapAllWebViews(void);
static void collectWebViewsInView(UIView *view, NSMutableArray *outArr);
static void appendLogView(NSString *msg);   // v1.1.0 任务面板代码先于定义使用

// ══════════════════════════════════════════
//  qsped 式纯后台任务执行器（v1.1.0）
//  接口来自 qsped 运行时抓包实锤（D:/android-build/qsped_rerun.log）
//  全部直接 POST，零页面点击，防封防检测
// ══════════════════════════════════════════

// ── 组装等级任务通用 Cookie（p_skey 体系 + skey 尝试）──
static NSString *levelCookie(NSString *uin, NSString *extraPskeyDomain) {
    NSString *pskey = getPskey(@"ti.qq.com", uin, 1);
    if (!pskey) pskey = getPskey(@"ti.qq.com", uin, 0);
    NSString *skey = getSkey(uin);
    NSString *qunPskey = getPskey(extraPskeyDomain ?: @"ti.qq.com", uin, 1);
    if (!qunPskey) qunPskey = pskey;
    NSMutableString *ck = [NSMutableString string];
    if (skey && skey.length > 0) [ck appendFormat:@"skey=%@; ", skey];
    [ck appendFormat:@"uin=o%@; p_uin=o%@; p_skey=%@", uin, uin, qunPskey];
    return ck;
}

// ── 日签卡打卡（纯后台）─
//  实测接口: POST ti.qq.com/hybrid-h5/api/json/daily_attendance/SignIn
//  Cookie: skey/uin/p_uin/p_skey
static BOOL runDailySignTask(NSString *uin) {
    qqlog(@"[任务] 日签卡打卡…");
    NSString *cookie = levelCookie(uin, @"ti.qq.com");
    // body 先试空对象，如失败再根据响应调整
    NSString *resp = httpPostText(@"https://ti.qq.com/hybrid-h5/api/json/daily_attendance/SignIn",
                                  @"{}", @"application/json", cookie, nil, 15);
    if (!resp) { qqlog(@"[任务] 日签卡 无响应"); return NO; }
    qqlog(@"[任务] 日签卡 响应: %@", resp.length > 500 ? [resp substringToIndex:500] : resp);
    if ([resp containsString:@"__ERR__"]) { qqlog(@"[任务] 日签卡 网络错误"); return NO; }
    // 响应含 errCode/ret：0 或成功标志
    return !([resp containsString:@"\"ret\":-"] || [resp containsString:@"\"code\":-"] || [resp containsString:@"\"errCode\":-"]);
}

// ── 加好友（纯后台，qsped 实锤接口）──
//  实测接口: POST web.qun.qq.com/qunrobot/proxy/domain/qun.qq.com/cgi-bin/qunapp/robots_addfriend?bkn=
//  headers: qname-service: 976321:131072, qname-space: Production
//  机器人号: qsped 抓包里加的是机器人（robots），body 需测试确认
static BOOL runAddFriendTask(NSString *uin, NSString *targetUin) {
    qqlog(@"[任务] 加好友 %@…", targetUin ?: @"?");
    if (!targetUin || targetUin.length == 0) { qqlog(@"[任务] 加好友 缺目标号"); return NO; }
    NSString *pskey = getQunPskey(uin);
    if (!pskey) pskey = getPskey(@"qun.qq.com", uin, 1);
    if (!pskey) pskey = getPskey(@"web.qun.qq.com", uin, 1);
    if (!pskey) { qqlog(@"[任务] 加好友 拿不到 qun 域 p_skey"); return NO; }
    int bkn = hash33(pskey);
    NSString *url = [NSString stringWithFormat:@"https://web.qun.qq.com/qunrobot/proxy/domain/qun.qq.com/cgi-bin/qunapp/robots_addfriend?bkn=%d", bkn];
    NSString *cookie = [NSString stringWithFormat:@"skey=%@; uin=o%@; p_uin=o%@; p_skey=%@",
                        (getSkey(uin) ?: @""), uin, uin, pskey];
    NSDictionary *extra = @{
        @"qname-service": @"976321:131072",
        @"qname-space": @"Production",
        @"Origin": @"https://web.qun.qq.com",
        @"Referer": @"https://web.qun.qq.com/",
        @"User-Agent": @"Mozilla/5.0 (Linux; Android 13; M2105K81AC Build/TKQ1.221013.002; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/104.0.5112.97 Mobile Safari/537.36 V1_AND_SQ_9.2.0_10970_YYB_D QQ/9.2.0.28325 NetType/WIFI",
    };
    // body: qsped 抓包是 form 编码，body 需实测（先用最小 form）
    NSString *body = [NSString stringWithFormat:@"to_uin=%@&from=%@&verify=1", targetUin, uin];
    NSString *resp = httpPostText(url, body, @"application/x-www-form-urlencoded", cookie, extra, 15);
    if (!resp) { qqlog(@"[任务] 加好友 无响应"); return NO; }
    qqlog(@"[任务] 加好友 响应: %@", resp.length > 500 ? [resp substringToIndex:500] : resp);
    return YES; // 结果判断等真实响应后定
}

// ── 删好友（纯后台，测试模式收尾用）──
static BOOL runRemoveFriendTask(NSString *uin, NSString *targetUin) {
    qqlog(@"[任务] 删好友 %@…", targetUin ?: @"?");
    if (!targetUin || targetUin.length == 0) return NO;
    NSString *pskey = getQunPskey(uin);
    if (!pskey) pskey = getPskey(@"qun.qq.com", uin, 1);
    if (!pskey) pskey = getPskey(@"web.qun.qq.com", uin, 1);
    if (!pskey) { qqlog(@"[任务] 删好友 拿不到 qun 域 p_skey"); return NO; }
    int bkn = hash33(pskey);
    NSString *url = [NSString stringWithFormat:@"https://web.qun.qq.com/qunrobot/proxy/domain/qun.qq.com/cgi-bin/qunapp/robots_removefriend?bkn=%d", bkn];
    NSString *cookie = [NSString stringWithFormat:@"skey=%@; uin=o%@; p_uin=o%@; p_skey=%@",
                        (getSkey(uin) ?: @""), uin, uin, pskey];
    NSDictionary *extra = @{
        @"qname-service": @"976321:131072",
        @"qname-space": @"Production",
        @"Origin": @"https://web.qun.qq.com",
        @"Referer": @"https://web.qun.qq.com/",
        @"User-Agent": @"Mozilla/5.0 (Linux; Android 13; M2105K81AC Build/TKQ1.221013.002; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/104.0.5112.97 Mobile Safari/537.36 V1_AND_SQ_9.2.0_10970_YYB_D QQ/9.2.0.28325 NetType/WIFI",
    };
    NSString *body = [NSString stringWithFormat:@"to_uin=%@&from=%@", targetUin, uin];
    NSString *resp = httpPostText(url, body, @"application/x-www-form-urlencoded", cookie, extra, 15);
    if (!resp) { qqlog(@"[任务] 删好友 无响应"); return NO; }
    qqlog(@"[任务] 删好友 响应: %@", resp.length > 500 ? [resp substringToIndex:500] : resp);
    return YES;
}

// ── 金币兑换等级加速（QQ音乐 musics.fcg，ZZC sign 已复刻）──
//  注意: 需要 qm_keyst cookie（QQ音乐域），iOS QQ 内可能没有，先探测
static BOOL runCoinExchangeTask(NSString *uin) {
    qqlog(@"[任务] 金币兑换加速…");
    // 探测 qm_keyst
    NSString *qmKey = nil;
    @try {
        Class mgrCls = NSClassFromString(@"QQLoginPSKeyManager");
        id mgr = mgrCls ? ((id (*)(id, SEL))objc_msgSend)(mgrCls, NSSelectorFromString(@"sharedInstance")) : nil;
        if (mgr) {
            for (NSString *dom in @[@"y.qq.com", @"u6.y.qq.com", @"i2.y.qq.com"]) {
                for (int kt = 0; kt <= 2; kt++) {
                    NSString *k = getPskey(dom, uin, kt);
                    if (k && k.length > 0) { qmKey = k; break; }
                }
                if (qmKey) break;
            }
        }
    } @catch (NSException *e) {}
    if (!qmKey) {
        qqlog(@"[任务] 金币兑换 无 qm_keyst（QQ音乐登录态不在本机，需小号抓包或跳过）");
        return NO;
    }
    qqlog(@"[任务] 金币兑换 找到 qm_keyst，走 musics.fcg…");
    // 兑换 body: 与 qsped_bot.py exchange 一致
    NSString *bodyStr = @"{\"comm\":{\"uin\":%lld,\"format\":\"json\",\"inCharset\":\"utf-8\",\"outCharset\":\"utf-8\",\"notice\":0,\"platform\":\"h5\",\"needNewCode\":1,\"ct\":23,\"cv\":0},\"req_0\":{\"module\":\"music.pointcgi.ExchangeCgi\",\"method\":\"QQAccelerateTaskFulfillment\",\"param\":{\"taskID\":1084}}}";
    bodyStr = [NSString stringWithFormat:bodyStr, [uin longLongValue]];
    // ZZC sign 算法（C 实现，qsped_chain.py 同源）
    NSString *sign = zzcSign(bodyStr);
    NSString *url = [NSString stringWithFormat:@"https://u6.y.qq.com/cgi-bin/musics.fcg?sign=%@", sign];
    NSString *cookie = [NSString stringWithFormat:@"uin=o%@; qm_keyst=%@", uin, qmKey];
    NSDictionary *extra = @{@"Origin": @"https://y.qq.com", @"Referer": @"https://y.qq.com/"};
    NSString *resp = httpPostText(url, bodyStr, @"application/json", cookie, extra, 15);
    if (!resp) { qqlog(@"[任务] 金币兑换 无响应"); return NO; }
    qqlog(@"[任务] 金币兑换 响应: %@", resp.length > 500 ? [resp substringToIndex:500] : resp);
    return YES;
}

// ── 发空间说说（纯后台，qsped 实锤接口）──
static BOOL runShuoshuoTask(NSString *uin, NSString *content) {
    qqlog(@"[任务] 发布空间说说…");
    NSString *pskey = getPskey(@"qzone.qq.com", uin, 1);
    if (!pskey) pskey = getPskey(@"user.qzone.qq.com", uin, 1);
    if (!pskey) pskey = getPskey(@"ti.qq.com", uin, 1);
    if (!pskey) { qqlog(@"[任务] 发说说 拿不到 p_skey"); return NO; }
    int gtk = hash33(pskey);
    NSString *url = [NSString stringWithFormat:@"https://user.qzone.qq.com/proxy/domain/taotao.qzone.qq.com/cgi-bin/emotion_cgi_publish_v6?g_tk=%d", gtk];
    NSString *cookie = [NSString stringWithFormat:@"p_uin=o%@; p_skey=%@; uin=o%@", uin, pskey, uin];
    NSString *text = content ?: @"等级任务打卡";
    // body 格式: qzone publish_v6 标准 form（con=内容&format=json&...）
    NSString *body = [NSString stringWithFormat:@"con=%@&feedversion=1&ver=1&ugc_right=1&format=json&richtype=1&richtext=&private=0&to_sign=0&uin=%@&rd=0", text, uin];
    NSString *resp = httpPostText(url, body, @"application/x-www-form-urlencoded", cookie, nil, 15);
    if (!resp) { qqlog(@"[任务] 发说说 无响应"); return NO; }
    qqlog(@"[任务] 发说说 响应: %@", resp.length > 500 ? [resp substringToIndex:500] : resp);
    return YES;
}

// ── 空间点赞（纯后台）──
static BOOL runLikeTask(NSString *uin, NSString *targetUin) {
    qqlog(@"[任务] 空间点赞…");
    NSString *pskey = getPskey(@"qzone.qq.com", uin, 1);
    if (!pskey) pskey = getPskey(@"ti.qq.com", uin, 1);
    if (!pskey) { qqlog(@"[任务] 点赞 拿不到 p_skey"); return NO; }
    int gtk = hash33(pskey);
    NSString *url = [NSString stringWithFormat:@"https://h5.qzone.qq.com/proxy/domain/w.qzone.qq.com/cgi-bin/likes/internal_dolike_app?g_tk=%d", gtk];
    NSString *cookie = levelCookie(uin, @"qzone.qq.com");
    NSString *body = [NSString stringWithFormat:@"to_uin=%@&uin=%@&format=json", targetUin ?: uin, uin];
    NSString *resp = httpPostText(url, body, @"application/x-www-form-urlencoded", cookie, nil, 15);
    if (!resp) { qqlog(@"[任务] 点赞 无响应"); return NO; }
    qqlog(@"[任务] 点赞 响应: %@", resp.length > 500 ? [resp substringToIndex:500] : resp);
    return YES;
}

// ── 按任务标题分派执行（点「做」按钮走这里）──
static void execTaskByTitle(NSString *title, NSString *uin) {
    if (!title) return;
    if ([title containsString:@"日签卡"]) {
        runDailySignTask(uin);
    } else if ([title containsString:@"加一位好友"] || [title containsString:@"加好友"]) {
        runAddFriendTask(uin, @"10001"); // 机器人号待定，测试时日志确认
    } else if ([title containsString:@"金币兑换"] || [title containsString:@"金币"]) {
        runCoinExchangeTask(uin);
    } else if ([title containsString:@"说说"] || [title containsString:@"空间"]) {
        runShuoshuoTask(uin, nil);
    } else if ([title containsString:@"点赞"] || [title containsString:@"好友动态"]) {
        runLikeTask(uin, nil);
    } else {
        qqlog(@"[任务] %@ 无纯后台接口，跳转页面…", title);
    }
}

// ── 一键任务主流程：自动导航执行（v1.0.7 升级）──
//   点一键 → 逐个打开未完成任务页 → 日志实时显示正在做哪个 → 自动检测状态变化
//   能做自动完成的自动确认；需要手动操作的跳转页面引导用户点一下，然后自动验证
__attribute__((unused)) static void runAutoTasks(void) {
    if (_taskRunning) {
        qqlog(@"[auto] 任务执行已在运行中");
        return;
    }
    _taskRunning = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            qqlog(@"\n========== 一键任务自动执行开始 ==========");

            // ══ ① 取 uin + ti 域 p_skey ══
            NSString *uin = getCurrentUin();
            NSString *tiPskey = getPskey(@"ti.qq.com", uin, 1);
            if (!tiPskey) tiPskey = getPskey(@"ti.qq.com", uin, 0);
            if (!tiPskey) {
                qqlog(@"[auto] ✗ 拿不到 ti 域 p_skey，无法执行任务");
                _taskRunning = NO;
                return;
            }

            // ══ ② 拉任务列表 ══
            int retCode = 0;
            NSArray *taskList = fetchTaskList(uin, tiPskey, &retCode);
            if (!taskList || taskList.count == 0) {
                qqlog(@"[auto] ✗ 任务列表为空 (ret=%d)", retCode);
                _taskRunning = NO;
                return;
            }

            // ══ ③ 分类：未做且能做的任务（按原始顺序）══
            NSMutableArray *todoTasks = [NSMutableArray array];
            int doneCnt = 0, cannotCnt = 0;
            for (NSDictionary *task in taskList) {
                if (![task isKindOfClass:[NSDictionary class]]) continue;
                NSString *title = task[@"title"] ?: task[@"task_name"] ?: @"?";
                NSNumber *statusNum = task[@"status"];
                int status = statusNum ? [statusNum intValue] : -1;
                NSString *buttonText = task[@"button_text"] ?: @"";
                NSString *extendStr = task[@"extend"] ?: @"";
                NSString *jump = task[@"jump_schema"] ?: @"";

                BOOL isBlocked = NO;
                if ([buttonText containsString:@"开通"] || [buttonText containsString:@"充值"] ||
                    [buttonText containsString:@"购买"] || [buttonText containsString:@"升级"] ||
                    [buttonText containsString:@"会员"] || [buttonText containsString:@"需"] ||
                    [extendStr containsString:@"is_ios_review_hide"] || [extendStr containsString:@"\"hide\":true"]) {
                    isBlocked = YES;
                }

                if (isBlocked) {
                    cannotCnt++;
                    qqlog(@"[task] ⛔ 跳过不能做: %@ (按钮:%@)", title, buttonText);
                } else if (status == 0 || status == -1) {
                    if (jump.length > 0) {
                        [todoTasks addObject:@{@"title": title, @"jump": jump}];
                        qqlog(@"[task] ▶ 待执行: %@ (跳转:%@)", title, jump);
                    } else {
                        qqlog(@"[task] 📋 未做且无跳转: %@ (需手动在等级页完成)", title);
                    }
                } else if (status >= 1) {
                    doneCnt++;
                    qqlog(@"[task] ✅ 已完成: %@ (status=%d)", title, status);
                }
            }
            qqlog(@"[auto] 本次待执行 %lu 个任务", (unsigned long)todoTasks.count);

            if (todoTasks.count == 0) {
                qqlog(@"[auto] ══ 汇总: 已完成=%d 跳过=%d 无待执行任务 ══", doneCnt, cannotCnt);
                _taskRunning = NO;
                return;
            }

            // ══ ④ 逐个自动执行：跳转页面 → 注入 JS 自动点按钮 → 验证状态 ══
            int execDone = 0, execSkip = 0;
            for (int i = 0; i < (int)todoTasks.count; i++) {
                NSDictionary *item = todoTasks[i];
                NSString *title = item[@"title"];
                NSString *jump = item[@"jump"];
                qqlog(@"[auto] ── [%d/%lu] 正在做: %@ ──", i + 1, (unsigned long)todoTasks.count, title);
                qqlog(@"[auto] 跳转任务页 + 注入自动点击…");
                dispatch_async(dispatch_get_main_queue(), ^{
                    openJumpSchema(jump);
                });
                // 页面加载 + JS 自动点击：等待 6 秒后注入，共注入 3 轮
                for (int round = 0; round < 3; round++) {
                    [NSThread sleepForTimeInterval:6];
                    autoTapAllWebViews();
                }
                [NSThread sleepForTimeInterval:4];

                // 重新拉列表验证该任务是否完成
                NSArray *freshList = fetchTaskList(uin, tiPskey, NULL);
                int st = findTaskStatusByTitle(freshList ?: taskList, title);
                if (st >= 1) {
                    execDone++;
                    qqlog(@"[auto] ✅ 完成: %@ (status=%d)", title, st);
                } else {
                    execSkip++;
                    qqlog(@"[auto] ⏭ 未完成: %@ (status=%d，可能需更多操作，稍后可在等级页手动处理)", title, st);
                }
            }

            // ══ ⑤ 汇总 + 回到等级页 ══
            qqlog(@"[auto] ══ 汇总: 完成=%d 未完成=%d 已完成=%d 跳过=%d ══", execDone, execSkip, doneCnt, cannotCnt);
            qqlog(@"[auto] 自动跳回等级页…");
            dispatch_async(dispatch_get_main_queue(), ^{
                openLevelPage();
            });
        } @catch (NSException *e) {
            qqlog(@"[auto] 主流程异常: %@", e);
        }
        _taskRunning = NO;
    });
}

// ══════════════════════════════════════════
//  任务列表面板 UI（v1.1.0 新 UI，替代系统弹窗）
//  勾选任务 → 执行勾选；测试模式 → 加好友→删好友
// ══════════════════════════════════════════

// ── 任务状态文案 ──
static NSString *taskStatusText(NSDictionary *task) {
    NSNumber *s = task[@"status"];
    int st = s ? [s intValue] : -1;
    if (st >= 1) return @"✅已完成";
    if (st == 0) return @"▶可做";
    return @"❓未知";
}

// ── 加速天数文案（accelerate_days 字段）──
static NSString *taskDaysText(NSDictionary *task) {
    id days = task[@"accelerate_days"];
    if (days) {
        double d = [days doubleValue];
        return [NSString stringWithFormat:@"+%.1f天", d];
    }
    NSString *title = task[@"title"] ?: @"";
    NSRange r = [title rangeOfString:@"\\+[0-9.]+天" options:NSRegularExpressionSearch];
    if (r.location != NSNotFound) {
        return [title substringWithRange:r];
    }
    return @"";
}

// ── 内置任务定义（v1.2.0：已实锤纯后台接口，可单独测试）──
//  勾选用 key = builtin_<idx>，与额外活跃任务的 task_id 区分
static NSArray *builtinTaskDefs(void) {
    return @[
        @{@"title": @"日签卡打卡", @"needTarget": @NO},
        @{@"title": @"加好友", @"needTarget": @YES},
        @{@"title": @"删好友", @"needTarget": @YES},
        @{@"title": @"发空间说说", @"needTarget": @NO},
        @{@"title": @"空间点赞", @"needTarget": @YES},
        @{@"title": @"金币兑换加速", @"needTarget": @NO},
    ];
}

// ── 执行内置任务（idx 对应 builtinTaskDefs 下标）──
static BOOL execBuiltinTask(int idx, NSString *uin, NSString *targetUin) {
    switch (idx) {
        case 0: return runDailySignTask(uin);
        case 1: return runAddFriendTask(uin, targetUin);
        case 2: return runRemoveFriendTask(uin, targetUin);
        case 3: return runShuoshuoTask(uin, @"等级任务打卡");
        case 4: return runLikeTask(uin, targetUin);
        case 5: return runCoinExchangeTask(uin);
        default: return NO;
    }
}

// ── 渲染任务列表（v1.2.0：内置任务组 + 额外活跃任务组）──
static void renderTaskRows(void) {
    if (!_taskScroll) return;
    for (UIView *sub in _taskScroll.subviews) [sub removeFromSuperview];
    CGFloat y = 6;
    CGFloat rowH = 46;
    CGFloat w = _taskScroll.bounds.size.width;

    // ── 组1: 内置任务（可单独测试）──
    NSArray *builtin = builtinTaskDefs();
    if (builtin.count > 0) {
        UILabel *grpLb = [[UILabel alloc] initWithFrame:CGRectMake(10, y, w - 20, 20)];
        grpLb.text = @"⬡ 内置任务（已实锤接口，可单测）";
        grpLb.textColor = [UIColor systemCyanColor];
        grpLb.font = [UIFont boldSystemFontOfSize:11];
        [_taskScroll addSubview:grpLb];
        y += 22;
        for (int i = 0; i < (int)builtin.count; i++) {
            NSDictionary *def = builtin[i];
            NSString *title = def[@"title"] ?: @"?";
            UIView *row = [[UIView alloc] initWithFrame:CGRectMake(6, y, w - 12, rowH)];
            row.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
            row.layer.cornerRadius = 8;
            row.userInteractionEnabled = YES;

            // 勾选框
            UIButton *chk = [UIButton buttonWithType:UIButtonTypeCustom];
            chk.frame = CGRectMake(8, (rowH - 28) / 2.0, 28, 28);
            chk.tag = i;
            NSString *bid = [NSString stringWithFormat:@"builtin_%d", i];
            BOOL checked = _checkedTaskIds && [_checkedTaskIds containsObject:bid];
            [chk setTitle:checked ? @"☑" : @"☐" forState:UIControlStateNormal];
            [chk setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            chk.titleLabel.font = [UIFont systemFontOfSize:18];
            [chk addTarget:[UIApplication sharedApplication] action:@selector(_builtinCheckTapped:) forControlEvents:UIControlEventTouchUpInside];
            [row addSubview:chk];

            // 标题
            UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(42, 4, w - 12 - 42 - 100, 26)];
            tl.text = title;
            tl.textColor = [UIColor whiteColor];
            tl.font = [UIFont systemFontOfSize:12];
            tl.numberOfLines = 1;
            tl.lineBreakMode = NSLineBreakByTruncatingTail;
            [row addSubview:tl];

            // 加速天数占位（内置任务固定 +0.5）
            UILabel *dl = [[UILabel alloc] initWithFrame:CGRectMake(w - 12 - 8 - 74, 4, 74, 18)];
            dl.text = @"+0.5天";
            dl.textColor = [UIColor systemYellowColor];
            dl.font = [UIFont systemFontOfSize:11];
            dl.textAlignment = NSTextAlignmentRight;
            [row addSubview:dl];

            // 测试按钮（单个测试）
            UIButton *testBtn = [UIButton buttonWithType:UIButtonTypeCustom];
            testBtn.frame = CGRectMake(w - 12 - 8 - 74, 24, 74, 18);
            testBtn.tag = i;
            [testBtn setTitle:@"▶ 测试" forState:UIControlStateNormal];
            [testBtn setTitleColor:[UIColor systemOrangeColor] forState:UIControlStateNormal];
            testBtn.titleLabel.font = [UIFont systemFontOfSize:10];
            [testBtn addTarget:[UIApplication sharedApplication] action:@selector(_builtinTestTapped:) forControlEvents:UIControlEventTouchUpInside];
            [row addSubview:testBtn];

            [_taskScroll addSubview:row];
            y += rowH + 4;
        }
        y += 6;
    }

    // ── 组2: 额外活跃任务（一键获取自等级页数据源）──
    NSArray *list = _taskListCache;
    if (!list || list.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(10, y, w - 20, 40)];
        empty.text = @"额外活跃任务为空，点「🔄获取」拉取";
        empty.textColor = [UIColor whiteColor];
        empty.font = [UIFont systemFontOfSize:12];
        empty.numberOfLines = 0;
        [_taskScroll addSubview:empty];
        return;
    }
    UILabel *grpLb2 = [[UILabel alloc] initWithFrame:CGRectMake(10, y, w - 20, 20)];
    grpLb2.text = [NSString stringWithFormat:@"☀ 额外活跃任务（%lu 个）", (unsigned long)list.count];
    grpLb2.textColor = [UIColor systemYellowColor];
    grpLb2.font = [UIFont boldSystemFontOfSize:11];
    [_taskScroll addSubview:grpLb2];
    y += 22;
    for (int i = 0; i < (int)list.count; i++) {
        NSDictionary *task = list[i];
        if (![task isKindOfClass:[NSDictionary class]]) continue;
        NSString *title = task[@"title"] ?: task[@"task_name"] ?: @"?";
        NSString *tid = task[@"task_id"] ?: @"";
        NSString *days = taskDaysText(task);
        NSString *status = taskStatusText(task);

        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(6, y, w - 12, rowH)];
        row.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
        row.layer.cornerRadius = 8;
        row.userInteractionEnabled = YES;

        // 勾选框
        UIButton *chk = [UIButton buttonWithType:UIButtonTypeCustom];
        chk.frame = CGRectMake(8, (rowH - 28) / 2.0, 28, 28);
        chk.tag = i;
        BOOL checked = _checkedTaskIds && [tid length] > 0 && [_checkedTaskIds containsObject:tid];
        [chk setTitle:checked ? @"☑" : @"☐" forState:UIControlStateNormal];
        [chk setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        chk.titleLabel.font = [UIFont systemFontOfSize:18];
        [chk addTarget:[UIApplication sharedApplication] action:@selector(_taskCheckTapped:) forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:chk];

        // 标题（可两行）
        UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(42, 4, w - 12 - 42 - 80, 26)];
        tl.text = title;
        tl.textColor = [UIColor whiteColor];
        tl.font = [UIFont systemFontOfSize:12];
        tl.numberOfLines = 1;
        tl.lineBreakMode = NSLineBreakByTruncatingTail;
        [row addSubview:tl];

        // 加速天数
        UILabel *dl = [[UILabel alloc] initWithFrame:CGRectMake(w - 12 - 8 - 74, 4, 74, 18)];
        dl.text = days;
        dl.textColor = [UIColor systemYellowColor];
        dl.font = [UIFont systemFontOfSize:11];
        dl.textAlignment = NSTextAlignmentRight;
        [row addSubview:dl];

        // 状态
        UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(w - 12 - 8 - 74, 24, 74, 16)];
        sl.text = status;
        sl.textColor = [UIColor systemGreenColor];
        sl.font = [UIFont systemFontOfSize:10];
        sl.textAlignment = NSTextAlignmentRight;
        [row addSubview:sl];

        [_taskScroll addSubview:row];
        y += rowH + 4;
    }
    _taskScroll.contentSize = CGSizeMake(w, y + 10);
}

// ── 刷新任务列表（拉接口 → 渲染）──
static void refreshTaskListUI(void) {
    // v1.2.2: 优先用客户端原生捕获的全量任务列表（QQ 自己请求带 skey 全凭证，服务端给全量）
    // v1.2.12: 不再在日志区提示「使用客户端原生全量」（用户要求静默，捕获信息由 [捕获] 日志记录）
    if (_capturedTaskList && _capturedTaskList.count > 0) {
        _taskListCache = _capturedTaskList;
        if (!_checkedTaskIds) _checkedTaskIds = [NSMutableSet set];
        renderTaskRows();
        return;
    }
    appendLogView(@"🔄 拉取任务列表…");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *uin = getCurrentUin();
        NSString *tiPskey = getPskey(@"ti.qq.com", uin, 1);
        if (!tiPskey) tiPskey = getPskey(@"ti.qq.com", uin, 0);
        int retCode = 0;
        NSArray *list = nil;
        if (tiPskey) list = fetchTaskList(uin, tiPskey, &retCode);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (list && list.count > 0) {
                _taskListCache = list;
                if (!_checkedTaskIds) _checkedTaskIds = [NSMutableSet set];
                appendLogView([NSString stringWithFormat:@"✅ 拉取 %lu 个任务", (unsigned long)list.count]);
            } else {
                appendLogView([NSString stringWithFormat:@"❌ 任务列表为空 (ret=%d, pskey=%@)", retCode, tiPskey ? @"有" : @"无"]);
                appendLogView(@"💡 请点「🌐等级页」打开等级任务页，客户端会自动加载全量任务，再点「🔄获取」");
            }
            renderTaskRows();
        });
    });
}

// ── 顶部安全区高度(灵动岛/刘海) ──
static CGFloat safeTopInset(void) {
    CGFloat topInset = 20;
    UIWindow *mainWin = [UIApplication sharedApplication].keyWindow;
    if (@available(iOS 11.0, *)) {
        if (mainWin && mainWin.safeAreaInsets.top > 0) topInset = mainWin.safeAreaInsets.top;
    }
    return topInset;
}

// ── 显示任务面板 ──
static void showTaskPanel(void) {
    if (_taskPanel) { // 已开则收起
        [_taskPanel removeFromSuperview];
        _taskPanel = nil;
        _logView = nil;
        _logTextView = nil;
        _taskScroll = nil;
        return;
    }
    if (!_floatWindow) return;
    CGRect frame = _floatWindow.bounds;
    CGFloat w = MIN(330, frame.size.width - 16);
    // v1.1.4: 面板默认显示在安全区下方, 不压灵动岛(否则顶部拖拽区收不到触摸)
    CGFloat y = safeTopInset() + 70;
    CGFloat h = MIN(480, frame.size.height - y - 40);
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(frame.size.width - w - 8, y, w, h)];
    panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    panel.layer.cornerRadius = 14;
    panel.layer.masksToBounds = YES;
    panel.userInteractionEnabled = YES;
    _taskPanel = panel;

    // 标题栏
    UILabel *titleLb = [[UILabel alloc] initWithFrame:CGRectMake(12, 10, 140, 22)];
    titleLb.text = @"⚡ iOS等级页抓取";
    titleLb.textColor = [UIColor whiteColor];
    titleLb.font = [UIFont boldSystemFontOfSize:15];
    [panel addSubview:titleLb];

    // 标题栏拖动条：仅覆盖标题区域，不能挡住右侧两个独立操作按钮。
    UIView *dragBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 112, 40)];
    dragBar.backgroundColor = [UIColor clearColor];
    dragBar.userInteractionEnabled = YES;
    UIPanGestureRecognizer *panelPan = [[UIPanGestureRecognizer alloc] initWithTarget:[UIApplication sharedApplication]
                                                                              action:@selector(_taskPanelPanned:)];
    [dragBar addGestureRecognizer:panelPan];
    [panel addSubview:dragBar];
    [panel bringSubviewToFront:dragBar];

    // 两个操作：打开并抓取（先开抓包再打开页面），或单独抓取当前页面。
    UIButton *openBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    openBtn.frame = CGRectMake(w - 184, 8, 78, 26);
    [openBtn setTitle:@"🌐 打开并抓取" forState:UIControlStateNormal];
    [openBtn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    openBtn.titleLabel.font = [UIFont systemFontOfSize:11];
    [openBtn addTarget:[UIApplication sharedApplication] action:@selector(_taskOpenLevelPageTapped:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:openBtn];

    UIButton *captureBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    captureBtn.frame = CGRectMake(w - 108, 8, 78, 26);
    [captureBtn setTitle:@"⏺ 抓取" forState:UIControlStateNormal];
    [captureBtn setTitleColor:[UIColor systemGreenColor] forState:UIControlStateNormal];
    captureBtn.titleLabel.font = [UIFont systemFontOfSize:11];
    [captureBtn addTarget:[UIApplication sharedApplication] action:@selector(_taskCaptureTapped:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:captureBtn];

    // 关闭
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(w - 30, 8, 24, 26);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    [closeBtn addTarget:[UIApplication sharedApplication] action:@selector(_taskCloseTapped:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:closeBtn];

    // 日志区：不内置安卓任务列表、不执行任务；页面抓到什么就显示什么。
    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(6, 44, w - 12, h - 50)];
    tv.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
    tv.layer.cornerRadius = 6;
    tv.textColor = [UIColor whiteColor];
    tv.font = [UIFont systemFontOfSize:10];
    tv.editable = NO;
    tv.selectable = YES;
    tv.text = @"iOS 等级页抓取日志：\n点「打开并抓取」会先开启抓包，再打开等级页，记录 30 秒初始化请求。\n也可以先进入页面，再点「抓取」补抓当前页面。\n\n";
    _logTextView = tv;
    _logView = panel;
    [panel addSubview:tv];

    [_floatWindow addSubview:panel];
}

// ══════════════════════════════════════════
//  AI 对话分析（v1.2.11，参考微信插件 wxresearch 对话模式）
//  用途：把当前任务列表/抓包数据打包发给 DeepSeek，分析每个任务怎么做
//  key 留空（QQFB_AI_KEY_UD 存 NSUserDefaults），用户在面板「🤖AI」里自己填
// ══════════════════════════════════════════
static NSString *qqfbAIRequest(NSArray *messages, int timeoutSec) {
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:QQFB_AI_KEY_UD];
    if (!apiKey || ![apiKey length]) return nil;
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"model"] = QQFB_AI_MODEL;
    payload[@"messages"] = messages;
    payload[@"temperature"] = @(0.7);
    payload[@"max_tokens"] = @(4096);
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!bodyData) return nil;
    NSURL *url = [NSURL URLWithString:@"https://api.deepseek.com/chat/completions"];
    NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:url];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    [req setHTTPBody:bodyData];
    [req setTimeoutInterval:timeoutSec];
    NSHTTPURLResponse *resp = nil;
    NSError *err = nil;
    NSData *respData = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
    qqlog(@"[AI] resp status=%ld len=%lu err=%@", (long)resp.statusCode, (unsigned long)respData.length, err);
    if (err || !respData) return nil;
    if (resp.statusCode != 200) return nil;
    return [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding];
}

static NSString *qqfbAIExtractContent(NSString *jsonStr) {
    if (!jsonStr) return nil;
    NSData *data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!obj) return nil;
    NSArray *choices = obj[@"choices"];
    if (![choices count]) return nil;
    return choices[0][@"message"][@"content"];
}

// 把任务列表打包成文本给 AI 分析
static NSString *taskListToAIText(NSArray *tasks) {
    if (!tasks || !tasks.count) return @"（当前无任务数据，请先点「🔄获取」或打开等级页抓包）";
    NSMutableString *s = [NSMutableString string];
    for (NSDictionary *t in tasks) {
        NSString *title = t[@"title"] ?: @"";
        id days = t[@"accelerate_days"];
        NSString *jump = t[@"jump_schema"] ?: @"";
        NSString *status = [t[@"status"] intValue] == 1 ? @"已完成" : ([t[@"status"] intValue] == 2 ? @"可领取" : @"待完成");
        [s appendFormat:@"- [%@] %@ (+%@天) status=%@ jump=%@\n",
         status, title, days ? [NSString stringWithFormat:@"%.1f", [days doubleValue]] : @"?",
         status, jump];
    }
    return s;
}

// 后台线程调 AI，主线程回调显示（对话模式：自动带历史）
static void qqfbAIRun(NSString *userQuestion) {
    if (_aiBusy) { appendLogView(@"🤖 AI 正在分析中，稍等…"); return; }
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:QQFB_AI_KEY_UD];
    if (!apiKey || ![apiKey length]) {
        appendLogView(@"⚠️ 未配置 API key：请先在面板点「🔑Key」填写（留空无法调用）");
        return;
    }
    _aiBusy = YES;
    appendLogView(@"🤖 AI 思考中…");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            // 组装 system 提示（任务数据 + 抓包现状 + 让 AI 分析每个任务怎么做）
            NSMutableArray *messages = [NSMutableArray array];
            NSMutableString *sysPrompt = [NSMutableString string];
            [sysPrompt appendString:@"你是 QQ 等级加速任务自动化助手。用户手机装了 QQ 悬浮球插件，插件能抓取等级页任务数据并调用部分后台接口。\n"];
            [sysPrompt appendString:@"以下是当前抓到的任务列表（title=任务名, jump=跳转深链/页面）：\n"];
            [sysPrompt appendString:taskListToAIText(_taskListCache ?: _capturedTaskList)];
            [sysPrompt appendString:@"\n请分析：1) 每个任务怎么做（跳转什么页面/调什么接口） 2) 哪些能自动完成、哪些只能跳页面 3) 给出按顺序执行的建议。用中文，条理清晰。"];
            [messages addObject:@{@"role": @"system", @"content": sysPrompt}];
            // 已有历史则带历史（对话模式）
            for (NSDictionary *m in _aiHistory) [messages addObject:m];
            [messages addObject:@{@"role": @"user", @"content": userQuestion}];

            NSString *jsonStr = qqfbAIRequest(messages, 60);
            NSString *reply = qqfbAIExtractContent(jsonStr);
            dispatch_async(dispatch_get_main_queue(), ^{
                _aiBusy = NO;
                if (!reply) {
                    appendLogView(@"❌ AI 调用失败（检查 key 是否正确 / 网络）");
                    return;
                }
                if (!_aiHistory) _aiHistory = [NSMutableArray array];
                [_aiHistory addObject:@{@"role": @"user", @"content": userQuestion}];
                [_aiHistory addObject:@{@"role": @"assistant", @"content": reply}];
                appendLogView([NSString stringWithFormat:@"🤖 AI：%@", reply]);
            });
        }
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

__attribute__((unused)) static void showLogPanel(void) {
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
- (void)_taskCheckTapped:(UIButton *)sender;
- (void)_builtinCheckTapped:(UIButton *)sender;
- (void)_builtinTestTapped:(UIButton *)sender;
- (void)_taskRefreshTapped:(UIButton *)sender;
- (void)_taskCloseTapped:(UIButton *)sender;
- (void)_taskExecCheckedTapped:(UIButton *)sender;
- (void)_taskOpenLevelPageTapped:(UIButton *)sender;
- (void)_taskCaptureTapped:(UIButton *)sender;
@end

%hook UIApplication
%new
- (void)_closeLogPanel:(UIButton *)sender {
    if (_logView) {
        [_logView removeFromSuperview];
        _logView = nil;
        _logTextView = nil;
        _taskScroll = nil;
        _taskPanel = nil;
    }
}
%end

// ── 任务面板按钮处理（v1.1.0）──
%hook UIApplication
%new
- (void)_taskCheckTapped:(UIButton *)sender {
    int idx = (int)sender.tag;
    if (!_taskListCache || idx < 0 || idx >= (int)_taskListCache.count) return;
    NSDictionary *task = _taskListCache[idx];
    NSString *tid = task[@"task_id"] ?: @"";
    if (tid.length == 0) return;
    if (!_checkedTaskIds) _checkedTaskIds = [NSMutableSet set];
    if ([_checkedTaskIds containsObject:tid]) {
        [_checkedTaskIds removeObject:tid];
    } else {
        [_checkedTaskIds addObject:tid];
    }
    renderTaskRows();
    appendLogView([NSString stringWithFormat:@"☑ 勾选: %@", task[@"title"] ?: tid]);
}

%new
- (void)_builtinCheckTapped:(UIButton *)sender {
    int idx = (int)sender.tag;
    NSArray *builtin = builtinTaskDefs();
    if (idx < 0 || idx >= (int)builtin.count) return;
    NSString *bid = [NSString stringWithFormat:@"builtin_%d", idx];
    if (!_checkedTaskIds) _checkedTaskIds = [NSMutableSet set];
    if ([_checkedTaskIds containsObject:bid]) {
        [_checkedTaskIds removeObject:bid];
    } else {
        [_checkedTaskIds addObject:bid];
    }
    renderTaskRows();
    appendLogView([NSString stringWithFormat:@"☑ 勾选: %@", builtin[idx][@"title"]]);
}

%new
- (void)_builtinTestTapped:(UIButton *)sender {
    int idx = (int)sender.tag;
    NSArray *builtin = builtinTaskDefs();
    if (idx < 0 || idx >= (int)builtin.count) return;
    NSString *title = builtin[idx][@"title"];
    NSString *uin = getCurrentUin();
    appendLogView([NSString stringWithFormat:@"🧪 测试: %@", title]);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL ok = execBuiltinTask(idx, uin, _friendRobotUin);
        appendLogView([NSString stringWithFormat:@"%@ %@: %@", ok ? @"✅" : @"❌", title, ok ? @"已执行(详见日志)" : @"失败(详见日志)"]);
    });
}

%new
- (void)_taskRefreshTapped:(UIButton *)sender {
    refreshTaskListUI();
}

%new
- (void)_taskCloseTapped:(UIButton *)sender {
    if (_taskPanel) {
        [_taskPanel removeFromSuperview];
        _taskPanel = nil;
        _logView = nil;
        _logTextView = nil;
        _taskScroll = nil;
    }
}

%new
- (void)_taskAITapped:(UIButton *)sender {
    // v1.2.11: AI 对话分析——首次点弹窗填 key（留空用户自己填），再点分析当前任务
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:QQFB_AI_KEY_UD];
    if (!apiKey || ![apiKey length]) {
        // 无 key：弹窗输入
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"配置 DeepSeek API Key"
                                                                    message:@"填一次即可（存本机），key 留空无法调用 AI"
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"sk-...";
            tf.secureTextEntry = YES;
        }];
        [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *k = [ac.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (k.length) {
                [[NSUserDefaults standardUserDefaults] setObject:k forKey:QQFB_AI_KEY_UD];
                appendLogView(@"✅ API key 已保存，点「🤖 AI」开始分析");
            } else {
                appendLogView(@"⚠️ key 为空，未保存");
            }
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *top = [[UIApplication sharedApplication] keyWindow].rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        [top presentViewController:ac animated:YES completion:nil];
        return;
    }
    // 有 key：清空历史后开始分析当前任务
    _aiHistory = [NSMutableArray array];
    qqfbAIRun(@"分析当前任务列表：每个任务怎么做、哪些能自动完成，给出执行建议");
}

%new
- (void)_taskKeyTapped:(UIButton *)sender {
    // 换 key / 查看当前 key 状态
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:QQFB_AI_KEY_UD];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"DeepSeek API Key"
                                                                message:apiKey.length ? [NSString stringWithFormat:@"当前已配置（…%@）", [apiKey substringFromIndex:MAX(0, (NSInteger)apiKey.length - 4)]] : @"当前未配置"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"sk-...";
        tf.text = apiKey ?: @"";
        tf.secureTextEntry = YES;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *k = [ac.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (k.length) {
            [[NSUserDefaults standardUserDefaults] setObject:k forKey:QQFB_AI_KEY_UD];
            appendLogView(@"✅ API key 已更新");
        } else {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:QQFB_AI_KEY_UD];
            appendLogView(@"⚠️ key 已清空");
        }
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *top = [[UIApplication sharedApplication] keyWindow].rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:ac animated:YES completion:nil];
}

%new
- (void)_taskOpenLevelPageTapped:(UIButton *)sender {
    // 关键时序：先开启抓包，再打开等级页，确保不漏掉首轮初始化请求。
    if (_dumpAllRequests) {
        appendLogView(@"[iOS抓取] 已在抓取中，请直接进入等级界面");
        return;
    }
    _dumpAllRequests = YES;
    appendLogView(@"[iOS抓取] 已开启，准备打开等级页…");
    qqlog(@"[iOS抓取] 先开抓包，再打开等级页");
    // v1.2.22: 打开等级页即启动自动停止窗口（响应到达自动续期，8 秒无新数据自动停）
    qqfbScheduleAutoStop();

    NSString *pageUrl = @"https://ti.qq.com/qqlevel/index?_wv=3&_wwv=1&tab=6&source=15";
    NSData *bd = [pageUrl dataUsingEncoding:NSUTF8StringEncoding];
    NSString *b64 = [bd base64EncodedStringWithOptions:0];
    NSString *deep = [NSString stringWithFormat:@"mqqapi://forward/url?src_type=web&version=1&url_prefix=%@", b64];
    NSURL *u = [NSURL URLWithString:deep];
    if (!u || ![[UIApplication sharedApplication] canOpenURL:u]) {
        _dumpAllRequests = NO;
        appendLogView(@"[iOS抓取] 无法拉起等级页深链");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
        appendLogView(@"[iOS抓取] 等级页已打开，响应到达后自动停止");
        qqlog(@"[iOS抓取] 等级页已打开，抓包窗口（响应驱动自动停止）");
    });
}
%new
- (void)_taskCaptureTapped:(UIButton *)sender {
    // 仅抓取当前页面的真实网络流量，响应到达后自动停止（v1.2.22）。
    if (_dumpAllRequests) {
        appendLogView(@"[iOS抓取] 正在记录中，请等待当前窗口结束");
        return;
    }
    _dumpAllRequests = YES;
    appendLogView(@"[iOS抓取] 开始只读记录（响应驱动自动停止）");
    qqlog(@"[iOS抓取] 开始只读记录（响应驱动自动停止）");
    qqfbScheduleAutoStop();
}

%new
- (void)_taskExecCheckedTapped:(UIButton *)sender {
    if (!_checkedTaskIds || _checkedTaskIds.count == 0) {
        appendLogView(@"⚠️ 先勾选任务再执行");
        return;
    }
    NSString *uin = getCurrentUin();
    appendLogView([NSString stringWithFormat:@"▶ 开始执行 %lu 个勾选任务…", (unsigned long)_checkedTaskIds.count]);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 先执行内置任务组
        NSArray *builtin = builtinTaskDefs();
        for (int i = 0; i < (int)builtin.count; i++) {
            NSString *bid = [NSString stringWithFormat:@"builtin_%d", i];
            if (![_checkedTaskIds containsObject:bid]) continue;
            NSString *title = builtin[i][@"title"];
            qqlog(@"[任务] ── 执行内置: %@ ──", title);
            execBuiltinTask(i, uin, _friendRobotUin);
            [NSThread sleepForTimeInterval:2];
        }
        // 再执行额外活跃任务组
        for (NSDictionary *task in _taskListCache) {
            if (![task isKindOfClass:[NSDictionary class]]) continue;
            NSString *tid = task[@"task_id"] ?: @"";
            if (!tid || ![_checkedTaskIds containsObject:tid]) continue;
            NSString *title = task[@"title"] ?: @"?";
            qqlog(@"[任务] ── 执行: %@ ──", title);
            execTaskByTitle(title, uin);
            [NSThread sleepForTimeInterval:2];
        }
        appendLogView(@"✅ 勾选任务执行完毕（详见日志）");
    });
}
%end

// ══════════════════════════════════════════
//  WKWebView JS 自动点击（v1.0.8 qsped 式全自动）
//  打开任务页后主动轮询注入 JS 自动点「打卡/签到/领取/发布/完成」按钮
//  ⚠️ 不 hook WKWebView 类（swizzle 会导致 dylib 加载失败/球消失），
//     全部用 NSClassFromString + performSelector 动态调用，加载零风险
// ══════════════════════════════════════════

// ── 递归收集 WKWebView（不引用 WKWebView 头文件，防编译/加载依赖）──
static void collectWebViewsInView(UIView *view, NSMutableArray *outArr) {
    if (!view) return;
    if ([view isKindOfClass:NSClassFromString(@"WKWebView")]) {
        [outArr addObject:view];
    }
    for (UIView *sub in view.subviews) {
        collectWebViewsInView(sub, outArr);
    }
}

// ── 对单个 webView 注入自动点击 JS（纯动态调用，无 swizzle）──
static void autoTapWebView(id webView) {
    @try {
        if (!webView) return;
        SEL evalSel = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
        if (![webView respondsToSelector:evalSel]) return;
        NSURL *u = [webView valueForKey:@"URL"];
        NSString *url = u.absoluteString ?: @"";
        qqlog(@"[autotap] 注入页面: %@", url.length > 100 ? [url substringToIndex:100] : url);
        NSString *js =
        @"(function(){"
        "  var kws=['签到','立即签到','一键签到','打卡','立即打卡','领取','立即领取','去完成','发布','发表','确定','同意','完成','去打卡','已打卡','领福利'];"
        "  function tryClick(root){"
        "    var els=root.querySelectorAll('button,a,div,span,p,li,input[type=button],input[type=submit]');"
        "    for(var i=0;i<els.length;i++){"
        "      var el=els[i];"
        "      if(el.offsetParent===null) continue;"
        "      var t=(el.innerText||el.textContent||el.value||'').trim();"
        "      if(!t||t.length>12) continue;"
        "      for(var k=0;k<kws.length;k++){"
        "        if(t.indexOf(kws[k])!==-1){"
        "          el.click();"
        "          return '点击:'+t;"
        "        }"
        "      }"
        "    }"
        "    return '';"
        "  }"
        "  var r=tryClick(document);"
        "  if(!r){ window.scrollTo(0,document.body.scrollHeight); setTimeout(function(){r=tryClick(document);},800); }"
        "  return r;"
        "})()";
        void (^handler)(id, NSError *) = ^(id result, NSError *err) {
            if (err) {
                qqlog(@"[autotap] JS 执行失败: %@", err.localizedDescription);
            } else if (result) {
                qqlog(@"[autotap] JS 结果: %@", result);
            }
        };
        // NSInvocation 调用 evaluateJavaScript:completionHandler:（绕开 ARC performSelector 警告）
        NSMethodSignature *sig = [webView methodSignatureForSelector:evalSel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:webView];
            [inv setSelector:evalSel];
            [inv setArgument:&js atIndex:2];
            [inv setArgument:&handler atIndex:3];
            [inv invoke];
        } else {
            qqlog(@"[autotap] 无方法签名");
        }
    } @catch (NSException *e) {
        qqlog(@"[autotap] 注入异常: %@", e);
    }
}

// ── 遍历所有 window 找 WKWebView 注入自动点击 JS ──
static void autoTapAllWebViews(void) {
    @try {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *found = [NSMutableArray array];
            for (UIWindow *win in [UIApplication sharedApplication].windows) {
                collectWebViewsInView(win, found);
            }
            if (found.count == 0) {
                qqlog(@"[autotap] 未找到 WKWebView（页面可能还在加载）");
                return;
            }
            for (id wv in found) {
                autoTapWebView(wv);
            }
        });
    } @catch (NSException *e) {
        qqlog(@"[autotap] 遍历异常: %@", e);
    }
}

// ── 枚举 ObjC 类（找网络桥接类，只读安全）──
__attribute__((unused)) static void dumpObjCClasses(void) {
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
__attribute__((unused)) static void dumpPSKeys(void) {
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
    // ⚠️ iOS 13+ 必须关联 windowScene！否则 UIWindow 不参与 hitTest/触摸路由，
    //    表现为"球看得见但点了没反应"（2026-08-19 实锤根因）
    floatWindow.windowScene = targetScene;
    floatWindow.rootViewController = [UIViewController new];

    // ── 方案B：挂靠 QQ 顶层悬浮窗体系（2026-08-19 头文件实锤）──
    //    QQ 9.3.35 有 QQFloatingWindowTopLevelWindowManager（032238），
    //    它统一管理所有悬浮窗层级并随时 refreshWindowLevel。
    //    我们自建窗口若不走这套体系，QQ 一有浮层（来电窗/游戏浮窗/小助手浮窗）
    //    就会盖住我们 → "点了没反应"。
    //    acquireTopLevelWindowHighLevel: 把自己的窗口申请到 QQ 的顶层，
    //    层级永远跟 QQ 走，不打架。类不存在时静默跳过（兼容旧版本）。
    @try {
        // 声明为 Class + 已声明私有接口，编译器认得 selector；类不存在时静默降级
        Class topWinMgr = NSClassFromString(@"QQFloatingWindowTopLevelWindowManager");
        if (topWinMgr && [topWinMgr respondsToSelector:@selector(acquireTopLevelWindowHighLevel:)]) {
            [topWinMgr acquireTopLevelWindowHighLevel:floatWindow];
            // 双保险：参照 QQ 顶层窗口的实际 windowLevel，把我们的窗口提到它之上。
            // 不能 addSubview 嵌套 window（会破坏事件路由），只能比层级。
            double targetLevel = UIWindowLevelAlert + 1;   // 兜底 2001
            id topWin = [topWinMgr topLevelWindow];
            if (topWin && [topWin isKindOfClass:[UIWindow class]]) {
                double lv = [(UIWindow *)topWin windowLevel];
                if (lv > 0) targetLevel = lv + 1;
            }
            floatWindow.windowLevel = targetLevel;
        }
    } @catch (NSException *e) {
        // QQ 内部实现变化时静默降级为独立窗口
    }

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
//  点击球 → 打开/收起任务列表面板（v1.1.0，不再弹系统弹窗）
// ──────────────────────────────────────────
%new
- (void)_floatBallTapped:(UIButton *)sender {
    qqlog(@"[action] 点球 → 任务面板");
    showTaskPanel();
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

// ──────────────────────────────────────────
//  任务面板拖动（手势在标题栏 dragBar 上，拖动 _taskPanel 整体）
// ──────────────────────────────────────────
%new
- (void)_taskPanelPanned:(UIPanGestureRecognizer *)pan {
    if (!_taskPanel) return;
    UIView *panel = _taskPanel;
    CGPoint translation = [pan translationInView:panel.superview];
    if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint newCenter = CGPointMake(panel.center.x + translation.x,
                                        panel.center.y + translation.y);
        CGFloat halfW = panel.bounds.size.width / 2.0;
        CGFloat halfH = panel.bounds.size.height / 2.0;
        CGFloat minX = halfW;
        CGFloat maxX = panel.superview.bounds.size.width - halfW;
        // v1.1.4: 面板顶部不允许拖进灵动岛/状态栏区域(否则拖拽区收不到触摸)
        CGFloat minY = safeTopInset() + 20 + halfH;
        CGFloat maxY = panel.superview.bounds.size.height - halfH;
        newCenter.x = MAX(minX, MIN(maxX, newCenter.x));
        newCenter.y = MAX(minY, MIN(maxY, newCenter.y));
        panel.center = newCenter;
        [pan setTranslation:CGPointZero inView:panel.superview];
    }
}
%end

// ══════════════════════════════════════════
//  Kuikly 等级页生命周期监控（v1.2.6）
//  头文件实锤: QQKuiklyService.jumpKuiklyPageWithWebUrl: 是 web→Kuikly 跳转入口;
//  KuiklyRenderViewControllerDelegator 持有每个 Kuikly 页面的 pageName/renderView
//  目的: 确认等级页打开链路 + 拿到等级页 renderView 以便操作(切分页/点展开)
// ══════════════════════════════════════════
%hook QQKuiklyService
+ (BOOL)jumpKuiklyPageWithWebUrl:(id)url {
    qqlog(@"[Kuikly] jumpKuiklyPageWithWebUrl: %@", url);
    BOOL r = %orig;
    qqlog(@"[Kuikly] jumpKuiklyPageWithWebUrl → %d", r);
    return r;
}
+ (BOOL)tryTojumpKuiklyPageWithWebUrl:(id)url {
    qqlog(@"[Kuikly] tryTojumpKuiklyPageWithWebUrl: %@", url);
    BOOL r = %orig;
    qqlog(@"[Kuikly] tryTojumpKuiklyPageWithWebUrl → %d", r);
    return r;
}
+ (id)pageNameFromUrl:(id)url {
    id r = %orig;
    qqlog(@"[Kuikly] pageNameFromUrl: %@ → %@", url, r);
    return r;
}
+ (void)handleSchemeNotifiction:(id)arg1 {
    qqlog(@"[Kuikly] handleSchemeNotifiction: %@", arg1);
    %orig;
}
%end

%hook KuiklyRenderViewControllerDelegator
- (id)initWithPageName:(id)arg1 pageData:(id)arg2 {
    self = %orig;
    qqlog(@"[KuiklyVC] init pageName=%@ pageData=%@", arg1, arg2);
    return self;
}
- (void)contentViewDidLoadWithrenderView:(id)arg1 {
    qqlog(@"[KuiklyVC] contentViewDidLoad pageName=%@ view=%@", [(id)self valueForKey:@"pageName"], arg1);
    %orig;
}
- (void)viewDidAppear {
    qqlog(@"[KuiklyVC] viewDidAppear pageName=%@", [(id)self valueForKey:@"pageName"]);
    %orig;
}
%end

%hook KuiklyRenderView
- (id)initWithSize:(CGSize)arg1 contextCode:(id)arg2 contextParam:(id)arg3 params:(id)arg4 delegate:(id)arg5 {
    self = %orig;
    qqlog(@"[KuiklyView] init pageName=%@ size=%@", [(id)self valueForKey:@"pageName"], NSStringFromCGSize(arg1));
    return self;
}
- (void)viewDidAppear {
    qqlog(@"[KuiklyView] viewDidAppear pageName=%@", [(id)self valueForKey:@"pageName"]);
    %orig;
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
        // v1.2.10: 球建好后不自动弹面板（用户明确要求"默认面板不要打开就弹出来"）
    });
}
