// DKKeyGate.m — 弹壳战机 卡密门禁 (配合 弹壳战机_改.dylib 使用)
// 功能: 启动即全屏遮罩 + 卡密输入框
//   - 输错 → 提示"卡密无效", 遮罩不消失 (无法进入游戏)
//   - 输对 → NSUserDefaults 记录 dkzj_key_activated=YES, 下次启动自动放行
// 卡密表: 10 个内置 (与用户发放一致)
// 注入方式: 全能签/TrollFools 注入到 com.survivor.acecn (弹壳战机)

#import <UIKit/UIKit.h>

// ─────────────── 内置卡密表 ───────────────
static NSString * const kValidKeys[] = {
    @"NnKUJxbpptMQB",
    @"Cbf46DPzvqZvv",
    @"RHqPYB23uACGA",
    @"3pi02sniSlA00",
    @"dILhErfYZjEPX",
    @"1r4dB627SX9EJ",
    @"MGhJrbcF478bp",
    @"5PPNI3PDVKftJ",
    @"q1QRJlsZNd9q3",
    @"pAkg4Fcq8vjwo",
};
static const int kValidKeyCount = sizeof(kValidKeys) / sizeof(kValidKeys[0]);

static NSString * const kActivatedKey = @"dkzj_key_activated";   // NSUserDefaults 标记
static NSString * const kUsedKeyLog   = @"dkzj_key_used";        // 记录使用的卡密

static UIWindow *g_gateWindow = nil;

static BOOL isValidKey(NSString *input) {
    if (input.length == 0) return NO;
    NSString *trimmed = [input stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return NO;
    for (int i = 0; i < kValidKeyCount; i++) {
        if ([trimmed isEqualToString:kValidKeys[i]]) return YES;
    }
    return NO;
}

// ─────────────── ObjC 类 (前置声明) ───────────────
@class DKGateActionHelper, DKGateTFDelegate;

@interface DKGateActionHelper : NSObject
@property (copy) void (^block)(void);
- (void)tapped;
@end

@interface DKGateTFDelegate : NSObject <UITextFieldDelegate>
- (BOOL)textFieldShouldReturn:(UITextField *)f;
@end

static DKGateActionHelper *g_helper = nil;
static DKGateTFDelegate   *g_tfDel  = nil;

// ─────────────── 卡密弹窗 UI ───────────────
static void showGateUI(void);

static void hideGateUI(void) {
    if (g_gateWindow) {
        [UIView animateWithDuration:0.3 animations:^{
            g_gateWindow.alpha = 0;
        } completion:^(BOOL done) {
            g_gateWindow.hidden = YES;
            [g_gateWindow resignKeyWindow];
            g_gateWindow = nil;
        }];
    }
}

static void activateSuccess(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:YES forKey:kActivatedKey];
    [ud synchronize];
    hideGateUI();

    // 成功 toast
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *toast = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 260, 48)];
        toast.windowLevel = UIWindowLevelAlert + 200;
        toast.rootViewController = [UIViewController new];
        UIView *bg = [[UIView alloc] initWithFrame:toast.bounds];
        bg.backgroundColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.35 alpha:0.95];
        bg.layer.cornerRadius = 24;
        bg.layer.shadowColor = UIColor.blackColor.CGColor;
        bg.layer.shadowOpacity = 0.3;
        bg.layer.shadowOffset = CGSizeMake(0, 2);
        bg.layer.shadowRadius = 8;
        [toast.rootViewController.view addSubview:bg];
        UILabel *lb = [[UILabel alloc] initWithFrame:bg.bounds];
        lb.text = @"✅ 激活成功";
        lb.textColor = UIColor.whiteColor;
        lb.textAlignment = NSTextAlignmentCenter;
        lb.font = [UIFont boldSystemFontOfSize:16];
        lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [bg addSubview:lb];
        toast.center = CGPointMake(toast.center.x, toast.center.y + 60);
        toast.alpha = 0;
        // 挂到 keyWindow 的 scene
        UIWindowScene *sc = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (s.activationState == UISceneActivationStateForegroundActive &&
                [s isKindOfClass:[UIWindowScene class]]) { sc = (UIWindowScene *)s; break; }
        }
        if (sc) {
            toast.windowScene = sc;
            [sc.windows.firstObject makeKeyAndVisible];
        }
        toast.hidden = NO;
        [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 1; toast.center = CGPointMake(toast.center.x, toast.center.y - 60); }
                         completion:^(BOOL d) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 0; }
                                 completion:^(BOOL dd) { toast.hidden = YES; }];
            });
        }];
    });
}

static void showGateUI(void) {
    if (g_gateWindow) return;

    // 挂 scene: 优先 active, 退而求其次 inactive (冷启动过渡态也能弹)
    UIWindowScene *sc = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) { sc = (UIWindowScene *)s; break; }
    }
    if (!sc) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundInactive) { sc = (UIWindowScene *)s; break; }
        }
    }
    if (!sc) return;

    g_gateWindow = [[UIWindow alloc] initWithWindowScene:sc];
    g_gateWindow.frame = sc.coordinateSpace.bounds;
    g_gateWindow.windowLevel = UIWindowLevelAlert + 10000;   // 压住游戏与悬浮球全部层级
    g_gateWindow.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];
    g_gateWindow.rootViewController = [UIViewController new];
    g_gateWindow.hidden = NO;
    [g_gateWindow makeKeyAndVisible];

    UIView *rv = g_gateWindow.rootViewController.view;

    // ── 装饰背景渐变 ──
    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.frame = rv.bounds;
    grad.colors = @[(id)[UIColor colorWithRed:0.08 green:0.09 blue:0.14 alpha:1].CGColor,
                    (id)[UIColor colorWithRed:0.12 green:0.06 blue:0.16 alpha:1].CGColor];
    grad.locations = @[@0, @1];
    [rv.layer addSublayer:grad];

    // ── 中央卡片 ──
    CGFloat cardW = 300, cardH = 240;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cardW, cardH)];
    card.center = CGPointMake(rv.center.x, rv.center.y - 20);
    card.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1];
    card.layer.cornerRadius = 20;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [UIColor colorWithRed:0.35 green:0.65 blue:1 alpha:0.4].CGColor;
    card.layer.shadowColor = UIColor.blackColor.CGColor;
    card.layer.shadowOpacity = 0.5;
    card.layer.shadowOffset = CGSizeMake(0, 4);
    card.layer.shadowRadius = 16;
    card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                          | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [rv addSubview:card];

    // 顶部小图占位 (可选, 用色块+标题)
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 24, cardW - 40, 28)];
    title.text = @"✦ 昆哥儿科技 ✦";
    title.textColor = [UIColor colorWithRed:0.45 green:0.75 blue:1 alpha:1];
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textAlignment = NSTextAlignmentCenter;
    title.shadowColor = [UIColor colorWithRed:0.2 green:0.5 blue:1 alpha:0.6];
    title.shadowOffset = CGSizeMake(0, 0);
    [card addSubview:title];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(20, 56, cardW - 40, 18)];
    sub.text = @"请输入卡密激活";
    sub.textColor = [UIColor colorWithWhite:0.7 alpha:1];
    sub.font = [UIFont systemFontOfSize:13];
    sub.textAlignment = NSTextAlignmentCenter;
    [card addSubview:sub];

    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(24, 92, cardW - 48, 42)];
    tf.placeholder = @"输入卡密";
    tf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    tf.textColor = UIColor.whiteColor;
    tf.font = [UIFont systemFontOfSize:15];
    tf.textAlignment = NSTextAlignmentCenter;
    tf.layer.cornerRadius = 10;
    tf.layer.borderWidth = 1;
    tf.layer.borderColor = [UIColor colorWithWhite:0.35 alpha:1].CGColor;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.keyboardType = UIKeyboardTypeASCIICapable;
    tf.returnKeyType = UIReturnKeyDone;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    [card addSubview:tf];
    // 占位符颜色
    [tf setValue:[UIColor colorWithWhite:0.5 alpha:1] forKeyPath:@"placeholderLabel.textColor"];

    UILabel *err = [[UILabel alloc] initWithFrame:CGRectMake(20, 140, cardW - 40, 18)];
    err.text = @"";
    err.textColor = [UIColor colorWithRed:1 green:0.35 blue:0.35 alpha:1];
    err.font = [UIFont systemFontOfSize:12];
    err.textAlignment = NSTextAlignmentCenter;
    [card addSubview:err];

    UIButton *go = [UIButton buttonWithType:UIButtonTypeSystem];
    go.frame = CGRectMake(24, 168, cardW - 48, 44);
    go.layer.cornerRadius = 12;
    CAGradientLayer *bgGrad = [CAGradientLayer layer];
    bgGrad.frame = go.bounds;
    bgGrad.colors = @[(id)[UIColor colorWithRed:0.2 green:0.5 blue:1 alpha:1].CGColor,
                      (id)[UIColor colorWithRed:0.4 green:0.3 blue:1 alpha:1].CGColor];
    bgGrad.startPoint = CGPointMake(0, 0.5);
    bgGrad.endPoint = CGPointMake(1, 0.5);
    bgGrad.cornerRadius = 12;
    [go.layer insertSublayer:bgGrad atIndex:0];
    [go setTitle:@"激 活" forState:UIControlStateNormal];
    [go setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    go.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [card addSubview:go];

    // 提交逻辑 (block 捕获 tf/err)
    __weak UITextField *weakTf = tf;
    __weak UILabel *weakErr = err;
    void (^submit)(void) = ^{
        UITextField *strongTf = weakTf;
        UILabel *strongErr = weakErr;
        if (!strongTf) return;
        NSString *inp = strongTf.text ?: @"";
        if (isValidKey(inp)) {
            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
            [ud setObject:inp forKey:kUsedKeyLog];
            [ud synchronize];
            activateSuccess();
        } else {
            strongErr.text = @"❌ 卡密无效，请重新输入";
            strongErr.alpha = 0;
            [UIView animateWithDuration:0.2 animations:^{ strongErr.alpha = 1; }];
            strongTf.text = @"";
            CABasicAnimation *shake = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
            shake.fromValue = @-8;
            shake.toValue = @8;
            shake.duration = 0.08;
            shake.autoreverses = YES;
            shake.repeatCount = 3;
            [strongTf.layer addAnimation:shake forKey:@"shake"];
        }
    };

    // ── helper: action target (block → target-action) ──
    if (!g_helper) { g_helper = [DKGateActionHelper new]; g_helper.block = submit; }
    [go addTarget:g_helper action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];

    if (!g_tfDel) { g_tfDel = [DKGateTFDelegate new]; }
    tf.delegate = g_tfDel;
}

// ─────────────── helper 实现 ───────────────
@implementation DKGateActionHelper
- (void)tapped { if (self.block) self.block(); }
@end

@implementation DKGateTFDelegate
- (BOOL)textFieldShouldReturn:(UITextField *)f {
    [f resignFirstResponder];
    UIWindow *w = g_gateWindow;
    if (!w) return YES;
    for (UIView *v in w.rootViewController.view.subviews) {
        for (UIView *sv in v.subviews) {
            if ([sv isKindOfClass:[UIButton class]]) {
                [(UIButton *)sv sendActionsForControlEvents:UIControlEventTouchUpInside];
                return YES;
            }
        }
    }
    return YES;
}
@end

// ─────────────── 注入入口 ───────────────
// constructor: 主队列轮询等 scene 就绪 → 未激活立即弹门禁
// v2: 旧版固定 2.5s 只试一次, 冷启动 scene 未 active 时静默 return → 首次不弹(大退才弹)
//     改为 0.5s 轮询 ×120 次(60s), scene 一 active 立刻弹; 兼容 foregroundActive/Inactive
static void dk_gate_poll(void) {
    if (g_gateWindow) return;                                   // 已弹
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud boolForKey:kActivatedKey]) return;                  // 已激活
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ dk_gate_poll(); });
        return;
    }
    showGateUI();
    if (!g_gateWindow) {                                        // scene 未就绪, 下轮再试
        static int s_tries = 0;
        if (++s_tries > 120) return;                            // 60s 放弃
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ dk_gate_poll(); });
    }
}

__attribute__((constructor))
static void dk_keygate_init(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (![bid isEqualToString:@"com.survivor.acecn"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ dk_gate_poll(); });
    });
}
