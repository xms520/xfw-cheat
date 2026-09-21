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
static BOOL g_kill = NO, g_inv = NO, g_cd = NO;

static NSString *UDKey(NSString *k) { return [NSString stringWithFormat:@"xxc_%@", k]; }
static void loadFlags(void) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    g_kill = [ud boolForKey:UDKey(@"kill")];
    g_inv  = [ud boolForKey:UDKey(@"inv")];
    g_cd   = [ud boolForKey:UDKey(@"cd")];
}
static void saveFlag(NSString *k, BOOL v) {
    [[NSUserDefaults standardUserDefaults] setBool:v forKey:UDKey(k)];
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
    "LyoqCiAqIFhYQ2hlYXQgdjMg4oCUIOS4i+aWueS6hiAoQ29jb3MgMy44LjcganNiIC8gVjgg5byV5pOOKQogKiDms6jlhaXm"
    "lrnlvI/vvJpuYXRpdmUgZHlsaWIg6YCa6L+HIHNlOjpTY3JpcHRFbmdpbmU6OmV2YWxTdHJpbmcg5rOo5YWl5pys5paH5Lu2"
    "CiAqICAg56eS5p2AICA9IOi3n+i4qiBCYXR0bGVNb25zdGVyIOWunuS+i++8jHRpY2sg55u05YaZIF9ocD0wICsgc3RhdGU9"
    "RGllICsgcmVjb3ZlcnlWaWV3ICsgYmF0dGxlLnJlbW92ZU1vbnN0ZXIKICogICDml6DmlYwgID0g5YyF6KOFIEJhdHRsZVJv"
    "bGVCYXNlL0JhdHRsZVdhbGwvQmF0dGxlTGlmZVN1bW1vbmVkQ3JlYXR1cmVzIOeahCBocCBzZXR0ZXLvvIzlt7Hmlrkocm9s"
    "ZVR5cGUhPT1Nb25zdGVyKeemgeWHj+ihgAogKiAgIOaXoENEICA9IEJhdHRsZVNraWxsLmdldFNraWxsQ0Qg6L+U5ZueIDAu"
    "MDHvvIjku4Xlt7HmlrnvvIzmgKrnianmioDog73kv53ljp9DRO+8iQogKiBVSSDnlLEgbmF0aXZlIEZsb2F0R2xhc3Mg5oKs"
    "5rWu56qX5o+Q5L6b77yM5pys5paH5Lu25Y+q5YGa6YC76L6RICsgX19YWEMg5qGlCiAqIOKaoO+4jyBCYXR0bGVEcm9wQ3Ry"
    "bC5tb25zdGVyRHJvcCDml6DluYLnrYnkv53miqQg4oaSIOenkuadgOiHquW4piBfX3hmd0tpbGxlZCDpmLLph40KICovCihm"
    "dW5jdGlvbiAoKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICBpZiAodHlwZW9mIHdpbmRvdyAhPT0gJ3VuZGVmaW5lZCcgJiYg"
    "d2luZG93Ll9fWFhDKSByZXR1cm47IC8vIOmYsumHjeWkjeazqOWFpQogICAgdmFyIFRBRyA9ICdbWFhDXSc7CiAgICB2YXIg"
    "VkVSID0gJ3YzJzsKICAgIHZhciBHID0gKHR5cGVvZiB3aW5kb3cgIT09ICd1bmRlZmluZWQnKSA/IHdpbmRvdyA6IGdsb2Jh"
    "bFRoaXM7CgogICAgZnVuY3Rpb24gbG9nKCkgewogICAgICAgIHZhciBzID0gVEFHICsgJyAnICsgQXJyYXkucHJvdG90eXBl"
    "LnNsaWNlLmNhbGwoYXJndW1lbnRzKS5tYXAoZnVuY3Rpb24gKHgpIHsKICAgICAgICAgICAgdHJ5IHsgcmV0dXJuICh4IGlu"
    "c3RhbmNlb2YgRXJyb3IpID8gKHgubWVzc2FnZSArICd8JyArICh4LnN0YWNrIHx8ICcnKS5zcGxpdCgnXG4nKVsxXSkgOiBT"
    "dHJpbmcoeCk7IH0KICAgICAgICAgICAgY2F0Y2ggKGUpIHsgcmV0dXJuICc/JzsgfQogICAgICAgIH0pLmpvaW4oJyAnKTsK"
    "ICAgICAgICB0cnkgeyBjb25zb2xlLmxvZyhzKTsgfSBjYXRjaCAoZSkge30KICAgICAgICB0cnkgeyBqc2JMb2cocyk7IH0g"
    "Y2F0Y2ggKGUpIHt9CiAgICB9CiAgICB2YXIgX2xvZ0xpbmVzID0gW107CiAgICBmdW5jdGlvbiBqc2JMb2cocykgewogICAg"
    "ICAgIF9sb2dMaW5lcy5wdXNoKHMpOwogICAgICAgIGlmIChfbG9nTGluZXMubGVuZ3RoID4gMzAwKSBfbG9nTGluZXMuc3Bs"
    "aWNlKDAsIF9sb2dMaW5lcy5sZW5ndGggLSAzMDApOwogICAgICAgIGlmIChfbG9nTGluZXMubGVuZ3RoICUgMjAgPT09IDEg"
    "JiYgdHlwZW9mIGpzYiAhPT0gJ3VuZGVmaW5lZCcgJiYganNiLmZpbGVVdGlscykgewogICAgICAgICAgICB0cnkgewogICAg"
    "ICAgICAgICAgICAganNiLmZpbGVVdGlscy53cml0ZVN0cmluZ1RvRmlsZShfbG9nTGluZXMuam9pbignXG4nKSwKICAgICAg"
    "ICAgICAgICAgICAgICBqc2IuZmlsZVV0aWxzLmdldFdyaXRhYmxlUGF0aCgpICsgJ3h4Y2hlYXQubG9nJyk7CiAgICAgICAg"
    "ICAgIH0gY2F0Y2ggKGUpIHt9CiAgICAgICAgfQogICAgfQoKICAgIC8vIC0tLS0tLS0tLS0g5qCH5b+X77yIbmF0aXZlIOmd"
    "ouadv+WPr+i/kOihjOaXtuimhueblu+8iSAtLS0tLS0tLS0tCiAgICB2YXIgRiA9IHsKICAgICAgICBraWxsOiBsc0dldCgn"
    "a2lsbCcpID09PSAnMScsCiAgICAgICAgaW52OiAgbHNHZXQoJ2ludicpID09PSAnMScsCiAgICAgICAgY2Q6ICAgbHNHZXQo"
    "J2NkJykgPT09ICcxJwogICAgfTsKICAgIGZ1bmN0aW9uIGxzR2V0KGspIHsgdHJ5IHsgcmV0dXJuIGxvY2FsU3RvcmFnZS5n"
    "ZXRJdGVtKCd4ZmNfJyArIGspIHx8ICcnOyB9IGNhdGNoIChlKSB7IHJldHVybiAnJzsgfSB9CiAgICBmdW5jdGlvbiBsc1Nl"
    "dChrLCB2KSB7IHRyeSB7IGxvY2FsU3RvcmFnZS5zZXRJdGVtKCd4ZmNfJyArIGssIHYgPyAnMScgOiAnMCcpOyB9IGNhdGNo"
    "IChlKSB7fSB9CgogICAgLy8gLS0tLS0tLS0tLSDlhajlsYDmoaXvvIhuYXRpdmUg6Z2i5p2/6LCD55So77yJIC0tLS0tLS0t"
    "LS0KICAgIEcuX19YWEMgPSB7CiAgICAgICAgdmVyOiBWRVIsCiAgICAgICAgc2V0RmxhZzogZnVuY3Rpb24gKGssIHYpIHsK"
    "ICAgICAgICAgICAgaWYgKGsgaW4gRikgewogICAgICAgICAgICAgICAgRltrXSA9ICEhdjsKICAgICAgICAgICAgICAgIGxz"
    "U2V0KGssIEZba10pOwogICAgICAgICAgICAgICAgbG9nKCdzZXRGbGFnJywgaywgRltrXSk7CiAgICAgICAgICAgIH0KICAg"
    "ICAgICB9LAogICAgICAgIGdldEZsYWdzOiBmdW5jdGlvbiAoKSB7IHJldHVybiB7IGtpbGw6IEYua2lsbCwgaW52OiBGLmlu"
    "diwgY2Q6IEYuY2QgfTsgfSwKICAgICAgICBzdGF0czogeyBraWxsczogMCwgbW9uc3RlcnM6IDAgfQogICAgfTsKCiAgICAv"
    "LyAtLS0tLS0tLS0tIFN5c3RlbUpTIOaooeWdl+WumuS9jSAtLS0tLS0tLS0tCiAgICB2YXIgTU9EID0gJ2NodW5rczovLy9f"
    "dmlydHVhbC8nOwogICAgdmFyIE5FRUQgPSBbCiAgICAgICAgWydtb25zdGVyJywgTU9EICsgJ0JhdHRsZU1vbnN0ZXIudHMn"
    "LCAgICAgICAgJ0JhdHRsZU1vbnN0ZXInXSwKICAgICAgICBbJ2Jhc2UnLCAgICBNT0QgKyAnQmF0dGxlUm9sZUJhc2UudHMn"
    "LCAgICAgICAnQmF0dGxlUm9sZUJhc2UnXSwKICAgICAgICBbJ3NraWxsJywgICBNT0QgKyAnQmF0dGxlU2tpbGwudHMnLCAg"
    "ICAgICAgICAnQmF0dGxlU2tpbGwnXSwKICAgICAgICBbJ3dhbGwnLCAgICBNT0QgKyAnQmF0dGxlV2FsbC50cycsICAgICAg"
    "ICAgICAnQmF0dGxlV2FsbCddLAogICAgICAgIFsnbGlmZScsICAgIE1PRCArICdCYXR0bGVMaWZlU3VtbW9uZWRDcmVhdHVy"
    "ZXMudHMnLCAnQmF0dGxlTGlmZVN1bW1vbmVkQ3JlYXR1cmVzJ10sCiAgICAgICAgWydtb3ZlJywgICAgTU9EICsgJ01vbnN0"
    "ZXJNb3ZlQ3RybC50cycsICAgICAgJ01vbnN0ZXJNb3ZlQ3RybCddLAogICAgICAgIFsnc29ydCcsICAgIE1PRCArICdNb25z"
    "dGVyU29ydEN0cmwudHMnLCAgICAgICdNb25zdGVyU29ydEN0cmwnXSwKICAgICAgICBbJ2Ryb3AnLCAgICBNT0QgKyAnQmF0"
    "dGxlRHJvcEN0cmwudHMnLCAgICAgICAnQmF0dGxlRHJvcEN0cmwnXSwKICAgICAgICBbJ3JlYycsICAgICBNT0QgKyAnQmF0"
    "dGxlUmVjb3JkUGx1Z2luLnRzJywgICAnQmF0dGxlUmVjb3JkUGx1Z2luJ10KICAgIF07CiAgICB2YXIgQ0xTID0ge307CiAg"
    "ICBmdW5jdGlvbiBnZXROcyhrZXksIGV4cCkgewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIHZhciBucyA9IFN5c3RlbS5n"
    "ZXQoa2V5KTsKICAgICAgICAgICAgcmV0dXJuIChucyAmJiBuc1tleHBdKSA/IG5zW2V4cF0gOiBudWxsOwogICAgICAgIH0g"
    "Y2F0Y2ggKGUpIHsgcmV0dXJuIG51bGw7IH0KICAgIH0KICAgIHZhciBwYXRjaERvbmUgPSBmYWxzZTsKICAgIGZ1bmN0aW9u"
    "IHRyeVBhdGNoKCkgewogICAgICAgIHZhciBvayA9IHRydWU7CiAgICAgICAgZm9yICh2YXIgaSA9IDA7IGkgPCBORUVELmxl"
    "bmd0aDsgaSsrKSB7CiAgICAgICAgICAgIHZhciBpdCA9IE5FRURbaV07CiAgICAgICAgICAgIGlmICghQ0xTW2l0WzBdXSkg"
    "ewogICAgICAgICAgICAgICAgdmFyIGMgPSBnZXROcyhpdFsxXSwgaXRbMl0pOwogICAgICAgICAgICAgICAgaWYgKGMpIENM"
    "U1tpdFswXV0gPSBjOyBlbHNlIG9rID0gZmFsc2U7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgaWYgKCFvaykg"
    "cmV0dXJuIGZhbHNlOwogICAgICAgIGlmIChwYXRjaERvbmUpIHJldHVybiB0cnVlOwogICAgICAgIHBhdGNoRG9uZSA9IHRy"
    "dWU7CiAgICAgICAgZG9QYXRjaCgpOwogICAgICAgIHJldHVybiB0cnVlOwogICAgfQoKICAgIHZhciBNT05TID0gbmV3IFNl"
    "dCgpOwogICAgdmFyIFJPTEVfTU9OU1RFUiA9IDM7IC8vIEJhdHRsZVJvbGVUeXBlLk1vbnN0ZXIKICAgIHZhciBTVF9ESUUg"
    "PSAzOyAgICAgICAvLyBNb25zdGVyU3RhdGVFbnVtLkRpZQoKICAgIGZ1bmN0aW9uIGRvUGF0Y2goKSB7CiAgICAgICAgLy8g"
    "LS0tLSDml6DmlYzvvJrljIXoo4UgaHAgc2V0dGVy77yI5bex5pa556aB5YeP6KGA77yb5LiN6K6+IGludmluY2libGVTZW1h"
    "cGhvcmXvvIxhbGl2ZSDkvJrlgYfmrbvvvIkgLS0tLQogICAgICAgIHdyYXBIcChDTFMuYmFzZSk7IHdyYXBIcChDTFMud2Fs"
    "bCk7IHdyYXBIcChDTFMubGlmZSk7CiAgICAgICAgbG9nKCdpbnYgcGF0Y2ggb2snKTsKICAgICAgICAvLyAtLS0tIOenkuad"
    "gO+8mui3n+i4quaAqueJqeWunuS+i++8iOaxoOWkjeeUqCBpbml0IOa4heagh+iusCAvIG9uRnJlZSDnp7vpmaTvvIkgLS0t"
    "LQogICAgICAgIHZhciBCTSA9IENMUy5tb25zdGVyOwogICAgICAgIHZhciBvSW5pdCA9IEJNLnByb3RvdHlwZS5pbml0Owog"
    "ICAgICAgIEJNLnByb3RvdHlwZS5pbml0ID0gZnVuY3Rpb24gKCkgewogICAgICAgICAgICB0cnkgeyB0aGlzLl9feGZ3S2ls"
    "bGVkID0gMDsgTU9OUy5hZGQodGhpcyk7IH0gY2F0Y2ggKGUpIHt9CiAgICAgICAgICAgIHJldHVybiBvSW5pdC5hcHBseSh0"
    "aGlzLCBhcmd1bWVudHMpOwogICAgICAgIH07CiAgICAgICAgdmFyIG9GcmVlID0gQk0ucHJvdG90eXBlLm9uRnJlZTsKICAg"
    "ICAgICBCTS5wcm90b3R5cGUub25GcmVlID0gZnVuY3Rpb24gKCkgeyBNT05TLmRlbGV0ZSh0aGlzKTsgcmV0dXJuIG9GcmVl"
    "LmFwcGx5KHRoaXMsIGFyZ3VtZW50cyk7IH07CiAgICAgICAgbG9nKCdraWxsIHRyYWNrIG9rJyk7CiAgICAgICAgLy8gLS0t"
    "LSDmlLvpgJ/vvJpnZXRTa2lsbENEIC8gNO+8iOS7heW3seaWue+8m19zcmMg5pyq5Yid5aeL5YyW6KeG5Li65bex5pa577yb"
    "5Y6f5pegQ0TpnIDmsYLlj6/mlLnlm54gMC4wMe+8iSAtLS0tCiAgICAgICAgdmFyIEJTID0gQ0xTLnNraWxsOwogICAgICAg"
    "IHZhciBvQ0QgPSBCUy5wcm90b3R5cGUuZ2V0U2tpbGxDRDsKICAgICAgICBCUy5wcm90b3R5cGUuZ2V0U2tpbGxDRCA9IGZ1"
    "bmN0aW9uICgpIHsKICAgICAgICAgICAgaWYgKEYuY2QgJiYgKCF0aGlzLl9zcmMgfHwgdGhpcy5fc3JjLnJvbGVUeXBlICE9"
    "PSBST0xFX01PTlNURVIpKSByZXR1cm4gb0NELmNhbGwodGhpcykgKiAwLjI1OwogICAgICAgICAgICByZXR1cm4gb0NELmNh"
    "bGwodGhpcyk7CiAgICAgICAgfTsKICAgICAgICBsb2coJ2NkIHBhdGNoIG9rJyk7CiAgICB9CgogICAgZnVuY3Rpb24gd3Jh"
    "cEhwKGNscykgewogICAgICAgIHZhciBkID0gT2JqZWN0LmdldE93blByb3BlcnR5RGVzY3JpcHRvcihjbHMucHJvdG90eXBl"
    "LCAnaHAnKTsKICAgICAgICBpZiAoIWQgfHwgIWQuc2V0KSB7IGxvZygnd3JhcEhwIEZBSUwnLCBjbHMgJiYgY2xzLm5hbWUp"
    "OyByZXR1cm47IH0KICAgICAgICB2YXIgb3JpZyA9IGQuc2V0OwogICAgICAgIE9iamVjdC5kZWZpbmVQcm9wZXJ0eShjbHMu"
    "cHJvdG90eXBlLCAnaHAnLCB7CiAgICAgICAgICAgIGdldDogZC5nZXQsCiAgICAgICAgICAgIHNldDogZnVuY3Rpb24gKHYp"
    "IHsKICAgICAgICAgICAgICAgIGlmIChGLmludiAmJiB0aGlzLl9ocCA+IDAgJiYgdiA8IHRoaXMuX2hwICYmIHRoaXMuX3Jv"
    "bGVUeXBlICE9PSBST0xFX01PTlNURVIpIHJldHVybjsKICAgICAgICAgICAgICAgIG9yaWcuY2FsbCh0aGlzLCB2KTsKICAg"
    "ICAgICAgICAgfSwKICAgICAgICAgICAgY29uZmlndXJhYmxlOiB0cnVlLAogICAgICAgICAgICBlbnVtZXJhYmxlOiBmYWxz"
    "ZQogICAgICAgIH0pOwogICAgfQoKICAgIC8vIC0tLS0tLS0tLS0g56eS5p2AIHRpY2sgLS0tLS0tLS0tLQogICAgLy8gcmVt"
    "b3ZlTW9uc3RlciDlhoXpg6ggbW9uc3RlckRyb3Ag5a+55Yia5Ye655Sf5pegIHZpZXcg55qE5oCq5Lya5oqbIF9maW5kQ29t"
    "cG9uZW50KG51bGwpCiAgICAvLyDihpIg5YiG5q2l56e76Zmk77yaZHJvcC9tb3ZlL3NvcnQvcmVjIOWQhOiHqueLrOeriyB0"
    "cnnvvIzkv53or4HmgKrkuIDlrprooqvnp7vlh7rliJfooajvvIjlkKbliJnljaHov4flhbPliKTlrprvvIkKICAgIGZ1bmN0"
    "aW9uIGtpbGxPbmUobSkgewogICAgICAgIG0uX2hwID0gMDsgICAgICAgICAgICAgIC8vIOebtOWGmeWtl+aute+8mue7leW8"
    "gCBzZXR0ZXIg55qEIEJvc3Mg5oiY5a6I5Y2rCiAgICAgICAgbS5fc3RhdGUgPSBTVF9ESUU7CiAgICAgICAgdHJ5IHsgaWYg"
    "KG0ucmVjb3ZlcnlWaWV3KSBtLnJlY292ZXJ5VmlldygpOyB9IGNhdGNoIChlKSB7fQogICAgICAgIHZhciBidCA9IG0uYmF0"
    "dGxlOwogICAgICAgIGlmICghYnQpIHJldHVybjsKICAgICAgICB0cnkgeyBpZiAoQ0xTLmRyb3AgJiYgYnQuZ2V0Q3RybCkg"
    "YnQuZ2V0Q3RybChDTFMuZHJvcCkubW9uc3RlckRyb3AobSk7IH0gY2F0Y2ggKGUpIHt9CiAgICAgICAgdHJ5IHsgaWYgKENM"
    "Uy5tb3ZlICYmIGJ0LmdldEN0cmwpIGJ0LmdldEN0cmwoQ0xTLm1vdmUpLnJlbW92ZU1vbnN0ZXIobSk7IH0gY2F0Y2ggKGUp"
    "IHt9CiAgICAgICAgdHJ5IHsgaWYgKENMUy5zb3J0ICYmIGJ0LmdldEN0cmwpIGJ0LmdldEN0cmwoQ0xTLnNvcnQpLnJlbW92"
    "ZU1vbnN0ZXIobSk7IH0gY2F0Y2ggKGUpIHt9CiAgICAgICAgdHJ5IHsgaWYgKENMUy5yZWMgJiYgYnQuZ2V0UGx1Z2luKSBi"
    "dC5nZXRQbHVnaW4oQ0xTLnJlYykucmVtb3ZlTW9uc3RlcihtKTsgfSBjYXRjaCAoZSkge30KICAgIH0KCiAgICBmdW5jdGlv"
    "biBraWxsVGljaygpIHsKICAgICAgICBpZiAoIUYua2lsbCB8fCBNT05TLnNpemUgPT09IDApIHsgRy5fX1hYQy5zdGF0cy5t"
    "b25zdGVycyA9IE1PTlMuc2l6ZTsgcmV0dXJuOyB9CiAgICAgICAgdmFyIG4gPSAwOwogICAgICAgIE1PTlMuZm9yRWFjaChm"
    "dW5jdGlvbiAobSkgewogICAgICAgICAgICBpZiAobS5fX3hmd0tpbGxlZCkgcmV0dXJuOwogICAgICAgICAgICBpZiAodHlw"
    "ZW9mIG0uX2hwICE9PSAnbnVtYmVyJyB8fCAhbS5iYXR0bGUpIHJldHVybjsKICAgICAgICAgICAgaWYgKG0uX2hwID4gMCkg"
    "ewogICAgICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgICAgICBraWxsT25lKG0pOwogICAgICAgICAgICAgICAg"
    "ICAgIG4rKzsKICAgICAgICAgICAgICAgIH0gY2F0Y2ggKGUpIHsgbG9nKCdraWxsIGV4YycsIGUpOyB9CiAgICAgICAgICAg"
    "IH0KICAgICAgICB9KTsKICAgICAgICBpZiAobikgeyBHLl9fWFhDLnN0YXRzLmtpbGxzICs9IG47IGxvZygna2lsbCBuPScg"
    "KyBuICsgJyB0b3RhbD0nICsgRy5fX1hYQy5zdGF0cy5raWxscyk7IH0KICAgICAgICBHLl9fWFhDLnN0YXRzLm1vbnN0ZXJz"
    "ID0gTU9OUy5zaXplOwogICAgfQoKICAgIC8vIC0tLS0tLS0tLS0g5a6a5pe25Zmo77yIbmF0aXZlIHNldEludGVydmFsIOe8"
    "uuWkseaXtuW8leaTjuW4p+mpseWKqOWFnOW6le+8iSAtLS0tLS0tLS0tCiAgICBmdW5jdGlvbiBldmVyeShtcywgZm4pIHsK"
    "ICAgICAgICBpZiAodHlwZW9mIHNldEludGVydmFsID09PSAnZnVuY3Rpb24nKSByZXR1cm4gc2V0SW50ZXJ2YWwoZm4sIG1z"
    "KTsKICAgICAgICBTeXN0ZW0uaW1wb3J0KCdjYycpLnRoZW4oZnVuY3Rpb24gKGNjKSB7CiAgICAgICAgICAgIHRyeSB7IGNj"
    "LmRpcmVjdG9yLm9uKGNjLkRpcmVjdG9yLkVWRU5UX0JFRk9SRV9VUERBVEUsIGZ1bmN0aW9uICgpIHsgZm4oKTsgfSk7IH0g"
    "Y2F0Y2ggKGUpIHsgbG9nKCdmcmFtZSB0aWNrIGV4YycsIGUpOyB9CiAgICAgICAgfSkuY2F0Y2goZnVuY3Rpb24gKCkge30p"
    "OwogICAgfQogICAgdmFyIHQwID0gRGF0ZS5ub3coKSwgd2FybmVkID0gZmFsc2U7CiAgICBmdW5jdGlvbiBwb2xsKCkgewog"
    "ICAgICAgIHZhciBwYXRjaGVkID0gdHJ5UGF0Y2goKTsKICAgICAgICBpZiAoIXBhdGNoZWQgJiYgIXdhcm5lZCAmJiBEYXRl"
    "Lm5vdygpIC0gdDAgPiA5MDAwMCkgeyB3YXJuZWQgPSB0cnVlOyBsb2coJ1dBUk4gY2xhc3Mgd2FpdCB0aW1lb3V0Jyk7IH0K"
    "ICAgICAgICBraWxsVGljaygpOwogICAgfQogICAgZXZlcnkoMjUwLCBwb2xsKTsKICAgIC8vIG5hdGl2ZSDpqozor4HmoIfo"
    "rrDvvJrms6jlhaXmiJDlip/lkI7lhpnmlofku7YKICAgIHRyeSB7CiAgICAgICAgaWYgKHR5cGVvZiBqc2IgIT09ICd1bmRl"
    "ZmluZWQnICYmIGpzYi5maWxlVXRpbHMpIHsKICAgICAgICAgICAganNiLmZpbGVVdGlscy53cml0ZVN0cmluZ1RvRmlsZShT"
    "dHJpbmcoVkVSKSwKICAgICAgICAgICAgICAgIGpzYi5maWxlVXRpbHMuZ2V0V3JpdGFibGVQYXRoKCkgKyAneHhjaGVhdF9p"
    "bmplY3RlZC5mbGFnJyk7CiAgICAgICAgfQogICAgfSBjYXRjaCAoZSkge30KICAgIGxvZygnbG9hZGVkJywgVkVSLCAnZmxh"
    "Z3Mga2lsbD0nICsgRi5raWxsLCAnaW52PScgKyBGLmludiwgJ2NkPScgKyBGLmNkKTsKfSkoKTsK";

static NSString *decodeCheat(void) {
    NSData *d = [[NSData alloc] initWithBase64EncodedString:@(g_cheatB64) options:0];
    if (!d) return nil;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

static void syncFlagToJS(NSString *key, BOOL val) {
    if (!g_injected) return;
    seEval([NSString stringWithFormat:@"__XXC.setFlag('%@', %@);", key, val ? @"true" : @"false"]);
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
        syncFlagToJS(@"cd",   g_cd);
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
    CGFloat pw = 280, ph = 300;
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
                           @[@"cd",   @"攻速", @"技能释放x4"] ];
        for (int i = 0; i < 3; i++) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.frame = CGRectMake(16, 44 + i * 54, CGRectGetWidth(self.bounds) - 32, 46);
            btn.layer.cornerRadius = 12;
            btn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.5];
            btn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
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
    NSArray *flags = @[ @(g_kill), @(g_inv), @(g_cd) ];
    for (int i = 0; i < 3; i++) {
        UIButton *btn = g_btns[i];
        NSString *name = objc_getAssociatedObject(btn, "name");
        NSNumber *num = flags[i];
        BOOL on = num.boolValue;
        [btn setTitle:[NSString stringWithFormat:@"  %@  %@", name, on ? @"ON" : @"OFF"] forState:UIControlStateNormal];
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
    else if (i == 2) { g_cd = !g_cd; saveFlag(@"cd", g_cd); syncFlagToJS(@"cd", g_cd); }
    [self refreshButtons];
    xlog(@"toggle idx=%d kill=%d inv=%d cd=%d", i, g_kill, g_inv, g_cd);
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
        xlog(@"XXCFloat loaded bid=%@ exe=%@ flags kill=%d inv=%d cd=%d", bid, exe, g_kill, g_inv, g_cd);

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
