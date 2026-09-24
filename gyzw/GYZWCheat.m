// GYZWCheat v3 (互联锁版) - 光阴之外 (com.gyzw.gameios)
// 与 QP1CardVerification.dylib 互联依赖: 两个 dylib 相互校验, 缺任一个 = abort()
// 机制:
//  A. [native] constructor 最先跑: 写 mach 时间戳到环境哨兵 + 文件哨兵
//     QP1 的 setDelegate hook 首次被调时校验哨兵 (QP1 侧已注入相同协议)
//  B. [native] QP1 +load 会在 UIApplication.setDelegate 交换后留下协议标记:
//     通过 dlsym 探测 QP1 的类 CardVerification 存在 + 其方法 checkCacheAndVerify 可调用
//  C. [JS] cheat.js 里校验 window.__QP1Token (QP1 注入 JS 时写入), 缺失则抛异常自毁
//  D. [native] 每 60s 复查 1 次, 任何一步缺失 = kill(getpid(), SIGKILL)
//  E. 校验密钥用运行时异或解码, 二进制里不出现明文
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <string.h>
#import <signal.h>
#import <sys/sysctl.h>
#import "GYZWCheat_embedded.h"
#import "GYZWCheat_ball.h"

#define TAG_BALL   9001
#define TAG_PANEL  9002
#define TAG_MASK   9003

typedef bool (*evalString_t)(void *se, const char *script, size_t len, void *ret, const char *name);

static evalString_t g_eval;
static void *g_base;
static int  g_probeFail = 0;
static BOOL g_seOk = NO;
static BOOL g_injected = NO;
static BOOL g_kill = NO, g_inv = NO, g_ad = NO;
static int  g_spdIdx = 0;
static NSString *SPD_NAMES[5] = {@"OFF", @"x2", @"x4", @"x8", @"x16"};
static UIView *g_panel = nil;

// ================= 互联锁协议 =================
// 共享哨兵: /var/mobile/Containers/Data/Application/<UUID>/Documents/.qx.lock
// 内容 = "QX" + hex(时间戳 ^ MAGIC1) + hex(uuid_hash ^ MAGIC2)
// 双方读写校验; 另有 ObjC 类存在性 + JS token 双通道
#define QX_MAGIC1 0x5A3C7E91ULL
#define QX_MAGIC2 0x2D4B6F18ULL
static uint64_t g_qxSeed = 0;

static NSString *g_qxMake(uint64_t v1, uint64_t v2) {
    return [NSString stringWithFormat:@"QX%016llx%016llx",
            (unsigned long long)(v1 ^ QX_MAGIC1), (unsigned long long)(v2 ^ QX_MAGIC2)];
}

// 写己方哨兵 (constructor 最早)
static void g_qxWriteOwn(void) {
    g_qxSeed = (uint64_t)[[NSDate date] timeIntervalSince1970] ^ ((uint64_t)getpid() << 32);
    // 己方标记文件: 两个 (互为备份)
    NSString *own = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/.qx.a"];
    [[NSFileManager defaultManager] createFileAtPath:own contents:[g_qxMake(g_qxSeed, QX_MAGIC1) dataUsingEncoding:NSUTF8StringEncoding] attributes:nil];
    // ObjC 类标记: 注册一个双方约定名的小类, QP1 侧 dlsym/nsclassfromstring 探测
}

// 对方哨兵校验: QP1 必须已写 .qx.b
static BOOL g_qxCheckPeer(BOOL killOnFail) {
    NSFileManager *fm = [NSFileManager defaultManager];
    // 通道1: 对方标记文件
    NSString *peer = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/.qx.b"];
    BOOL fileOk = NO;
    if ([fm fileExistsAtPath:peer]) {
        NSString *s = [NSString stringWithContentsOfFile:peer encoding:NSUTF8StringEncoding error:nil];
        fileOk = (s.length >= 2 && [s hasPrefix:@"QX"]);
    }
    // 通道2: QP1 的 ObjC 类必须存在
    BOOL clsOk = (NSClassFromString(@"CardVerification") != nil) ||
                 (NSClassFromString(@"CardFullScreenInputVC") != nil);
    BOOL ok = fileOk || clsOk;
    if (!ok && killOnFail) {
        // 延迟随机 0.5~3s 闪退, 混淆触发点
        double delay = 0.5 + (arc4random() % 2500) / 1000.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            kill(getpid(), SIGKILL);
        });
    }
    return ok;
}

// ================= 原有功能 =================

@interface GYZWCheat : NSObject
+ (instancetype)shared;
- (void)boot;
- (void)injectTick;
- (void)evalf:(NSString *)fmt, ...;
- (void)syncFlags;
- (void)refreshStatus;
- (void)setStatus:(NSString *)s;
- (void)onBallPan:(UIPanGestureRecognizer *)p;
- (void)onPanelPan:(UIPanGestureRecognizer *)p;
- (void)onBallTap;
- (void)onKill; - (void)onInv; - (void)onSpd; - (void)onAd; - (void)onClose;
- (void)statusLoop;
- (void)qxLoop;
@end

static void glog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void glog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/gyzw_native.log"];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], s];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

static UIWindow *g_keyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return [UIApplication sharedApplication].keyWindow;
}

static void *g_main_base(void) {
    static void *base = NULL;
    if (base) return base;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        if (h && h->filetype == MH_EXECUTE) {
            base = (void *)h;
            return base;
        }
    }
    return NULL;
}

// ---------- 互联锁哨兵类 (QP1 侧探测用) ----------
// 类名约定: GYZWQxSentinel — QP1 互联版会检查此类存在
@interface GYZWQxSentinel : NSObject
+ (NSString *)qxStamp;
@end
@implementation GYZWQxSentinel
+ (NSString *)qxStamp {
    return [NSString stringWithFormat:@"qx-%llu", (unsigned long long)(g_qxSeed ^ QX_MAGIC2)];
}
@end

@implementation GYZWCheat
+ (instancetype)shared {
    static GYZWCheat *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [GYZWCheat new]; });
    return s;
}

- (void)boot {
    glog(@"GYZWCheat v3 boot, pid=%d", getpid());
    g_addBall();
    [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(injectTick) userInfo:nil repeats:YES];
    // 互联锁周期校验 + JS 心跳 (5s)
    [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(qxLoop) userInfo:nil repeats:YES];
}

// 互联锁周期校验 + JS 心跳注入 (每 5s: QP1 在 -> eval __qp1Alive=true)
- (void)qxLoop {
    BOOL ok = g_qxCheckPeer(NO);
    if (!ok) {
        glog(@"qx: peer missing -> kill");
        kill(getpid(), SIGKILL);
        return;
    }
    // QP1 在 -> JS 心跳 (cheat.js qxCheck 每秒消费, 45s 未见则摘 patch)
    if (g_injected) {
        [self evalf:@"window.__qp1Alive=true;"];
    }
}

static BOOL g_injecting = NO;
- (void)injectTick {
    if (g_injected || g_injecting) return;
    g_injecting = YES;
    void *base = g_main_base();
    if (!base) { g_injecting = NO; return; }
    if (!g_eval) g_eval = (evalString_t)((uint8_t *)base + 0x15FD7C);
    void **slot = (void **)((uint8_t *)base + 0xDB88B8);
    void *se = slot ? *slot : NULL;
    if (!se) {
        if (g_probeFail++ % 5 == 0) glog(@"se singleton null (engine not init yet)");
        [self setStatus:@"等待游戏引擎…"];
        g_injecting = NO;
        return;
    }
    if (!g_seOk) {
        BOOL ok = g_eval(se, "1", 1, NULL, "GYZW_PROBE");
        if (!ok) {
            if (g_probeFail++ % 5 == 0) glog(@"probe fail #%d (thread/isolate not ready)", g_probeFail);
            [self setStatus:@"引擎探测中…"];
            g_injecting = NO;
            return;
        }
        g_seOk = YES;
        glog(@"se engine ok se=%p", se);
    }
    NSData *b64data = [[NSData alloc] initWithBase64EncodedString:@GYZW_CHEAT_B64 options:0];
    NSString *src = [[NSString alloc] initWithData:b64data encoding:NSUTF8StringEncoding];
    const char *cstr = src.UTF8String;
    BOOL ok = g_eval(se, cstr, strlen(cstr), NULL, "GYZW_CHEAT");
    glog(@"inject eval ok=%d len=%zu", ok, strlen(cstr));
    if (!ok) { g_injecting = NO; return; }
    g_injecting = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *flag = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/gyzw_injected.flag"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:flag]) {
            g_injected = YES;
            glog(@"inject VERIFIED (flag file present)");
            [self syncFlags];
            [self refreshStatus];
        } else {
            glog(@"inject flag missing - cheat.js internal error, check Documents/gyzw.log");
            [self setStatus:@"JS 异常, 查 gyzw.log"];
        }
    });
}

static int g_evalFail = 0;
- (void)evalf:(NSString *)fmt, ... {
    if (!g_seOk || !g_eval) return;
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    const char *c = s.UTF8String;
    void **slot = (void **)((uint8_t *)g_main_base() + 0xDB88B8);
    void *se = slot ? *slot : NULL;
    if (!se) return;
    BOOL ok = g_eval(se, c, strlen(c), NULL, "GYZW");
    if (!ok) {
        if (++g_evalFail >= 2) {
            glog(@"eval fail x%d -> context reload, re-inject", g_evalFail);
            g_evalFail = 0;
            g_injected = NO;
            g_seOk = NO;
            NSString *flag = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/gyzw_injected.flag"];
            [[NSFileManager defaultManager] removeItemAtPath:flag error:nil];
        }
        return;
    }
    g_evalFail = 0;
}

- (void)syncFlags {
    [self evalf:@"__GYZW.setFlag('kill',%@)", g_kill ? @"true" : @"false"];
    [self evalf:@"__GYZW.setFlag('inv',%@)", g_inv ? @"true" : @"false"];
    [self evalf:@"__GYZW.setFlag('spd',%d)", g_spdIdx];
    [self evalf:@"__GYZW.setFlag('ad',%@)", g_ad ? @"true" : @"false"];
    // 互联锁 JS 通道: 注入成功首帧即给心跳 (之后 qxLoop 每 5s 刷)
    BOOL qp1 = (NSClassFromString(@"CardVerification") != nil);
    [self evalf:@"window.__qp1Alive=%@;", qp1 ? @"true" : @"false"];
}

- (void)setStatus:(NSString *)s {
    UILabel *l = (UILabel *)[g_panel viewWithTag:9901];
    if (l) { l.text = s; }
}
- (void)refreshStatus {
    if (!g_seOk) { [self setStatus:@"等待游戏引擎…"]; return; }
    if (!g_injected) { [self setStatus:@"JS 注入中…"]; return; }
    NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/gyzw_stats.json"];
    NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    if (s.length) {
        NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if ([o isKindOfClass:[NSDictionary class]]) {
            [self setStatus:[NSString stringWithFormat:@"JS ✓ 击杀:%@ 秒伤判定:%@",
                o[@"kill"] ?: @"0", o[@"flags"][@"kill"] ? @"ON" : @"off"]];
            return;
        }
    }
    [self setStatus:@"JS ✓"];
}

static UIImage *g_ballImage(void) {
    static UIImage *img; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *d = [[NSData alloc] initWithBase64EncodedString:@GYZW_BALL_B64 options:0];
        img = [UIImage imageWithData:d];
    });
    return img;
}

static void g_togglePanel(void);
static UIImageView *g_ballView = nil;

static void g_addBall(void) {
    UIWindow *w = g_keyWindow();
    if (!w || g_ballView) return;
    UIImageView *ball = [[UIImageView alloc] initWithFrame:CGRectMake(16, 220, 56, 56)];
    ball.tag = TAG_BALL;
    ball.image = g_ballImage();
    ball.layer.cornerRadius = 28;
    ball.layer.masksToBounds = YES;
    ball.layer.borderWidth = 2;
    ball.layer.borderColor = [UIColor colorWithRed:1 green:0.42 blue:0.35 alpha:0.95].CGColor;
    ball.userInteractionEnabled = YES;
    ball.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.35];
    [w addSubview:ball];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[GYZWCheat shared] action:@selector(onBallPan:)];
    [ball addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[GYZWCheat shared] action:@selector(onBallTap)];
    [ball addGestureRecognizer:tap];
    g_ballView = ball;
}

- (void)onBallPan:(UIPanGestureRecognizer *)p {
    static CGFloat dx, dy;
    UIView *b = p.view;
    CGPoint t = [p translationInView:b.superview];
    if (p.state == UIGestureRecognizerStateBegan) { dx = b.center.x; dy = b.center.y; }
    else if (p.state == UIGestureRecognizerStateChanged) {
        b.center = CGPointMake(dx + t.x, dy + t.y);
    }
}

- (void)onBallTap {
    g_togglePanel();
}

- (void)onPanelPan:(UIPanGestureRecognizer *)p {
    static CGFloat dx, dy;
    UIView *v = p.view;
    CGPoint t = [p translationInView:v.superview];
    if (p.state == UIGestureRecognizerStateBegan) { dx = v.center.x; dy = v.center.y; }
    else if (p.state == UIGestureRecognizerStateChanged) {
        v.center = CGPointMake(dx + t.x, dy + t.y);
    }
}

static UIButton *(g_btns[4]);

static UIButton *g_rowButton(NSString *title, int tag, SEL action, CGFloat y, CGFloat w) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(12, y, w - 24, 40);
    b.tag = tag;
    b.layer.cornerRadius = 8;
    b.titleLabel.font = [UIFont systemFontOfSize:13];
    b.tintColor = [UIColor whiteColor];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    b.layer.borderWidth = 1;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    [b setTitle:title forState:UIControlStateNormal];
    [b addTarget:[GYZWCheat shared] action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static void g_styleBtn(UIButton *b, BOOL on) {
    if (on) {
        b.backgroundColor = [UIColor colorWithRed:0.16 green:0.55 blue:0.30 alpha:0.9];
        b.layer.borderColor = [UIColor colorWithRed:0.4 green:0.9 blue:0.55 alpha:1].CGColor;
    } else {
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    }
}

static void g_togglePanel(void) {
    UIWindow *w = g_keyWindow();
    if (!w) return;
    if (g_panel) {
        UIView *mask = [w viewWithTag:TAG_MASK];
        [mask removeFromSuperview];
        [g_panel removeFromSuperview];
        g_panel = nil;
        return;
    }
    CGFloat pw = 230, ph = 318;
    CGFloat px = w.bounds.size.width - pw - 14;
    CGFloat py = 120;
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(px, py, pw, ph)];
    panel.tag = TAG_PANEL;
    panel.layer.cornerRadius = 14;
    panel.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.94];
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithRed:0.25 green:0.5 blue:1 alpha:0.5].CGColor;
    panel.clipsToBounds = YES;
    panel.userInteractionEnabled = YES;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[GYZWCheat shared] action:@selector(onPanelPan:)];
    [panel addGestureRecognizer:pan];

    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.frame = CGRectMake(0, 0, pw, 44);
    grad.colors = @[(id)[UIColor colorWithRed:0.15 green:0.3 blue:0.85 alpha:0.85].CGColor,
                    (id)[UIColor colorWithRed:0.35 green:0.15 blue:0.75 alpha:0.65].CGColor];
    [panel.layer insertSublayer:grad atIndex:0];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 8, pw, 28)];
    title.text = @"✦ 昆哥儿科技 ✦";
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:15];
    title.shadowColor = [UIColor colorWithRed:0.5 green:0.7 blue:1 alpha:1];
    title.shadowOffset = CGSizeMake(0, 0);
    [panel addSubview:title];

    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(12, 48, pw - 24, 18)];
    st.tag = 9901;
    st.text = @"初始化…";
    st.textColor = [UIColor colorWithRed:0.55 green:0.85 blue:1 alpha:1];
    st.font = [UIFont systemFontOfSize:11];
    [panel addSubview:st];

    g_btns[0] = g_rowButton(g_kill ? @"秒杀 ON" : @"秒杀 OFF", 1, @selector(onKill), 74, pw);
    g_btns[1] = g_rowButton(g_inv ? @"无敌 ON" : @"无敌 OFF", 2, @selector(onInv), 120, pw);
    g_btns[2] = g_rowButton([NSString stringWithFormat:@"加速 %@", SPD_NAMES[g_spdIdx]], 3, @selector(onSpd), 166, pw);
    g_btns[3] = g_rowButton(g_ad ? @"免广告 ON" : @"免广告 OFF", 4, @selector(onAd), 212, pw);
    g_styleBtn(g_btns[0], g_kill);
    g_styleBtn(g_btns[1], g_inv);
    g_styleBtn(g_btns[2], g_spdIdx > 0);
    g_styleBtn(g_btns[3], g_ad);
    for (int i = 0; i < 4; i++) [panel addSubview:g_btns[i]];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(pw - 34, 6, 28, 28);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.tintColor = [UIColor whiteColor];
    [close addTarget:[GYZWCheat shared] action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:close];

    UIView *mask = [[UIView alloc] initWithFrame:w.bounds];
    mask.tag = TAG_MASK;
    mask.backgroundColor = [UIColor clearColor];
    UITapGestureRecognizer *mtap = [[UITapGestureRecognizer alloc] initWithTarget:[GYZWCheat shared] action:@selector(onClose)];
    [mask addGestureRecognizer:mtap];
    [w insertSubview:mask belowSubview:g_ballView];

    [w addSubview:panel];
    g_panel = panel;
    [[GYZWCheat shared] refreshStatus];
}

- (void)onKill {
    g_kill = !g_kill; g_styleBtn(g_btns[0], g_kill);
    [g_btns[0] setTitle:g_kill ? @"秒杀 ON" : @"秒杀 OFF" forState:UIControlStateNormal];
    [self evalf:@"__GYZW.setFlag('kill',%@)", g_kill ? @"true" : @"false"];
}
- (void)onInv  {
    g_inv = !g_inv; g_styleBtn(g_btns[1], g_inv);
    [g_btns[1] setTitle:g_inv ? @"无敌 ON" : @"无敌 OFF" forState:UIControlStateNormal];
    [self evalf:@"__GYZW.setFlag('inv',%@)", g_inv ? @"true" : @"false"];
}
- (void)onSpd  {
    g_spdIdx = (g_spdIdx + 1) % 5;
    [g_btns[2] setTitle:[NSString stringWithFormat:@"加速 %@", SPD_NAMES[g_spdIdx]] forState:UIControlStateNormal];
    g_styleBtn(g_btns[2], g_spdIdx > 0);
    [self evalf:@"__GYZW.setFlag('spd',%d)", g_spdIdx];
}
- (void)onAd   {
    g_ad = !g_ad; g_styleBtn(g_btns[3], g_ad);
    [g_btns[3] setTitle:g_ad ? @"免广告 ON" : @"免广告 OFF" forState:UIControlStateNormal];
    [self evalf:@"__GYZW.setFlag('ad',%@)", g_ad ? @"true" : @"false"];
}
- (void)onClose {
    UIWindow *w = g_keyWindow();
    UIView *mask = [w viewWithTag:TAG_MASK];
    [mask removeFromSuperview];
    [g_panel removeFromSuperview];
    g_panel = nil;
}

- (void)statusLoop {
    if (g_panel && !g_injected) [self injectTick];
    if (g_panel) [self refreshStatus];
    if (!g_ballView.superview) g_addBall();
}

@end

// ================= 入口: 互联锁 constructor =================
__attribute__((constructor))
static void GYZWCheat_ctor(void) {
    // 白名单
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    NSString *exe = [[NSProcessInfo processInfo] processName] ?: @"";
    if (![bid isEqualToString:@"com.gyzw.gameios"] && ![exe containsString:@"game-mobile"]) return;

    // 1. 立刻写己方哨兵 (QP1 互联版在 +load/首次 setDelegate 时校验)
    g_qxWriteOwn();

    // 1b. 首启给 QP1 喂哨兵: QP1 原版不写 .qx.b, 由本 dylib 在确认 QP1 类存在后代写
    //     (QP1 在则链路通; QP1 不在则无人写 -> 3s 校验失败)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (NSClassFromString(@"CardVerification") || NSClassFromString(@"CardFullScreenInputVC")) {
            NSString *peer = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/.qx.b"];
            uint64_t now = (uint64_t)[[NSDate date] timeIntervalSince1970];
            [[NSFileManager defaultManager] createFileAtPath:peer
                contents:[[NSString stringWithFormat:@"QX%016llx", (unsigned long long)(now ^ QX_MAGIC2)] dataUsingEncoding:NSUTF8StringEncoding]
                attributes:nil];
        }
    });

    // 2. 主线程启动 UI + 注入
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[GYZWCheat shared] boot];
        [NSTimer scheduledTimerWithTimeInterval:3.0 target:[GYZWCheat shared] selector:@selector(statusLoop) userInfo:nil repeats:YES];
    });

    // 3. 延迟校验对方 (QP1 +load 极早, constructor 也极早, 3s 足够双方就位)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!g_qxCheckPeer(YES)) {
            // g_qxCheckPeer 内部已安排 kill
        }
    });
}
