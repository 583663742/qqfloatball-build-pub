#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonCrypto.h>
#import <substrate.h>

// ─────────────────────────────────────────────
// QQFloatBall 浮球
// v1.7.1 (2026-09-02):
//   · 0x9172 任务按服务端分组解析：field4.field3=付费加倍(pay,6个) field4.field4=日常活跃(daily,2个) field4.field5=额外活跃天数(extra,26个)
//   · 任务 JSON 每项带 group 标记；顶层 groups 统计 + dataUin（0x9172 响应体真实账号，可核对旧数据）
//   · 面板/闭环/自动任务/勾选执行全部只取 extra 组（用户需求：付费加倍与日常活跃不要）
//   · taskId 兼容 field20（extra 组用，实锤 24/23/1010..）与 field6（pay 组用，实锤 801-806）
//   · 0x9172 数据实锤来源：真机 KUILKY-PB-RSP hex 离线解析（2026-09-01 日志）
// v1.7.0 (2026-09-02):
//   · 修复 getCurrentUin 账号误判：捕获客户端请求 Cookie 里的真实 uin（_capturedCurrentUin），
//     优先返回真实登录账号。此前靠「哪个号有 ti 域 p_skey」猜账号，820284286 旧缓存
//     残留导致自动任务全发给旧账号（robots_addfriend csrf 100021 根因之一）
//   · 0x9172 解析 JSON 增加 uin 字段，任务状态可核对所属账号
// v1.6.9 (2026-09-02):
//   · 原生 UI 自动点击：发布说说/盲盒签等原生页面（无 WKWebView）——
//     遍历原生视图树找 UITextView 填文字 + 找「签到/打卡/发表/发布/分享」
//     按钮 sendActionsForControlEvents 直接点（用户要求「进去要操作的」任务）
//   · 修 QQWebView 老容器 valueForUndefinedKey: URL 噪音（安全读取）
// v1.6.8 (2026-09-01):
//   · autotap 收集放宽：不再是「必须是 WKWebView 类」，凡 respondsToSelector
//     evaluateJavaScript:completionHandler: 的视图都注入（覆盖 QQ 内部 H5 容器）
//   · 注入窗口 3轮×6s → 5轮×5s，覆盖盲盒签等慢加载页面
//   · 二次注入：首轮点击（签到）后 2.5s 再注入，命中「发布到空间/分享」
// v1.6.7:
//   · 等级域按域分开捕获（ti/club p_skey 不同值，SignIn 用 club key 必 -3000）
//   · levelCookie 按目标域选 key；runAutoTasks 完整自动导航
// v1.6.6:
//   · qun 域 bkn=hash33(skey)，按域捕获
// ─────────────────────────────────────────────
// v1.7.3 (2026-09-02):
//   · 「🔍 获取任务」改为实时获取：自动开抓包+打开等级页额外活跃tab，等新 0x9172 后自动刷新面板
//   · 显示额外活跃天数组全部任务（付费/已完成/无跳转都显示，不过滤）——用户需求「实时获取所有任务不管能不能做」
//   · 版本号显示修复：面板标题显示真实版本（此前硬编码 v1.6.6 误导）
#define kQQFloatBallVersion @"1.8.5"

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
// v1.6.7: 等级域按域分开捕获！实测 ti.qq.com 与 club.vip.qq.com 的 p_skey 是不同值，
//         SignIn(ti.qq.com) 用 club 域 key 必 -3000。按 URL 域精确归类
static NSString *_capturedTiPskey = nil;    // ti.qq.com 域（日签卡 SignIn 用）
static NSString *_capturedClubPskey = nil;  // club.vip.qq.com 域（等级页 Kuikly 接口用）
// ── 客户端原生请求捕获的全局 skey（v1.6.6：qun 域 bkn=hash33(skey)，getLocalKeyOfDomain 拿不到 skey）──
static NSString *_capturedSkey = nil;
// ── v1.7.0: 客户端真实请求 Cookie 里捕获的当前登录 uin（getCurrentUin 优先用真实值，不再靠 p_skey 猜账号）──
static NSString *_capturedCurrentUin = nil;

// ── 抓包开关：YES=记录网络请求；NO=停止 ──
// v1.1.0 起不再有抓包入口（防封防检测），代码保留但默认关
static BOOL _captureEnabled = NO;
// ── 仅抓等级关键词（keyTask）时才包装响应；全量模式只记请求不碰响应（防 Kuikly 白屏）──
static BOOL _captureOnlyTasks = NO;
// ── v1.2.9: 点击「额外活跃」后 5 秒内无条件记录所有请求 URL+body（锁定33任务真实接口）──
// v1.2.11: 打开等级页后立即开启 8 秒 DUMP（等级页一打开就拉取全量任务，不需点额外活跃）
static BOOL _dumpAllRequests = NO;
// v1.8.3: 会员状态缓存（福利社 GetZone 响应解析；非会员领券任务做不了直接跳过）
static BOOL _userIsSvip = NO;
static BOOL _userSvipChecked = NO;
// v1.4: 闭环执行进行中（暂停抓包自动停止，保证执行后重抓 0x9172 不被 8 秒定时器打断）
static BOOL _closedLoopRunning = NO;

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

// ── v1.5.0: 抓包改为手动控制 —— 不点「停止抓包」不停止（用户定案：要确定抓住所有包）
//  qqfbScheduleAutoStop 保留为 no-op（闭环流程有自己的 _dumpAllRequests 开关，不依赖这里）
static BOOL _autoStopScheduled = NO;
static void qqfbScheduleAutoStop(void) {
    // v1.5.0: 手动抓包模式——自动停止已禁用，抓包持续到用户点「⏹ 停止抓包」
    return;
#if 0
    // v1.4: 闭环执行期间禁止自动停（否则 8 秒无新响应会关抓包，导致执行后重抓 0x9172 失败）
    if (_closedLoopRunning) return;
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
#endif
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
                        // v1.8.3: 解析福利社 GetZone 响应的会员状态——非会员领券任务做不了
                        if ([url containsString:@"GetZone"] && !_userSvipChecked) {
                            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                            NSDictionary *uinfo = [obj isKindOfClass:[NSDictionary class]] ? obj[@"userInfo"] : nil;
                            if ([uinfo isKindOfClass:[NSDictionary class]]) {
                                _userIsSvip = [uinfo[@"isSvip"] boolValue];
                                _userSvipChecked = YES;
                                qqlog(@"[svip] 会员状态: isSvip=%d vipLevel=%@ (福利社领券任务据此跳过/执行)",
                                      _userIsSvip, uinfo[@"vipLevel"] ?: @"?");
                            }
                        }
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
        // v1.6.3: 顺带捕获全局 skey（qun 域 bkn=hash33(skey)，加好友必需）
        // v1.6.6: 全等级域打 Cookie 诊断——找 web 有效的短 skey（iOS 客户端 skey 是 44 字符长值，web 接口不认）
        if (request.allHTTPHeaderFields[@"Cookie"]) {
            NSString *ck = request.allHTTPHeaderFields[@"Cookie"];
            BOOL isQun = [url containsString:@"qun.qq.com"];
            BOOL isLevelDom = ([url containsString:@"ti.qq.com"] || [url containsString:@"club.vip.qq.com"]
                               || [url containsString:@"y.qq.com"] || [url containsString:@"vip.qq.com"]
                               || [url containsString:@"web.qq.com"] || [url containsString:@"qzone.qq.com"]);
            if (isQun || isLevelDom) {
                NSArray *parts = [ck componentsSeparatedByString:@";"];
                for (NSString *part in parts) {
                    NSString *trim = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    // v1.7.0: 捕获 Cookie 里的真实 uin（等级页/群请求都带，直接拿当前登录账号）
                    if ([trim hasPrefix:@"uin="]) {
                        NSString *val = [trim substringFromIndex:4];
                        if (val.length > 0 && val.length < 20 && [val rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound) {
                            _capturedCurrentUin = val;
                        }
                    }
                    if ([trim hasPrefix:@"p_skey="]) {
                        NSString *val = [trim substringFromIndex:7];
                        if (val.length >= 20) {
                            if (isQun) {
                                _capturedQunPskey = val;
                                qqlog(@"[捕获] qun 域真实 p_skey 已缓存 (len=%lu)", (unsigned long)val.length);
                            } else if ([url containsString:@"ti.qq.com"]) {
                                _capturedTiPskey = val;
                                qqlog(@"[捕获] ti.qq.com 域真实 p_skey 已缓存 (len=%lu)", (unsigned long)val.length);
                            } else if (!_capturedClubPskey) {
                                _capturedClubPskey = val;
                                qqlog(@"[捕获] club 域真实 p_skey 已缓存 (len=%lu)", (unsigned long)val.length);
                            }
                        }
                    } else if ([trim hasPrefix:@"skey="]) {
                        NSString *val = [trim substringFromIndex:5];
                        if (val.length >= 5 && !_capturedSkey) {
                            _capturedSkey = val;
                            qqlog(@"[捕获] 客户端真实 skey 已缓存 (len=%lu)", (unsigned long)val.length);
                        }
                    }
                }
                // v1.6.6/1.6.6: 诊断——打印域请求完整 Cookie（找短 skey）
                qqlog(@"[捕获] %@Cookie: %@", isQun ? @"qun请求" : @"等级域请求",
                      ck.length > 400 ? [ck substringToIndex:400] : ck);
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

// ══════════════════════════════════════════════════════════════
//  v1.3-test: 0x9172 任务状态解析（闭环验证 · 只读不改）
//  目标：把 sendPbRequest 捕获的 0x9172 pbBody 解析成结构化任务，
//        写入 Documents/qqtask_status.json，面板「刷新任务状态」可查看。
//  字段映射（真机抓包 hex 离线实锤，2026-08-27）：
//    field1=title  field2=desc  field3=iconURL  field4=按钮文案
//    field5=jumpURL  field20=taskId
//    status 由按钮文案推导：已完成/已领取/已打卡=1；已结束=2；其它=0
// ══════════════════════════════════════════════════════════════
static NSString *qqtaskStatusPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/qqtask_status.json"];
}

// varint 读取（带边界检查，防越界崩溃）；成功 YES 并前移 *pi
static BOOL pbReadVarint(const uint8_t *b, NSUInteger len, NSUInteger *pi, uint64_t *out) {
    uint64_t v = 0; int shift = 0; NSUInteger i = *pi;
    while (i < len) {
        uint8_t x = b[i++];
        v |= (uint64_t)(x & 0x7f) << shift;
        if (!(x & 0x80)) { *pi = i; *out = v; return YES; }
        shift += 7;
        if (shift > 63) return NO;
    }
    return NO;
}

// 判定字节段是否可读 UTF-8 文本（>70% 可打印）
static NSString *pbTryUTF8(const uint8_t *b, NSUInteger off, NSUInteger n) {
    if (n == 0) return nil;
    NSData *d = [NSData dataWithBytes:(b + off) length:n];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s || s.length == 0) return nil;
    NSUInteger printable = 0;
    for (NSUInteger k = 0; k < s.length; k++) {
        unichar c = [s characterAtIndex:k];
        if (c >= 0x20 || c == '\n' || c == '\t' || c == '\r') printable++;
    }
    if ((double)printable / (double)s.length > 0.7) return s;
    return nil;
}

// 解析单个任务节点（field4 分组内 field1 的直接子消息）
// 字段映射（真机 0x9172 hex 离线实锤，2026-09-01）：
//   f1=title  f2=desc  f3=iconURL  f4=按钮文案  f5=jumpURL
//   taskId: 付费组(分组A)用 f6=801..；额外活跃组(分组C)用 f20=24/23…；两者都试
//   status 由按钮文案推导：已完成/已领取/已打卡=1；已结束=2；其它=0
static NSDictionary *pbParseTaskNode(const uint8_t *b, NSUInteger len) {
    NSMutableDictionary *fs = [NSMutableDictionary dictionary];
    NSUInteger i = 0;
    while (i < len) {
        uint64_t tag;
        if (!pbReadVarint(b, len, &i, &tag)) break;
        uint64_t field = tag >> 3; int wtype = (int)(tag & 7);
        if (wtype == 0) {
            uint64_t v;
            if (!pbReadVarint(b, len, &i, &v)) break;
            if (!fs[@(field)]) fs[@(field)] = @{@"t": @"v", @"v": @(v)};
        } else if (wtype == 2) {
            uint64_t ln;
            if (!pbReadVarint(b, len, &i, &ln)) break;
            if (i + (NSUInteger)ln > len) break;
            NSString *s = pbTryUTF8(b, i, (NSUInteger)ln);
            if (s) {
                if (!fs[@(field)]) fs[@(field)] = @{@"t": @"s", @"s": s};
            }
            i += (NSUInteger)ln;
        } else if (wtype == 5) { i += 4; }
        else if (wtype == 1) { i += 8; }
        else break;
    }
    NSDictionary *f1 = fs[@1], *f3 = fs[@3], *f4 = fs[@4];
    if (!(f1 && [f1[@"t"] isEqualToString:@"s"] &&
          f4 && [f4[@"t"] isEqualToString:@"s"] &&
          f3 && [f3[@"t"] isEqualToString:@"s"] && [f3[@"s"] hasPrefix:@"http"])) return nil;
    NSString *title = f1[@"s"];
    NSString *btn   = f4[@"s"];
    NSString *desc  = (fs[@2] && [fs[@2][@"t"] isEqualToString:@"s"]) ? fs[@2][@"s"] : @"";
    NSString *jump  = (fs[@5] && [fs[@5][@"t"] isEqualToString:@"s"]) ? fs[@5][@"s"] : @"";
    NSString *taskId = @"";
    if (fs[@20] && [fs[@20][@"t"] isEqualToString:@"v"]) taskId = [NSString stringWithFormat:@"%@", fs[@20][@"v"]];
    if (fs[@6] && [fs[@6][@"t"] isEqualToString:@"v"] && taskId.length == 0) taskId = [NSString stringWithFormat:@"%@", fs[@6][@"v"]];
    int st = 0;
    if ([btn isEqualToString:@"已完成"] || [btn isEqualToString:@"已领取"] || [btn isEqualToString:@"已打卡"]) st = 1;
    else if ([btn isEqualToString:@"已结束"]) st = 2;
    return @{
        @"taskId": taskId,
        @"title": title ?: @"",
        @"desc": desc ?: @"",
        @"jumpURL": jump ?: @"",
        @"button": btn ?: @"",
        @"status": @(st)
    };
}

// 0x9172 分组扫描：field4 { f1=uin, f3=付费加倍组, f4=日常活跃组, f5=额外活跃天数组 }
// 每组内的 f1 重复消息=任务节点；输出 tasks（带 group 标记）+ 分组统计
static NSDictionary *pbScan9172Groups(const uint8_t *b, NSUInteger len, NSMutableArray *outTasks) {
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    NSUInteger i = 0;
    while (i < len) {
        uint64_t tag;
        if (!pbReadVarint(b, len, &i, &tag)) break;
        uint64_t field = tag >> 3; int wtype = (int)(tag & 7);
        if (wtype == 2) {
            uint64_t ln;
            if (!pbReadVarint(b, len, &i, &ln)) break;
            if (field == 4 && i + ln <= len) {
                const uint8_t *f4b = b + i;
                uint64_t f4len = ln;
                NSUInteger j = 0;
                uint64_t uin = 0;
                while (j < f4len) {
                    uint64_t t2;
                    if (!pbReadVarint(f4b, f4len, &j, &t2)) break;
                    uint64_t f2 = t2 >> 3; int w2 = (int)(t2 & 7);
                    if (w2 == 2) {
                        uint64_t ln2;
                        if (!pbReadVarint(f4b, f4len, &j, &ln2)) break;
                        if (j + ln2 > f4len) break;
                        if (f2 == 3 || f2 == 4 || f2 == 5) {
                            NSString *grp = (f2 == 3) ? @"pay" : ((f2 == 4) ? @"daily" : @"extra");
                            const uint8_t *gb = f4b + j;
                            uint64_t glen = ln2;
                            NSUInteger k = 0; int n = 0;
                            while (k < glen) {
                                uint64_t t3;
                                if (!pbReadVarint(gb, glen, &k, &t3)) break;
                                uint64_t f3 = t3 >> 3; int w3 = (int)(t3 & 7);
                                if (w3 == 2) {
                                    uint64_t ln3;
                                    if (!pbReadVarint(gb, glen, &k, &ln3)) break;
                                    if (k + ln3 > glen) break;
                                    if (f3 == 1) {
                                        NSDictionary *task = pbParseTaskNode(gb + k, (NSUInteger)ln3);
                                        if (task) {
                                            NSMutableDictionary *mt = [task mutableCopy];
                                            mt[@"group"] = grp;
                                            [outTasks addObject:mt];
                                            n++;
                                        }
                                    }
                                    k += ln3;
                                } else if (w3 == 0) {
                                    uint64_t v3;
                                    if (!pbReadVarint(gb, glen, &k, &v3)) break;
                                } else if (w3 == 5) k += 4;
                                else if (w3 == 1) k += 8;
                                else break;
                            }
                            counts[grp] = @(n);
                        }
                        j += ln2;
                    } else if (w2 == 0) {
                        uint64_t v2;
                        if (!pbReadVarint(f4b, f4len, &j, &v2)) break;
                        if (f2 == 1) uin = v2;
                    } else if (w2 == 5) j += 4;
                    else if (w2 == 1) j += 8;
                    else break;
                }
                counts[@"uin"] = @(uin);
                break;  // 已处理 field4
            }
            i += ln;
        } else if (wtype == 0) {
            uint64_t v;
            if (!pbReadVarint(b, len, &i, &v)) break;
        } else if (wtype == 5) i += 4;
        else if (wtype == 1) i += 8;
        else break;
    }
    return counts;
}

static void refreshTaskListUI(void);   // v1.7.2 前向声明：qqfbParse9172AndSave(764行) 先于定义(2526行)调用

// 解析 0x9172 pbBody → 写 qqtask_status.json，返回任务数（失败返回 -1）
static int qqfbParse9172AndSave(NSData *pbBody) {
    @try {
        if (![pbBody isKindOfClass:[NSData class]] || pbBody.length == 0) {
            qqlog(@"[9172-PARSE] pbBody 为空");
            return -1;
        }
        NSMutableArray *tasks = [NSMutableArray array];
        NSDictionary *groupInfo = pbScan9172Groups((const uint8_t *)pbBody.bytes, pbBody.length, tasks);
        if (tasks.count == 0) {
            // 解析失败：dump 前 200 字节 hex 供排查
            qqlog(@"[9172-PARSE] 解析任务=0，原始前200B hex=%@", qqfbHex(pbBody, 200));
            return 0;
        }
        NSDictionary *root = @{
            @"capturedAt": @([[NSDate date] timeIntervalSince1970]),
            @"cmd": @"OidbSvcTrpcTcp.0x9172_0",
            @"uin": (_capturedCurrentUin ?: @""),   // v1.7.0: 记录任务所属账号（客户端请求Cookie捕获）
            @"dataUin": groupInfo[@"uin"] ?: @(0),  // v1.7.1: 0x9172 响应体里的真实账号（可核对是否旧数据）
            @"pbBodyLen": @(pbBody.length),
            @"taskCount": @(tasks.count),
            @"groups": (groupInfo ?: @{}),          // v1.7.1: {pay:6,daily:2,extra:26,uin:xxx}
            @"tasks": tasks
        };
        NSError *err = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:root
                        options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys) error:&err];
        if (!json) {
            qqlog(@"[9172-PARSE] JSON 序列化失败: %@", err);
            return -1;
        }
        [json writeToFile:qqtaskStatusPath() atomically:YES];
        qqlog(@"[9172-PARSE] 已解析 %lu 个任务 → %@", (unsigned long)tasks.count, qqtaskStatusPath());
        // v1.7.2: 解析成功 → 自动刷新面板缓存（不用手动点「🔄获取」才看到最新状态）
        dispatch_async(dispatch_get_main_queue(), ^{
            refreshTaskListUI();
        });
        return (int)tasks.count;
    } @catch (NSException *e) {
        qqlog(@"[9172-PARSE] 异常 %@", e);
        return -1;
    }
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
                                                // result 结构实测 = (code, errMsg, NSData pbBody, 0, 0)
                                                // 取第 3 元素（index 2）才是 protobuf body
                                                id payload = result;
                                                if ([result isKindOfClass:[NSArray class]] && [(NSArray *)result count] > 2) {
                                                    payload = [(NSArray *)result objectAtIndex:2];
                                                    qqlog(@"[KUILKY-PB-RSP] cmd=%@ full=%@", bCmd, [result description]);
                                                }
                                                if ([payload isKindOfClass:[NSData class]]) {
                                                    qqlog(@"[KUILKY-PB-RSP] cmd=%@ dataLen=%lu dataHex=%@",
                                                          bCmd, (unsigned long)[(NSData *)payload length],
                                                          qqfbHex((NSData *)payload, 60000));
                                                    // v1.3-test: 命中 0x9172 → 解析任务状态写 JSON（只读，不改请求/响应）
                                                    if ([bCmd rangeOfString:@"0x9172"].location != NSNotFound) {
                                                        int n = qqfbParse9172AndSave((NSData *)payload);
                                                        appendLogView([NSString stringWithFormat:@"📊 0x9172 任务状态已更新：%d 个任务", n]);
                                                    }
                                                } else {
                                                    NSString *rd = [NSString stringWithFormat:@"%@", payload];
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

// ── hash33 算法：bkn/g_tk = hash33(key)（qsped_chain.py 同源，实锤版）──
//  2026-08-31 修正：原实现初始值 0 + 仅最后截断，与 qsped 每步截断版不等价，
//  导致 qun 域 robots_addfriend bkn 校验失败（csrf error 100021）。
//  实证：hash33('MuiZBP9BQR')=1081171642、hash33('MDzKvUD1zB')=469881207
//  均与安卓抓包 bkn 一致；qun 域 bkn 用 skey 算（不是 p_skey）。
static int hash33(NSString *str) {
    if (!str) return 0;
    long long e = 5381;
    for (NSUInteger i = 0; i < str.length; i++) {
        e = ((e + (e << 5)) & 0x7fffffff) + [str characterAtIndex:i];
    }
    return (int)(e & 0x7fffffff);
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
    // v1.7.0: 优先用客户端真实请求 Cookie 里捕获的 uin（等级页/群请求都带 uin=，最可靠）
    if (_capturedCurrentUin && _capturedCurrentUin.length > 0) {
        return _capturedCurrentUin;
    }
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
// ── QQLoginPSKeyManager 全局 skey（getRealSig_SKEYStr 方法，getLocalKeyOfDomain 拿不到 skey）──
static NSString *getRealSkey(void) {
    @try {
        Class mgrCls = NSClassFromString(@"QQLoginPSKeyManager");
        if (!mgrCls) return nil;
        id mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, NSSelectorFromString(@"sharedInstance"));
        if (!mgr) return nil;
        SEL sel = NSSelectorFromString(@"getRealSig_SKEYStr");
        if (![mgr respondsToSelector:sel]) {
            qqlog(@"[skey] getRealSig_SKEYStr 方法不存在");
            return nil;
        }
        id sk = ((id (*)(id, SEL))objc_msgSend)(mgr, sel);
        if ([sk isKindOfClass:[NSString class]] && [(NSString *)sk length] > 0) {
            qqlog(@"[skey] getRealSig_SKEYStr 拿到 len=%lu", (unsigned long)[(NSString *)sk length]);
            return sk;
        }
    } @catch (NSException *e) {
        qqlog(@"[skey] getRealSig_SKEYStr 异常 %@", e);
    }
    return nil;
}

static NSString *getSkey(NSString *uin) {
    // v1.6.6: ①客户端原生请求捕获的 skey 最可靠；②getRealSig_SKEYStr；③getLocalKeyOfDomain 兜底
    if (_capturedSkey && _capturedSkey.length > 0) {
        qqlog(@"[skey] 用客户端捕获 skey (len=%lu)", (unsigned long)_capturedSkey.length);
        return _capturedSkey;
    }
    NSString *real = getRealSkey();
    if (real) return real;
    @try {
        for (NSString *domain in @[@"qq.com", @"", @"web.qun.qq.com"]) {
            NSString *sk = getPskey(domain, uin, 0);
            if (sk && sk.length > 0) return sk;
        }
    } @catch (NSException *e) {}
    return nil;
}

// ── qun 域 skey：robots_addfriend/removefriend 的 bkn=hash33(qun域skey)（qsped 抓包实证）──
static NSString *getQunSkey(NSString *uin) {
    // v1.6.6: ①客户端捕获 skey；②getRealSig_SKEYStr；③getLocalKeyOfDomain 各域各 kt 兜底
    if (_capturedSkey && _capturedSkey.length > 0) {
        qqlog(@"[skey] qun域用客户端捕获 skey (len=%lu)", (unsigned long)_capturedSkey.length);
        return _capturedSkey;
    }
    NSString *real = getRealSkey();
    if (real) return real;
    @try {
        for (NSString *domain in @[@"web.qun.qq.com", @"qun.qq.com", @"qq.com", @""]) {
            for (int kt = 0; kt <= 3; kt++) {
                NSString *sk = getPskey(domain, uin, kt);
                if (sk && sk.length > 0) return sk;
            }
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

// ── v1.7.8 关闭最顶层容器（小游戏全屏容器/模态页/Kuikly 页）──
// 实测：qqminigame:// 小游戏打开后是全屏容器，openLevelPage 的 openURL
// 无法覆盖它 → 后续任务 autotap 一直注入小游戏页面、0x9172 永不更新。
// 必须先导航返回/dismiss 关闭容器，再回等级页。
// v1.7.8 修复：QQ 页面结构是 TabBar→NavigationController→push 的任务页，
//   旧代码只遍历 presentedViewController 链（QQ 无模态页→永远「已在根页面」→
//   容器关不掉）。新逻辑完整遍历：TabBar.selected → Nav.viewControllers.last
//   → presented 链，层层找最顶层可关闭的 VC。
static UIViewController *topMostViewController(UIViewController *root) {
    if (!root) return nil;
    UIViewController *top = root;
    int depth = 0;
    while (depth < 20) {
        UIViewController *next = nil;
        if ([top isKindOfClass:[UITabBarController class]]) {
            next = [(UITabBarController *)top selectedViewController];
        } else if ([top isKindOfClass:[UINavigationController class]]) {
            NSArray *vcs = [(UINavigationController *)top viewControllers];
            if (vcs.count > 0) next = vcs.lastObject;
        }
        if (top.presentedViewController) next = top.presentedViewController;
        if (!next || next == top) break;
        top = next;
        depth++;
    }
    return top;
}

static void closeTopContainer(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *top = topMostViewController([UIApplication sharedApplication].keyWindow.rootViewController);
            if (!top) return;
            // 场景1：在导航栈中间（有可返回的页面）→ pop 回上一页
            UINavigationController *nav = top.navigationController;
            if (nav && nav.viewControllers.count > 1) {
                [nav popViewControllerAnimated:YES];
                qqlog(@"[auto] 已关闭容器（导航返回 %lu→%lu）",
                      (unsigned long)nav.viewControllers.count,
                      (unsigned long)(nav.viewControllers.count - 1));
                return;
            }
            // 场景2：模态页 → dismiss
            if (top.presentingViewController) {
                [top dismissViewControllerAnimated:YES completion:nil];
                qqlog(@"[auto] 已关闭容器（dismiss 模态页）");
                return;
            }
            // 场景3：顶层 VC 本身就是导航控制器且栈 >1 → pop
            if ([top isKindOfClass:[UINavigationController class]]) {
                UINavigationController *nav2 = (UINavigationController *)top;
                if (nav2.viewControllers.count > 1) {
                    [nav2 popViewControllerAnimated:YES];
                    qqlog(@"[auto] 已关闭容器（顶层导航返回）");
                    return;
                }
            }
            qqlog(@"[auto] 无容器可关闭（已在根页面: %@）", NSStringFromClass([top class]));
        } @catch (NSException *e) {
            qqlog(@"[auto] 关闭容器异常: %@", e);
        }
    });
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
static void autoTapNativeUI(void);
static void qqfbTapCloseButton(void);
static BOOL qqfbGestureInvoke(UIGestureRecognizer *g, NSString *logTag);
static BOOL qqfbKuiklyInvoke(UIView *view, id block, NSString *logTag);
static void qqfbDumpViewTree(void);
static void appendLogView(NSString *msg);   // v1.1.0 任务面板代码先于定义使用
static void runLevelTasksAuto(void) __attribute__((unused));   // v1.2.25 一键执行(v1.4已被闭环替代,保留备用)
// v1.7.6: 0x9172 全量任务数据源（定义在 runAutoTasks 之后，须前向声明）
static NSArray *qqfbReadExtraOnlyTasks(void);
static BOOL qqfbIsPaidTaskTitle(NSString *title);
static double qqfbStatusCapturedAt(void);
static BOOL qqfbWaitStatusRefresh(double oldTs, int timeoutSec);
static int qqfbFindTaskStatusIn(NSArray *tasks, NSString *taskId, NSString *title);

// ══════════════════════════════════════════
// ══════════════════════════════════════════════════════════════
//  内置免费任务清单（方案A · 离线兜底）
//  来源：0x9172 pbBody 抓包实锤（2026-08-23，jumpURL 已验证）
//  用途：iOS 上在线 levelTask/Get 接口返回空/任务极少时，
//        runAutoTasks 回退到本清单，逐条 openJumpSchema 跳转执行。
//  跳过规则：充值开通/包月/年费(打钱)、已结束、听歌(第三方QQ音乐,留手动)、
//        会员活动页(act.qzone vip/tx/p)、买断/黑金/炫彩靓号。
// ══════════════════════════════════════════════════════════════
static NSArray *builtInTasks(void) {
    return @[
        @{@"title": @"加一位好友", @"jump": @"mqqapi://contact/add?src_type=web&version=1&des_type=0"},
        @{@"title": @"发布一条空间说说", @"jump": @"mqqapi://qzoneschema/?schema=bXF6b25lOi8vYXJvdXNlL3dyaXRlbW9vZD9hZElkPXFxX2xldmVsX3NodW9zaHVvJmxvZ2luZnJvbT02MQ=="},
        @{@"title": @"去日签卡打一次卡", @"jump": @"https://ti.qq.com/signin/public/index.html?_wv=1090528161&_wwv=13"},
        @{@"title": @"去免费小说看任一本书", @"jump": @"mqqapi://kuikly/open?version=1&src_type=web&bundle_name=vas_qqvip_novel_book_store&qqmc_config=vas_kuikly_config&page_name=vas_qqvip_novel_book_store&from=dengji_task&custom_back_pressed=1"},
        @{@"title": @"每日登录QQ经典农场", @"jump": @"mqqapi://miniapp/open?_atype=1&_mappid=1112386029&_miniapptype=1&_mvid=&_vt=3&via=nc_qqlevel_task&_sig=846276564"},
        @{@"title": @"去QQ会员福利社领福利券", @"jump": @"https://club.vip.qq.com/transfer?open_kuikly_info=%7B%22bundle_name%22%3A%22vas_qqvip_benefit%22%7D&qqmc_config=vas_kuikly_config&page_name=vas_qqvip_benefit&kr_turbo_display=1&enteranceId&is_test=1&outer_scene_source=1"},
        @{@"title": @"完成视频任务获得加速时长", @"jump": @"mqqapi://kuikly/open?page_name=benefits_center&version=1&src_type=web&bundle_name=benefits_center&from=qqgrade"},
        @{@"title": @"体验任一款小游戏15s", @"jump": @"mqqapi://kuikly/open?page_name=mini_game_recommend&version=1&src_type=web&bundle_name=qgame_mini_game_third_page&recommend_module_type=12&kr_turbo_display=qqlevel_task&from=qqlevel_task&backend_from=qqlevel_task&kr_min_res_version=1890"},
        @{@"title": @"浏览十条空间好友动态", @"jump": @"mqqapi://qzoneschema/?schema=bXF6b25lOi8vYXJvdXNlL2FjdGl2ZWZlZWQmbG9naW5mcm9tPTYx"},
        @{@"title": @"参与盲盒签并成功发布至空间", @"jump": @"https://h5.tu.qq.com/stable/daily-check-in/index.html?_wv=2&root_channel=qiandao&currentchannel=dengjirenwu&current_channel=dengjirenwu&jump2App=1&_loading=1&loginfrom=66"},
        @{@"title": @"SVIP712会员节礼包加速", @"jump": @"https://club.vip.qq.com/openKuikly/vas_vip_fest_2026?open_kuikly_info=%7B%22bundle_name%22%3A%22vas_vip_fest_2026%22%7D&qqmc_config=vas_kuikly_config&page_name=vas_vip_fest_2026&kr_turbo_display=1&bottom_nav_bar_immersive=1&enteranceId=xtsrw&_wv=16777216"},
        @{@"title": @"创建小游戏擂台并取得成绩", @"jump": @"mqqapi://kuikly/open?page_name=mini_game_arena_rank&bundle_name=mini_game_arena_rank&version=1&src_type=web&kr_turbo_display=1&use_host_display_metrics=1&from=qqlevel_task&kr_min_res_version=610"},
        @{@"title": @"看10秒漫剧", @"jump": @"https://club.vip.qq.com/mono/comic/wx-share?_wv=3&min_version=9.3.25&target=mqqapi%3A%2F%2Fcomicvideo%2Fopentab%3Ftabtype%3Drecommend%26task%3Dwatch%26watchTime%3D10%26from%3Ddengji_task"},
        @{@"title": @"去元宝提问1次", @"jump": @"https://yuanbao.tencent.com/e/evt/dl/6a57a8a7777270f8491d298a?chid=5318&source=imgH5LandingPage&trid=qqhy.zhxxdjjs.app&openid=C6C837A2F1ECB5B91758862B5D622D8A"},
    ];
}


//  qsped 式纯后台任务执行器（v1.1.0）
//  接口来自 qsped 运行时抓包实锤（D:/android-build/qsped_rerun.log）
//  全部直接 POST，零页面点击，防封防检测
// ══════════════════════════════════════════

// ── 组装等级任务通用 Cookie（p_skey 体系）──
//  v1.6.7: 按目标域选 key！ti.qq.com 用 ti 域 key，club 用 club 域 key（实测两者不同值，
//          SignIn 用错域 key 返回 -3000 ptlogin auth failed）
static NSString *levelCookie(NSString *uin, NSString *extraPskeyDomain) {
    NSString *pskey = nil;
    if ([extraPskeyDomain containsString:@"ti.qq.com"]) {
        pskey = _capturedTiPskey;
        if (!pskey) pskey = getPskey(@"ti.qq.com", uin, 1);
        if (!pskey) pskey = getPskey(@"ti.qq.com", uin, 0);
    } else if ([extraPskeyDomain containsString:@"club.vip.qq.com"]) {
        pskey = _capturedClubPskey;
        if (!pskey) pskey = getPskey(@"club.vip.qq.com", uin, 1);
    }
    if (!pskey) pskey = _capturedTiPskey ?: getPskey(@"ti.qq.com", uin, 1);
    NSString *skey = getSkey(uin);
    NSMutableString *ck = [NSMutableString string];
    if (skey && skey.length > 0) [ck appendFormat:@"skey=%@; ", skey];
    [ck appendFormat:@"uin=o%@; p_uin=o%@; p_skey=%@", uin, uin, pskey];
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
    // 2026-08-31 实测：ret:0 但 data.retCode:-1 = 未真正打卡（可能今日已打/条件不满足），
    // 必须解析 data.retCode==0 才算成功
    NSRange rcRange = [resp rangeOfString:@"\"retCode\":"];
    if (rcRange.location != NSNotFound) {
        NSString *tail = [resp substringFromIndex:NSMaxRange(rcRange)];
        int rc = 0;
        NSScanner *sc = [NSScanner scannerWithString:tail];
        if ([sc scanInt:&rc]) {
            // v1.7.4: retCode==-1 = 今日已打卡（已完成），同样视为成功！
            // 实测小号响应 {"ret":0,"msg":"success!","data":{"retCode":-1,...}}
            // 旧代码把 -1 当失败 → 跳页面兜底 → autotap 死循环点「今日已打卡」
            if (rc == 0 || rc == -1) {
                if (rc == -1) qqlog(@"[任务] 日签卡 retCode=-1 = 今日已打卡（任务已完成），视为成功");
                else qqlog(@"[任务] 日签卡 打卡成功 retCode=0");
                return YES;
            }
            qqlog(@"[任务] 日签卡 服务端拒绝 retCode=%d（可能条件不满足）", rc);
            return NO;
        }
    }
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
    NSString *qskey = getQunSkey(uin);
    if (!qskey) qskey = getSkey(uin);
    if (!qskey) { qqlog(@"[任务] 加好友 拿不到 qun 域 skey"); return NO; }
    // v1.6.6: bkn=hash33(qun域p_skey)！实测 iOS 等级页 g_tk=2099675429=hash33(等级域p_skey ZUTU...) 匹配，
    //          iOS 客户端无安卓式短 skey（qun 域 skey/p_skey 都是 44 字符长值），服务端按 p_skey 校验
    int bkn = hash33(pskey);
    qqlog(@"[任务] 加好友 qun域pskey=%@ bkn=%d (skey=%@)", pskey, bkn, qskey ?: @"无");
    NSString *url = [NSString stringWithFormat:@"/qunrobot/proxy/domain/qun.qq.com/cgi-bin/qunapp/robots_addfriend?bkn=%d", bkn];
    url = [@"https://web.qun.qq.com" stringByAppendingString:url];
    NSString *cookie = [NSString stringWithFormat:@"skey=%@; uin=o%@; p_uin=o%@; p_skey=%@",
                        qskey, uin, uin, pskey];
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
    // v1.6.6: 成功判据——cgicode/retcode 必须为 0（实测 100000 login error / 100021 csrf 都算失败）
    @try {
        NSRange r1 = [resp rangeOfString:@"\"cgicode\":"];
        if (r1.location != NSNotFound) {
            NSString *tail = [resp substringFromIndex:NSMaxRange(r1)];
            int rc = 0;
            NSScanner *sc = [NSScanner scannerWithString:tail];
            if ([sc scanInt:&rc]) {
                if (rc == 0) { qqlog(@"[任务] 加好友 成功 cgicode=0"); return YES; }
                qqlog(@"[任务] 加好友 服务端拒绝 cgicode=%d（100000=login error 凭证无效/100021=csrf）", rc);
                return NO;
            }
        }
    } @catch (NSException *e) {
        qqlog(@"[任务] 加好友 判据解析异常 %@", e);
    }
    return YES; // 无 cgicode 字段（如纯 HTML/非 JSON）时保守放行
}

// ── 删好友（纯后台，测试模式收尾用）──
static BOOL runRemoveFriendTask(NSString *uin, NSString *targetUin) {
    qqlog(@"[任务] 删好友 %@…", targetUin ?: @"?");
    if (!targetUin || targetUin.length == 0) return NO;
    NSString *pskey = getQunPskey(uin);
    if (!pskey) pskey = getPskey(@"qun.qq.com", uin, 1);
    if (!pskey) pskey = getPskey(@"web.qun.qq.com", uin, 1);
    if (!pskey) { qqlog(@"[任务] 删好友 拿不到 qun 域 p_skey"); return NO; }
    NSString *qskey = getQunSkey(uin);
    if (!qskey) qskey = getSkey(uin);
    if (!qskey) { qqlog(@"[任务] 删好友 拿不到 qun 域 skey"); return NO; }
    // v1.6.6: bkn 同样用 qun 域 p_skey 算（iOS 体系实证，见加好友注释）
    int bkn = hash33(pskey);
    qqlog(@"[任务] 删好友 qun域pskey=%@ bkn=%d", pskey, bkn);
    NSString *url = [NSString stringWithFormat:@"/qunrobot/proxy/domain/qun.qq.com/cgi-bin/qunapp/robots_removefriend?bkn=%d", bkn];
    url = [@"https://web.qun.qq.com" stringByAppendingString:url];
    NSString *cookie = [NSString stringWithFormat:@"skey=%@; uin=o%@; p_uin=o%@; p_skey=%@",
                        qskey, uin, uin, pskey];
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
    // 2026-08-31 实测：外层 code:0 但 req_0.code:1000 = 兑换业务失败，必须解析 req_0.code
    NSRange r0Range = [resp rangeOfString:@"\"req_0\":"];
    if (r0Range.location != NSNotFound) {
        NSString *tail = [resp substringFromIndex:NSMaxRange(r0Range)];
        NSRange codeRange = [tail rangeOfString:@"\"code\":"];
        if (codeRange.location != NSNotFound) {
            NSString *ctail = [tail substringFromIndex:NSMaxRange(codeRange)];
            int rc = 0;
            NSScanner *sc = [NSScanner scannerWithString:ctail];
            if ([sc scanInt:&rc]) {
                if (rc == 0) { qqlog(@"[任务] 金币兑换 兑换成功 req_0.code=0"); return YES; }
                qqlog(@"[任务] 金币兑换 服务端拒绝 req_0.code=%d（无金币/已兑换/参数错）", rc);
                return NO;
            }
        }
    }
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
//   v1.6.7: 纯后台接口任务（日签卡 HTTP 直调）优先执行，加好友 iOS 无短 skey 跳过，
//           其余任务自动导航（跳页面 + 注入 JS 自动点按钮 + 回查状态）
static void runAutoTasks(void) {
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
            // v1.7.5: 数据源优先级改为 0x9172 全量任务（iOS 等级页真全量，含额外活跃全部任务）
            //         旧代码用 fetchTaskList 在线拉取——iOS 上 levelTask/Get 有 is_ios_review_hide
            //         审核过滤只回 10 个基础任务，导致「一键任务只有3个」bug
            int retCode = 0;
            NSArray *taskList = qqfbReadExtraOnlyTasks();
            BOOL useBuiltIn = NO;
            if (taskList && taskList.count > 0) {
                qqlog(@"[auto] 使用 0x9172 全量额外活跃任务 %lu 个", (unsigned long)taskList.count);
            } else {
                qqlog(@"[auto] 0x9172 无数据，回退在线拉取…");
                taskList = fetchTaskList(uin, tiPskey, &retCode);
                if (!taskList || taskList.count == 0) {
                    qqlog(@"[auto] ✗ 在线任务列表为空 (ret=%d)，回退内置免费任务清单", retCode);
                    taskList = builtInTasks();
                    useBuiltIn = YES;
                } else if (taskList.count < 3) {
                    qqlog(@"[auto] ⚠ 在线任务仅 %lu 条，过少，回退内置免费任务清单", (unsigned long)taskList.count);
                    taskList = builtInTasks();
                    useBuiltIn = YES;
                }
            }
            if (useBuiltIn) {
                qqlog(@"[auto] 使用内置清单 %lu 条（0x9172 与在线接口都拿不到，兜底）", (unsigned long)taskList.count);
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
                // v1.7.5: 0x9172 数据无 button_text/extend 字段；付费判定改用 qqfbIsPaidTaskTitle(title)
                //         （旧 isBlocked 的 extendStr is_ios_review_hide 会把 iOS 全部可做任务误杀；
                //           旧 buttonText 含「会员」会把「会员福利社」误杀）
                NSString *jump = task[@"jumpURL"] ?: task[@"jump_schema"] ?: @"";

                BOOL isBlocked = qqfbIsPaidTaskTitle(title);
                if ([buttonText containsString:@"开通"] || [buttonText containsString:@"充值"] ||
                    [buttonText containsString:@"购买"] || [buttonText containsString:@"买断"]) {
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

            // ══ ④ 逐个自动执行：纯后台接口直调 → 跳转页面 → 注入 JS 自动点按钮 → 验证状态 ══
            int execDone = 0, execSkip = 0;
            for (int i = 0; i < (int)todoTasks.count; i++) {
                NSDictionary *item = todoTasks[i];
                NSString *title = item[@"title"];
                NSString *jump = item[@"jump"];
                qqlog(@"[auto] ── [%d/%lu] 正在做: %@ ──", i + 1, (unsigned long)todoTasks.count, title);

                // v1.6.7: 纯后台 HTTP 任务优先直调（ti 域 key 已按域修复，SignIn 不再 -3000）
                BOOL httpDone = NO;
                if ([title containsString:@"日签卡"] || [title containsString:@"打卡"]) {
                    httpDone = runDailySignTask(uin);
                    if (httpDone) qqlog(@"[auto] ✅ 日签卡 HTTP 打卡成功（接口返回成功）");
                    else qqlog(@"[auto] ⚠ 日签卡 HTTP 失败，继续跳页面兜底…");
                } else if ([title containsString:@"金币"] || [title containsString:@"兑换"]) {
                    runCoinExchangeTask(uin);  // code=0+req0=1000 = 已兑换/无金币（账号状态，非代码问题）
                    continue;
                } else if ([title containsString:@"加好友"] || [title containsString:@"加一位好友"]) {
                    qqlog(@"[auto] ⚠ iOS 客户端无 10 字符短 skey（qsped 实测 robots_addfriend bkn=hash33(短skey)），此接口 iOS 走不通，跳过（可等级页手动加）");
                    continue;
                }
                if (httpDone) { execDone++; continue; }

                // v1.7.7: 任务类型分流——
                //  「跳转+停留」型（农场/福利社/视频/小游戏/漫剧/元宝/小说/听歌）：
                //    打开页面停留服务端要求的秒数即完成，无需 JS 注入（JS 对 canvas/原生页无效，
                //    实测全部返回空且浪费 5 轮×5 秒）；停留完关闭容器再验证。
                //  「需点击」型（说说/盲盒签）：打开页面注入 JS + 原生点击。
                NSArray *stayTitles = @[@"农场", @"福利社", @"视频任务", @"小游戏", @"漫剧", @"元宝", @"小说", @"看书", @"听歌"];
                BOOL isStayTask = NO;
                for (NSString *kw in stayTitles) {
                    if ([title containsString:kw]) { isStayTask = YES; break; }
                }

                // v1.7.7: 重试循环——每个任务最多尝试 3 次：
                //  做任务 → 关闭容器 → 回等级页触发新 0x9172 验证 → 未完成重做（用户要求）
                int maxAttempts = 3;
                BOOL taskDone = NO;
                for (int attempt = 1; attempt <= maxAttempts && !taskDone; attempt++) {
                    if (attempt > 1) {
                        qqlog(@"[auto] ↻ 重试第 %d 次（上次未完成）…", attempt);
                    }
                    // v1.7.8: 删掉每轮「先回等级页」——上一个任务验证已回等级页，
                    // 重复回等级页会 openURL 冲突 + 刷屏；直接从当前等级页跳转任务页
                    // （v1.7.5 加它防旧页面残留，但验证本身已保证回到等级页）

                    if (isStayTask) {
                        // v1.8.5 debug: 小说任务跳转后 dump 视图树，实锤书卡片组件结构
                        if ([title containsString:@"小说"] || [title containsString:@"书"]) {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                qqfbDumpViewTree();
                            });
                        }
                        // v1.8.3: 福利社领券——非会员做不了（日志实锤 isSvip=false，
                        // 用户明确「不是会员就做不了那个领券的任务」），直接跳过不浪费时间乱点
                        if ([title containsString:@"福利社"] && !_userIsSvip) {
                            qqlog(@"[auto] ⏭ 福利社领券：非会员做不了（isSvip=0），跳过该任务");
                            appendLogView(@"⏭ 福利社领券：非会员不可做，已跳过");
                            taskDone = YES; // 标记完成跳过后续重试
                            break;
                        }
                        // 停留时长按任务类型取（实测/服务端要求）
                        int staySec = 5;
                        if ([title containsString:@"小游戏"]) staySec = 16;
                        else if ([title containsString:@"漫剧"]) staySec = 11;
                        else if ([title containsString:@"视频"]) staySec = 32;
                        else if ([title containsString:@"农场"]) staySec = 3;
                        else if ([title containsString:@"福利社"]) staySec = 8;
                        else if ([title containsString:@"元宝"]) staySec = 5;
                        else if ([title containsString:@"小说"] || [title containsString:@"看书"]) staySec = 8;
                        else if ([title containsString:@"听歌"]) staySec = 3;
                        qqlog(@"[auto] 跳转任务页，停留 %d 秒（跳转+停留型）…", staySec);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            openJumpSchema(jump);
                        });
                        // v1.8.3 视频任务（用户实测「老乱点广告」）：进页面后**不点任何东西**，
                        // 等右上角广告计时器结束（服务端要求 32 秒停留），然后点右上角 X 关闭。
                        // 日志实锤：旧逻辑每轮 autoTapNativeUI 点到了全屏 KRView(0 0; 430 932)=乱点广告。
                        // v1.8.4 修复：rounds=1 只等 5 秒就关闭=停留不足服务端要求→任务永不完成→
                        // 每任务 3 重试×11 任务=疯狂重复跳等级页。必须等满 staySec。
                        BOOL isVideoTask = [title containsString:@"视频"];
                        // v1.7.8: 停留型任务期间每轮做「原生 UI 点击」——Kuikly 任务页不是
                        // WKWebView（JS 注入永远找不到，纯刷屏日志），但原生按钮（看广告/
                        // 进入游戏/开始阅读等）可点；「未找到 WKWebView」只在第一轮打一次
                        BOOL wvLogged = NO;
                        int rounds = isVideoTask ? (staySec / 5) : (staySec / 5 + 1);
                        for (int round = 0; round < rounds; round++) {
                            [NSThread sleepForTimeInterval:5];
                            if (!isVideoTask) {
                                autoTapNativeUI();
                            }
                            if (!wvLogged) {
                                autoTapAllWebViews();
                                wvLogged = YES;
                            }
                        }
                        if (isVideoTask) {
                            // 视频：计时器结束 → 点右上角 X 关闭（用户要求精准）
                            qqlog(@"[auto] 视频停留结束，点右上角 X 关闭…");
                            [NSThread sleepForTimeInterval:2];
                            qqfbTapCloseButton();
                            [NSThread sleepForTimeInterval:1];
                        }
                        // 停留型任务：服务端按停留时长记账，不强制注入
                        qqlog(@"[auto] 停留结束，关闭容器回等级页验证…");
                        closeTopContainer();
                        [NSThread sleepForTimeInterval:2];
                    } else {
                        qqlog(@"[auto] 跳转任务页 + 注入自动点击…");
                        dispatch_async(dispatch_get_main_queue(), ^{
                            openJumpSchema(jump);
                        });
                        // 页面加载 + JS 自动点击：等待 5 秒后注入，共注入 5 轮（v1.6.8 加长窗口覆盖慢加载）
                        // v1.6.9: 每轮补一次原生 UI 点击（说说/盲盒签原生页面无 WKWebView）
                        for (int round = 0; round < 5; round++) {
                            [NSThread sleepForTimeInterval:5];
                            autoTapAllWebViews();
                            autoTapNativeUI();
                        }
                        [NSThread sleepForTimeInterval:4];

                        // v1.7.7: 需点击型任务完成后也先关容器（说说/盲盒签是 push 的原生/Kuikly 页，
                        // 不关会叠加，openLevelPage 无法覆盖最顶层）
                        closeTopContainer();
                        [NSThread sleepForTimeInterval:2];
                    }

                    // 重新验证该任务是否完成：回等级页触发新 0x9172 → 按 title 找 status
                    // v1.7.5: 旧代码用 fetchTaskList 在线拉取验证（iOS 只回 10 个基础任务，
                    //         额外活跃任务找不到 → 全部误报未完成），改用 0x9172 全量验证
                    double t0 = qqfbStatusCapturedAt();
                    dispatch_async(dispatch_get_main_queue(), ^{
                        openLevelPage();
                    });
                    BOOL got = qqfbWaitStatusRefresh(t0, 20);
                    int st = -1;
                    if (got) {
                        NSArray *freshList = qqfbReadExtraOnlyTasks();
                        st = qqfbFindTaskStatusIn(freshList ?: @[], @"", title);
                    }
                    if (st >= 1) {
                        execDone++;
                        taskDone = YES;
                        qqlog(@"[auto] ✅ 完成: %@ (status=%d)", title, st);
                    } else if (attempt >= maxAttempts) {
                        execSkip++;
                        qqlog(@"[auto] ⏭ 未完成: %@ (status=%d%@，重试 %d 次仍失败，稍后可在等级页手动处理)",
                              title, st, got ? @"" : @"，重抓超时", maxAttempts);
                    } else {
                        qqlog(@"[auto] ⏳ 未完成: %@ (status=%d)，将重试…", title, st);
                    }
                }
                // 上面验证已回等级页触发新 0x9172（也兼作「每个任务做完回等级页」，
                // 避免旧任务页面残留导致 autotap 注入错误页面）
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
//  等级任务一键执行（v1.2.25：硬编码 jumpURL 遍历，纯页面停留推进任务）
//  遍历免费任务 → openJumpSchema 打开 → 停留 N 秒 → 日志记录 → 下一个 → 回等级页
// ══════════════════════════════════════════
static NSArray *levelTaskDefs(void) {
    return @[
        @{@"title": @"去日签卡打一次卡", @"jump": @"https://ti.qq.com/signin/public/index.html?_wv=1090528161&_wwv=13"},
        @{@"title": @"每日登录QQ经典农场", @"jump": @"mqqapi://miniapp/open?_atype=1&_mappid=1112386029&_miniapptype=1&_mvid=&_vt=3&via=nc_qqlevel_task&_sig=846276564"},
        @{@"title": @"去QQ会员福利社领福利券", @"jump": @"https://club.vip.qq.com/transfer?open_kuikly_info=%7B%22bundle_name%22%3A%22vas_qqvip_benefit%22%7D&qqmc_config=vas_kuikly_config&page_name=vas_qqvip_benefit&kr_turbo_display=1&enteranceId&is_test=1&outer_scene_source=1"},
        @{@"title": @"浏览十条空间好友动态", @"jump": @"mqqapi://qzoneschema/?schema=bXF6b25lOi8vYXJvdXNlL2FjdGl2ZWZlZWQmbG9naW5mcm9tPTYx"},
        @{@"title": @"看10秒漫剧", @"jump": @"https://club.vip.qq.com/mono/comic/wx-share?_wv=3&min_version=9.3.25&target=mqqapi%3A%2F%2Fcomicvideo%2Fopentab%3Ftabtype%3Drecommend%26task%3Dwatch%26watchTime%3D10%26from%3Ddengji_task"},
        @{@"title": @"去元宝提问1次", @"jump": @"https://yuanbao.tencent.com/e/evt/dl/6a57a8a7777270f8491d298a?chid=5318&source=imgH5LandingPage&trid=qqhy.zhxxdjjs.app&openid=C6C837A2F1ECB5B91758862B5D622D8A"},
        @{@"title": @"体验任一款小游戏15s", @"jump": @"mqqapi://kuikly/open?page_name=mini_game_recommend&version=1&src_type=web&bundle_name=qgame_mini_game_third_page&recommend_module_type=12&kr_turbo_display=qqlevel_task&from=qqlevel_task&backend_from=qqlevel_task&kr_min_res_version=1890"},
        @{@"title": @"完成视频任务获得加速时长", @"jump": @"mqqapi://kuikly/open?page_name=benefits_center&version=1&src_type=web&bundle_name=benefits_center&from=qqgrade"},
    ];
}

static BOOL _levelTasksRunning = NO;

// ── 一键遍历执行等级任务（后台线程，主线程开页面）──
static void runLevelTasksAuto(void) __attribute__((unused));
static void runLevelTasksAuto(void) {
    if (_levelTasksRunning) {
        appendLogView(@"⚠️ 任务已在执行中，请勿重复点击");
        return;
    }
    _levelTasksRunning = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *tasks = levelTaskDefs();
        appendLogView([NSString stringWithFormat:@"🚀 开始执行 %lu 个等级任务", (unsigned long)tasks.count]);
        int idx = 0;
        for (NSDictionary *task in tasks) {
            idx++;
            NSString *title = task[@"title"] ?: @"?";
            NSString *jump = task[@"jump"] ?: @"";
            appendLogView([NSString stringWithFormat:@"── [%d/%lu] 正在做：%@", idx, (unsigned long)tasks.count, title]);
            dispatch_async(dispatch_get_main_queue(), ^{
                openJumpSchema(jump);
            });
            // 页面加载后注入 JS 自动点击（3 轮，间隔 5 秒），再停留
            // v1.6.9: 每轮补原生 UI 点击
            for (int round = 0; round < 3; round++) {
                [NSThread sleepForTimeInterval:5];
                autoTapAllWebViews();
                autoTapNativeUI();
            }
            appendLogView([NSString stringWithFormat:@"✓ [%d/%lu] %@ 已停留完成", idx, (unsigned long)tasks.count, title]);
        }
        appendLogView(@"🎉 全部任务已遍历完成，返回等级页查看进度");
        dispatch_async(dispatch_get_main_queue(), ^{
            openLevelPage();
        });
        _levelTasksRunning = NO;
    });
}

// ══════════════════════════════════════════
//  v1.4 闭环执行引擎（状态闭环：执行前抓 0x9172 → 过滤 → 执行 → 重抓对比）
//  复用现有 openJumpSchema / autoTapAllWebViews / 停留逻辑，不新增复杂操作
// ══════════════════════════════════════════

// ── 读取 qqtask_status.json 的任务列表（nil=无数据）──
static NSArray *qqfbReadTaskStatusList(void) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/qqtask_status.json"];
    NSData *jd = [NSData dataWithContentsOfFile:path];
    if (!jd || jd.length == 0) return nil;
    @try {
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
        if ([root isKindOfClass:[NSDictionary class]]) {
            return root[@"tasks"];
        }
    } @catch (NSException *e) {}
    return nil;
}

// v1.7.1: 只返回「额外活跃天数」组的任务（用户需求：付费加倍/日常活跃不要）
// group=extra 优先；旧 JSON 无 group 字段时退化为过滤付费标题（兼容历史数据）
static BOOL qqfbIsPaidTaskTitle(NSString *title);   // 前向声明（定义在下方 2216 行）
static NSArray *qqfbReadExtraOnlyTasks(void) {
    NSArray *all = qqfbReadTaskStatusList();
    if (!all || all.count == 0) return nil;
    NSMutableArray *out = [NSMutableArray array];
    BOOL hasGroupField = NO;
    for (NSDictionary *t in all) {
        if ([t isKindOfClass:[NSDictionary class]] && [t[@"group"] length] > 0) { hasGroupField = YES; break; }
    }
    for (NSDictionary *t in all) {
        if (![t isKindOfClass:[NSDictionary class]]) continue;
        if (hasGroupField) {
            if ([t[@"group"] isEqualToString:@"extra"]) [out addObject:t];
        } else {
            NSString *title = t[@"title"] ?: @"";
            if (qqfbIsPaidTaskTitle(title)) continue;   // 付费加倍排除
            if ([title containsString:@"在线"]) continue; // 日常活跃排除（电脑QQ在线/手机QQ连续在线）
            [out addObject:t];
        }
    }
    return out.count > 0 ? out : nil;
}

// ── 当前 qqtask_status.json 的 capturedAt（Unix 时间戳，无文件=0）──
static double qqfbStatusCapturedAt(void) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/qqtask_status.json"];
    NSData *jd = [NSData dataWithContentsOfFile:path];
    if (!jd || jd.length == 0) return 0;
    @try {
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
        NSNumber *ts = root[@"capturedAt"];
        if ([ts isKindOfClass:[NSNumber class]]) return [ts doubleValue];
    } @catch (NSException *e) {}
    return 0;
}

// ── 等待 capturedAt 更新（打开等级页触发 0x9172 后轮询，最多 timeoutSec 秒）──
static BOOL qqfbWaitStatusRefresh(double oldTs, int timeoutSec) {
    for (int i = 0; i < timeoutSec * 2; i++) {
        [NSThread sleepForTimeInterval:0.5];
        if (qqfbStatusCapturedAt() > oldTs + 0.001) return YES;
    }
    return NO;
}

// ── 按 taskId 或 title 在任务列表找 status（-1=找不到）──
static int qqfbFindTaskStatusIn(NSArray *tasks, NSString *taskId, NSString *title) {
    for (NSDictionary *t in tasks) {
        if (![t isKindOfClass:[NSDictionary class]]) continue;
        NSString *tid = t[@"taskId"] ?: @"";
        if (taskId.length && [tid isEqualToString:taskId]) {
            NSNumber *s = t[@"status"];
            return s ? [s intValue] : -1;
        }
    }
    if (title.length) {
        int st = findTaskStatusByTitle(tasks, title);
        if (st >= 0) return st;
    }
    return -1;
}

// ── 付费任务标题判定（真机 0x9172 数据实锤：付费任务带 taskId 但标题含这些词）──
static BOOL qqfbIsPaidTaskTitle(NSString *title) {
    if (!title) return NO;
    static NSArray *kws = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kws = @[@"开通", @"购买", @"买断", @"包月", @"年费", @"专享", @"靓号", @"黑金", @"炫彩",
                @"大会员", @"SVIP", @"黄钻", @"至尊"];
    });
    for (NSString *kw in kws) {
        if ([title containsString:kw]) return YES;
    }
    return NO;
}

// ── 过滤可执行任务：status=0 + 有taskId + 有jumpURL + 非付费 ──
static NSMutableArray *qqfbFilterExecutableTasks(NSArray *tasks) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *t in tasks) {
        if (![t isKindOfClass:[NSDictionary class]]) continue;
        int st = [t[@"status"] intValue];
        if (st != 0) continue;                    // 已完成/已结束跳过
        NSString *tid = t[@"taskId"] ?: @"";
        if (tid.length == 0) continue;            // 无taskId（付费/无法判断）跳过
        NSString *jump = t[@"jumpURL"] ?: @"";
        if (jump.length == 0) continue;           // 无跳转入口跳过
        NSString *title = t[@"title"] ?: @"";
        if (qqfbIsPaidTaskTitle(title)) continue; // 付费任务跳过
        [out addObject:t];
    }
    return out;
}

// ── 随机抽 maxCount 个（可执行任务超过上限时用；≤上限全用）──
static NSArray *qqfbPickRandomTasks(NSArray *tasks, int maxCount) {
    NSMutableArray *pool = [tasks mutableCopy];
    NSMutableArray *picked = [NSMutableArray array];
    while (pool.count > 0 && picked.count < maxCount) {
        NSUInteger idx = arc4random_uniform((uint32_t)pool.count);
        [picked addObject:pool[idx]];
        [pool removeObjectAtIndex:idx];
    }
    return picked;
}

// ── 闭环执行主流程 ──
static void runClosedLoopTasks(void) __attribute__((unused));
static void runClosedLoopTasks(void) {
    if (_levelTasksRunning) {
        appendLogView(@"⚠️ 任务已在执行中，请勿重复点击");
        return;
    }
    _levelTasksRunning = YES;
    _closedLoopRunning = YES;   // 暂停抓包自动停止
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            qqlog(@"[闭环] ── 闭环执行开始（执行前抓取 0x9172 任务列表）──");

            // ── 1. 执行前：开抓包 + 打开等级页触发 0x9172 → 等待新数据 ──
            double oldTs = qqfbStatusCapturedAt();
            dispatch_async(dispatch_get_main_queue(), ^{
                _dumpAllRequests = YES;
                qqlog(@"[闭环] 抓包已开启，打开等级页刷新任务列表…");
                openLevelPage();
            });
            if (!qqfbWaitStatusRefresh(oldTs, 15)) {
                qqlog(@"[闭环] ⚠️ 15 秒内未抓到新的 0x9172 响应（等级页可能未打开/已抓过最新数据）");
            }
            NSArray *taskList = qqfbReadExtraOnlyTasks();
            if (!taskList || taskList.count == 0) {
                qqlog(@"[闭环] ❌ 没有额外活跃任务数据，请先手动打开等级页并点「额外活跃」一次");
                return;
            }
            NSMutableArray *cand = qqfbFilterExecutableTasks(taskList);
            qqlog(@"[闭环] 0x9172 共 %lu 个任务，可执行（status=0 免费有入口）%lu 个",
                  (unsigned long)taskList.count, (unsigned long)cand.count);
            for (NSDictionary *t in cand) {
                qqlog(@"[闭环]   候选: id=%@ %@", t[@"taskId"] ?: @"", t[@"title"] ?: @"?");
            }
            if (cand.count == 0) {
                qqlog(@"[闭环] ✅ 没有可执行任务（可能今天都做完了）");
                return;
            }

            // ── 2. 随机抽 3 个执行（真机测试要求）──
            NSArray *picked = qqfbPickRandomTasks(cand, 3);
            qqlog(@"[闭环] 本次随机抽取 %lu 个任务执行", (unsigned long)picked.count);
            int okN = 0, failN = 0;
            int idx = 0;
            for (NSDictionary *task in picked) {
                idx++;
                NSString *title = task[@"title"] ?: @"?";
                NSString *tid = task[@"taskId"] ?: @"";
                NSString *jump = task[@"jumpURL"] ?: @"";
                int before = [task[@"status"] intValue];
                qqlog(@"[闭环] ── [%d/%lu] %@（id=%@）执行前 status=%d ──", idx, (unsigned long)picked.count, title, tid, before);

                // 3. 打开任务页 + JS 自动点击（复用现有逻辑）+ 停留
                dispatch_async(dispatch_get_main_queue(), ^{
                    openJumpSchema(jump);
                });
                for (int round = 0; round < 3; round++) {
                    [NSThread sleepForTimeInterval:5];
                    autoTapAllWebViews();
                    autoTapNativeUI();
                }

                // 4. 执行后：回等级页触发新 0x9172 → 对比 status
                double t0 = qqfbStatusCapturedAt();
                dispatch_async(dispatch_get_main_queue(), ^{
                    openLevelPage();
                });
                BOOL got = qqfbWaitStatusRefresh(t0, 20);
                int after = -1;
                if (got) {
                    NSArray *newList = qqfbReadExtraOnlyTasks();
                    after = qqfbFindTaskStatusIn(newList ?: @[], tid, title);
                }
                if (after == 1) {
                    okN++;
                    qqlog(@"[闭环] ✅ [完成] %@ %d → %d", title, before, after);
                } else if (after == 0) {
                    failN++;
                    qqlog(@"[闭环] ❌ [失败] %@ %d → %d（状态未变化，可能任务完成方式不对）", title, before, after);
                } else {
                    failN++;
                    qqlog(@"[闭环] ❌ [失败] %@ %d → %@（执行后未抓到新状态%@）",
                          title, before, after == -1 ? @"?" : @(after),
                          got ? @"" : @"，重抓超时");
                }
            }
            qqlog(@"[闭环] ── 闭环执行结束：成功 %d / 失败 %d ──", okN, failN);
        } @catch (NSException *e) {
            qqlog(@"[闭环] 异常 %@", e);
        }
        _closedLoopRunning = NO;
        _levelTasksRunning = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            _dumpAllRequests = NO;
        });
    });
}

// ── 一键自动任务（v1.6.6：改造指引第一版——HTTP 直调可完成的任务）──
//  iOS 插件注入 QQ 进程内 = 天然同源（进程内现取分域 p_skey，2026-08-19 实测 levelTask/Get 直调可行，
//  不踩安卓 Qsped 的 -3000 死路——那是独立 app 无登录态的问题）。改造指引任务 2 的 Native 拦截 openKuikly
//  在 iOS 实测判死（task-center 网页版自动跳 Kuikly，拦截后页面又跳走，见 kuikly-pivot reference），第一版不做。
//  第一版只做改造指引第五节"能 HTTP 持久完成"的：日签卡打卡(SignIn) / 加好友(robots_addfriend) / 金币兑换(musics.fcg)。
//  执行前开抓包→打开等级页拿 0x9172 快照；执行后回等级页重抓 0x9172 对比 status 验收（不盲赌）。
static void runAutoHttpTasks(void) __attribute__((unused));
static void runAutoHttpTasks(void) {
    if (_levelTasksRunning) {
        appendLogView(@"⚠️ 任务已在执行中，请勿重复点击");
        return;
    }
    _levelTasksRunning = YES;
    _closedLoopRunning = YES;   // 暂停抓包自动停止（v1.5.0 已是 no-op，双保险）
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            qqlog(@"[自动任务] ── 一键自动任务开始（v1.6.6）──");

            // 1. 执行前：开抓包 + 打开等级页触发 0x9172 → 等新数据（执行前快照）
            double oldTs = qqfbStatusCapturedAt();
            dispatch_async(dispatch_get_main_queue(), ^{
                _dumpAllRequests = YES;
                openLevelPage();
            });
            if (!qqfbWaitStatusRefresh(oldTs, 15)) {
                qqlog(@"[自动任务] ⚠️ 15 秒内未抓到新 0x9172（等级页可能未打开/数据未变），继续执行但回查可能失败");
            }
            NSArray *taskList = qqfbReadExtraOnlyTasks();
            if (!taskList || taskList.count == 0) {
                qqlog(@"[自动任务] ❌ 没有额外活跃任务数据，请先手动打开等级页并点「额外活跃」一次");
                return;
            }
            NSMutableDictionary *beforeStatus = [NSMutableDictionary dictionary];
            for (NSDictionary *t in taskList) {
                NSString *tid = t[@"taskId"] ?: t[@"task_id"] ?: @"";
                NSString *title = t[@"title"] ?: @"?";
                if (tid.length) beforeStatus[tid] = @{@"title": title, @"status": t[@"status"] ?: @(-1)};
            }

            NSString *uin = getCurrentUin();
            qqlog(@"[自动任务] 当前 uin=%@，0x9172 共 %lu 个任务", uin, (unsigned long)taskList.count);

            int okN = 0, failN = 0, skipN = 0;

            // 2. 日签卡打卡（ti 域 SignIn，改造指引第五节：能 HTTP 持久完成）
            qqlog(@"[自动任务] ── [1/3] 日签卡打卡（ti.qq.com/hybrid-h5 SignIn）──");
            if (runDailySignTask(uin)) { okN++; qqlog(@"[自动任务] ✅ 日签卡打卡 接口返回成功"); }
            else { failN++; qqlog(@"[自动任务] ❌ 日签卡打卡 失败（见上面响应日志）"); }

            // 3. 加好友（qun 域 robots_addfriend）
            qqlog(@"[自动任务] ── [2/3] 加好友（%@，qun 域 robots_addfriend）──", _friendRobotUin);
            if (runAddFriendTask(uin, _friendRobotUin)) { okN++; qqlog(@"[自动任务] ✅ 加好友 接口返回成功"); }
            else { failN++; qqlog(@"[自动任务] ❌ 加好友 失败（见上面响应日志）"); }

            // 4. 金币兑换等级加速（musics.fcg，需 qm_keyst；iOS QQ 内可能没有 QQ 音乐登录态 → 自动跳过不算失败）
            qqlog(@"[自动任务] ── [3/3] 金币兑换等级加速（musics.fcg）──");
            if (runCoinExchangeTask(uin)) { okN++; qqlog(@"[自动任务] ✅ 金币兑换 接口返回成功"); }
            else { skipN++; qqlog(@"[自动任务] ⏭ 金币兑换 跳过（无 qm_keyst 或接口失败，详见上面日志）"); }

            // 5. 执行后：回等级页触发新 0x9172 → 对比 status（验收：0/1 → 1/2 才算真完成）
            qqlog(@"[自动任务] 执行完毕，回等级页重抓 0x9172 回查状态…");
            double t0 = qqfbStatusCapturedAt();
            dispatch_async(dispatch_get_main_queue(), ^{ openLevelPage(); });
            BOOL got = qqfbWaitStatusRefresh(t0, 20);
            int pushedN = 0;
            if (got) {
                NSArray *newList = qqfbReadExtraOnlyTasks();
                for (NSString *tid in beforeStatus) {
                    int before = [beforeStatus[tid][@"status"] intValue];
                    int after = qqfbFindTaskStatusIn(newList ?: @[], tid, beforeStatus[tid][@"title"]);
                    if (before == 0 && after == 1) {
                        pushedN++;
                        qqlog(@"[自动任务] ✅ [完成] %@ %d → %d", beforeStatus[tid][@"title"], before, after);
                    } else if (before != after && after >= 0) {
                        qqlog(@"[自动任务] ℹ️ [变化] %@ %d → %d", beforeStatus[tid][@"title"], before, after);
                    }
                }
                if (pushedN == 0) {
                    qqlog(@"[自动任务] ⚠️ 回查无 status 推进（0→1）——HTTP 接口虽返回成功，但服务端可能未记账（ad 埋点类任务需真实交互）");
                }
            } else {
                qqlog(@"[自动任务] ⚠️ 执行后未抓到新 0x9172（等级页可能未打开），请点「📊 刷新任务状态」人工复核");
            }

            qqlog(@"[自动任务] ── 一键自动任务结束：接口成功 %d / 失败 %d / 跳过 %d / status推进 %d ──", okN, failN, skipN, pushedN);
        } @catch (NSException *e) {
            qqlog(@"[自动任务] 异常 %@", e);
        }
        _closedLoopRunning = NO;
        _levelTasksRunning = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ _dumpAllRequests = NO; });
    });
}

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

    // ── 只显示等级页获取到的任务；内置任务已移除，避免误点无效任务 ──
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

        // 标题（显示等级页获取到的任务）
        UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, w - 12 - 136, 20)];
        tl.text = title;
        tl.textColor = [UIColor whiteColor];
        tl.font = [UIFont systemFontOfSize:12];
        tl.numberOfLines = 1;
        tl.lineBreakMode = NSLineBreakByTruncatingTail;
        [row addSubview:tl];

        // 任务收益
        UILabel *dl = [[UILabel alloc] initWithFrame:CGRectMake(8, 24, w - 12 - 136, 18)];
        dl.text = [NSString stringWithFormat:@"%@ / %@", days, status];
        dl.textColor = [UIColor systemYellowColor];
        dl.font = [UIFont systemFontOfSize:10];
        dl.numberOfLines = 1;
        dl.lineBreakMode = NSLineBreakByTruncatingTail;
        [row addSubview:dl];

        // 单项测试按钮：只执行用户点击的这一行，不自动随机执行，不批量执行
        UIButton *testBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        testBtn.frame = CGRectMake(w - 12 - 78, 8, 78, 30);
        testBtn.tag = i;
        [testBtn setTitle:@"▶ 测试" forState:UIControlStateNormal];
        [testBtn setTitleColor:[UIColor systemOrangeColor] forState:UIControlStateNormal];
        testBtn.titleLabel.font = [UIFont systemFontOfSize:10];
        [testBtn addTarget:[UIApplication sharedApplication] action:@selector(_taskTestTapped:) forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:testBtn];

        [_taskScroll addSubview:row];
        y += rowH + 4;
    }
    _taskScroll.contentSize = CGSizeMake(w, y + 10);
}

// ── 刷新任务列表（拉接口 → 渲染）──
static void refreshTaskListUI(void) {
    // v1.4.9: 数据源优先级改为 0x9172 全量任务（iOS 等级页真全量 26+ 条，qqtask_status.json）
    //          → 客户端 levelTask/Get 捕获（iOS 只回 10 个，安卓才全量） → 在线拉取
    // iOS 上 levelTask/Get 有 is_ios_review_hide 审核过滤只给 10 条，必须用 0x9172 PB 的 taskId/jumpURL/status
    NSArray *statusTasks = qqfbReadExtraOnlyTasks();
    if (statusTasks && statusTasks.count > 0) {
        _taskListCache = statusTasks;
        if (!_checkedTaskIds) _checkedTaskIds = [NSMutableSet set];
        appendLogView([NSString stringWithFormat:@"✅ 使用 0x9172 额外活跃任务 %lu 个", (unsigned long)statusTasks.count]);
        renderTaskRows();
        return;
    }
    // v1.2.2: 其次用客户端原生捕获的任务列表（QQ 自己请求带 skey 全凭证）
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
    if (_taskPanel) { // 已存在：收起↔展开切换（v1.7.4 不再销毁，日志保留）
        _taskPanel.hidden = !_taskPanel.hidden;
        if (!_taskPanel.hidden) renderTaskRows();
        return;
    }
    if (!_floatWindow) return;
    CGRect frame = _floatWindow.bounds;
    CGFloat w = MIN(330, frame.size.width - 16);
    // v1.1.4: 面板默认显示在安全区下方, 不压灵动岛(否则顶部拖拽区收不到触摸)
    CGFloat y = safeTopInset() + 70;
    CGFloat h = MIN(480, frame.size.height - y - 40);
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(frame.size.width - w - 8, y, w, h)];
    panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    panel.layer.cornerRadius = 14;
    panel.layer.masksToBounds = YES;
    panel.userInteractionEnabled = YES;
    _taskPanel = panel;

    // 分区标签 helper（小灰字，分隔功能区）
    UILabel * (^sectionLabel)(CGFloat sy, NSString *text) = ^UILabel *(CGFloat sy, NSString *text) {
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(12, sy, w - 24, 16)];
        lb.text = text;
        lb.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55];
        lb.font = [UIFont systemFontOfSize:10];
        [panel addSubview:lb];
        return lb;
    };

    // 标题栏
    UILabel *titleLb = [[UILabel alloc] initWithFrame:CGRectMake(12, 10, 170, 22)];
    titleLb.text = [NSString stringWithFormat:@"⚡ QQ等级助手 v%@", kQQFloatBallVersion];
    titleLb.textColor = [UIColor whiteColor];
    titleLb.font = [UIFont boldSystemFontOfSize:15];
    [panel addSubview:titleLb];

    // 标题栏拖动条：扩大可拖区域；右侧按钮区域保留点击能力。
    // v1.7.4: 拖宽加大到 w-120，整条标题栏都可拖（原 w-190 太窄不好拖）
    UIView *dragBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w - 120, 40)];
    dragBar.backgroundColor = [UIColor clearColor];
    dragBar.userInteractionEnabled = YES;
    UIPanGestureRecognizer *panelPan = [[UIPanGestureRecognizer alloc] initWithTarget:[UIApplication sharedApplication]
                                                                              action:@selector(_taskPanelPanned:)];
    [dragBar addGestureRecognizer:panelPan];
    [panel addSubview:dragBar];
    [panel bringSubviewToFront:dragBar];

    // 关闭
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(w - 30, 8, 24, 26);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    [closeBtn addTarget:[UIApplication sharedApplication] action:@selector(_taskCloseTapped:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:closeBtn];

    // ══ 分区1：一键任务（主功能，最醒目）══
    sectionLabel(42, @"🚀 一键任务");
    UIButton *autoBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    autoBtn.frame = CGRectMake(6, 60, w - 12, 36);
    [autoBtn setTitle:@"🚀 一键自动任务（日签卡/加好友/金币兑换）" forState:UIControlStateNormal];
    [autoBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    autoBtn.backgroundColor = [UIColor systemOrangeColor];
    autoBtn.layer.cornerRadius = 8;
    autoBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [autoBtn addTarget:[UIApplication sharedApplication] action:@selector(_taskAutoRunTapped:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:autoBtn];

    // ══ 分区2：任务状态 ══
    sectionLabel(102, @"📋 任务状态");
    UIButton *runBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    // v1.7.4: 全宽按钮（原「📊 刷新状态」废按钮已删——它只读本地旧文件不重新抓取，
    //          真正的刷新流程=点「🔄 获取任务」→自动开抓包→跳等级页→等新0x9172→列表自动刷新）
    runBtn.frame = CGRectMake(6, 120, w - 12, 30);
    [runBtn setTitle:@"🔄 获取任务（自动抓包+跳等级页+自动刷新）" forState:UIControlStateNormal];
    [runBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    runBtn.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.85];
    runBtn.layer.cornerRadius = 6;
    runBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [runBtn addTarget:[UIApplication sharedApplication] action:@selector(_taskRunLevelTapped:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:runBtn];

    // ══ 分区3：抓包调试（排查用，弱化）══
    sectionLabel(156, @"🔧 抓包调试");
    UIButton *openBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    openBtn.frame = CGRectMake(6, 174, (w - 18) / 3, 26);
    [openBtn setTitle:@"🌐 打开等级页" forState:UIControlStateNormal];
    [openBtn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    openBtn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    openBtn.layer.cornerRadius = 6;
    openBtn.titleLabel.font = [UIFont systemFontOfSize:10];
    [openBtn addTarget:[UIApplication sharedApplication] action:@selector(_taskOpenLevelPageTapped:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:openBtn];

    UIButton *captureBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    captureBtn.frame = CGRectMake(6 + (w - 18) / 3 + 3, 174, (w - 18) / 3, 26);
    [captureBtn setTitle:@"⏺ 抓取" forState:UIControlStateNormal];
    [captureBtn setTitleColor:[UIColor systemGreenColor] forState:UIControlStateNormal];
    captureBtn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    captureBtn.layer.cornerRadius = 6;
    captureBtn.titleLabel.font = [UIFont systemFontOfSize:10];
    [captureBtn addTarget:[UIApplication sharedApplication] action:@selector(_taskCaptureTapped:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:captureBtn];

    UIButton *stopBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    stopBtn.frame = CGRectMake(6 + (w - 18) / 3 * 2 + 6, 174, (w - 18) / 3, 26);
    [stopBtn setTitle:@"⏹ 停止" forState:UIControlStateNormal];
    [stopBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    stopBtn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    stopBtn.layer.cornerRadius = 6;
    stopBtn.titleLabel.font = [UIFont systemFontOfSize:10];
    [stopBtn addTarget:[UIApplication sharedApplication] action:@selector(_taskStopCaptureTapped:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:stopBtn];

    // ══ 任务列表区：获取后展示任务 ══
    sectionLabel(206, @"📄 任务列表");
    CGFloat listH = MAX(70, MIN(140, h - 206 - 100));
    UIScrollView *taskScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(6, 224, w - 12, listH)];
    taskScroll.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    taskScroll.layer.cornerRadius = 6;
    taskScroll.userInteractionEnabled = YES;
    taskScroll.alwaysBounceVertical = YES;
    _taskScroll = taskScroll;
    [panel addSubview:taskScroll];

    // ══ 日志区 ══
    sectionLabel(232 + listH, @"📜 运行日志");
    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(6, 250 + listH, w - 12, h - 256 - listH)];
    tv.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
    tv.layer.cornerRadius = 6;
    tv.textColor = [UIColor whiteColor];
    tv.font = [UIFont systemFontOfSize:10];
    tv.editable = NO;
    tv.selectable = YES;
    tv.text = @"QQ等级助手日志：\n🚀 一键任务＝自动跑 日签卡打卡/加好友/金币兑换，执行前后自动对比完成状态。\n📋 任务状态＝查看/刷新任务列表和完成情况。\n🔧 抓包调试＝排查接口用，日常不用点。\n\n";
    _logTextView = tv;
    _logView = panel;
    [panel addSubview:tv];

    [_floatWindow addSubview:panel];
    renderTaskRows();
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
- (void)_taskTestTapped:(UIButton *)sender;
- (void)_builtinCheckTapped:(UIButton *)sender;
- (void)_builtinTestTapped:(UIButton *)sender;
- (void)_taskRefreshTapped:(UIButton *)sender;
- (void)_taskCloseTapped:(UIButton *)sender;
- (void)_taskExecCheckedTapped:(UIButton *)sender;
- (void)_taskOpenLevelPageTapped:(UIButton *)sender;
- (void)_taskCaptureTapped:(UIButton *)sender;
- (void)_taskStopCaptureTapped:(UIButton *)sender;
- (void)_taskRunLevelTapped:(UIButton *)sender;
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
    NSString *tid = task[@"task_id"] ?: task[@"taskId"] ?: @"";
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
- (void)_taskAutoRunTapped:(UIButton *)sender {
    // v1.6.7: 完整自动导航（HTTP 直调 + 跳页面自动点击 + 回查状态），覆盖全部可做任务
    appendLogView(@"🚀 一键自动任务启动…（HTTP直调 + 自动导航遍历全部任务）");
    runAutoTasks();
}

%new
- (void)_taskCloseTapped:(UIButton *)sender {
    // v1.7.4: ✕ = 收起面板（隐藏），不销毁——日志/状态保留，点浮球可恢复
    // （旧实现 removeFromSuperview+置nil 导致日志面板消失后无法找回）
    if (_taskPanel) {
        _taskPanel.hidden = YES;
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
    // v1.5.0: 只打开等级页，不自动开抓包（抓包由「抓取」手动控制，停止由「停止抓包」控制）
    if (_dumpAllRequests) {
        appendLogView(@"[iOS抓取] 抓包进行中，打开等级页后将记录所有请求");
    } else {
        appendLogView(@"[iOS抓取] 提示：等级页将打开，如要抓包请先点「⏺ 抓取」");
    }
    NSString *pageUrl = @"https://ti.qq.com/qqlevel/index?_wv=3&_wwv=1&tab=6&source=15";
    NSData *bd = [pageUrl dataUsingEncoding:NSUTF8StringEncoding];
    NSString *b64 = [bd base64EncodedStringWithOptions:0];
    NSString *deep = [NSString stringWithFormat:@"mqqapi://forward/url?src_type=web&version=1&url_prefix=%@", b64];
    NSURL *u = [NSURL URLWithString:deep];
    if (!u || ![[UIApplication sharedApplication] canOpenURL:u]) {
        appendLogView(@"[iOS抓取] 无法拉起等级页深链");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
        appendLogView(@"[iOS抓取] 等级页已打开");
        qqlog(@"[iOS抓取] 等级页已打开");
    });
}
%new
- (void)_taskCaptureTapped:(UIButton *)sender {
    // v1.5.0: 手动开启抓包，不自动停止——持续记录直到用户点「⏹ 停止抓包」
    if (_dumpAllRequests) {
        appendLogView(@"[iOS抓取] 已在抓包中（不点停止不停止）");
        return;
    }
    _dumpAllRequests = YES;
    appendLogView(@"[iOS抓取] ⏺ 已开始抓包：记录所有请求，点「⏹ 停止抓包」结束");
    qqlog(@"[iOS抓取] 手动抓包开始（不自动停止）");
}

%new
- (void)_taskStopCaptureTapped:(UIButton *)sender {
    // v1.5.0: 手动停止抓包
    if (!_dumpAllRequests) {
        appendLogView(@"[iOS抓取] 当前未在抓包");
        return;
    }
    _dumpAllRequests = NO;
    appendLogView(@"[iOS抓取] ⏹ 已停止抓包");
    qqlog(@"[iOS抓取] 手动停止抓包");
}

%new
- (void)_taskRunLevelTapped:(UIButton *)sender {
    // v1.7.3: 实时获取——自动开抓包+打开等级页(额外活跃tab)，等新 0x9172 后自动刷新
    //         显示额外活跃天数组全部任务（付费/已完成/不能做的都显示，不过滤）
    appendLogView(@"🔄 实时获取：自动开抓包+打开等级页，等待最新任务…");
    if (!_dumpAllRequests) {
        _dumpAllRequests = YES;
        appendLogView(@"[iOS抓取] ⏺ 已自动开抓包");
    }
    double oldTs = qqfbStatusCapturedAt();
    // 打开等级页（tab=6 额外活跃，0x9172 在此 tab 下触发）
    NSString *pageUrl = @"https://ti.qq.com/qqlevel/index?_wv=3&_wwv=1&tab=6&source=15";
    NSData *bd = [pageUrl dataUsingEncoding:NSUTF8StringEncoding];
    NSString *b64 = [bd base64EncodedStringWithOptions:0];
    NSString *deep = [NSString stringWithFormat:@"mqqapi://forward/url?src_type=web&version=1&url_prefix=%@", b64];
    NSURL *u = [NSURL URLWithString:deep];
    if (!u || ![[UIApplication sharedApplication] canOpenURL:u]) {
        appendLogView(@"[iOS抓取] 无法拉起等级页深链");
        return;
    }
    [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    appendLogView(@"[iOS抓取] 等级页已打开，等待 0x9172 响应…");
    // 后台等新数据（最长 20 秒），抓到后自动刷新面板
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL got = qqfbWaitStatusRefresh(oldTs, 20);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (got) {
                refreshTaskListUI();
                appendLogView(@"✅ 已获取最新额外活跃任务（全部显示，含付费/已完成）");
            } else {
                appendLogView(@"⚠️ 20秒内未抓到新 0x9172：可再点一次「🔄获取」（等级页需加载到额外活跃tab）");
            }
        });
    });
}

%new
- (void)_taskTestTapped:(UIButton *)sender {
    int idx = (int)sender.tag;
    if (!_taskListCache || idx < 0 || idx >= (int)_taskListCache.count) return;
    NSDictionary *task = _taskListCache[idx];
    if (![task isKindOfClass:[NSDictionary class]]) return;
    NSString *title = task[@"title"] ?: task[@"task_name"] ?: @"?";
    NSString *jump = task[@"jumpURL"] ?: task[@"jump_schema"] ?: task[@"jump"] ?: @"";
    NSString *uin = getCurrentUin();
    if (!uin.length) {
        appendLogView(@"❌ 无法测试：未找到当前 QQ 账号");
        return;
    }
    appendLogView([NSString stringWithFormat:@"🧪 测试单个任务：%@（仅执行此行）", title]);
    // v1.8.1: 用户点选任务后：打开页面 + 自动扫描点击 5 轮（不再「后续操作由用户完成」——
    // 用户实测「进去小说又不点 就是乱逛」= 手动点任务后插件完全不动）
    if (jump.length > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            qqlog(@"[任务测试] 用户点选，打开页面：%@ jump=%@", title, jump);
            openJumpSchema(jump);
            appendLogView([NSString stringWithFormat:@"➡️ 已打开：%@，自动扫描点击中…", title]);
        });
        // 后台线程：等待页面加载后自动扫描点击 5 轮（与一键任务同逻辑）
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @autoreleasepool {
                for (int round = 0; round < 5; round++) {
                    [NSThread sleepForTimeInterval:5];
                    autoTapAllWebViews();
                    autoTapNativeUI();
                }
                qqlog(@"[任务测试] 自动扫描结束（5 轮），可手动补充操作");
            }
        });
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            qqlog(@"[任务测试] 用户点选，执行后台任务：%@", title);
            execTaskByTitle(title, uin);
            appendLogView([NSString stringWithFormat:@"✅ 测试已完成：%@（详见设备日志）", title]);
        }
    });
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
            NSString *tid = task[@"task_id"] ?: task[@"taskId"] ?: @"";
            if (!tid || ![_checkedTaskIds containsObject:tid]) continue;
            NSString *title = task[@"title"] ?: @"?";
            qqlog(@"[任务] ── 执行: %@ (tid=%@) ──", title, tid);
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

// ── 递归收集可注入 JS 的视图（不引用 WKWebView 头文件，防编译/加载依赖）──
// v1.6.8: 从「必须是 WKWebView 类」放宽为「respondsToSelector:evaluateJavaScript:completionHandler:」
//         覆盖 QQ 内部 H5 容器（QQWebViewController 内 webView 类名可能不同）
static void collectWebViewsInView(UIView *view, NSMutableArray *outArr) {
    if (!view) return;
    if ([view respondsToSelector:NSSelectorFromString(@"evaluateJavaScript:completionHandler:")]) {
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
        // v1.8.0: 不再读 URL 判断跳过——Kuikly 容器 URL KVC 读不出但能执行 JS，
        // 一律注入（「注入页面」日志只在 JS 有结果时打，防刷屏）
        NSString *js =
        @"(function(){"
        "  var kws=['签到','立即签到','一键签到','打卡','立即打卡','领取','立即领取','去完成','发布','发表','确定','同意','完成','去打卡','领福利','免费阅读','试读','开始阅读'];"
        "  var skipWords=['已打卡','今日已打卡','已完成','已领取','已发布','已参与','已签到','已达成','已获得','已领取奖励','已奖励','已领','已完'];"
        "  function isSkip(t){ for(var i=0;i<skipWords.length;i++){ if(t.indexOf(skipWords[i])!==-1) return true; } return false; }"
        "  function tryClick(root){"
        "    var els=root.querySelectorAll('button,a,div,span,p,li,input[type=button],input[type=submit]');"
        "    for(var i=0;i<els.length;i++){"
        "      var el=els[i];"
        "      if(el.offsetParent===null) continue;"
        "      var t=(el.innerText||el.textContent||el.value||'').trim();"
        "      if(!t||t.length>12) continue;"
        "      if(isSkip(t)) continue;"
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
        "  if(!r){"
        "    // v1.7.9: 小说书城等列表页 fallback——没有按钮词时点第一个可点链接（进书详情/下一页）"
        "    var links=document.querySelectorAll('a');"
        "    for(var i=0;i<links.length;i++){"
        "      var a=links[i];"
        "      if(a.offsetParent===null) continue;"
        "      var h=a.href||'';"
        "      var at=(a.innerText||a.textContent||'').trim();"
        "      if(h && at.length>0 && at.length<=20 && !isSkip(at)){"
        "        a.click();"
        "        return '点链接:'+at;"
        "      }"
        "    }"
        "    window.scrollTo(0,document.body.scrollHeight);"
        "    setTimeout(function(){r=tryClick(document);},800);"
        "  }"
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
            void *handlerPtr = (__bridge void *)handler;
            [inv setArgument:&handlerPtr atIndex:3];
            [inv invoke];
        } else {
            qqlog(@"[autotap] 无方法签名");
        }
        // v1.6.8 二次注入：首轮点击（如「签到」）后等 2.5 秒再注入一轮，
        // 命中新出现的按钮（如「发布到空间」「分享」）——盲盒签两步流程
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                if (![webView respondsToSelector:evalSel]) return;
                NSString *js2 =
                @"(function(){"
                "  var kws=['发布到空间','分享','去分享','发表','发布','确认','确定','完成','好的','继续','立即参与','参与'];"
                "  var els=document.querySelectorAll('button,a,div,span,p,li,input[type=button],input[type=submit]');"
                "  for(var i=0;i<els.length;i++){"
                "    var el=els[i];"
                "    if(el.offsetParent===null) continue;"
                "    var t=(el.innerText||el.textContent||el.value||'').trim();"
                "    if(!t||t.length>12) continue;"
                "    for(var k=0;k<kws.length;k++){"
                "      if(t.indexOf(kws[k])!==-1){ el.click(); return '二击:'+t; }"
                "    }"
                "  }"
                "  return '';"
                "})()";
                NSMethodSignature *sig2 = [webView methodSignatureForSelector:evalSel];
                if (sig2) {
                    NSInvocation *inv2 = [NSInvocation invocationWithMethodSignature:sig2];
                    [inv2 setTarget:webView];
                    [inv2 setSelector:evalSel];
                    [inv2 setArgument:&js2 atIndex:2];
                    void *handler2Ptr = (__bridge void *)handler;
                    [inv2 setArgument:&handler2Ptr atIndex:3];
                    [inv2 invoke];
                }
            } @catch (NSException *e2) {
                qqlog(@"[autotap] 二次注入异常: %@", e2);
            }
        });
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
                // v1.7.8: 日志降噪——「未找到 WKWebView」连续打 N 次刷屏（Kuikly 任务页
                // 本来就没有 WKWebView），改为最多 10 秒打一次
                static NSTimeInterval lastLog = 0;
                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                if (now - lastLog > 10) {
                    qqlog(@"[autotap] 未找到 WKWebView（页面可能还在加载/Kuikly 原生页）");
                    lastLog = now;
                }
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

// ══════════════════════════════════════════
//  v1.6.9 原生 UI 自动点击（QQ 空间说说/盲盒签等原生页面没有 WKWebView）
//  JS 注入对原生页面无效，改为遍历原生视图树：
//   1) 找 UITextView 输入文字（发布说说：先填内容再点发表）
//   2) 找标题含 签到/打卡/发表/发布/分享/确认/完成 的 UIButton 直接点
//  纯动态调用 + 主线程，无 swizzle，加载零风险
// ══════════════════════════════════════════

// ── 读取手势 target/action（v1.8.2 修复）──
// UIGestureRecognizerTarget 的 _target/_action 是 ivar 不是 KVC 属性，
// valueForKey:@"_target" 必抛 valueForUndefinedKey 异常（v1.8.1 实测刷屏），
// 必须用 object_getIvar + class_getInstanceVariable 读取。
static BOOL qqfbGestureInvoke(UIGestureRecognizer *g, NSString *logTag) {
    @try {
        // v1.8.4（用户「随便点一本书就行了」）：过滤文本交互手势——
        // UITextNonEditableInteraction 继承自 UITapGestureRecognizer，会被 isKindOfClass
        // 误判为 tap。日志实锤：小说书城兜底点击点中 <UITextNonEditableInteraction>
        // (6,390 318x84)（书城顶部文本条），触发它=白点不点书。
        // 凡类名含 UIText / TextInteraction 的一律跳过，只点真正的点击手势。
        NSString *gcls = NSStringFromClass([g class]);
        if ([gcls containsString:@"UIText"] || [gcls containsString:@"TextInteraction"]) {
            return NO;
        }
        id targets = [g valueForKey:@"_targets"];
        if (![targets isKindOfClass:[NSArray class]] || [(NSArray *)targets count] == 0) return NO;
        id tgt = [(NSArray *)targets firstObject];
        if (!tgt) return NO;
        Ivar targetIvar = class_getInstanceVariable([tgt class], "_target");
        Ivar actionIvar = class_getInstanceVariable([tgt class], "_action");
        if (!targetIvar || !actionIvar) return NO;
        id obj = object_getIvar(tgt, targetIvar);
        // ARC 禁 (SEL) 指针转换：_action ivar 实为指针，memcpy 取出
        SEL action = NULL;
        void *actionPtr = (__bridge void *)object_getIvar(tgt, actionIvar);
        memcpy(&action, &actionPtr, sizeof(action));
        if (!obj || !action) return NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [obj performSelector:action withObject:g];
#pragma clang diagnostic pop
        qqlog(@"[autotap] %@: %@", logTag, [obj description]);
        return YES;
    } @catch (NSException *e) {
        qqlog(@"[autotap] 手势触发异常(%@): %@", logTag, e);
        return NO;
    }
}

// ── debug: dump 当前窗口视图树（v1.8.5 小说书城结构实锤）──
// 打印：类名 frame + css_click/css_touchUp block 有无 + 手势类型，最多 60 个节点
static void qqfbDumpViewTree(void) {
    @try {
        dispatch_async(dispatch_get_main_queue(), ^{
            qqlog(@"[dump] ===== 视图树开始 =====");
            int depth = 0;
            __block int count = 0;
            __block void (^walk)(UIView *, int);
            walk = ^(UIView *v, int d) {
                if (!v || count >= 60) return;
                count++;
                NSString *indent = [@"" stringByPaddingToLength:d*2 withString:@" " startingAtIndex:0];
                NSString *cls = NSStringFromClass([v class]);
                CGRect f = v.frame;
                NSString *extra = @"";
                SEL clickSel = NSSelectorFromString(@"css_click");
                SEL touchSel = NSSelectorFromString(@"css_touchUp");
                if ([v respondsToSelector:clickSel]) {
                    id (*getter)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                    id b = getter(v, clickSel);
                    if (b) extra = [extra stringByAppendingString:@" [css_click]"];
                }
                if ([v respondsToSelector:touchSel]) {
                    id (*getter)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                    id b = getter(v, touchSel);
                    if (b) extra = [extra stringByAppendingString:@" [css_touchUp]"];
                }
                if (v.gestureRecognizers.count > 0) {
                    for (UIGestureRecognizer *g in v.gestureRecognizers) {
                        extra = [extra stringByAppendingFormat:@" [%@]", NSStringFromClass([g class])];
                    }
                }
                NSString *acc = v.accessibilityLabel;
                if (acc.length > 0) extra = [extra stringByAppendingFormat:@" acc=%@", acc];
                qqlog(@"[dump] %@%@ frame=(%.0f,%.0f %.0fx%.0f)%@", indent, cls, f.origin.x, f.origin.y, f.size.width, f.size.height, extra);
                for (UIView *sub in v.subviews) {
                    walk(sub, d+1);
                }
            };
            for (UIWindow *win in [UIApplication sharedApplication].windows) {
                if (win.hidden) continue;
                qqlog(@"[dump] window=%@", NSStringFromClass([win class]));
                walk(win, 1);
            }
            qqlog(@"[dump] ===== 视图树结束 (%d 节点) =====", count);
        });
    } @catch (NSException *e) {
        qqlog(@"[dump] 异常: %@", e);
    }
}

// ── 调 Kuikly css_click/css_touchUp block（v1.8.5，腾讯开源 KuiklyUI 实锤）──
// KuiklyUI core-render-ios/Extension/Category/UIView+CSS.m：
//   css_onClickTapWithSender: 里 css_click(@{x,y,pageX,pageY}) —— x/y 是组件本地坐标，
//   pageX/pageY 是 Kuikly 渲染根视图坐标（kr_convertLocalPointToRenderRoot: 转换）。
// 我们用组件中心点模拟点击；page 坐标通过动态调用 kr_convertLocalPointToRenderRoot: 转换，
// 调用失败则退化为本地坐标（多数业务只用相对坐标判断命中区域，中心点必中）。
static BOOL qqfbKuiklyInvoke(UIView *view, id block, NSString *logTag) {
    @try {
        if (!view || !block) return NO;
        CGPoint center = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
        CGPoint page = center;
        // 动态调用 kr_convertLocalPointToRenderRoot:（Kuikly 私有但 category 公开）
        SEL convSel = NSSelectorFromString(@"kr_convertLocalPointToRenderRoot:");
        if (convSel && [view respondsToSelector:convSel]) {
            NSMethodSignature *sig = [view methodSignatureForSelector:convSel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = view;
                inv.selector = convSel;
                [inv setArgument:&center atIndex:2];
                [inv invoke];
                CGPoint outP;
                [inv getReturnValue:&outP];
                page = outP;
            }
        }
        NSDictionary *param = @{
            @"x": @(center.x), @"y": @(center.y),
            @"pageX": @(page.x), @"pageY": @(page.y),
        };
        // KuiklyRenderCallback = void(^)(id) —— 直接调 block
        void (^cb)(id) = block;
        cb(param);
        qqlog(@"[autotap] %@: %@ (%.0f,%.0f)", logTag, NSStringFromClass([view class]), page.x, page.y);
        return YES;
    } @catch (NSException *e) {
        qqlog(@"[autotap] Kuikly点击异常(%@): %@", logTag, e);
        return NO;
    }
}

// ── 递归收集可点击的原生按钮 + 可输入文本框 ──
static void collectNativeActionsInView(UIView *view, NSMutableArray *buttons, NSMutableArray *textViews) {
    if (!view) return;
    // v1.7.9: 从「只收 UIButton」放宽为「收所有 UIControl」——QQ 空间说说的「发表」
    // 在导航栏右上角，是 UIBarButtonItem 内部视图（_UIButtonBarButton 继承 UIControl
    // 而非 UIButton），旧代码收集不到 → 「原生点击: 发表」从未出现 → 任务失败
    if ([view isKindOfClass:[UIControl class]]) {
        NSString *t = @"";
        @try {
            // UIButton 直接读 currentTitle；UIBarButtonItem 内部按钮读 accessibilityLabel
            if ([view respondsToSelector:@selector(currentTitle)]) {
                t = ((UIButton *)view).currentTitle ?: @"";
            }
            if (t.length == 0) {
                t = view.accessibilityLabel ?: @"";
            }
            if (t.length == 0 && [view respondsToSelector:@selector(titleLabel)]) {
                t = ((UIButton *)view).titleLabel.text ?: @"";
            }
        } @catch (NSException *e) {
            t = @"";
        }
        if (t.length > 0 && t.length <= 12) {
            [buttons addObject:@{@"btn": view, @"title": t}];
        }
    }
    // v1.8.5（Kuikly 源码实锤）：Kuikly 页面的点击组件是「带 css_click block 的 UIView」——
    // 腾讯开源 KuiklyUI core-render-ios/Extension/Category/UIView+CSS.m：
    //   setCss_click: 时自动挂 UITapGestureRecognizer(css_tapGR, action=css_onClickTapWithSender:)
    //   css_onClickTapWithSender: 调 css_click(@{x,y,pageX,pageY})
    // 旧方案遍历 gestureRecognizers 找 tap 手势会误中 UITextNonEditableInteraction（UITapGestureRecognizer
    // 私有子类，文本交互）→ 触发它=文本菜单不点书（v1.8.4 实锤）。直接调 css_click block 才是官方点击路径。
    // 优先级：css_click > css_touchUp > 手势遍历
    if (![view isKindOfClass:[UIControl class]] && !view.hidden && view.alpha > 0.1) {
        // 1) css_click（业务点击，书卡片/立即领取都是它）
        SEL cssClickSel = NSSelectorFromString(@"css_click");
        if ([view respondsToSelector:cssClickSel]) {
            id (*clickGetter)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            id clickBlock = clickGetter(view, cssClickSel);
            if (clickBlock) {
                NSString *t = view.accessibilityLabel ?: @"";
                if (t.length == 0) t = @"(kuikly点击)";
                [buttons addObject:@{@"btn": view, @"title": t, @"gesture": @NO, @"kuiklyClick": clickBlock}];
            }
        }
        // 2) css_touchUp（KRView 触摸回调，普通触摸组件）
        SEL cssTouchSel = NSSelectorFromString(@"css_touchUp");
        if ([view respondsToSelector:cssTouchSel]) {
            id (*touchGetter)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            id touchBlock = touchGetter(view, cssTouchSel);
            if (touchBlock) {
                [buttons addObject:@{@"btn": view, @"title": @"(kuikly触摸)", @"gesture": @NO, @"kuiklyTouch": touchBlock}];
            }
        }
    }
    // v1.8.1: Kuikly 页面的可点击组件是「带 UITapGestureRecognizer 的 UIView」
    //（Kuikly 原生渲染，不是 UIControl 也没有 DOM）——小说书城点书/福利社立即领取
    // 都靠手势。收集可见且带 tap 手势的 view（避开已有标题的 UIControl 和纯容器）
    if (![view isKindOfClass:[UIControl class]] && view.gestureRecognizers.count > 0 && !view.hidden && view.alpha > 0.1) {
        BOOL hasTap = NO;
        for (UIGestureRecognizer *g in view.gestureRecognizers) {
            // v1.8.4: 过滤 UIText* 文本交互手势（UITextNonEditableInteraction 继承
            // UITapGestureRecognizer 会被误判为 tap，但触发它=文本菜单不是点击）
            NSString *gcls = NSStringFromClass([g class]);
            if ([gcls containsString:@"UIText"] || [gcls containsString:@"TextInteraction"]) {
                continue;
            }
            if ([g isKindOfClass:[UITapGestureRecognizer class]]) {
                hasTap = YES;
                break;
            }
        }
        if (hasTap) {
            // 只收有实质内容的 view（文字/图片/子视图数适中），避免误收整个页面容器
            NSString *acc = view.accessibilityLabel ?: @"";
            BOOL hasContent = acc.length > 0 || view.subviews.count >= 1;
            if (hasContent && view.frame.size.width > 40 && view.frame.size.height > 20) {
                NSString *t = acc.length > 0 ? acc : @"(手势组件)";
                [buttons addObject:@{@"btn": view, @"title": t, @"gesture": @YES}];
            }
        }
    }
    if ([view isKindOfClass:[UITextView class]]) {
        [textViews addObject:view];
    }
    for (UIView *sub in view.subviews) {
        collectNativeActionsInView(sub, buttons, textViews);
    }
}

// ── 原生页面自动操作：输入 + 点按钮 ──
static void autoTapNativeUI(void) {
    @try {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *buttons = [NSMutableArray array];
            NSMutableArray *textViews = [NSMutableArray array];
            for (UIWindow *win in [UIApplication sharedApplication].windows) {
                collectNativeActionsInView(win, buttons, textViews);
            }
            // 1) 文本框：先输入「等级任务」文字（发布说说必须填内容才能点发表）
            for (id tv in textViews) {
                @try {
                    if ([tv isFirstResponder] == NO) {
                        [tv becomeFirstResponder];
                    }
                    // 用 UITextViewDelegate 的方式设置文字（直接 setText 不触发代理）
                    if ([tv respondsToSelector:@selector(setText:)]) {
                        NSString *cur = [tv valueForKey:@"text"] ?: @"";
                        if (cur.length == 0) {
                            // v1.7.9: 内容改为「等级任务 + 今天日期」（用户要求：内容应该是 等级任务今天的日期）
                            NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
                            fmt.dateFormat = @"yyyy-MM-dd";
                            NSString *today = [fmt stringFromDate:[NSDate date]];
                            [tv setValue:[NSString stringWithFormat:@"等级任务 %@", today] forKey:@"text"];
                            // v1.7.8 关键修复：QQ 发表按钮监听 textViewDidChange: 才点亮，
                            // 直接 setText 不触发 delegate → 按钮永远 disabled 点不了（用户实测
                            // 「粘贴进去文字了但发表按键不亮」）。填字后手动触发 delegate 回调 +
                            // 发系统通知，让 QQ 内部逻辑点亮发表按钮。
                            @try {
                                id delegate = [tv valueForKey:@"delegate"];
                                if (delegate && [delegate respondsToSelector:@selector(textViewDidChange:)]) {
                                    [delegate textViewDidChange:tv];
                                    qqlog(@"[autotap] 已触发 textViewDidChange 点亮发表按钮");
                                }
                            } @catch (NSException *e) {
                                qqlog(@"[autotap] 触发 delegate 异常: %@", e);
                            }
                            @try {
                                [[NSNotificationCenter defaultCenter]
                                    postNotificationName:UITextViewTextDidChangeNotification object:tv];
                            } @catch (NSException *e) {}
                            qqlog(@"[autotap] 原生输入框已填文字");
                        }
                    }
                } @catch (NSException *e) {
                    qqlog(@"[autotap] 原生输入异常: %@", e);
                }
            }
            // 2) 按钮：按关键词匹配点击
            NSArray *kws = @[@"签到", @"打卡", @"发表", @"发送", @"发布", @"分享", @"确认", @"确定", @"完成", @"立即", @"去完成", @"领取"];
            BOOL clicked = NO;
            for (NSDictionary *item in buttons) {
                NSString *t = item[@"title"];
                for (NSString *kw in kws) {
                    if ([t containsString:kw]) {
                        UIControl *btn = item[@"btn"];
                        if (btn.hidden == NO && btn.alpha > 0.1) {
                            // v1.8.5: Kuikly 组件优先——直接调 css_click/css_touchUp block
                            //（官方点击路径，腾讯开源 KuiklyUI 实锤）
                            id kuiklyClick = item[@"kuiklyClick"];
                            id kuiklyTouch = item[@"kuiklyTouch"];
                            if (kuiklyClick) {
                                if (qqfbKuiklyInvoke(btn, kuiklyClick, @"Kuikly点击")) { clicked = YES; }
                            } else if (kuiklyTouch) {
                                if (qqfbKuiklyInvoke(btn, kuiklyTouch, @"Kuikly触摸")) { clicked = YES; }
                            } else if ([item[@"gesture"] boolValue]) {
                                // v1.8.1: Kuikly 手势组件（小说书城点书/福利社立即领取）——
                                // 不是 UIControl，直接调手势的 target/action 模拟点击
                                UIView *gv = (UIView *)btn;
                                for (UIGestureRecognizer *g in gv.gestureRecognizers) {
                                    if ([g isKindOfClass:[UITapGestureRecognizer class]]) {
                                        if (qqfbGestureInvoke(g, @"手势点击")) {
                                            clicked = YES;
                                        }
                                        if (clicked) break;
                                    }
                                }
                                if (clicked) break;
                            } else {
                                // v1.7.8: 若按钮 disabled 但标题是发表/发布/发送（需文字才点亮），
                                // 文字已填+delegate 已触发，此时强制 sendActions 也能触发逻辑
                                if (!btn.enabled) {
                                    qqlog(@"[autotap] 按钮 %@ 当前 disabled，强制触发（文字已填）", t);
                                }
                                [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
                                qqlog(@"[autotap] 原生点击: %@", t);
                                clicked = YES;
                            }
                            break;
                        }
                    }
                }
                if (clicked) break;
            }
            if (!clicked && buttons.count == 0) {
                qqlog(@"[autotap] 原生无可点按钮");
            }
            // v1.8.2: kws 都没命中时，兜底点击「屏幕中部的大手势组件」——
            // 小说书城的书卡片是 Kuikly 手势组件（无关键词标题），必须点进书才完成
            //「看任一本书」。
            // v1.8.3 修复（用户实测「拉起来小程序」）：不能无差别点第一个手势组件——
            // 日志实锤点到了右上角 52×24 的返回/收起小按钮（frame=(378 64; 52 24)）
            // 拉起小程序。书卡片在屏幕中部、尺寸较大（宽>100），按区域+尺寸筛选：
            //   · 排除 y<120（顶部导航区：返回/关闭/分享按钮都在那）
            //   · 排除 x>屏宽-80（右上角操作区）
            //   · 只点 宽>=100 且 高>=80 的大卡片（书卡片/视频封面/礼包卡片）
            if (!clicked) {
                CGSize scrSize = [UIScreen mainScreen].bounds.size;
                NSMutableArray *candidates = [NSMutableArray array];
                for (NSDictionary *item in buttons) {
                    if (![item[@"gesture"] boolValue]) continue;
                    UIControl *gv = item[@"btn"];
                    if (gv.hidden || gv.alpha <= 0.1) continue;
                    CGRect f = gv.frame;
                    CGFloat x = f.origin.x, y = f.origin.y;
                    // 坐标基于窗口，Kuikly 全屏页 window 原点即屏幕原点
                    if (y < 120) continue;              // 顶部导航区排除
                    if (x > scrSize.width - 80) continue; // 右上角操作区排除
                    if (f.size.width < 100 || f.size.height < 80) continue; // 只点大卡片
                    // v1.8.5: 书卡片是带 css_click 的 Kuikly 组件（无关键词标题）——
                    // 手势组件也收（老 Kuikly 页面可能只挂手势），但 Kuikly block 优先
                    [candidates addObject:item];
                }
                // v1.8.5: Kuikly 组件优先（css_click=官方业务点击），手势组件兜底
                [candidates sortUsingComparator:^NSComparisonResult(id a, id b) {
                    BOOL aK = [a[@"kuiklyClick"] boolValue] || [a[@"kuiklyTouch"] boolValue];
                    BOOL bK = [b[@"kuiklyClick"] boolValue] || [b[@"kuiklyTouch"] boolValue];
                    if (aK != bK) return aK ? NSOrderedAscending : NSOrderedDescending;
                    CGRect fa = [a[@"btn"] frame], fb = [b[@"btn"] frame];
                    if (fa.origin.y < fb.origin.y) return NSOrderedAscending;
                    return NSOrderedDescending;
                }];
                for (NSDictionary *item in candidates) {
                    UIControl *gv = item[@"btn"];
                    @try {
                        id kuiklyClick = item[@"kuiklyClick"];
                        id kuiklyTouch = item[@"kuiklyTouch"];
                        if (kuiklyClick) {
                            if (qqfbKuiklyInvoke(gv, kuiklyClick, @"Kuikly兜底点击")) {
                                qqlog(@"[autotap] 兜底点中区域: (%.0f,%.0f %.0fx%.0f)", gv.frame.origin.x, gv.frame.origin.y, gv.frame.size.width, gv.frame.size.height);
                                clicked = YES;
                            }
                        } else if (kuiklyTouch) {
                            if (qqfbKuiklyInvoke(gv, kuiklyTouch, @"Kuikly兜底触摸")) {
                                qqlog(@"[autotap] 兜底点中区域: (%.0f,%.0f %.0fx%.0f)", gv.frame.origin.x, gv.frame.origin.y, gv.frame.size.width, gv.frame.size.height);
                                clicked = YES;
                            }
                        } else {
                            for (UIGestureRecognizer *g in gv.gestureRecognizers) {
                                if ([g isKindOfClass:[UITapGestureRecognizer class]]) {
                                    if (qqfbGestureInvoke(g, @"手势兜底点击")) {
                                        qqlog(@"[autotap] 兜底点中区域: (%.0f,%.0f %.0fx%.0f)", gv.frame.origin.x, gv.frame.origin.y, gv.frame.size.width, gv.frame.size.height);
                                        clicked = YES;
                                    }
                                    if (clicked) break;
                                }
                            }
                        }
                    } @catch (NSException *e) {
                        qqlog(@"[autotap] 手势兜底异常: %@", e);
                    }
                    if (clicked) break;
                }
            }
        });
    } @catch (NSException *e) {
        qqlog(@"[autotap] 原生遍历异常: %@", e);
    }
}

// ── 点右上角 X 关闭按钮（v1.8.3 视频任务用）──
// 用户实测视频任务「进去了就等右上角计时器结束了点击右上角的x 关闭就行」。
// 遍历当前窗口找右上角区域的关闭组件：优先标题含 关闭/X/×/取消 的，
// 其次右上角坐标区(x>屏宽-70, y<140)的手势组件（视频页关闭 X 无文字）。
static void qqfbTapCloseButton(void) {
    @try {
        __block BOOL done = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            CGSize scrSize = [UIScreen mainScreen].bounds.size;
            NSMutableArray *buttons = [NSMutableArray array];
            NSMutableArray *textViews = [NSMutableArray array];
            for (UIWindow *win in [UIApplication sharedApplication].windows) {
                collectNativeActionsInView(win, buttons, textViews);
            }
            // 1) 标题含 关闭/X/×/取消（视频广告页关闭按钮常见）
            NSArray *closeKws = @[@"关闭", @"X", @"×", @"取消", @"✕"];
            for (NSDictionary *item in buttons) {
                NSString *t = item[@"title"];
                for (NSString *kw in closeKws) {
                    if ([t containsString:kw]) {
                        UIView *bv = item[@"btn"];
                        CGRect f = bv.frame;
                        // 右上角优先，但也接受任意位置明确叫「关闭」的
                        if (f.origin.x > scrSize.width - 120 || f.origin.y < 140) {
                            if ([item[@"gesture"] boolValue]) {
                                for (UIGestureRecognizer *g in bv.gestureRecognizers) {
                                    if ([g isKindOfClass:[UITapGestureRecognizer class]]) {
                                        if (qqfbGestureInvoke(g, @"关闭按钮(关键词)")) { done = YES; break; }
                                    }
                                }
                            } else {
                                [(UIControl *)bv sendActionsForControlEvents:UIControlEventTouchUpInside];
                                qqlog(@"[autotap] 关闭按钮(关键词): %@", t);
                                done = YES;
                            }
                            if (done) break;
                        }
                    }
                }
                if (done) break;
            }
            // 2) 右上角无文字手势组件（X 图标）
            if (!done) {
                NSMutableArray *corners = [NSMutableArray array];
                for (NSDictionary *item in buttons) {
                    if (![item[@"gesture"] boolValue]) continue;
                    UIView *bv = item[@"btn"];
                    if (bv.hidden || bv.alpha <= 0.1) continue;
                    CGRect f = bv.frame;
                    // 右上角区域：x 在屏宽-90 以内靠右，y<140 顶部
                    if (f.origin.x > scrSize.width - 90 && f.origin.y < 140 &&
                        f.size.width < 80 && f.size.height < 80) {
                        [corners addObject:item];
                    }
                }
                // 优先最靠右上角的（X 通常在屏幕最右上）
                [corners sortUsingComparator:^NSComparisonResult(id a, id b) {
                    CGRect fa = [a[@"btn"] frame], fb = [b[@"btn"] frame];
                    CGFloat da = (scrSize.width - fa.origin.x) + fa.origin.y;
                    CGFloat db = (scrSize.width - fb.origin.x) + fb.origin.y;
                    if (da < db) return NSOrderedAscending;
                    return NSOrderedDescending;
                }];
                for (NSDictionary *item in corners) {
                    UIView *bv = item[@"btn"];
                    for (UIGestureRecognizer *g in bv.gestureRecognizers) {
                        if ([g isKindOfClass:[UITapGestureRecognizer class]]) {
                            if (qqfbGestureInvoke(g, @"关闭按钮(右上角)")) {
                                qqlog(@"[autotap] 右上角关闭: (%.0f,%.0f %.0fx%.0f)", bv.frame.origin.x, bv.frame.origin.y, bv.frame.size.width, bv.frame.size.height);
                                done = YES; break;
                            }
                        }
                    }
                    if (done) break;
                }
            }
            if (!done) {
                qqlog(@"[autotap] 未找到关闭按钮，走 closeTopContainer 兜底");
            }
        });
        // 等主线程执行完（同步等待）
        for (int i = 0; i < 20 && !done; i++) {
            [NSThread sleepForTimeInterval:0.05];
        }
    } @catch (NSException *e) {
        qqlog(@"[autotap] 关闭按钮异常: %@", e);
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
    // v1.7.3: 加载即打印版本号，拉日志一眼确认设备装的哪个版本
    qqlog(@"[QQFloatBall] 版本 v%@ 已加载 (build %s)", kQQFloatBallVersion, __DATE__);
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
