// XXCheatDylib v1 — 下方了 (com.feiyu.freakout / xxgame-mobile) Cocos 3.8.7 jsb
// 原理：swizzle JSContext(-init/-initWithVirtualMachine:) 捕获游戏 context
//       → 主线程 NSTimer 识别（jsb+System 存在）→ evaluateScript 注入内嵌 cheat.js
// 零 hook C++、零二进制符号依赖；对非游戏 context 只读探测
#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

static IMP g_origInit = NULL;
static IMP g_origInitVM = NULL;
static NSHashTable *g_ctxs = nil;      // weak objects
static JSContext *g_gameCtx = nil;
static BOOL g_injected = NO;
static BOOL g_active = NO;             // bundle 防呆通过
static NSString *g_logPath = nil;

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

// ---------- swizzle hooks ----------
static void hookedInit(id self, SEL _cmd) {
    if (g_origInit) ((void (*)(id, SEL))g_origInit)(self, _cmd);
    if (g_active) [g_ctxs addObject:self];
}
static id hookedInitVM(id self, SEL _cmd, JSVirtualMachine *vm) {
    id r = ((id (*)(id, SEL, JSVirtualMachine *))g_origInitVM)(self, _cmd, vm);
    if (g_active) [g_ctxs addObject:self];
    return r;
}

// ---------- 内嵌 cheat.js (base64) ----------
static const char *g_cheatB64 =
    "LyoqCiAqIFhYQ2hlYXQgdjEg4oCUIOS4i+aWueS6hiAxLjAuNiAoQ29jb3MgQ3JlYXRvciAzLjguNyBqc2IpCiAqIOazqOWF"
    "peeCue+8mm1haW4uanMg5ZyoIHJlcXVpcmUoInNyYy9zeXN0ZW0uYnVuZGxlLmpzIikg5LmL5ZCOIHJlcXVpcmUg5pys5paH"
    "5Lu2CiAqIOWOn+eQhu+8mui9ruivoiBTeXN0ZW1KUyByZWdpc3RyeSDmi7/muLjmiI/nsbsg4oaSIOWOn+WeiyBwYXRjaAog"
    "KiAgIOenkuadgCAgPSDot5/ouKogQmF0dGxlTW9uc3RlciDlrp7kvovvvIx0aWNrIOebtOaOpSBfaHA9MCArIHN0YXRlPURp"
    "ZSArIHJlY292ZXJ5VmlldyArIGJhdHRsZS5yZW1vdmVNb25zdGVyCiAqICAg5peg5pWMICA9IOWMheijhSBCYXR0bGVSb2xl"
    "QmFzZS9CYXR0bGVXYWxsL0JhdHRsZUxpZmVTdW1tb25lZENyZWF0dXJlcyDnmoQgaHAgc2V0dGVy77yM5bex5pa5KHJvbGVU"
    "eXBlIT09TW9uc3RlcinnpoHlh4/ooYAKICogICDml6BDRCAgPSBCYXR0bGVTa2lsbC5nZXRTa2lsbENEIOi/lOWbniAwLjAx"
    "CiAqIOKaoO+4jyDlr7nosaHmsaDlpI3nlKjvvJppbml0IOa4heagh+iusCAvIG9uRnJlZSDnp7vlh7rpm4blkIgKICog4pqg"
    "77iPIEJhdHRsZURyb3BDdHJsLm1vbnN0ZXJEcm9wIOaXoOW5guetieS/neaKpCDihpIg56eS5p2A55SoIF9feGZ3S2lsbGVk"
    "IOmYsumHjQogKi8KKGZ1bmN0aW9uICgpIHsKICAgICd1c2Ugc3RyaWN0JzsKICAgIHZhciBUQUcgPSAnW1hYQ10nOwogICAg"
    "dmFyIFZFUiA9ICd2Mic7CiAgICB0cnkgeyAodHlwZW9mIHdpbmRvdyAhPT0gJ3VuZGVmaW5lZCcgPyB3aW5kb3cgOiB0aGlz"
    "KS5fX1hYQyA9IHsgdmVyOiBWRVIgfTsgfSBjYXRjaCAoZSkge30KCiAgICBmdW5jdGlvbiBsb2coKSB7CiAgICAgICAgdmFy"
    "IHMgPSBUQUcgKyAnICcgKyBBcnJheS5wcm90b3R5cGUuc2xpY2UuY2FsbChhcmd1bWVudHMpLm1hcChmdW5jdGlvbiAoeCkg"
    "ewogICAgICAgICAgICB0cnkgeyByZXR1cm4gKHggaW5zdGFuY2VvZiBFcnJvcikgPyAoeC5tZXNzYWdlICsgJ3wnICsgKHgu"
    "c3RhY2sgfHwgJycpLnNwbGl0KCdcbicpWzFdKSA6IFN0cmluZyh4KTsgfQogICAgICAgICAgICBjYXRjaCAoZSkgeyByZXR1"
    "cm4gJz8nOyB9CiAgICAgICAgfSkuam9pbignICcpOwogICAgICAgIHRyeSB7IGNvbnNvbGUubG9nKHMpOyB9IGNhdGNoIChl"
    "KSB7fQogICAgICAgIHRyeSB7IGpzYkxvZyhzKTsgfSBjYXRjaCAoZSkge30KICAgIH0KCiAgICAvLyAtLS0tLS0tLS0tIOaW"
    "h+S7tuaXpeW/l++8iOWPr+WGmeebruW9le+8jOaWueS+v+ecn+acuuWPluivge+8iSAtLS0tLS0tLS0tCiAgICB2YXIgX2xv"
    "Z0xpbmVzID0gW107CiAgICBmdW5jdGlvbiBqc2JMb2cocykgewogICAgICAgIF9sb2dMaW5lcy5wdXNoKHMpOwogICAgICAg"
    "IGlmIChfbG9nTGluZXMubGVuZ3RoID4gNDAwKSBfbG9nTGluZXMuc3BsaWNlKDAsIF9sb2dMaW5lcy5sZW5ndGggLSA0MDAp"
    "OwogICAgICAgIGlmIChfbG9nTGluZXMubGVuZ3RoICUgMjAgPT09IDEgJiYgdHlwZW9mIGpzYiAhPT0gJ3VuZGVmaW5lZCcg"
    "JiYganNiLmZpbGVVdGlscykgewogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAganNiLmZpbGVVdGlscy53cml0"
    "ZVN0cmluZ1RvRmlsZShfbG9nTGluZXMuam9pbignXG4nKSwKICAgICAgICAgICAgICAgICAgICBqc2IuZmlsZVV0aWxzLmdl"
    "dFdyaXRhYmxlUGF0aCgpICsgJ3h4Y2hlYXQubG9nJyk7CiAgICAgICAgICAgIH0gY2F0Y2ggKGUpIHt9CiAgICAgICAgfQog"
    "ICAgfQoKICAgIC8vIC0tLS0tLS0tLS0g5byA5YWz5oyB5LmF5YyWIC0tLS0tLS0tLS0KICAgIHZhciBGID0gewogICAgICAg"
    "IGtpbGw6IGxzR2V0KCdraWxsJykgPT09ICcxJywKICAgICAgICBpbnY6ICBsc0dldCgnaW52JykgPT09ICcxJywKICAgICAg"
    "ICBjZDogICBsc0dldCgnY2QnKSA9PT0gJzEnCiAgICB9OwogICAgZnVuY3Rpb24gbHNHZXQoaykgeyB0cnkgeyByZXR1cm4g"
    "bG9jYWxTdG9yYWdlLmdldEl0ZW0oJ3hmY18nICsgaykgfHwgJyc7IH0gY2F0Y2ggKGUpIHsgcmV0dXJuICcnOyB9IH0KICAg"
    "IGZ1bmN0aW9uIGxzU2V0KGssIHYpIHsgdHJ5IHsgbG9jYWxTdG9yYWdlLnNldEl0ZW0oJ3hmY18nICsgaywgdiA/ICcxJyA6"
    "ICcwJyk7IH0gY2F0Y2ggKGUpIHt9IH0KCiAgICAvLyAtLS0tLS0tLS0tIOetieW+hSBTeXN0ZW1KUyDmqKHlnZcgLS0tLS0t"
    "LS0tLQogICAgdmFyIE1PRCA9ICdjaHVua3M6Ly8vX3ZpcnR1YWwvJzsKICAgIHZhciBORUVEID0gWwogICAgICAgIFsnbW9u"
    "c3RlcicsIE1PRCArICdCYXR0bGVNb25zdGVyLnRzJywgICAgICAgICdCYXR0bGVNb25zdGVyJ10sCiAgICAgICAgWydiYXNl"
    "JywgICAgTU9EICsgJ0JhdHRsZVJvbGVCYXNlLnRzJywgICAgICAgJ0JhdHRsZVJvbGVCYXNlJ10sCiAgICAgICAgWydza2ls"
    "bCcsICAgTU9EICsgJ0JhdHRsZVNraWxsLnRzJywgICAgICAgICAgJ0JhdHRsZVNraWxsJ10sCiAgICAgICAgWyd3YWxsJywg"
    "ICAgTU9EICsgJ0JhdHRsZVdhbGwudHMnLCAgICAgICAgICAgJ0JhdHRsZVdhbGwnXSwKICAgICAgICBbJ2xpZmUnLCAgICBN"
    "T0QgKyAnQmF0dGxlTGlmZVN1bW1vbmVkQ3JlYXR1cmVzLnRzJywgJ0JhdHRsZUxpZmVTdW1tb25lZENyZWF0dXJlcyddCiAg"
    "ICBdOwogICAgdmFyIENMUyA9IHt9OwoKICAgIGZ1bmN0aW9uIGdldE5zKGtleSwgZXhwKSB7CiAgICAgICAgdHJ5IHsKICAg"
    "ICAgICAgICAgdmFyIG5zID0gU3lzdGVtLmdldChrZXkpOwogICAgICAgICAgICByZXR1cm4gKG5zICYmIG5zW2V4cF0pID8g"
    "bnNbZXhwXSA6IG51bGw7CiAgICAgICAgfSBjYXRjaCAoZSkgeyByZXR1cm4gbnVsbDsgfQogICAgfQoKICAgIHZhciBwYXRj"
    "aERvbmUgPSBmYWxzZTsKICAgIGZ1bmN0aW9uIHRyeVBhdGNoKCkgewogICAgICAgIHZhciBvayA9IHRydWU7CiAgICAgICAg"
    "Zm9yICh2YXIgaSA9IDA7IGkgPCBORUVELmxlbmd0aDsgaSsrKSB7CiAgICAgICAgICAgIHZhciBpdCA9IE5FRURbaV07CiAg"
    "ICAgICAgICAgIGlmICghQ0xTW2l0WzBdXSkgewogICAgICAgICAgICAgICAgdmFyIGMgPSBnZXROcyhpdFsxXSwgaXRbMl0p"
    "OwogICAgICAgICAgICAgICAgaWYgKGMpIENMU1tpdFswXV0gPSBjOyBlbHNlIG9rID0gZmFsc2U7CiAgICAgICAgICAgIH0K"
    "ICAgICAgICB9CiAgICAgICAgaWYgKCFvaykgcmV0dXJuIGZhbHNlOwogICAgICAgIGlmIChwYXRjaERvbmUpIHJldHVybiB0"
    "cnVlOwogICAgICAgIHBhdGNoRG9uZSA9IHRydWU7CiAgICAgICAgZG9QYXRjaCgpOwogICAgICAgIHJldHVybiB0cnVlOwog"
    "ICAgfQoKICAgIC8vIC0tLS0tLS0tLS0g5Li7IHBhdGNoIC0tLS0tLS0tLS0KICAgIHZhciBNT05TID0gbmV3IFNldCgpOwog"
    "ICAgdmFyIGdfa2lsbHMgPSAwOwogICAgdmFyIFJPTEVfTU9OU1RFUiA9IDM7IC8vIEJhdHRsZVJvbGVUeXBlLk1vbnN0ZXIK"
    "ICAgIHZhciBTVF9ESUUgPSAzOyAgICAgICAvLyBNb25zdGVyU3RhdGVFbnVtLkRpZQoKICAgIGZ1bmN0aW9uIGRvUGF0Y2go"
    "KSB7CiAgICAgICAgLy8gLS0tLSDml6DmlYzvvJrljIXoo4UgaHAgc2V0dGVy77yI5bex5pa556aB5YeP6KGA77yJIC0tLS0K"
    "ICAgICAgICB3cmFwSHAoQ0xTLmJhc2UpOwogICAgICAgIHdyYXBIcChDTFMud2FsbCk7CiAgICAgICAgd3JhcEhwKENMUy5s"
    "aWZlKTsKICAgICAgICBsb2coJ2ludiBwYXRjaCBvaycpOwoKICAgICAgICAvLyAtLS0tIOenkuadgO+8mui3n+i4quaAqueJ"
    "qeWunuS+iyAtLS0tCiAgICAgICAgdmFyIEJNID0gQ0xTLm1vbnN0ZXI7CiAgICAgICAgdmFyIG9Jbml0ID0gQk0ucHJvdG90"
    "eXBlLmluaXQ7CiAgICAgICAgQk0ucHJvdG90eXBlLmluaXQgPSBmdW5jdGlvbiAoKSB7CiAgICAgICAgICAgIHRyeSB7IHRo"
    "aXMuX194ZndLaWxsZWQgPSAwOyBNT05TLmFkZCh0aGlzKTsgfSBjYXRjaCAoZSkge30KICAgICAgICAgICAgcmV0dXJuIG9J"
    "bml0LmFwcGx5KHRoaXMsIGFyZ3VtZW50cyk7CiAgICAgICAgfTsKICAgICAgICB2YXIgb0ZyZWUgPSBCTS5wcm90b3R5cGUu"
    "b25GcmVlOwogICAgICAgIEJNLnByb3RvdHlwZS5vbkZyZWUgPSBmdW5jdGlvbiAoKSB7CiAgICAgICAgICAgIE1PTlMuZGVs"
    "ZXRlKHRoaXMpOwogICAgICAgICAgICByZXR1cm4gb0ZyZWUuYXBwbHkodGhpcywgYXJndW1lbnRzKTsKICAgICAgICB9Owog"
    "ICAgICAgIGxvZygna2lsbCB0cmFjayBvaycpOwoKICAgICAgICAvLyAtLS0tIOaXoENE77yaZ2V0U2tpbGxDRCAtPiAwLjAx"
    "77yI4pqg77iPIOS7heW3seaWue+8muaAqueJqeaKgOiDveS/neaMgeWOn0NE77yM5ZCm5YiZ5oCq54mp5Lmf6L+e5Y+R77yJ"
    "IC0tLS0KICAgICAgICB2YXIgQlMgPSBDTFMuc2tpbGw7CiAgICAgICAgdmFyIG9DRCA9IEJTLnByb3RvdHlwZS5nZXRTa2ls"
    "bENEOwogICAgICAgIEJTLnByb3RvdHlwZS5nZXRTa2lsbENEID0gZnVuY3Rpb24gKCkgewogICAgICAgICAgICBpZiAoRi5j"
    "ZCAmJiB0aGlzLl9zcmMgJiYgdGhpcy5fc3JjLnJvbGVUeXBlICE9PSBST0xFX01PTlNURVIpIHJldHVybiAwLjAxOwogICAg"
    "ICAgICAgICByZXR1cm4gb0NELmNhbGwodGhpcyk7CiAgICAgICAgfTsKICAgICAgICBsb2coJ2NkIHBhdGNoIG9rJyk7CiAg"
    "ICB9CgogICAgZnVuY3Rpb24gd3JhcEhwKGNscykgewogICAgICAgIHZhciBkID0gT2JqZWN0LmdldE93blByb3BlcnR5RGVz"
    "Y3JpcHRvcihjbHMucHJvdG90eXBlLCAnaHAnKTsKICAgICAgICBpZiAoIWQgfHwgIWQuc2V0KSB7IGxvZygnd3JhcEhwIEZB"
    "SUwnLCBjbHMgJiYgY2xzLm5hbWUpOyByZXR1cm47IH0KICAgICAgICB2YXIgb3JpZyA9IGQuc2V0OwogICAgICAgIHZhciBu"
    "ZCA9IHsKICAgICAgICAgICAgZ2V0OiBkLmdldCwKICAgICAgICAgICAgc2V0OiBmdW5jdGlvbiAodikgewogICAgICAgICAg"
    "ICAgICAgaWYgKEYuaW52ICYmIHRoaXMuX2hwID4gMCAmJiB2IDwgdGhpcy5faHAgJiYgdGhpcy5fcm9sZVR5cGUgIT09IFJP"
    "TEVfTU9OU1RFUikgcmV0dXJuOwogICAgICAgICAgICAgICAgb3JpZy5jYWxsKHRoaXMsIHYpOwogICAgICAgICAgICB9LAog"
    "ICAgICAgICAgICBjb25maWd1cmFibGU6IHRydWUsCiAgICAgICAgICAgIGVudW1lcmFibGU6IGZhbHNlCiAgICAgICAgfTsK"
    "ICAgICAgICBPYmplY3QuZGVmaW5lUHJvcGVydHkoY2xzLnByb3RvdHlwZSwgJ2hwJywgbmQpOwogICAgfQoKICAgIC8vIC0t"
    "LS0tLS0tLS0g56eS5p2AIHRpY2sgLS0tLS0tLS0tLQogICAgZnVuY3Rpb24ga2lsbFRpY2soKSB7CiAgICAgICAgaWYgKCFG"
    "LmtpbGwgfHwgTU9OUy5zaXplID09PSAwKSByZXR1cm47CiAgICAgICAgdmFyIG4gPSAwOwogICAgICAgIE1PTlMuZm9yRWFj"
    "aChmdW5jdGlvbiAobSkgewogICAgICAgICAgICBpZiAobS5fX3hmd0tpbGxlZCkgcmV0dXJuOwogICAgICAgICAgICBpZiAo"
    "dHlwZW9mIG0uX2hwICE9PSAnbnVtYmVyJyB8fCAhbS5iYXR0bGUpIHJldHVybjsKICAgICAgICAgICAgaWYgKG0uX2hwID4g"
    "MCkgewogICAgICAgICAgICAgICAgbS5fX3hmd0tpbGxlZCA9IDE7CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAg"
    "ICAgICAgICAgIG0uX2hwID0gMDsgICAgICAgICAgLy8g55u05YaZ5a2X5q6177ya57uV5byAIHNldHRlciDnmoQgQm9zcyDm"
    "iJjlrojljasKICAgICAgICAgICAgICAgICAgICBtLl9zdGF0ZSA9IFNUX0RJRTsKICAgICAgICAgICAgICAgICAgICBpZiAo"
    "bS5yZWNvdmVyeVZpZXcpIG0ucmVjb3ZlcnlWaWV3KCk7CiAgICAgICAgICAgICAgICAgICAgbS5iYXR0bGUucmVtb3ZlTW9u"
    "c3RlcihtKTsKICAgICAgICAgICAgICAgICAgICBuKys7CiAgICAgICAgICAgICAgICB9IGNhdGNoIChlKSB7IGxvZygna2ls"
    "bCBleGMnLCBlKTsgfQogICAgICAgICAgICB9CiAgICAgICAgfSk7CiAgICAgICAgaWYgKG4pIHsgZ19raWxscyArPSBuOyBs"
    "b2coJ2tpbGwgbj0nICsgbiArICcgdG90YWw9JyArIGdfa2lsbHMpOyB9CiAgICB9CgogICAgLy8gPT09PT09PT09PT09PT09"
    "PT0gVUkgPT09PT09PT09PT09PT09PT0KICAgIHZhciB1aVJlYWR5ID0gZmFsc2UsIGJhbGwgPSBudWxsLCBwYW5lbCA9IG51"
    "bGwsIHN0YXR1c0xiID0gbnVsbDsKICAgIHZhciBXID0gMjUwLCBIID0gMjk2LCBST1dTID0gW107CgogICAgZnVuY3Rpb24g"
    "YnVpbGRVSShjYykgewogICAgICAgIGlmICh1aVJlYWR5KSByZXR1cm47CiAgICAgICAgdmFyIHNjZW5lID0gY2MuZGlyZWN0"
    "b3IuZ2V0U2NlbmUoKTsKICAgICAgICBpZiAoIXNjZW5lKSByZXR1cm47CiAgICAgICAgdmFyIGNhbnZhcyA9IG51bGw7CiAg"
    "ICAgICAgdHJ5IHsgY2FudmFzID0gc2NlbmUuZ2V0Q2hpbGRCeU5hbWUoJ0NhbnZhcycpOyB9IGNhdGNoIChlKSB7fQogICAg"
    "ICAgIGlmICghY2FudmFzKSB7IHRyeSB7IGNhbnZhcyA9IHNjZW5lLmdldENvbXBvbmVudEluQ2hpbGRyZW4oY2MuQ2FudmFz"
    "KSAmJiBzY2VuZS5nZXRDb21wb25lbnRJbkNoaWxkcmVuKGNjLkNhbnZhcykubm9kZTsgfSBjYXRjaCAoZSkge30gfQogICAg"
    "ICAgIGlmICghY2FudmFzKSByZXR1cm47CiAgICAgICAgdmFyIFVJMkQgPSAoY2MuTGF5ZXJzICYmIGNjLkxheWVycy5FbnVt"
    "ICYmIGNjLkxheWVycy5FbnVtLlVJXzJEKSB8fCAoMSA8PCAyNSk7CgogICAgICAgIGZ1bmN0aW9uIG1rTm9kZShuYW1lLCB3"
    "LCBoLCBwYXJlbnQpIHsKICAgICAgICAgICAgdmFyIG4gPSBuZXcgY2MuTm9kZShuYW1lKTsKICAgICAgICAgICAgbi5sYXll"
    "ciA9IFVJMkQ7CiAgICAgICAgICAgIHZhciB1dCA9IG4uYWRkQ29tcG9uZW50KGNjLlVJVHJhbnNmb3JtKTsKICAgICAgICAg"
    "ICAgdXQuc2V0Q29udGVudFNpemUodywgaCk7CiAgICAgICAgICAgIGlmIChwYXJlbnQpIG4uc2V0UGFyZW50KHBhcmVudCk7"
    "CiAgICAgICAgICAgIHJldHVybiBuOwogICAgICAgIH0KICAgICAgICBmdW5jdGlvbiBta0JnKG4sIGNvbG9yLCByKSB7CiAg"
    "ICAgICAgICAgIHZhciBnID0gbi5hZGRDb21wb25lbnQoY2MuR3JhcGhpY3MpOwogICAgICAgICAgICBnLmZpbGxDb2xvciA9"
    "IGNvbG9yOyBnLnN0cm9rZUNvbG9yID0gY29sb3I7IGcubGluZVdpZHRoID0gMTsKICAgICAgICAgICAgdmFyIHV0ID0gbi5n"
    "ZXRDb21wb25lbnQoY2MuVUlUcmFuc2Zvcm0pOwogICAgICAgICAgICBnLnJvdW5kUmVjdCgtdXQud2lkdGggLyAyLCAtdXQu"
    "aGVpZ2h0IC8gMiwgdXQud2lkdGgsIHV0LmhlaWdodCwgciA9PT0gdW5kZWZpbmVkID8gMTIgOiByKTsKICAgICAgICAgICAg"
    "Zy5maWxsKCk7CiAgICAgICAgICAgIHJldHVybiBnOwogICAgICAgIH0KICAgICAgICBmdW5jdGlvbiBta0xhYmVsKHBhcmVu"
    "dCwgc3RyLCBzaXplLCBjb2xvciwgYm9sZCkgewogICAgICAgICAgICB2YXIgbiA9IG1rTm9kZSgnbGInLCAwLCAwLCBwYXJl"
    "bnQpOwogICAgICAgICAgICB2YXIgbGIgPSBuLmFkZENvbXBvbmVudChjYy5MYWJlbCk7CiAgICAgICAgICAgIGxiLnN0cmlu"
    "ZyA9IHN0cjsgbGIuZm9udFNpemUgPSBzaXplOyBsYi5saW5lSGVpZ2h0ID0gc2l6ZSArIDQ7CiAgICAgICAgICAgIGxiLmNv"
    "bG9yID0gY29sb3IgfHwgY2MuY29sb3IoMjM1LCAyMzUsIDI0MCwgMjU1KTsKICAgICAgICAgICAgbGIuaXNCb2xkID0gISFi"
    "b2xkOwogICAgICAgICAgICBsYi5ob3Jpem9udGFsQWxpZ24gPSBjYy5MYWJlbC5BbGlnbi5DRU5URVI7CiAgICAgICAgICAg"
    "IGxiLnZlcnRpY2FsQWxpZ24gPSBjYy5MYWJlbC5BbGlnbi5DRU5URVI7CiAgICAgICAgICAgIHJldHVybiB7IG46IG4sIGxi"
    "OiBsYiB9OwogICAgICAgIH0KCiAgICAgICAgLy8gLS0tLSDmgqzmta7nkIMgLS0tLQogICAgICAgIGJhbGwgPSBta05vZGUo"
    "J1hYQ0JhbGwnLCA1NCwgNTQsIGNhbnZhcyk7CiAgICAgICAgbWtCZyhiYWxsLCBjYy5jb2xvcigyMCwgMTIwLCAyNDAsIDIz"
    "NSksIDE0KTsKICAgICAgICB2YXIgYmwgPSBta0xhYmVsKGJhbGwsICfmlLknLCAyNCwgY2MuY29sb3IoMjU1LCAyNTUsIDI1"
    "NSwgMjU1KSwgdHJ1ZSk7CiAgICAgICAgYmwubi5zZXRQb3NpdGlvbigwLCAwKTsKICAgICAgICB2YXIgdnMgPSBjYy52aWV3"
    "LmdldFZpc2libGVTaXplKCk7CiAgICAgICAgYmFsbC5zZXRQb3NpdGlvbih2cy53aWR0aCAvIDIgLSA0NCwgLXZzLmhlaWdo"
    "dCAvIDIgKyAxMjAsIDApOwoKICAgICAgICAvLyAtLS0tIOmdouadvyAtLS0tCiAgICAgICAgcGFuZWwgPSBta05vZGUoJ1hY"
    "Q1BhbmVsJywgVywgSCwgY2FudmFzKTsKICAgICAgICBta0JnKHBhbmVsLCBjYy5jb2xvcigyNiwgMjgsIDM0LCAyNDIpLCAx"
    "NCk7CiAgICAgICAgcGFuZWwuYWN0aXZlID0gZmFsc2U7CiAgICAgICAgdmFyIHRpdGxlID0gbWtMYWJlbChwYW5lbCwgJ+S4"
    "i+aWueS6huaUuSAnICsgVkVSLCAxOSwgY2MuY29sb3IoMTIwLCAyMDAsIDI1NSwgMjU1KSwgdHJ1ZSk7CiAgICAgICAgdGl0"
    "bGUubi5zZXRQb3NpdGlvbigwLCBIIC8gMiAtIDI0KTsKCiAgICAgICAgUk9XUyA9IFtdOwogICAgICAgIHZhciBkZWZzID0g"
    "WwogICAgICAgICAgICBbJ+enkuadgCcsICdraWxsJywgJ+WFqOWcuuaAqueJqeWNs+atuyddLAogICAgICAgICAgICBbJ+aX"
    "oOaVjCcsICdpbnYnLCAn5aKZL+iLsembhC/lj6zllKTniankuI3mjonooYAnXSwKICAgICAgICAgICAgWyfmioDog73ml6BD"
    "RCcsICdjZCcsICfmioDog73lhrfljbTov5HkuY7kuLrpm7YnXQogICAgICAgIF07CiAgICAgICAgZm9yICh2YXIgaSA9IDA7"
    "IGkgPCBkZWZzLmxlbmd0aDsgaSsrKSB7CiAgICAgICAgICAgIChmdW5jdGlvbiAoaWR4KSB7CiAgICAgICAgICAgICAgICB2"
    "YXIgZCA9IGRlZnNbaWR4XTsKICAgICAgICAgICAgICAgIHZhciBybiA9IG1rTm9kZSgncm93JyArIGlkeCwgVyAtIDIwLCA0"
    "NiwgcGFuZWwpOwogICAgICAgICAgICAgICAgbWtCZyhybiwgY2MuY29sb3IoNDYsIDUwLCA2MCwgMjU1KSwgMTApOwogICAg"
    "ICAgICAgICAgICAgcm4uc2V0UG9zaXRpb24oMCwgSCAvIDIgLSA2NiAtIGlkeCAqIDU0KTsKICAgICAgICAgICAgICAgIHZh"
    "ciBsYiA9IG1rTGFiZWwocm4sICcnLCAxOCwgY2MuY29sb3IoMjU1LCAyNTUsIDI1NSwgMjU1KSwgdHJ1ZSk7CiAgICAgICAg"
    "ICAgICAgICBsYi5uLnNldFBvc2l0aW9uKC0oVyAtIDIwKSAvIDIgKyAxNCwgMCk7CiAgICAgICAgICAgICAgICBsYi5sYi5o"
    "b3Jpem9udGFsQWxpZ24gPSBjYy5MYWJlbC5BbGlnbi5MRUZUOwogICAgICAgICAgICAgICAgdmFyIGhpbnQgPSBta0xhYmVs"
    "KHJuLCBkWzJdLCAxMSwgY2MuY29sb3IoMTUwLCAxNTUsIDE2NSwgMjU1KSk7CiAgICAgICAgICAgICAgICBoaW50Lm4uc2V0"
    "UG9zaXRpb24oMTAsIC0xNSk7CiAgICAgICAgICAgICAgICBoaW50LmxiLmhvcml6b250YWxBbGlnbiA9IGNjLkxhYmVsLkFs"
    "aWduLlJJR0hUOwogICAgICAgICAgICAgICAgUk9XUy5wdXNoKHsgbm9kZTogcm4sIGtleTogZFsxXSwgbmFtZTogZFswXSwg"
    "bGI6IGxiLmxiIH0pOwogICAgICAgICAgICB9KShpKTsKICAgICAgICB9CiAgICAgICAgdmFyIHN0ID0gbWtMYWJlbChwYW5l"
    "bCwgJycsIDEyLCBjYy5jb2xvcigxNjAsIDIyMCwgMTYwLCAyNTUpKTsKICAgICAgICBzdC5uLnNldFBvc2l0aW9uKDAsIC1I"
    "IC8gMiArIDM0KTsKICAgICAgICBzdGF0dXNMYiA9IHN0LmxiOwogICAgICAgIHZhciB0aXAgPSBta0xhYmVsKHBhbmVsLCAn"
    "6Z2i5p2/5Y+v5ouW5YqoIMK3IOeKtuaAgeiHquWKqOS/neWtmCcsIDEwLCBjYy5jb2xvcigxMjAsIDEyNSwgMTM1LCAyNTUp"
    "KTsKICAgICAgICB0aXAubi5zZXRQb3NpdGlvbigwLCAtSCAvIDIgKyAxNCk7CgogICAgICAgIHJlZnJlc2hSb3dzKCk7Cgog"
    "ICAgICAgIC8vIC0tLS0g57uf5LiA5omL5Yq/77ya5ouW5YqoIC8g54K55oyJ77yIRU5EIOaXtuaMiSBtb3ZlZCDljLrliIbv"
    "vIzpgb/lhY3mi5blrozor6/op6blj5Hngrnlh7vvvIkgLS0tLQogICAgICAgIGZ1bmN0aW9uIGJpbmRVSShub2RlLCBvbkVu"
    "ZCkgewogICAgICAgICAgICB2YXIgc3ggPSAwLCBzeSA9IDAsIG94ID0gMCwgb3kgPSAwLCBtb3ZlZCA9IGZhbHNlOwogICAg"
    "ICAgICAgICBub2RlLm9uKGNjLk5vZGUuRXZlbnRUeXBlLlRPVUNIX1NUQVJULCBmdW5jdGlvbiAoZSkgewogICAgICAgICAg"
    "ICAgICAgdmFyIHAgPSBlLmdldFVJTG9jYXRpb24oKTsKICAgICAgICAgICAgICAgIHN4ID0gcC54OyBzeSA9IHAueTsgb3gg"
    "PSBub2RlLnBvc2l0aW9uLng7IG95ID0gbm9kZS5wb3NpdGlvbi55OyBtb3ZlZCA9IGZhbHNlOwogICAgICAgICAgICB9KTsK"
    "ICAgICAgICAgICAgbm9kZS5vbihjYy5Ob2RlLkV2ZW50VHlwZS5UT1VDSF9NT1ZFLCBmdW5jdGlvbiAoZSkgewogICAgICAg"
    "ICAgICAgICAgdmFyIHAgPSBlLmdldFVJTG9jYXRpb24oKTsKICAgICAgICAgICAgICAgIHZhciBkeCA9IHAueCAtIHN4LCBk"
    "eSA9IHAueSAtIHN5OwogICAgICAgICAgICAgICAgaWYgKE1hdGguYWJzKGR4KSArIE1hdGguYWJzKGR5KSA+IDgpIG1vdmVk"
    "ID0gdHJ1ZTsKICAgICAgICAgICAgICAgIGlmIChtb3ZlZCkgewogICAgICAgICAgICAgICAgICAgIHZhciB2c3ogPSBjYy52"
    "aWV3LmdldFZpc2libGVTaXplKCk7CiAgICAgICAgICAgICAgICAgICAgdmFyIG54ID0gTWF0aC5tYXgoLXZzei53aWR0aCAv"
    "IDIgKyAyMCwgTWF0aC5taW4odnN6LndpZHRoIC8gMiAtIDIwLCBveCArIGR4KSk7CiAgICAgICAgICAgICAgICAgICAgdmFy"
    "IG55ID0gTWF0aC5tYXgoLXZzei5oZWlnaHQgLyAyICsgMjAsIE1hdGgubWluKHZzei5oZWlnaHQgLyAyIC0gMjAsIG95ICsg"
    "ZHkpKTsKICAgICAgICAgICAgICAgICAgICBub2RlLnNldFBvc2l0aW9uKG54LCBueSwgMCk7CiAgICAgICAgICAgICAgICB9"
    "CiAgICAgICAgICAgIH0pOwogICAgICAgICAgICBub2RlLm9uKGNjLk5vZGUuRXZlbnRUeXBlLlRPVUNIX0VORCwgZnVuY3Rp"
    "b24gKGUpIHsKICAgICAgICAgICAgICAgIG9uRW5kKG1vdmVkLCBlLmdldFVJTG9jYXRpb24oKSk7CiAgICAgICAgICAgIH0p"
    "OwogICAgICAgICAgICBub2RlLm9uKGNjLk5vZGUuRXZlbnRUeXBlLlRPVUNIX0NBTkNFTCwgZnVuY3Rpb24gKCkge30pOwog"
    "ICAgICAgIH0KCiAgICAgICAgYmluZFVJKGJhbGwsIGZ1bmN0aW9uIChtb3ZlZCkgeyBpZiAoIW1vdmVkKSB7IHBhbmVsLmFj"
    "dGl2ZSA9ICFwYW5lbC5hY3RpdmU7IGlmIChwYW5lbC5hY3RpdmUpIHN0YXR1c1RpY2tVSSgpOyB9IH0pOwogICAgICAgIC8v"
    "IOmdouadv++8muaLluWKqOeUsSBiaW5kVUkg5aSE55CG77yb5pyq56e75YqoID0g5Yik5a6a5byA5YWz6KGM54K55Ye7CiAg"
    "ICAgICAgYmluZFVJKHBhbmVsLCBmdW5jdGlvbiAobW92ZWQsIHVpUCkgewogICAgICAgICAgICBpZiAobW92ZWQpIHJldHVy"
    "bjsKICAgICAgICAgICAgdmFyIGxwID0gcGFuZWwuZ2V0Q29tcG9uZW50KGNjLlVJVHJhbnNmb3JtKS5jb252ZXJ0VG9Ob2Rl"
    "U3BhY2VBUih1aVApOwogICAgICAgICAgICBmb3IgKHZhciBpID0gMDsgaSA8IFJPV1MubGVuZ3RoOyBpKyspIHsKICAgICAg"
    "ICAgICAgICAgIHZhciByID0gUk9XU1tpXTsKICAgICAgICAgICAgICAgIHZhciByeSA9IHIubm9kZS5wb3NpdGlvbi55Owog"
    "ICAgICAgICAgICAgICAgaWYgKE1hdGguYWJzKGxwLngpIDw9IChXIC0gMjApIC8gMiAmJiBscC55IDw9IHJ5ICsgMjMgJiYg"
    "bHAueSA+PSByeSAtIDIzKSB7CiAgICAgICAgICAgICAgICAgICAgRltyLmtleV0gPSAhRltyLmtleV07CiAgICAgICAgICAg"
    "ICAgICAgICAgbHNTZXQoci5rZXksIEZbci5rZXldKTsKICAgICAgICAgICAgICAgICAgICByZWZyZXNoUm93cygpOwogICAg"
    "ICAgICAgICAgICAgICAgIGxvZygndG9nZ2xlJywgci5rZXksIEZbci5rZXldKTsKICAgICAgICAgICAgICAgICAgICBzdGF0"
    "dXNUaWNrVUkoKTsKICAgICAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0K"
    "ICAgICAgICB9KTsKCiAgICAgICAgdWlSZWFkeSA9IHRydWU7CiAgICAgICAgbG9nKCd1aSBvaycpOwogICAgfQoKICAgIGZ1"
    "bmN0aW9uIHJlZnJlc2hSb3dzKCkgewogICAgICAgIGZvciAodmFyIGkgPSAwOyBpIDwgUk9XUy5sZW5ndGg7IGkrKykgewog"
    "ICAgICAgICAgICB2YXIgciA9IFJPV1NbaV07CiAgICAgICAgICAgIHZhciBvbiA9ICEhRltyLmtleV07CiAgICAgICAgICAg"
    "IHIubGIuc3RyaW5nID0gKG9uID8gJ1tPTl0gICcgOiAnW09GRl0gJykgKyByLm5hbWU7CiAgICAgICAgICAgIHIubGIuY29s"
    "b3IgPSBvbiA/IGNjLmNvbG9yKDkwLCAyMzAsIDEzMCwgMjU1KSA6IGNjLmNvbG9yKDIxMCwgMjEwLCAyMTUsIDI1NSk7CiAg"
    "ICAgICAgfQogICAgfQoKICAgIGZ1bmN0aW9uIHN0YXR1c1RpY2tVSSgpIHsKICAgICAgICBpZiAoc3RhdHVzTGIgJiYgcGFu"
    "ZWwgJiYgcGFuZWwuYWN0aXZlKSB7CiAgICAgICAgICAgIHN0YXR1c0xiLnN0cmluZyA9ICfmgKrniak6JyArIE1PTlMuc2l6"
    "ZSArICcg5bey5p2AOicgKyBnX2tpbGxzOwogICAgICAgIH0KICAgIH0KCiAgICAvLyAtLS0tLS0tLS0tIOW8leaTjuetieW+"
    "hSArIOS4u+W+queOryAtLS0tLS0tLS0tCiAgICB2YXIgdDAgPSBEYXRlLm5vdygpLCBjY1RyaWVkID0gMCwgd2FybmVkID0g"
    "ZmFsc2U7CiAgICBmdW5jdGlvbiBwb2xsKCkgewogICAgICAgIC8vIDEpIOetiea4uOaIj+exu+azqOWGjOW5tiBwYXRjaAog"
    "ICAgICAgIHZhciBwYXRjaGVkID0gdHJ5UGF0Y2goKTsKICAgICAgICBpZiAoIXBhdGNoZWQgJiYgIXdhcm5lZCAmJiBEYXRl"
    "Lm5vdygpIC0gdDAgPiA5MDAwMCkgeyB3YXJuZWQgPSB0cnVlOyBsb2coJ1dBUk4g57G7562J5b6F6LaF5pe2Jyk7IH0KICAg"
    "ICAgICAvLyAyKSDmi78gY2Mg5bu6IFVJCiAgICAgICAgaWYgKCF1aVJlYWR5ICYmIHR5cGVvZiBTeXN0ZW0gIT09ICd1bmRl"
    "ZmluZWQnKSB7CiAgICAgICAgICAgIGNjVHJpZWQrKzsKICAgICAgICAgICAgaWYgKGNjVHJpZWQgJSAyMCA9PT0gMSkgewog"
    "ICAgICAgICAgICAgICAgU3lzdGVtLmltcG9ydCgnY2MnKS50aGVuKGZ1bmN0aW9uIChjYykgewogICAgICAgICAgICAgICAg"
    "ICAgIHRyeSB7IGJ1aWxkVUkoY2MpOyB9IGNhdGNoIChlKSB7IGxvZygndWkgZXhjJywgZSk7IH0KICAgICAgICAgICAgICAg"
    "IH0pLmNhdGNoKGZ1bmN0aW9uICgpIHt9KTsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgICAgICBraWxsVGljaygpOwog"
    "ICAgICAgIHN0YXR1c1RpY2tVSSgpOwogICAgfQoKICAgIGZ1bmN0aW9uIGVuc3VyZVVJQWxpdmUoKSB7CiAgICAgICAgaWYg"
    "KCF1aVJlYWR5KSByZXR1cm47CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgaWYgKCFiYWxsIHx8ICFiYWxsLmlzVmFsaWQg"
    "fHwgIWJhbGwucGFyZW50KSB1aVJlYWR5ID0gZmFsc2U7IC8vIOWcuuaZr+WIh+aNouWQjumHjeW7ugogICAgICAgICAgICBp"
    "ZiAodWlSZWFkeSAmJiBwYW5lbCAmJiBwYW5lbC5hY3RpdmUpIHN0YXR1c1RpY2tVSSgpOwogICAgICAgIH0gY2F0Y2ggKGUp"
    "IHsgdWlSZWFkeSA9IGZhbHNlOyB9CiAgICB9CgogICAgLy8g5a6a5pe25Zmo5oq96LGh77yabmF0aXZlIGpzYiDml6Agc2V0"
    "SW50ZXJ2YWwg5pe255So5byV5pOO5bin6amx5Yqo5YWc5bqV77yIZHlsaWIg5rOo5YWl5Zy65pmv77yJCiAgICBmdW5jdGlv"
    "biBldmVyeShtcywgZm4pIHsKICAgICAgICBpZiAodHlwZW9mIHNldEludGVydmFsID09PSAnZnVuY3Rpb24nKSByZXR1cm4g"
    "c2V0SW50ZXJ2YWwoZm4sIG1zKTsKICAgICAgICBTeXN0ZW0uaW1wb3J0KCdjYycpLnRoZW4oZnVuY3Rpb24gKGNjKSB7CiAg"
    "ICAgICAgICAgIHRyeSB7IGNjLmRpcmVjdG9yLm9uKGNjLkRpcmVjdG9yLkVWRU5UX0JFRk9SRV9VUERBVEUsIGZ1bmN0aW9u"
    "ICgpIHsgZm4oKTsgfSk7IH0gY2F0Y2ggKGUpIHsgbG9nKCdmcmFtZSB0aWNrIGV4YycsIGUpOyB9CiAgICAgICAgfSkuY2F0"
    "Y2goZnVuY3Rpb24gKCkge30pOwogICAgfQogICAgZXZlcnkoMjUwLCBwb2xsKTsKICAgIGV2ZXJ5KDEwMDAsIGVuc3VyZVVJ"
    "QWxpdmUpOwogICAgbG9nKCdsb2FkZWQnLCBWRVIsICdmbGFncyBraWxsPScgKyBGLmtpbGwsICdpbnY9JyArIEYuaW52LCAn"
    "Y2Q9JyArIEYuY2QpOwp9KSgpOwo=";

static NSString *decodeCheat(void) {
    NSData *d = [[NSData alloc] initWithBase64EncodedString:@(g_cheatB64) options:0];
    if (!d) return nil;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

// ---------- 注入 ----------
static void tryInject(void) {
    @autoreleasepool {
        if (!g_gameCtx) {
            for (JSContext *c in g_ctxs.allObjects) {
                @try {
                    JSValue *r = [c evaluateScript:@"(typeof jsb==='object')&&(typeof System==='object')"];
                    if (r.isBoolean && r.boolValue) {
                        g_gameCtx = c;
                        xlog(@"game ctx found: %@ size=%lu", c, (unsigned long)g_ctxs.count);
                        break;
                    }
                } @catch (NSException *e) { /* 广告等其它 context */ }
            }
            if (!g_gameCtx) return;
        }
        if (g_injected) return;
        NSString *js = decodeCheat();
        if (!js) { xlog(@"ERROR b64 decode fail"); g_injected = YES; return; }
        @try {
            [g_gameCtx evaluateScript:js withSourceURL:[NSURL URLWithString:@"xxcheat.js"]];
            JSValue *v = [g_gameCtx evaluateScript:@"(typeof __XXC!=='undefined')?__XXC.ver:0"];
            if (!v.isUndefined && ![v isEqualToObject:@0]) {
                g_injected = YES;
                xlog(@"inject OK ver=%@ (js %@ bytes)", v.toString, @(js.length));
            } else {
                xlog(@"inject verify fail, retry. exc=%@", g_gameCtx.exception ? g_gameCtx.exception.toString : @"(none)");
            }
        } @catch (NSException *e) {
            xlog(@"inject exc: %@", e);
        }
    }
}

// ---------- 入口 ----------
__attribute__((constructor)) static void XXCDylibMain(void) {
    @autoreleasepool {
        NSBundle *mb = [NSBundle mainBundle];
        NSString *bid = mb.bundleIdentifier ?: @"";
        NSString *exe = mb.executablePath.lastPathComponent ?: @"";
        if (![bid isEqualToString:@"com.feiyu.freakout"] && ![exe isEqualToString:@"xxgame-mobile"]) {
            return; // 非目标 app，静默退出
        }
        g_active = YES;
        g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/xxcheat_dylib.log"];
        xlog(@"dylib loaded bid=%@ exe=%@", bid, exe);

        g_ctxs = [NSHashTable weakObjectsHashTable];
        Class c = objc_getClass("JSContext");
        Method m1 = class_getInstanceMethod(c, @selector(init));
        g_origInit = method_getImplementation(m1);
        method_setImplementation(m1, (IMP)hookedInit);
        Method m2 = class_getInstanceMethod(c, @selector(initWithVirtualMachine:));
        g_origInitVM = method_getImplementation(m2);
        method_setImplementation(m2, (IMP)hookedInitVM);

        dispatch_async(dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
                tryInject();
            }];
        });
    }
}
