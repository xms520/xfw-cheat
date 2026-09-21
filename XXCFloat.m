// XXCFloat v1 — 下方了 (com.feiyu.freakout / xxgame-mobile) 悬浮窗 + se(V8) 引擎注入
// UI: FloatGlass 液态玻璃悬浮球/面板（用户提供源码改造）
// 注入: se::ScriptEngine 单例 [base+0x3106E08] + evalString [base+0x73E7C] 直接调用（零 hook）
// 面板: 秒杀 / 无敌 / 技能无CD 三开关 → evalString 调 __XXC.setFlag 同步进 JS
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <math.h>

#define SE_INSTANCE_RVA   0x3106E08ULL   // se::ScriptEngine* 单例全局指针 (__DATA)
#define SE_EVALSTRING_RVA 0x73E7CULL     // bool evalString(this, const char*, unsigned, Value*, Value*)

typedef bool (*se_eval_t)(void *self, const char *script, unsigned len, void *ret, void *source);

static uint64_t g_execBase = 0;
static se_eval_t g_eval = NULL;
static BOOL g_injected = NO;
static BOOL g_engineOk = NO;
static NSString *g_logPath = nil;
static UILabel *g_statusLabel = nil;
static NSMutableArray<UIButton *> *g_btns = nil;
static BOOL g_kill = NO, g_inv = NO, g_ad = NO;
static int g_cd = 0, g_eng = 0;   // 挡位 0-3

static NSString *UDKey(NSString *k) { return [NSString stringWithFormat:@"xxc_%@", k]; }
static void loadFlags(void) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    g_kill = [ud boolForKey:UDKey(@"kill")];
    g_inv  = [ud boolForKey:UDKey(@"inv")];
    g_ad   = [ud boolForKey:UDKey(@"ad")];
    g_cd   = (int)[ud integerForKey:UDKey(@"cd")];
    g_eng  = (int)[ud integerForKey:UDKey(@"eng")];
    if (g_cd < 0 || g_cd > 3) g_cd = 0;
    if (g_eng < 0 || g_eng > 3) g_eng = 0;
}
static void saveFlag(NSString *k, BOOL v) {
    [[NSUserDefaults standardUserDefaults] setBool:v forKey:UDKey(k)];
}
static void saveInt(NSString *k, int v) {
    [[NSUserDefaults standardUserDefaults] setInteger:v forKey:UDKey(k)];
}

static void xlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void xlog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[XXCD] %@", s);
    if (g_logPath) {
        static FILE *fp = NULL;
        if (!fp) fp = fopen(g_logPath.UTF8String, "a");
        if (fp) { fprintf(fp, "%s\n", s.UTF8String); fflush(fp); }
    }
}

static void *seInstance(void) {
    if (!g_execBase) return NULL;
    return *(void **)(g_execBase + SE_INSTANCE_RVA);
}
static void seEval(NSString *js) {
    void *se = seInstance();
    if (!se || !g_eval) return;
    const char *cstr = js.UTF8String;
    g_eval(se, cstr, (unsigned)strlen(cstr), NULL, "XXCFloat");
}

static const char *g_cheatB64 =
    "LyoqCiAqIFhYQ2hlYXQgdjQg4oCUIOS4i+aWueS6hiAoQ29jb3MgMy44LjcganNiIC8gVjgg5byV5pOOKQogKiBuYXRpdmUg"
    "WFhDRmxvYXQuZHlsaWIg57uPIHNlOjpTY3JpcHRFbmdpbmU6OmV2YWxTdHJpbmcg5rOo5YWlCiAqICAg56eS5p2AICAgPSDo"
    "t5/ouKogQmF0dGxlTW9uc3Rlcu+8jOebtOWGmSBfaHA9MCArIHN0YXRlPURpZSArIOeri+WNs+makOi6qyB2aWV3ICsg5YiG"
    "5q2l56e76Zmk77yI6Ziy5Y2h6aG2L+mYsuWNoei/h+WFs++8iQogKiAgIOaXoOaVjCAgID0g5YyF6KOFIEJhdHRsZVJvbGVC"
    "YXNlL0JhdHRsZVdhbGwvQmF0dGxlTGlmZVN1bW1vbmVkQ3JlYXR1cmVzIOeahCBocCBzZXR0ZXLvvIjlt7HmlrnnpoHlh4/o"
    "oYDvvIkKICogICDmlLvpgJ8gICA9IEJhdHRsZVNraWxsLmdldFNraWxsQ0Qgw5cgWzEvMC41LzAuMjUvMC4xMjVd77yI5LuF"
    "5bex5pa577yM5oyh5L2N55SxIG5hdGl2ZSDpnaLmnb/lvqrnjq/vvIkKICogICDlhY3lub/lkYogPSBwYXRjaCBDaGFubmVs"
    "LmNyZWF0ZVJld2FyZGVkVmlkZW9BZCDihpIg55u05o6lIHN1Y2Nlc3NjYu+8iOi3s+i/h+W5v+WRiiBTREvvvIzlpZblirHn"
    "haflj5HvvIkKICogICDlj5jpgJ8gICA9IHBhdGNoIERpcmVjdG9yLl9jYWxjdWxhdGVEVCDlhajlsYAgZHQg57yp5pS+IFsx"
    "LzIvNC84Xe+8m+S4jeWPr+eUqOaXtumAgOWMluS4uuaImOaWl+WGhSBzZXRUaW1lU2NhbGUKICogVUkg5YWo5ZyoIG5hdGl2"
    "ZSDpnaLmnb/vvJvmnKzmlofku7blj6rlgZrpgLvovpEgKyBfX1hYQyDmoaUKICovCihmdW5jdGlvbiAoKSB7CiAgICAndXNl"
    "IHN0cmljdCc7CiAgICB2YXIgRyA9ICh0eXBlb2Ygd2luZG93ICE9PSAndW5kZWZpbmVkJykgPyB3aW5kb3cgOiBnbG9iYWxU"
    "aGlzOwogICAgaWYgKEcuX19YWEMpIHJldHVybjsgLy8g6Ziy6YeN5aSN5rOo5YWlCiAgICB2YXIgVEFHID0gJ1tYWENdJzsK"
    "ICAgIHZhciBWRVIgPSAndjQnOwoKICAgIGZ1bmN0aW9uIGxvZygpIHsKICAgICAgICB2YXIgcyA9IFRBRyArICcgJyArIEFy"
    "cmF5LnByb3RvdHlwZS5zbGljZS5jYWxsKGFyZ3VtZW50cykubWFwKGZ1bmN0aW9uICh4KSB7CiAgICAgICAgICAgIHRyeSB7"
    "IHJldHVybiAoeCBpbnN0YW5jZW9mIEVycm9yKSA/ICh4Lm1lc3NhZ2UgKyAnfCcgKyAoeC5zdGFjayB8fCAnJykuc3BsaXQo"
    "J1xuJylbMV0pIDogU3RyaW5nKHgpOyB9CiAgICAgICAgICAgIGNhdGNoIChlKSB7IHJldHVybiAnPyc7IH0KICAgICAgICB9"
    "KS5qb2luKCcgJyk7CiAgICAgICAgdHJ5IHsgY29uc29sZS5sb2cocyk7IH0gY2F0Y2ggKGUpIHt9CiAgICAgICAgdHJ5IHsg"
    "anNiTG9nKHMpOyB9IGNhdGNoIChlKSB7fQogICAgfQogICAgdmFyIF9sb2dMaW5lcyA9IFtdOwogICAgZnVuY3Rpb24ganNi"
    "TG9nKHMpIHsKICAgICAgICBfbG9nTGluZXMucHVzaChzKTsKICAgICAgICBpZiAoX2xvZ0xpbmVzLmxlbmd0aCA+IDMwMCkg"
    "X2xvZ0xpbmVzLnNwbGljZSgwLCBfbG9nTGluZXMubGVuZ3RoIC0gMzAwKTsKICAgICAgICBpZiAoX2xvZ0xpbmVzLmxlbmd0"
    "aCAlIDIwID09PSAxICYmIHR5cGVvZiBqc2IgIT09ICd1bmRlZmluZWQnICYmIGpzYi5maWxlVXRpbHMpIHsKICAgICAgICAg"
    "ICAgdHJ5IHsKICAgICAgICAgICAgICAgIGpzYi5maWxlVXRpbHMud3JpdGVTdHJpbmdUb0ZpbGUoX2xvZ0xpbmVzLmpvaW4o"
    "J1xuJyksCiAgICAgICAgICAgICAgICAgICAganNiLmZpbGVVdGlscy5nZXRXcml0YWJsZVBhdGgoKSArICd4eGNoZWF0Lmxv"
    "ZycpOwogICAgICAgICAgICB9IGNhdGNoIChlKSB7fQogICAgICAgIH0KICAgIH0KCiAgICAvLyAtLS0tLS0tLS0tIOagh+W/"
    "l++8iG5hdGl2ZSDpnaLmnb/ov5DooYzml7bopobnm5bvvIkgLS0tLS0tLS0tLQogICAgLy8ga2lsbC9pbnYvYWQ6IGJvb2zv"
    "vJtjZDog5pS76YCf5oyh5L2NIDAtM++8m2VuZzog5Y+Y6YCf5oyh5L2NIDAtMwogICAgdmFyIEYgPSB7CiAgICAgICAga2ls"
    "bDogbHNHZXQoJ2tpbGwnKSA9PT0gJzEnLAogICAgICAgIGludjogIGxzR2V0KCdpbnYnKSA9PT0gJzEnLAogICAgICAgIGFk"
    "OiAgIGxzR2V0KCdhZCcpID09PSAnMScsCiAgICAgICAgY2Q6ICAgcGFyc2VJbnQobHNHZXQoJ2NkJykgfHwgJzAnLCAxMCkg"
    "fHwgMCwKICAgICAgICBlbmc6ICBwYXJzZUludChsc0dldCgnZW5nJykgfHwgJzAnLCAxMCkgfHwgMAogICAgfTsKICAgIHZh"
    "ciBDRF9NVUwgID0gWzEsIDAuNSwgMC4yNSwgMC4xMjVdOyAvLyBPRkYveDIveDQveDgKICAgIHZhciBFTkdfTVVMID0gWzEs"
    "IDIsIDQsIDhdOyAgICAgICAgICAvLyBPRkYveDIveDQveDgKICAgIHZhciBDRF9MQkwgID0gWydPRkYnLCAneDInLCAneDQn"
    "LCAneDgnXTsKICAgIGZ1bmN0aW9uIGxzR2V0KGspIHsgdHJ5IHsgcmV0dXJuIGxvY2FsU3RvcmFnZS5nZXRJdGVtKCd4ZmNf"
    "JyArIGspIHx8ICcnOyB9IGNhdGNoIChlKSB7IHJldHVybiAnJzsgfSB9CiAgICBmdW5jdGlvbiBsc1NldChrLCB2KSB7IHRy"
    "eSB7IGxvY2FsU3RvcmFnZS5zZXRJdGVtKCd4ZmNfJyArIGssIHYpOyB9IGNhdGNoIChlKSB7fSB9CgogICAgLy8gLS0tLS0t"
    "LS0tLSDlhajlsYDmoaUgLS0tLS0tLS0tLQogICAgRy5fX1hYQyA9IHsKICAgICAgICB2ZXI6IFZFUiwKICAgICAgICBzZXRG"
    "bGFnOiBmdW5jdGlvbiAoaywgdikgewogICAgICAgICAgICBpZiAoayBpbiBGKSB7CiAgICAgICAgICAgICAgICBGW2tdID0g"
    "ISF2OwogICAgICAgICAgICAgICAgbHNTZXQoaywgRltrXSA/ICcxJyA6ICcwJyk7CiAgICAgICAgICAgICAgICBsb2coJ3Nl"
    "dEZsYWcnLCBrLCBGW2tdKTsKICAgICAgICAgICAgfQogICAgICAgIH0sCiAgICAgICAgc2V0U3BkOiBmdW5jdGlvbiAoa2lu"
    "ZCwgbHZsKSB7CiAgICAgICAgICAgIGx2bCA9IE1hdGgubWF4KDAsIE1hdGgubWluKDMsIGx2bCB8IDApKTsKICAgICAgICAg"
    "ICAgaWYgKGtpbmQgPT09ICdjZCcpICB7IEYuY2QgPSBsdmw7ICBsc1NldCgnY2QnLCBsdmwpOyAgbG9nKCdzcGQgY2Q9Jywg"
    "Q0RfTEJMW2x2bF0pOyB9CiAgICAgICAgICAgIGlmIChraW5kID09PSAnZW5nJykgeyBGLmVuZyA9IGx2bDsgbHNTZXQoJ2Vu"
    "ZycsIGx2bCk7IGxvZygnc3BkIGVuZz0nLCBDRF9MQkxbbHZsXSk7IH0KICAgICAgICB9LAogICAgICAgIGdldEZsYWdzOiBm"
    "dW5jdGlvbiAoKSB7IHJldHVybiBKU09OLnN0cmluZ2lmeShGKTsgfSwKICAgICAgICBzdGF0czogeyBraWxsczogMCwgbW9u"
    "c3RlcnM6IDAgfQogICAgfTsKCiAgICAvLyAtLS0tLS0tLS0tIFN5c3RlbUpTIOaooeWdl+WumuS9jSAtLS0tLS0tLS0tCiAg"
    "ICB2YXIgTU9EID0gJ2NodW5rczovLy9fdmlydHVhbC8nOwogICAgdmFyIE5FRUQgPSBbCiAgICAgICAgWydtb25zdGVyJywg"
    "TU9EICsgJ0JhdHRsZU1vbnN0ZXIudHMnLCAgICAgICAgJ0JhdHRsZU1vbnN0ZXInXSwKICAgICAgICBbJ2Jhc2UnLCAgICBN"
    "T0QgKyAnQmF0dGxlUm9sZUJhc2UudHMnLCAgICAgICAnQmF0dGxlUm9sZUJhc2UnXSwKICAgICAgICBbJ3NraWxsJywgICBN"
    "T0QgKyAnQmF0dGxlU2tpbGwudHMnLCAgICAgICAgICAnQmF0dGxlU2tpbGwnXSwKICAgICAgICBbJ3dhbGwnLCAgICBNT0Qg"
    "KyAnQmF0dGxlV2FsbC50cycsICAgICAgICAgICAnQmF0dGxlV2FsbCddLAogICAgICAgIFsnbGlmZScsICAgIE1PRCArICdC"
    "YXR0bGVMaWZlU3VtbW9uZWRDcmVhdHVyZXMudHMnLCAnQmF0dGxlTGlmZVN1bW1vbmVkQ3JlYXR1cmVzJ10sCiAgICAgICAg"
    "Wydtb3ZlJywgICAgTU9EICsgJ01vbnN0ZXJNb3ZlQ3RybC50cycsICAgICAgJ01vbnN0ZXJNb3ZlQ3RybCddLAogICAgICAg"
    "IFsnc29ydCcsICAgIE1PRCArICdNb25zdGVyU29ydEN0cmwudHMnLCAgICAgICdNb25zdGVyU29ydEN0cmwnXSwKICAgICAg"
    "ICBbJ2Ryb3AnLCAgICBNT0QgKyAnQmF0dGxlRHJvcEN0cmwudHMnLCAgICAgICAnQmF0dGxlRHJvcEN0cmwnXSwKICAgICAg"
    "ICBbJ3JlYycsICAgICBNT0QgKyAnQmF0dGxlUmVjb3JkUGx1Z2luLnRzJywgICAnQmF0dGxlUmVjb3JkUGx1Z2luJ10sCiAg"
    "ICAgICAgWydjaGFuJywgICAgTU9EICsgJ0NoYW5uZWxDdHJsLnRzJywgICAgICAgICAgJ2NoYW5uZWxDdHJsJ10KICAgIF07"
    "CiAgICB2YXIgQ0xTID0ge307CiAgICBmdW5jdGlvbiBnZXROcyhrZXksIGV4cCkgewogICAgICAgIHRyeSB7CiAgICAgICAg"
    "ICAgIHZhciBucyA9IFN5c3RlbS5nZXQoa2V5KTsKICAgICAgICAgICAgcmV0dXJuIChucyAmJiBuc1tleHBdKSA/IG5zW2V4"
    "cF0gOiBudWxsOwogICAgICAgIH0gY2F0Y2ggKGUpIHsgcmV0dXJuIG51bGw7IH0KICAgIH0KICAgIHZhciBwYXRjaERvbmUg"
    "PSBmYWxzZTsKICAgIGZ1bmN0aW9uIHRyeVBhdGNoKCkgewogICAgICAgIHZhciBvayA9IHRydWU7CiAgICAgICAgZm9yICh2"
    "YXIgaSA9IDA7IGkgPCBORUVELmxlbmd0aDsgaSsrKSB7CiAgICAgICAgICAgIHZhciBpdCA9IE5FRURbaV07CiAgICAgICAg"
    "ICAgIGlmICghQ0xTW2l0WzBdXSkgewogICAgICAgICAgICAgICAgdmFyIGMgPSBnZXROcyhpdFsxXSwgaXRbMl0pOwogICAg"
    "ICAgICAgICAgICAgaWYgKGMpIENMU1tpdFswXV0gPSBjOyBlbHNlIG9rID0gZmFsc2U7CiAgICAgICAgICAgIH0KICAgICAg"
    "ICB9CiAgICAgICAgaWYgKCFvaykgcmV0dXJuIGZhbHNlOwogICAgICAgIGlmIChwYXRjaERvbmUpIHJldHVybiB0cnVlOwog"
    "ICAgICAgIHBhdGNoRG9uZSA9IHRydWU7CiAgICAgICAgZG9QYXRjaCgpOwogICAgICAgIHJldHVybiB0cnVlOwogICAgfQoK"
    "ICAgIHZhciBNT05TID0gbmV3IFNldCgpOwogICAgdmFyIFJPTEVfTU9OU1RFUiA9IDM7IC8vIEJhdHRsZVJvbGVUeXBlLk1v"
    "bnN0ZXIKICAgIHZhciBTVF9ESUUgPSAzOyAgICAgICAvLyBNb25zdGVyU3RhdGVFbnVtLkRpZQogICAgdmFyIGVuZ2luZVNw"
    "ZE9rID0gZmFsc2U7ICAgLy8g5byV5pOO57qn5Y+Y6YCf5piv5ZCm5oyC5LiK77yI5oyC5LiK5YiZ5oiY5paX5YaF5LiN6YeN"
    "5aSN5Yqg6YCf77yJCiAgICB2YXIgbGFzdEJhdHRsZSA9IG51bGw7CgogICAgZnVuY3Rpb24gZG9QYXRjaCgpIHsKICAgICAg"
    "ICAvLyAtLS0tIOaXoOaVjCAtLS0tCiAgICAgICAgd3JhcEhwKENMUy5iYXNlKTsgd3JhcEhwKENMUy53YWxsKTsgd3JhcEhw"
    "KENMUy5saWZlKTsKICAgICAgICBsb2coJ2ludiBwYXRjaCBvaycpOwogICAgICAgIC8vIC0tLS0g56eS5p2A6Lef6LiqIC0t"
    "LS0KICAgICAgICB2YXIgQk0gPSBDTFMubW9uc3RlcjsKICAgICAgICB2YXIgb0luaXQgPSBCTS5wcm90b3R5cGUuaW5pdDsK"
    "ICAgICAgICBCTS5wcm90b3R5cGUuaW5pdCA9IGZ1bmN0aW9uICgpIHsKICAgICAgICAgICAgdHJ5IHsgdGhpcy5fX3hmd0tp"
    "bGxlZCA9IDA7IE1PTlMuYWRkKHRoaXMpOyB9IGNhdGNoIChlKSB7fQogICAgICAgICAgICByZXR1cm4gb0luaXQuYXBwbHko"
    "dGhpcywgYXJndW1lbnRzKTsKICAgICAgICB9OwogICAgICAgIHZhciBvRnJlZSA9IEJNLnByb3RvdHlwZS5vbkZyZWU7CiAg"
    "ICAgICAgQk0ucHJvdG90eXBlLm9uRnJlZSA9IGZ1bmN0aW9uICgpIHsgTU9OUy5kZWxldGUodGhpcyk7IHJldHVybiBvRnJl"
    "ZS5hcHBseSh0aGlzLCBhcmd1bWVudHMpOyB9OwogICAgICAgIGxvZygna2lsbCB0cmFjayBvaycpOwogICAgICAgIC8vIC0t"
    "LS0g5pS76YCf77yI5oyh5L2N77yJIC0tLS0KICAgICAgICB2YXIgQlMgPSBDTFMuc2tpbGw7CiAgICAgICAgdmFyIG9DRCA9"
    "IEJTLnByb3RvdHlwZS5nZXRTa2lsbENEOwogICAgICAgIEJTLnByb3RvdHlwZS5nZXRTa2lsbENEID0gZnVuY3Rpb24gKCkg"
    "ewogICAgICAgICAgICBpZiAoRi5jZCA+IDAgJiYgKCF0aGlzLl9zcmMgfHwgdGhpcy5fc3JjLnJvbGVUeXBlICE9PSBST0xF"
    "X01PTlNURVIpKSB7CiAgICAgICAgICAgICAgICByZXR1cm4gb0NELmNhbGwodGhpcykgKiBDRF9NVUxbRi5jZF07CiAgICAg"
    "ICAgICAgIH0KICAgICAgICAgICAgcmV0dXJuIG9DRC5jYWxsKHRoaXMpOwogICAgICAgIH07CiAgICAgICAgbG9nKCdjZCBw"
    "YXRjaCBvaycpOwogICAgICAgIC8vIC0tLS0g5YWN5bm/5ZGK77ya6Lez6L+H5bm/5ZGKIFNESyDnm7TmjqXlj5HlpZbvvIjm"
    "nI3liqHlmajmrKHmlbDpmZDliLbkuI3lj5flvbHlk43vvIkgLS0tLQogICAgICAgIHZhciBjaGFuID0gQ0xTLmNoYW4gJiYg"
    "Q0xTLmNoYW4uQ2hhbm5lbDsKICAgICAgICBpZiAoY2hhbikgewogICAgICAgICAgICBjaGFuLmNyZWF0ZVJld2FyZGVkVmlk"
    "ZW9BZCA9IGZ1bmN0aW9uIChpZCwgc3VjY2Vzc2NiLCBmYWlsY2IpIHsKICAgICAgICAgICAgICAgIGlmIChGLmFkKSB7IHRy"
    "eSB7IHN1Y2Nlc3NjYiAmJiBzdWNjZXNzY2IoKTsgfSBjYXRjaCAoZSkgeyBsb2coJ2FkIGNiIGV4YycsIGUpOyB9IHJldHVy"
    "bjsgfQogICAgICAgICAgICAgICAgLy8g6LWw5Y6f5Z6L5Y6f5a6e546wCiAgICAgICAgICAgICAgICB2YXIgcCA9IE9iamVj"
    "dC5nZXRQcm90b3R5cGVPZihjaGFuKTsKICAgICAgICAgICAgICAgIGlmIChwICYmIHAuY3JlYXRlUmV3YXJkZWRWaWRlb0Fk"
    "ICYmIHAuY3JlYXRlUmV3YXJkZWRWaWRlb0FkICE9PSBhcmd1bWVudHMuY2FsbGVlKSB7CiAgICAgICAgICAgICAgICAgICAg"
    "cmV0dXJuIHAuY3JlYXRlUmV3YXJkZWRWaWRlb0FkLmNhbGwodGhpcywgaWQsIHN1Y2Nlc3NjYiwgZmFpbGNiKTsKICAgICAg"
    "ICAgICAgICAgIH0KICAgICAgICAgICAgICAgIHRyeSB7IHN1Y2Nlc3NjYiAmJiBzdWNjZXNzY2IoKTsgfSBjYXRjaCAoZSkg"
    "eyBsb2coJ2FkIGNiMiBleGMnLCBlKTsgfQogICAgICAgICAgICB9OwogICAgICAgICAgICBsb2coJ2FkIHBhdGNoIG9rJyk7"
    "CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgbG9nKCdXQVJOIGNoYW5uZWwgbm90IGZvdW5kLCBhZCBwYXRjaCBza2lw"
    "Jyk7CiAgICAgICAgfQogICAgfQoKICAgIGZ1bmN0aW9uIHdyYXBIcChjbHMpIHsKICAgICAgICB2YXIgZCA9IE9iamVjdC5n"
    "ZXRPd25Qcm9wZXJ0eURlc2NyaXB0b3IoY2xzLnByb3RvdHlwZSwgJ2hwJyk7CiAgICAgICAgaWYgKCFkIHx8ICFkLnNldCkg"
    "eyBsb2coJ3dyYXBIcCBGQUlMJywgY2xzICYmIGNscy5uYW1lKTsgcmV0dXJuOyB9CiAgICAgICAgdmFyIG9yaWcgPSBkLnNl"
    "dDsKICAgICAgICBPYmplY3QuZGVmaW5lUHJvcGVydHkoY2xzLnByb3RvdHlwZSwgJ2hwJywgewogICAgICAgICAgICBnZXQ6"
    "IGQuZ2V0LAogICAgICAgICAgICBzZXQ6IGZ1bmN0aW9uICh2KSB7CiAgICAgICAgICAgICAgICBpZiAoRi5pbnYgJiYgdGhp"
    "cy5faHAgPiAwICYmIHYgPCB0aGlzLl9ocCAmJiB0aGlzLl9yb2xlVHlwZSAhPT0gUk9MRV9NT05TVEVSKSByZXR1cm47CiAg"
    "ICAgICAgICAgICAgICBvcmlnLmNhbGwodGhpcywgdik7CiAgICAgICAgICAgIH0sCiAgICAgICAgICAgIGNvbmZpZ3VyYWJs"
    "ZTogdHJ1ZSwKICAgICAgICAgICAgZW51bWVyYWJsZTogZmFsc2UKICAgICAgICB9KTsKICAgIH0KCiAgICAvLyAtLS0tLS0t"
    "LS0tIOW8leaTjue6p+WPmOmAn++8iOWFqOWxgCBkdCDnvKnmlL7vvIkgLS0tLS0tLS0tLQogICAgZnVuY3Rpb24gZW5naW5l"
    "UGF0Y2goKSB7CiAgICAgICAgU3lzdGVtLmltcG9ydCgnY2MnKS50aGVuKGZ1bmN0aW9uIChjYykgewogICAgICAgICAgICB0"
    "cnkgewogICAgICAgICAgICAgICAgdmFyIEQgPSBjYy5EaXJlY3RvcjsKICAgICAgICAgICAgICAgIGlmIChEICYmIEQucHJv"
    "dG90eXBlICYmIEQucHJvdG90eXBlLl9jYWxjdWxhdGVEVCkgewogICAgICAgICAgICAgICAgICAgIHZhciBvQ2FsYyA9IEQu"
    "cHJvdG90eXBlLl9jYWxjdWxhdGVEVDsKICAgICAgICAgICAgICAgICAgICBELnByb3RvdHlwZS5fY2FsY3VsYXRlRFQgPSBm"
    "dW5jdGlvbiAoKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIHZhciBkdCA9IG9DYWxjLmFwcGx5KHRoaXMsIGFyZ3VtZW50"
    "cyk7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmIChGLmVuZyA+IDApIGR0ICo9IEVOR19NVUxbRi5lbmddOwogICAgICAg"
    "ICAgICAgICAgICAgICAgICByZXR1cm4gZHQ7CiAgICAgICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgICAgICAgICBl"
    "bmdpbmVTcGRPayA9IHRydWU7CiAgICAgICAgICAgICAgICAgICAgbG9nKCdlbmdpbmUgc3BkIHBhdGNoIG9rIChfY2FsY3Vs"
    "YXRlRFQpJyk7CiAgICAgICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgICAgIGxvZygnV0FSTiBfY2FsY3Vs"
    "YXRlRFQgbWlzc2luZywgZW5naW5lIHNwZCBmYWxsYmFjayB0byBiYXR0bGUgdGltZXNjYWxlJyk7CiAgICAgICAgICAgICAg"
    "ICB9CiAgICAgICAgICAgIH0gY2F0Y2ggKGUpIHsgbG9nKCdlbmdpbmUgc3BkIGV4YycsIGUpOyB9CiAgICAgICAgfSkuY2F0"
    "Y2goZnVuY3Rpb24gKCkge30pOwogICAgfQoKICAgIC8vIC0tLS0tLS0tLS0g56eS5p2AIC0tLS0tLS0tLS0KICAgIGZ1bmN0"
    "aW9uIGtpbGxPbmUobSkgewogICAgICAgIG0uX2hwID0gMDsKICAgICAgICBtLl9zdGF0ZSA9IFNUX0RJRTsKICAgICAgICAv"
    "LyDnq4vljbPpmpDouqsgKyDlgZzmjonliqjnlLvvvJrpmLIi5Y2h5Zyo5bGP5bmV6aG26YOo5LiN5Yqo55qE5oCqIu+8iOWH"
    "uueUn+WKqOeUu+S4reiiq+aJk+atu+aXtiBwbGF5RGllIOWbnuiwg+mTvuWPr+iDveS4jeWujOaVtO+8iQogICAgICAgIHRy"
    "eSB7CiAgICAgICAgICAgIGlmIChtLnZpZXcgJiYgbS52aWV3Lm5vZGUpIHsKICAgICAgICAgICAgICAgIG0udmlldy5ub2Rl"
    "LmFjdGl2ZSA9IGZhbHNlOwogICAgICAgICAgICAgICAgdmFyIHNrID0gbS52aWV3LmdldENvbXBvbmVudCAmJiBtLnZpZXcu"
    "Z2V0Q29tcG9uZW50KCdzcC5Ta2VsZXRvbicpOwogICAgICAgICAgICAgICAgLy8g5LiN5by65Yi25riF55CGIFNrZWxldG9u"
    "IOeKtuaAge+8jOS6pOeUsSByZWNvdmVyeVZpZXcvcGxheURpZSDmraPluLjlm57msaAKICAgICAgICAgICAgfQogICAgICAg"
    "IH0gY2F0Y2ggKGUpIHt9CiAgICAgICAgdHJ5IHsgaWYgKG0ucmVjb3ZlcnlWaWV3KSBtLnJlY292ZXJ5VmlldygpOyB9IGNh"
    "dGNoIChlKSB7fQogICAgICAgIHZhciBidCA9IG0uYmF0dGxlOwogICAgICAgIGlmICghYnQpIHJldHVybjsKICAgICAgICBs"
    "YXN0QmF0dGxlID0gYnQ7CiAgICAgICAgdHJ5IHsgaWYgKENMUy5kcm9wICYmIGJ0LmdldEN0cmwpIGJ0LmdldEN0cmwoQ0xT"
    "LmRyb3ApLm1vbnN0ZXJEcm9wKG0pOyB9IGNhdGNoIChlKSB7fQogICAgICAgIHRyeSB7IGlmIChDTFMubW92ZSAmJiBidC5n"
    "ZXRDdHJsKSBidC5nZXRDdHJsKENMUy5tb3ZlKS5yZW1vdmVNb25zdGVyKG0pOyB9IGNhdGNoIChlKSB7fQogICAgICAgIHRy"
    "eSB7IGlmIChDTFMuc29ydCAmJiBidC5nZXRDdHJsKSBidC5nZXRDdHJsKENMUy5zb3J0KS5yZW1vdmVNb25zdGVyKG0pOyB9"
    "IGNhdGNoIChlKSB7fQogICAgICAgIHRyeSB7IGlmIChDTFMucmVjICYmIGJ0LmdldFBsdWdpbikgYnQuZ2V0UGx1Z2luKENM"
    "Uy5yZWMpLnJlbW92ZU1vbnN0ZXIobSk7IH0gY2F0Y2ggKGUpIHt9CiAgICB9CgogICAgZnVuY3Rpb24gYmF0dGxlU3BkVGlj"
    "aygpIHsKICAgICAgICAvLyDlvJXmk47nuqflj5jpgJ/msqHmjILkuIrml7bvvIzmiJjmlpflhoXnlKggUHZlQmF0dGxlLnNl"
    "dFRpbWVTY2FsZSDlhZzlupUKICAgICAgICBpZiAoZW5naW5lU3BkT2sgfHwgRi5lbmcgPT09IDApIHJldHVybjsKICAgICAg"
    "ICB2YXIgYnQgPSBsYXN0QmF0dGxlOwogICAgICAgIGlmICghYnQpIHsKICAgICAgICAgICAgTU9OUy5mb3JFYWNoKGZ1bmN0"
    "aW9uIChtKSB7IGlmICghYnQgJiYgbS5iYXR0bGUpIGJ0ID0gbGFzdEJhdHRsZSA9IG0uYmF0dGxlOyB9KTsKICAgICAgICB9"
    "CiAgICAgICAgaWYgKGJ0ICYmIGJ0Ll90aW1lU2NhbGUgIT09IEVOR19NVUxbRi5lbmddKSB7CiAgICAgICAgICAgIHRyeSB7"
    "IGJ0LnNldFRpbWVTY2FsZShFTkdfTVVMW0YuZW5nXSk7IH0gY2F0Y2ggKGUpIHt9CiAgICAgICAgfQogICAgfQoKICAgIGZ1"
    "bmN0aW9uIGtpbGxUaWNrKCkgewogICAgICAgIGlmICghRi5raWxsIHx8IE1PTlMuc2l6ZSA9PT0gMCkgeyBHLl9fWFhDLnN0"
    "YXRzLm1vbnN0ZXJzID0gTU9OUy5zaXplOyByZXR1cm47IH0KICAgICAgICB2YXIgbiA9IDA7CiAgICAgICAgTU9OUy5mb3JF"
    "YWNoKGZ1bmN0aW9uIChtKSB7CiAgICAgICAgICAgIGlmIChtLl9feGZ3S2lsbGVkKSByZXR1cm47CiAgICAgICAgICAgIGlm"
    "ICh0eXBlb2YgbS5faHAgIT09ICdudW1iZXInIHx8ICFtLmJhdHRsZSkgcmV0dXJuOwogICAgICAgICAgICBpZiAobS5faHAg"
    "PiAwKSB7CiAgICAgICAgICAgICAgICB0cnkgeyBraWxsT25lKG0pOyBuKys7IH0gY2F0Y2ggKGUpIHsgbG9nKCdraWxsIGV4"
    "YycsIGUpOyB9CiAgICAgICAgICAgIH0KICAgICAgICB9KTsKICAgICAgICBpZiAobikgeyBHLl9fWFhDLnN0YXRzLmtpbGxz"
    "ICs9IG47IGxvZygna2lsbCBuPScgKyBuICsgJyB0b3RhbD0nICsgRy5fX1hYQy5zdGF0cy5raWxscyk7IH0KICAgICAgICBH"
    "Ll9fWFhDLnN0YXRzLm1vbnN0ZXJzID0gTU9OUy5zaXplOwogICAgfQoKICAgIC8vIC0tLS0tLS0tLS0g5a6a5pe25ZmoIC0t"
    "LS0tLS0tLS0KICAgIGZ1bmN0aW9uIGV2ZXJ5KG1zLCBmbikgewogICAgICAgIGlmICh0eXBlb2Ygc2V0SW50ZXJ2YWwgPT09"
    "ICdmdW5jdGlvbicpIHJldHVybiBzZXRJbnRlcnZhbChmbiwgbXMpOwogICAgICAgIFN5c3RlbS5pbXBvcnQoJ2NjJykudGhl"
    "bihmdW5jdGlvbiAoY2MpIHsKICAgICAgICAgICAgdHJ5IHsgY2MuZGlyZWN0b3Iub24oY2MuRGlyZWN0b3IuRVZFTlRfQkVG"
    "T1JFX1VQREFURSwgZnVuY3Rpb24gKCkgeyBmbigpOyB9KTsgfSBjYXRjaCAoZSkge30KICAgICAgICB9KS5jYXRjaChmdW5j"
    "dGlvbiAoKSB7fSk7CiAgICB9CiAgICB2YXIgdDAgPSBEYXRlLm5vdygpLCB3YXJuZWQgPSBmYWxzZTsKICAgIGZ1bmN0aW9u"
    "IHBvbGwoKSB7CiAgICAgICAgdmFyIHBhdGNoZWQgPSB0cnlQYXRjaCgpOwogICAgICAgIGlmICghcGF0Y2hlZCAmJiAhd2Fy"
    "bmVkICYmIERhdGUubm93KCkgLSB0MCA+IDkwMDAwKSB7IHdhcm5lZCA9IHRydWU7IGxvZygnV0FSTiBjbGFzcyB3YWl0IHRp"
    "bWVvdXQnKTsgfQogICAgICAgIGtpbGxUaWNrKCk7CiAgICAgICAgYmF0dGxlU3BkVGljaygpOwogICAgfQogICAgZXZlcnko"
    "MjUwLCBwb2xsKTsKICAgIGVuZ2luZVBhdGNoKCk7CiAgICB0cnkgewogICAgICAgIGlmICh0eXBlb2YganNiICE9PSAndW5k"
    "ZWZpbmVkJyAmJiBqc2IuZmlsZVV0aWxzKSB7CiAgICAgICAgICAgIGpzYi5maWxlVXRpbHMud3JpdGVTdHJpbmdUb0ZpbGUo"
    "U3RyaW5nKFZFUiksCiAgICAgICAgICAgICAgICBqc2IuZmlsZVV0aWxzLmdldFdyaXRhYmxlUGF0aCgpICsgJ3h4Y2hlYXRf"
    "aW5qZWN0ZWQuZmxhZycpOwogICAgICAgIH0KICAgIH0gY2F0Y2ggKGUpIHt9CiAgICBsb2coJ2xvYWRlZCcsIFZFUiwgJ2Zs"
    "YWdzJywgSlNPTi5zdHJpbmdpZnkoRikpOwp9KSgpOwo=";

static NSString *decodeCheat(void) {
    NSData *d = [[NSData alloc] initWithBase64EncodedString:@(g_cheatB64) options:0];
    if (!d) return nil;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

static void syncFlagToJS(NSString *key, BOOL val) {
    if (!g_injected) return;
    seEval([NSString stringWithFormat:@"__XXC.setFlag('%@', %@);", key, val ? @"true" : @"false"]);
}
static void syncSpdToJS(NSString *key, int lvl) {
    if (!g_injected) return;
    seEval([NSString stringWithFormat:@"__XXC.setSpd('%@', %d);", key, lvl]);
}

// 前向声明
@class FloatGlassButton;
@interface FloatGlassPanel : UIView
- (void)fg_close;
- (void)refreshButtons;
@end
static FloatGlassPanel *g_panel = nil;
static FloatGlassButton *g_floatBtn = nil;
static UIWindow *fg_keyWindow(void);
static void fg_toast(NSString *msg);
void updateStatusLabel(void);

void updateStatusLabel(void) {
    if (!g_statusLabel) return;
    NSString *inj = g_injected ? @"JS 注入 ✓ 功能即时生效"
                   : (g_engineOk ? @"引擎就绪 正在注入…" : @"等待游戏引擎…");
    g_statusLabel.text = inj;
}

static void injectTick(void) {
    if (g_injected) return;
    if (!g_execBase || !g_eval) return;
    void *se = seInstance();
    if (!se) {
        static int n1 = 0;
        if (++n1 % 15 == 1) xlog(@"waiting: se singleton still NULL");
        return;
    }
    if (!g_engineOk) {
        bool ok = g_eval(se, "1", 1, NULL, "XXC_PROBE");
        if (!ok) {
            static int n2 = 0;
            if (++n2 % 15 == 1) xlog(@"probe fail se=%p (isolate not on main thread?)", se);
            return;
        }
        g_engineOk = YES;
        xlog(@"se engine ok se=%p", se);
        dispatch_async(dispatch_get_main_queue(), ^{ updateStatusLabel(); });
    }
    NSString *js = decodeCheat();
    if (!js) { xlog(@"ERROR b64 decode"); g_injected = YES; return; }
    // ⚠️ len 必须用 UTF8 字节数：js.length 是 UTF-16 单元数，含中文注释时脚本被截断 → 语法异常 → ok=0
    const char *cstr = js.UTF8String;
    unsigned clen = (unsigned)strlen(cstr);
    bool ok = g_eval(se, cstr, clen, NULL, "xxcheat.js");
    // 验证：cheat.js 加载成功后写标记文件 Documents/xxcheat_injected.flag
    NSString *flagPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/xxcheat_injected.flag"];
    BOOL verified = [[NSFileManager defaultManager] fileExistsAtPath:flagPath];
    if (ok && verified) {
        g_injected = YES;
        xlog(@"inject OK cheat_len=%u", clen);
        [[NSFileManager defaultManager] removeItemAtPath:flagPath error:nil];
        syncFlagToJS(@"kill", g_kill);
        syncFlagToJS(@"inv",  g_inv);
        syncFlagToJS(@"ad",   g_ad);
        syncSpdToJS(@"cd",  g_cd);
        syncSpdToJS(@"eng", g_eng);
        dispatch_async(dispatch_get_main_queue(), ^{ updateStatusLabel(); });
    } else {
        static int n3 = 0;
        if (++n3 % 5 == 1) xlog(@"inject retry ok=%d verified=%d", ok, verified);
    }
}

// ===== 悬浮球（液态玻璃） =====
@interface FloatGlassButton : UIControl
@property (nonatomic, strong) UIView *glassView;
@end
@implementation FloatGlassButton
- (instancetype)initWithSize:(CGFloat)size {
    if (self = [super initWithFrame:CGRectMake(0, 0, size, size)]) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.shadowColor   = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.40;
        self.layer.shadowRadius  = 14;
        self.layer.shadowOffset  = CGSizeMake(0, 5);

        _glassView = [[UIView alloc] initWithFrame:self.bounds];
        _glassView.layer.cornerRadius = size / 2.0;
        _glassView.clipsToBounds = YES;
        _glassView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
        _glassView.userInteractionEnabled = NO;
        [self addSubview:_glassView];

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialLight];
        UIVisualEffectView *bv = [[UIVisualEffectView alloc] initWithEffect:blur];
        bv.frame = _glassView.bounds;
        bv.userInteractionEnabled = NO;
        [_glassView addSubview:bv];

        CAGradientLayer *sheen = [CAGradientLayer layer];
        sheen.frame = _glassView.bounds;
        sheen.colors = @[(__bridge id)[UIColor colorWithWhite:1.0 alpha:0.60].CGColor,
                         (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
        sheen.startPoint = CGPointMake(0.5, 0.0);
        sheen.endPoint   = CGPointMake(0.5, 0.65);
        [_glassView.layer addSublayer:sheen];

        CABasicAnimation *breathe = [CABasicAnimation animationWithKeyPath:@"opacity"];
        breathe.fromValue = @0.6; breathe.toValue = @0.95;
        breathe.duration = 2.6; breathe.autoreverses = YES; breathe.repeatCount = HUGE_VALF;
        [sheen addAnimation:breathe forKey:@"fg_breathe"];

        CGFloat px = 1.0 / [UIScreen mainScreen].scale;
        _glassView.layer.borderWidth = px;
        _glassView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;

        UILabel *t = [[UILabel alloc] initWithFrame:self.bounds];
        t.text = @"改"; t.textColor = [UIColor whiteColor];
        t.font = [UIFont boldSystemFontOfSize:19];
        t.textAlignment = NSTextAlignmentCenter;
        t.userInteractionEnabled = NO;
        [self addSubview:t];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(fg_pan:)];
        [self addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(fg_tap:)];
        [tap requireGestureRecognizerToFail:pan];
        [self addGestureRecognizer:tap];
    }
    return self;
}
- (void)fg_pan:(UIPanGestureRecognizer *)g {
    UIView *sv = self.superview; if (!sv) return;
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:sv]; CGPoint c = self.center;
        c.x += t.x; c.y += t.y;
        CGFloat hw = self.frame.size.width/2.0, hh = self.frame.size.height/2.0;
        c.x = MAX(hw, MIN(c.x, sv.bounds.size.width - hw));
        c.y = MAX(hh, MIN(c.y, sv.bounds.size.height - hh));
        self.center = c; [g setTranslation:CGPointZero inView:sv];
    } else if (g.state == UIGestureRecognizerStateEnded) {
        CGFloat W = sv.bounds.size.width; CGPoint c = self.center;
        CGFloat margin = self.frame.size.width/2.0 + 8.0;
        c.x = (c.x < W/2.0) ? margin : (W - margin);
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut
            animations:^{ self.center = c; } completion:nil];
    }
}
- (void)fg_tap:(UITapGestureRecognizer *)g {
    if (g_panel) { [g_panel fg_close]; return; }
    UIWindow *kw = fg_keyWindow(); if (!kw) return;
    CGFloat pw = 280, ph = 340;
    g_panel = [[FloatGlassPanel alloc] initWithFrame:
        CGRectMake((kw.bounds.size.width - pw)/2.0, (kw.bounds.size.height - ph)/2.0, pw, ph)];
    [kw addSubview:g_panel];
    [kw bringSubviewToFront:g_panel];
}
@end

// ===== 面板 =====
@implementation FloatGlassPanel
- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.42; self.layer.shadowRadius = 22;
        self.layer.shadowOffset = CGSizeMake(0, 8);
        self.layer.cornerRadius = 26; self.clipsToBounds = YES;
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialLight];
        UIVisualEffectView *bv = [[UIVisualEffectView alloc] initWithEffect:blur];
        bv.frame = self.bounds;
        bv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        bv.userInteractionEnabled = NO;
        [self addSubview:bv];

        CAGradientLayer *sheen = [CAGradientLayer layer];
        sheen.frame = self.bounds;
        sheen.colors = @[(__bridge id)[UIColor colorWithWhite:1.0 alpha:0.55].CGColor,
                         (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
        sheen.startPoint = CGPointMake(0.5, 0.0); sheen.endPoint = CGPointMake(0.5, 0.60);
        [self.layer addSublayer:sheen];

        CGFloat px = 1.0 / [UIScreen mainScreen].scale;
        self.layer.borderWidth = px;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 14, CGRectGetWidth(self.bounds), 22)];
        title.text = @"下方了改";
        title.textAlignment = NSTextAlignmentCenter;
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:16];
        title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self addSubview:title];

        g_btns = [NSMutableArray array];
        NSArray *defs = @[ @[@"kill", @"秒杀", @"全场怪即死"],
                           @[@"inv",  @"无敌", @"己方不掉血"],
                           @[@"cd",   @"攻速", @"OFF→x2→x4→x8"],
                           @[@"ad",   @"免广告", @"跳广告直接得奖"],
                           @[@"eng",  @"变速", @"全局 OFF→x2→x4→x8"] ];
        for (int i = 0; i < 5; i++) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.frame = CGRectMake(16, 44 + i * 50, CGRectGetWidth(self.bounds) - 32, 42);
            btn.layer.cornerRadius = 12;
            btn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.5];
            btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
            btn.tag = i;
            [btn addTarget:self action:@selector(fg_toggle:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:btn];
            [g_btns addObject:btn];
            objc_setAssociatedObject(btn, "key", defs[i][0], OBJC_ASSOCIATION_RETAIN);
            objc_setAssociatedObject(btn, "name", defs[i][1], OBJC_ASSOCIATION_RETAIN);
        }
        [self refreshButtons];

        g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, CGRectGetHeight(self.bounds) - 42, CGRectGetWidth(self.bounds) - 32, 26)];
        g_statusLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
        g_statusLabel.font = [UIFont systemFontOfSize:11];
        g_statusLabel.textAlignment = NSTextAlignmentCenter;
        g_statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [self addSubview:g_statusLabel];
        updateStatusLabel();
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(fg_drag:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}
- (void)refreshButtons {
    NSArray *lbls = @[@"OFF", @"x2", @"x4", @"x8"];
    for (int i = 0; i < 5; i++) {
        UIButton *btn = g_btns[i];
        NSString *name = objc_getAssociatedObject(btn, "name");
        NSString *val = nil;
        BOOL on = NO;
        if (i == 0) { on = g_kill; val = on ? @"ON" : @"OFF"; }
        else if (i == 1) { on = g_inv; val = on ? @"ON" : @"OFF"; }
        else if (i == 2) { on = g_cd > 0; val = lbls[g_cd]; }
        else if (i == 3) { on = g_ad; val = on ? @"ON" : @"OFF"; }
        else if (i == 4) { on = g_eng > 0; val = lbls[g_eng]; }
        [btn setTitle:[NSString stringWithFormat:@"  %@  %@", name, val] forState:UIControlStateNormal];
        btn.backgroundColor = on ? [UIColor colorWithRed:0.13 green:0.55 blue:0.27 alpha:0.88]
                                 : [UIColor colorWithWhite:0.18 alpha:0.55];
        [btn setTitleColor:(on ? UIColor.whiteColor : [UIColor colorWithWhite:1.0 alpha:0.65])
                  forState:UIControlStateNormal];
    }
}
- (void)fg_toggle:(UIButton *)btn {
    int i = (int)btn.tag;
    if (i == 0) { g_kill = !g_kill; saveFlag(@"kill", g_kill); syncFlagToJS(@"kill", g_kill); }
    else if (i == 1) { g_inv = !g_inv; saveFlag(@"inv", g_inv); syncFlagToJS(@"inv", g_inv); }
    else if (i == 2) { g_cd = (g_cd + 1) % 4; saveInt(@"cd", g_cd); syncSpdToJS(@"cd", g_cd); }
    else if (i == 3) { g_ad = !g_ad; saveFlag(@"ad", g_ad); syncFlagToJS(@"ad", g_ad); }
    else if (i == 4) { g_eng = (g_eng + 1) % 4; saveInt(@"eng", g_eng); syncSpdToJS(@"eng", g_eng); }
    [self refreshButtons];
    xlog(@"toggle idx=%d kill=%d inv=%d cd=%d ad=%d eng=%d", i, g_kill, g_inv, g_cd, g_ad, g_eng);
}
- (void)fg_close {
    [self removeFromSuperview];
    if (g_panel == self) g_panel = nil;
    g_statusLabel = nil;
}
- (void)fg_drag:(UIPanGestureRecognizer *)g {
    UIView *sv = self.superview; if (!sv) return;
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:sv]; CGPoint c = self.center;
        c.x += t.x; c.y += t.y;
        CGFloat hw = self.frame.size.width/2.0, hh = self.frame.size.height/2.0;
        c.x = MAX(hw, MIN(c.x, sv.bounds.size.width - hw));
        c.y = MAX(hh, MIN(c.y, sv.bounds.size.height - hh));
        self.center = c; [g setTranslation:CGPointZero inView:sv];
    }
}
@end

// ===== 工具 =====
static UIWindow *fg_keyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (!app) return nil;
    for (UIScene *s in app.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            ((UIWindowScene *)s).activationState == UISceneActivationStateForegroundActive) {
            UIWindowScene *ws = (UIWindowScene *)s;
            for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
            for (UIWindow *w in ws.windows) if (w.rootViewController) return w;
            if (ws.windows.count) return ws.windows.firstObject;
        }
    }
    for (UIWindow *w in app.windows) if (w.isKeyWindow) return w;
    return app.keyWindow;
}

static void fg_toast(NSString *msg) {
    UIWindow *kw = fg_keyWindow(); if (!kw) return;
    UILabel *lab = [[UILabel alloc] init];
    lab.text = msg;
    lab.textColor = [UIColor whiteColor];
    lab.font = [UIFont systemFontOfSize:13];
    lab.textAlignment = NSTextAlignmentCenter;
    lab.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.72];
    lab.layer.cornerRadius = 10; lab.clipsToBounds = YES;
    lab.numberOfLines = 0;
    [lab sizeToFit];
    CGFloat w = MIN(lab.frame.size.width + 28, kw.bounds.size.width - 40);
    CGFloat h = lab.frame.size.height + 16;
    lab.frame = CGRectMake((kw.bounds.size.width - w)/2.0, kw.bounds.size.height - 110, w, h);
    lab.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [kw addSubview:lab];
    [kw bringSubviewToFront:lab];
    [UIView animateWithDuration:0.35 delay:2.0 options:0
        animations:^{ lab.alpha = 0; }
        completion:^(BOOL f) { [lab removeFromSuperview]; }];
}

static int g_ensureTries = 0;
static void fg_ensureButton(void) {
    if (!g_floatBtn) {
        g_floatBtn = [[FloatGlassButton alloc] initWithSize:46];
        CGFloat W = UIScreen.mainScreen.bounds.size.width;
        CGFloat H = UIScreen.mainScreen.bounds.size.height;
        g_floatBtn.center = CGPointMake(W - 32, H / 2.0);
    }
    UIWindow *kw = fg_keyWindow();
    if (kw) {
        if (g_floatBtn.superview != kw) [kw addSubview:g_floatBtn];
        [kw bringSubviewToFront:g_floatBtn];
    } else if (g_ensureTries < 24) {
        g_ensureTries++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ fg_ensureButton(); });
    }
}

// ===== 入口 =====
static BOOL fg_shouldActivate(NSString *bid, NSString *exe) {
    return [bid isEqualToString:@"com.feiyu.freakout"] || [exe isEqualToString:@"xxgame-mobile"];
}

__attribute__((constructor)) static void xxc_ctor(void) {
    @autoreleasepool {
        NSBundle *mb = NSBundle.mainBundle;
        NSString *bid = mb.bundleIdentifier ?: @"";
        NSString *exe = mb.executablePath.lastPathComponent ?: @"";
        if (!fg_shouldActivate(bid, exe)) return;

        loadFlags();
        g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/xxcheat_dylib.log"];
        xlog(@"XXCFloat loaded bid=%@ exe=%@ flags kill=%d inv=%d cd=%d ad=%d eng=%d", bid, exe, g_kill, g_inv, g_cd, g_ad, g_eng);

        // se 引擎偏移定位
        const struct mach_header *hdr = _dyld_get_image_header(0);
        if (hdr) {
            g_execBase = (uint64_t)hdr;
            g_eval = (se_eval_t)(g_execBase + SE_EVALSTRING_RVA);
            xlog(@"base=0x%llx eval=0x%llx instGv=0x%llx",
                 (unsigned long long)g_execBase,
                 (unsigned long long)(g_execBase + SE_EVALSTRING_RVA),
                 (unsigned long long)(g_execBase + SE_INSTANCE_RVA));
        } else {
            xlog(@"ERROR: no exec image");
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            fg_toast(@"XXCheat 已加载");
            fg_ensureButton();
            [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
                injectTick();
                if (g_injected) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        updateStatusLabel();
                    });
                    [t invalidate];
                }
            }];
            [NSNotificationCenter.defaultCenter
                addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *n) {
                            if (g_floatBtn.superview) [g_floatBtn.superview bringSubviewToFront:g_floatBtn];
                            else fg_ensureButton();
                        }];
        });
    }
}
