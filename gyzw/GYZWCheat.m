// GYZWCheat v1 - 光阴之外 (com.gyzw.gameios) iOS 内购助手 dylib
// 架构: se::ScriptEngine::evalString 直调注入 JS (复用 XXCFloat 验证过的 V8 方案)
// 二进制定位 (game-mobile arm64, __TEXT vm=0x100000000):
//   se::ScriptEngine::getInstance 返回单例存储于 *(base+0xDB88B8)
//   se::ScriptEngine::evalString @ RVA 0x15FD7C
//     签名: bool f(void* se, const char* script, size_t len, se::Value* ret, const char* name)
//     len<0/0 -> strlen; ret=NULL 合法(游戏自身 0x1001331e4 处传 0); name=NULL -> 默认
//   ⚠️ evalString 开头有引擎线程校验([this+0x1A0]), 必须在主线程调用
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <string.h>
#import "GYZWCheat_embedded.h"
#import "GYZWCheat_ball.h"

#define TAG_BALL   9001
#define TAG_PANEL  9002
#define TAG_MASK   9003

typedef bool (*evalString_t)(void *se, const char *script, size_t len, void *ret, const char *name);

static evalString_t g_eval;
static void *g_base;
static int  g_probeFail = 0;
static BOOL g_seOk = NO;      // se 指针拿到 + probe 通过
static BOOL g_injected = NO;  // cheat.js 已注入且 flag 文件验证通过
// 开关状态 (默认全关, 每次启动不恢复)
static BOOL g_kill = NO, g_inv = NO, g_ad = NO;
static int  g_spdIdx = 0; // 0=OFF 1=x2 2=x4 3=x8 4=x16
static const int SPD_VALS[5] = {0, 2, 4, 8, 16};
static NSString *SPD_NAMES[5] = {@"OFF", @"x2", @"x4", @"x8", @"x16"};
static UIView *g_panel = nil;

@interface GYZWCheat : NSObject
+ (instancetype)shared;
- (void)boot;
- (void)injectTick;
- (void)evalf:(NSString *)fmt, ...;
- (void)syncFlags;
- (void)refreshStatus;
- (void)setStatus:(NSString *)s;
- (void)onBallPan:(UIPanGestureRecognizer *)p;
- (void)onBallTap;
- (void)onKill; - (void)onInv; - (void)onSpd; - (void)onAd; - (void)onClose;
- (void)statusLoop;
@end

// ---------- 日志 ----------
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

// ---------- keyWindow ----------
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

// ---------- 主二进制基址 ----------
static void *g_main_base(void) {
    static void *base = NULL;
    if (base) return base;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        if (h && h->filetype == MH_EXECUTE) {
            base = (void *)h;
            glog(@"main binary base=%p slide=%lld", base, (long long)_dyld_get_image_vmaddr_slide(i));
            return base;
        }
    }
    return NULL;
}

// ---------- bid 白名单 ----------
static BOOL g_whitelist_ok(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    NSString *exe = [[NSProcessInfo processInfo] processName] ?: @"";
    if ([bid isEqualToString:@"com.gyzw.gameios"]) return YES;
    if ([exe containsString:@"game-mobile"]) return YES;
    glog(@"whitelist miss bid=%@ exe=%@", bid, exe);
    return NO;
}

@implementation GYZWCheat
+ (instancetype)shared {
    static GYZWCheat *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [GYZWCheat new]; });
    return s;
}

- (void)boot {
    glog(@"GYZWCheat v1 boot, pid=%d", getpid());
    g_addBall();
    [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(injectTick) userInfo:nil repeats:YES];
}

// ---------- 引擎注入 ----------
- (void)injectTick {
    if (g_injected) return;
    void *base = g_main_base();
    if (!base) return;
    if (!g_eval) g_eval = (evalString_t)((uint8_t *)base + 0x15FD7C);
    void **slot = (void **)((uint8_t *)base + 0xDB88B8);
    void *se = slot ? *slot : NULL;
    if (!se) {
        if (g_probeFail++ % 5 == 0) glog(@"se singleton null (engine not init yet)");
        [self setStatus:@"等待游戏引擎…"];
        return;
    }
    if (!g_seOk) {
        BOOL ok = g_eval(se, "1", 1, NULL, "GYZW_PROBE");
        if (!ok) {
            if (g_probeFail++ % 5 == 0) glog(@"probe fail #%d (thread/isolate not ready)", g_probeFail);
            [self setStatus:@"引擎探测中…"];
            return;
        }
        g_seOk = YES;
        glog(@"se engine ok se=%p", se);
    }
    // 注入 cheat.js (⚠️ 长度必须用 UTF8 strlen, 不能用 NSString.length)
    NSData *b64data = [[NSData alloc] initWithBase64EncodedString:@GYZW_CHEAT_B64 options:0];
    NSString *src = [[NSString alloc] initWithData:b64data encoding:NSUTF8StringEncoding];
    const char *cstr = src.UTF8String;
    BOOL ok = g_eval(se, cstr, strlen(cstr), NULL, "GYZW_CHEAT");
    glog(@"inject eval ok=%d len=%zu", ok, strlen(cstr));
    if (!ok) return;
    // 验证: cheat.js 写 gyzw_injected.flag
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

// ---------- eval 辅助 ----------
- (void)evalf:(NSString *)fmt, ... {
    if (!g_seOk || !g_eval) return;
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    const char *c = s.UTF8String;
    BOOL ok = g_eval(*((void **)((uint8_t *)g_main_base() + 0xDB88B8)), c, strlen(c), NULL, "GYZW");
    glog(@"eval '%@' ok=%d", s, ok);
}

- (void)syncFlags {
    [self evalf:@"__GYZW.setFlag('kill',%@)", g_kill ? @"true" : @"false"];
    [self evalf:@"__GYZW.setFlag('inv',%@)", g_inv ? @"true" : @"false"];
    [self evalf:@"__GYZW.setFlag('spd',%d)", g_spdIdx];
    [self evalf:@"__GYZW.setFlag('ad',%@)", g_ad ? @"true" : @"false"];
}

// ---------- eval 辅助 ----------
- (void)setStatus:(NSString *)s {
    UILabel *l = (UILabel *)[g_panel viewWithTag:9901];
    if (l) { l.text = s; }
}
- (void)refreshStatus {
    if (!g_seOk) { [self setStatus:@"等待游戏引擎…"]; return; }
    if (!g_injected) { [self setStatus:@"JS 注入中…"]; return; }
    // 读 JS 统计
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

// ---------- UI: 悬浮球 ----------
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
    ball.layer.borderColor = [UIColor colorWithRed:1 green:0.42 blue:0.35 alpha:0.95].CGColor; // 红围巾同色边
    ball.userInteractionEnabled = YES;
    ball.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.35];
    [w addSubview:ball];

    // 拖动 + 点按
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

// ---------- UI: 面板 ----------
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
        // 已开 -> 收起(连同遮罩)
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

    // 顶部渐变标题
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

    g_btns[0] = g_rowButton(@"秒杀 OFF", 1, @selector(onKill), 74, pw);
    g_btns[1] = g_rowButton(@"无敌 OFF", 2, @selector(onInv), 120, pw);
    g_btns[2] = g_rowButton(@"加速 OFF", 3, @selector(onSpd), 166, pw);
    g_btns[3] = g_rowButton(@"免广告 OFF", 4, @selector(onAd), 212, pw);
    for (int i = 0; i < 4; i++) [panel addSubview:g_btns[i]];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(pw - 34, 6, 28, 28);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.tintColor = [UIColor whiteColor];
    [close addTarget:[GYZWCheat shared] action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:close];

    // 全屏透明遮罩: 点面板外收起 (在面板之下、悬浮球之下)
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

// ---------- 按钮事件 ----------
- (void)onKill { g_kill = !g_kill; g_styleBtn(g_btns[0], g_kill);
    [g_btns[0] setTitle:g_kill ? @"秒杀 ON" : @"秒杀 OFF" forState:UIControlStateNormal];
    [self evalf:@"__GYZW.setFlag('kill',%@)", g_kill ? @"true" : @"false"]; }
- (void)onInv  { g_inv = !g_inv; g_styleBtn(g_btns[1], g_inv);
    [g_btns[1] setTitle:g_inv ? @"无敌 ON" : @"无敌 OFF" forState:UIControlStateNormal];
    [self evalf:@"__GYZW.setFlag('inv',%@)", g_inv ? @"true" : @"false"]; }
- (void)onSpd  {
    g_spdIdx = (g_spdIdx + 1) % 5;
    [g_btns[2] setTitle:[NSString stringWithFormat:@"加速 %@", SPD_NAMES[g_spdIdx]] forState:UIControlStateNormal];
    g_styleBtn(g_btns[2], g_spdIdx > 0);
    [self evalf:@"__GYZW.setFlag('spd',%d)", g_spdIdx];
}
- (void)onAd   { g_ad = !g_ad; g_styleBtn(g_btns[3], g_ad);
    [g_btns[3] setTitle:g_ad ? @"免广告 ON" : @"免广告 OFF" forState:UIControlStateNormal];
    [self evalf:@"__GYZW.setFlag('ad',%@)", g_ad ? @"true" : @"false"]; }
- (void)onClose {
    UIWindow *w = g_keyWindow();
    UIView *mask = [w viewWithTag:TAG_MASK];
    [mask removeFromSuperview];
    [g_panel removeFromSuperview];
    g_panel = nil;
}

// 每 3s 刷状态
- (void)statusLoop {
    if (g_panel && !g_injected) [self injectTick];
    if (g_panel) [self refreshStatus];
    if (!g_ballView.superview) g_addBall(); // 场景切换后悬浮球丢失则重建
}

@end

// ---------- 入口 ----------
__attribute__((constructor))
static void GYZWCheat_ctor(void) {
    if (![GYZWCheat respondsToSelector:@selector(shared)]) return;
    // 白名单检查
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    NSString *exe = [[NSProcessInfo processInfo] processName] ?: @"";
    if (![bid isEqualToString:@"com.gyzw.gameios"] && ![exe containsString:@"game-mobile"]) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[GYZWCheat shared] boot];
        [NSTimer scheduledTimerWithTimeInterval:3.0 target:[GYZWCheat shared] selector:@selector(statusLoop) userInfo:nil repeats:YES];
    });
}
