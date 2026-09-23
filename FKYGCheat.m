// FKYGCheat.m — 放开那妖怪 1.0.15 (Unity 2021.3.42f1 + HybridCLR/ET9 ECS)
// 秒杀 / 无敌 / 全局加速 — 纯 il2cpp 反射 invoke 官方方法，零 RVA hook
//
// 锚点链（全部反射调用，dump.cs 实证）：
//   ClientSceneManagerComponent.Instance [StaticField 非泛型静态]
//   -> Entity.domain(偏移运行时取) = clientScene
//   -> invoke CurrentScenesComponentSystem.CurrentScene(clientScene)
//   -> invoke Entity.GetComponent(Type=MainUnitComponent) -> unitRef.entity(+0x8) = 主角Unit
//   -> Unit.domain = battleScene
//   -> invoke GetComponent(UnitComponent) -> FightUnits(List<Unit> @off, _items@0x10, _size@0x18, 数据@0x20)
// 秒杀: FightSystem.Hurt(u, Damage{Value=1e9, Source=mainUnit}) 官方伤害管线(护盾/事件/死亡动画/掉落全真)
// 无敌: NumericComponentSystem.SetNoEvent(nc, CurrentHp=1001, MaxHp) 每tick锁满血
// 加速: BattleSceneHelper.SetTimeScale(battleScene, N) 官方倍速(逻辑帧33ms追帧+动画同步)
// 日志: Documents/fkyg.log
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <stdatomic.h>

static FILE *g_log = NULL;
static void flog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void flog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[FKYG] %@", s);
    if (!g_log) {
        NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/fkyg.log"];
        g_log = fopen(p.UTF8String, "a");
    }
    if (g_log) { fprintf(g_log, "[FKYG] %s\n", s.UTF8String); fflush(g_log); }
}

#pragma mark - il2cpp API
static void *g_uf = NULL;
static void *p_domain_get, *p_domain_get_assemblies, *p_assembly_get_image, *p_image_get_name;
static void *p_class_from_name, *p_class_get_type, *p_class_get_field_from_name, *p_class_get_method_from_name;
static void *p_field_get_offset, *p_field_static_get_value, *p_type_get_object, *p_runtime_invoke;
static void *p_object_new, *p_value_box, *p_object_get_class, *p_class_get_name, *p_array_new;

static BOOL load_il2cpp_api(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *im = _dyld_get_image_name(i);
        if (im && strstr(im, "UnityFramework")) {
            g_uf = dlopen(im, RTLD_NOW | RTLD_GLOBAL | RTLD_NOLOAD);
            if (g_uf) break;
        }
    }
    if (!g_uf) return NO;
    p_domain_get                = dlsym(g_uf, "il2cpp_domain_get");
    p_domain_get_assemblies     = dlsym(g_uf, "il2cpp_domain_get_assemblies");
    p_assembly_get_image        = dlsym(g_uf, "il2cpp_assembly_get_image");
    p_image_get_name            = dlsym(g_uf, "il2cpp_image_get_name");
    p_class_from_name           = dlsym(g_uf, "il2cpp_class_from_name");
    p_class_get_type            = dlsym(g_uf, "il2cpp_class_get_type");
    p_class_get_field_from_name = dlsym(g_uf, "il2cpp_class_get_field_from_name");
    p_class_get_method_from_name= dlsym(g_uf, "il2cpp_class_get_method_from_name");
    p_field_get_offset          = dlsym(g_uf, "il2cpp_field_get_offset");
    p_field_static_get_value    = dlsym(g_uf, "il2cpp_field_static_get_value");
    p_type_get_object           = dlsym(g_uf, "il2cpp_type_get_object");
    p_runtime_invoke            = dlsym(g_uf, "il2cpp_runtime_invoke");
    p_object_new                = dlsym(g_uf, "il2cpp_object_new");
    p_value_box                 = dlsym(g_uf, "il2cpp_value_box");
    p_object_get_class          = dlsym(g_uf, "il2cpp_object_get_class");
    p_class_get_name            = dlsym(g_uf, "il2cpp_class_get_name");
    p_array_new                 = dlsym(g_uf, "il2cpp_array_new");
    return p_runtime_invoke && p_class_from_name && p_domain_get && p_field_static_get_value;
}

#pragma mark - helper
static void *g_imgCore, *g_imgModel, *g_imgHotfix, *g_imgCorlib;

// v9: 内核级内存探针（mach_vm_read_overwrite）——扫描动态实体树防 SIGSEGV
#import <mach/mach.h>
extern kern_return_t mach_vm_read_overwrite(vm_map_t target_task, mach_vm_address_t address,
    mach_vm_size_t size, mach_vm_address_t data, mach_vm_size_t *outsize);
static BOOL fk_readable(const void *p, uint64_t len) {
    if (!p || ((uintptr_t)p & 7)) return NO;
    char dummy[8];
    mach_vm_address_t outAddr = (mach_vm_address_t)(uintptr_t)dummy;
    mach_vm_size_t outSz = 0;
    kern_return_t kr = mach_vm_read_overwrite(mach_task_self(),
        (mach_vm_address_t)(uintptr_t)p, (mach_vm_size_t)len, outAddr, &outSz);
    return kr == KERN_SUCCESS;
}

static void *fk_meth(void *cls, const char *m, int argc);
static void *fk_invoke2(void *method, void *inst);
static void *fk_invoke(void *method, void *inst, void **params) {
    void *exc = NULL;
    void *r = ((void*(*)(void*,void*,void**,void*))p_runtime_invoke)(method, inst, params, &exc);
    if (exc) {
        static int excLogN = 0;
        const char *cn = "?";
        void *cls = ((void*(*)(void*))p_object_get_class)(exc);
        if (cls) cn = ((const char*(*)(void*))p_class_get_name)(cls);
        NSString *detail = @"";
        if (excLogN < 8) {
            // Exception.ToString() 详情（UTF16）
            void *mTs = fk_meth(cls, "ToString", 0);
            void *so = mTs ? fk_invoke2(mTs, exc) : NULL;
            if (so) {
                int len = *(int32_t*)((char*)so + 0x10);
                if (len > 0 && len < 512) {
                    unichar buf[512];
                    for (int i = 0; i < len; i++) buf[i] = *(unichar*)((char*)so + 0x14 + 2*i);
                    detail = [NSString stringWithCharacters:buf length:len];
                }
            }
        }
        if (excLogN++ < 8) flog(@"invoke exc[%s]: %@", cn, detail);
        return NULL;
    }
    return r;
}
// 无日志版 invoke（fk_dict_values 高频路径防刷屏）
static void *fk_invoke2(void *method, void *inst) {
    void *exc = NULL;
    return ((void*(*)(void*,void*,void**,void*))p_runtime_invoke)(method, inst, NULL, &exc);
}
// box 值读取：Il2CppObject 头 0x10，值数据 @0x10
static long   fk_box_get_long (void *b) { return b ? *(long*)((char*)b + 0x10) : 0; }
static int    fk_box_get_int  (void *b) { return b ? *(int32_t*)((char*)b + 0x10) : 0; }
static BOOL   fk_box_get_bool (void *b) { return b ? *(uint8_t*)((char*)b + 0x10) : 0; }

static void *fk_class_img(void *img, const char *ns, const char *name) {
    if (!img) return NULL;
    return ((void*(*)(void*,const char*,const char*))p_class_from_name)(img, ns, name);
}
// ET9 命名空间分 ET / ET.Client（MainUnitComponent、BattleSceneHelper 在 ET.Client）
static void *fk_class(const char *ns0, const char *name) {
    const char *nss[2] = { ns0, "ET.Client" };
    void *c = NULL;
    for (int i = 0; i < 2 && !c; i++) {
        c = fk_class_img(g_imgModel, nss[i], name);
        if (!c) c = fk_class_img(g_imgHotfix, nss[i], name);
        if (!c) c = fk_class_img(g_imgCore, nss[i], name);
    }
    return c;
}
static long fk_foff(void *cls, const char *fname) {
    void *f = ((void*(*)(void*,const char*))p_class_get_field_from_name)(cls, fname);
    return f ? ((long(*)(void*))p_field_get_offset)(f) : -1;
}
static void *fk_meth(void *cls, const char *m, int argc) {
    return cls ? ((void*(*)(void*,const char*,int))p_class_get_method_from_name)(cls, m, argc) : NULL;
}
static void *fk_typeobj(void *cls) {
    if (!cls) return NULL;
    void *t = ((void*(*)(void*))p_class_get_type)(cls);
    return t ? ((void*(*)(void*))p_type_get_object)(t) : NULL;
}

#pragma mark - 解析缓存
static void *g_clsEntity, *g_clsMainUnitComp, *g_clsUnitComp, *g_clsNumericComp, *g_clsNumericType;
static void *g_clsDamage, *g_clsBattleComp, *g_clsBSM;
static void *g_mGetComponent, *g_mCurrentScene, *g_mHurt, *g_mIsDead, *g_mGetCamp;
static void *g_mSetNoEvent, *g_mGetAsLong, *g_mGetTS, *g_mSetTS;
static void *g_fieldCSCInst;
static void *g_clsInt32, *g_clsInt64;
static long g_offDomain = -1, g_offMainUnitRef = -1, g_offFightUnits = -1;
static long g_offDmgValue = -1, g_offDmgSource = -1, g_offIsFighting = -1;
static long g_offChildren = -1, g_offComps = -1;
static int g_resolveTry = 0;
static BOOL g_resolved = NO;

static BOOL fk_find_images(void) {
    void *dom = ((void*(*)())p_domain_get)();
    if (!dom) return NO;
    size_t n = 0;
    void **list = ((void**(*)(void*,size_t*))p_domain_get_assemblies)(dom, &n);
    if (!list) return NO;
    for (size_t i = 0; i < n; i++) {
        if (!list[i]) continue;
        void *img = ((void*(*)(void*))p_assembly_get_image)(list[i]);
        if (!img) continue;
        const char *nm = ((const char*(*)(void*))p_image_get_name)(img);
        if (!nm) continue;
        // HybridCLR/AOT image 名可能带或不带 .dll —— 用前缀匹配
        if (!strncmp(nm, "Unity.Core", 10)) g_imgCore = img;
        else if (!strncmp(nm, "Model", 5) && !strstr(nm, "Config")) g_imgModel = img;
        else if (!strncmp(nm, "Hotfix", 6)) g_imgHotfix = img;
        else if (!strncmp(nm, "mscorlib", 8)) g_imgCorlib = img;
    }
    // 诊断：列出自定义程序集
    NSMutableString *cust = [NSMutableString string];
    for (size_t i = 0; i < n; i++) {
        if (!list[i]) continue;
        void *img = ((void*(*)(void*))p_assembly_get_image)(list[i]);
        const char *nm2 = img ? ((const char*(*)(void*))p_image_get_name)(img) : NULL;
        if (nm2 && !strncmp(nm2, "Unity.", 6) == 0 && !strncmp(nm2, "System", 6) && strncmp(nm2, "UnityEngine", 11) && strncmp(nm2, "mscorlib", 8) && strncmp(nm2, "Mono", 4) && strncmp(nm2, "netstandard", 11))
            [cust appendFormat:@"%s ", nm2];
    }
    flog(@"images: core=%p model=%p hotfix=%p corlib=%p | custom: %@",
         g_imgCore, g_imgModel, g_imgHotfix, g_imgCorlib, cust);
    return (g_imgCore && g_imgModel && g_imgHotfix);
}

static BOOL fk_resolve(void) {
    g_resolveTry++;
    if (g_resolveTry == 1 || g_resolveTry % 15 == 0) flog(@"resolve try #%d", g_resolveTry);
    if (!g_imgModel && !fk_find_images()) return NO;

    if (!g_clsEntity) {
        g_clsEntity = fk_class_img(g_imgCore, "ET", "Entity");
        if (!g_clsEntity) { flog(@"Entity class miss (ns ET @ Unity.Core)"); return NO; }
        g_mGetComponent = fk_meth(g_clsEntity, "GetComponent", 1);
        g_offDomain = fk_foff(g_clsEntity, "domain");
        g_offChildren = fk_foff(g_clsEntity, "children");
        g_offComps = fk_foff(g_clsEntity, "components");
        if (!g_mGetComponent || g_offDomain < 0) { flog(@"GetComponent=%p dom=%ld", g_mGetComponent, g_offDomain); return NO; }
        flog(@"Entity offs: domain=%ld children=%ld components=%ld", g_offDomain, g_offChildren, g_offComps);
    }
    g_clsMainUnitComp = fk_class("ET", "MainUnitComponent");
    g_clsUnitComp     = fk_class("ET", "UnitComponent");
    g_clsNumericComp  = fk_class("ET", "NumericComponent");
    g_clsNumericType  = fk_class("ET", "NumericType");
    g_clsDamage       = fk_class("ET", "Damage");
    g_clsBattleComp   = fk_class("ET", "BattleComponent");
    g_clsBSM          = fk_class("ET", "BattleSceneManagerComponent");
    if (!g_clsMainUnitComp || !g_clsUnitComp || !g_clsNumericComp || !g_clsNumericType || !g_clsDamage || !g_clsBattleComp || !g_clsBSM) {
        if (g_resolveTry % 15 == 0) flog(@"cls miss main=%p unit=%p num=%p nt=%p dmg=%p bat=%p bsm=%p",
            g_clsMainUnitComp, g_clsUnitComp, g_clsNumericComp, g_clsNumericType, g_clsDamage, g_clsBattleComp, g_clsBSM);
        return NO; // 热更 dll 尚未加载
    }
    g_offMainUnitRef = fk_foff(g_clsMainUnitComp, "unitRef");
    g_offFightUnits  = fk_foff(g_clsUnitComp, "<FightUnits>k__BackingField");
    g_offDmgValue    = fk_foff(g_clsDamage, "Value");
    g_offDmgSource   = fk_foff(g_clsDamage, "Source");
    g_offIsFighting  = fk_foff(g_clsBattleComp, "<IsFighting>k__BackingField");
    if (g_offMainUnitRef < 0 || g_offFightUnits < 0 || g_offDmgValue < 0) {
        if (g_resolveTry % 15 == 0) flog(@"off miss mur=%ld fu=%ld dmgV=%ld", g_offMainUnitRef, g_offFightUnits, g_offDmgValue);
        return NO;
    }
    void *fsFight = fk_class("ET", "FightSystem");
    void *fsHelp  = fk_class("ET", "FightHelper");
    void *fsNum   = fk_class("ET", "NumericComponentSystem");
    void *fsBSH   = fk_class("ET", "BattleSceneHelper");
    void *fsCur   = fk_class("ET", "CurrentScenesComponentSystem");
    void *fsCSC   = fk_class("ET", "ClientSceneManagerComponent");
    if (!fsFight || !fsHelp || !fsNum || !fsBSH || !fsCur || !fsCSC) {
        if (g_resolveTry % 15 == 0) flog(@"syscls miss fight=%p help=%p num=%p bsh=%p cur=%p csc=%p",
            fsFight, fsHelp, fsNum, fsBSH, fsCur, fsCSC);
        return NO;
    }
    g_mHurt        = fk_meth(fsFight, "Hurt", 2);
    g_mIsDead      = fk_meth(fsHelp, "IsDead", 1);
    g_mGetCamp     = fk_meth(fsHelp, "GetCamp", 1);
    g_mSetNoEvent  = fk_meth(fsNum, "SetNoEvent", 3);
    g_mGetAsLong   = fk_meth(fsNum, "GetAsLong", 2);
    g_mGetTS       = fk_meth(fsBSH, "GetTimeScale", 1);
    g_mSetTS       = fk_meth(fsBSH, "SetTimeScale", 2);
    g_mCurrentScene= fk_meth(fsCur, "CurrentScene", 1);
    g_fieldCSCInst = ((void*(*)(void*,const char*))p_class_get_field_from_name)(fsCSC, "Instance");
    if (!g_mHurt || !g_mIsDead || !g_mGetCamp || !g_mSetNoEvent || !g_mGetAsLong || !g_mGetTS || !g_mSetTS || !g_mCurrentScene || !g_fieldCSCInst) {
        if (g_resolveTry % 15 == 0) flog(@"meth miss hurt=%p dead=%p camp=%p sne=%p gal=%p gts=%p sts=%p cur=%p cscf=%p",
            g_mHurt, g_mIsDead, g_mGetCamp, g_mSetNoEvent, g_mGetAsLong, g_mGetTS, g_mSetTS, g_mCurrentScene, g_fieldCSCInst);
        return NO;
    }
    if (!g_clsInt32) {
        g_clsInt32 = fk_class_img(g_imgCorlib, "System", "Int32");
        g_clsInt64 = fk_class_img(g_imgCorlib, "System", "Int64");
    }
    g_resolved = YES;
    flog(@"resolve OK try#%d", g_resolveTry);
    return YES;
}

#pragma mark - 开关状态
static atomic_int g_kill = 0;   // 秒杀
static atomic_int g_inv  = 0;   // 无敌
static volatile int g_spd = 0;  // 0=1x 1=2x 2=4x 3=8x
static const int SPD_N[4] = {1, 2, 4, 8};
static void *g_lastTSscene = NULL;
static int g_killCnt = 0, g_lastKilled = 0, g_lastHealed = 0;
static int g_status = 0; // 0=未就绪 1=已就绪 2=战斗中

#define NT_MaxHp     3
#define NT_CurrentHp 1001

// v8 关键修复：runtime_invoke 值类型参数必须传【未装箱数据指针】（非装箱对象）
// 之前传装箱对象 → 参数被当数据指针解引用（对象头被读成 int/long/struct）→ 全部功能静默失效
static int32_t  g_ai[8]; static int g_ain = 0;
static int64_t  g_al[8]; static int g_aln = 0;
static uint16_t g_au[8]; static int g_aun = 0;
static void *fk_argi(int v)    { int32_t  *p = &g_ai[g_ain++ & 7]; *p = v; return p; }
static void *fk_argl(long v)   { int64_t  *p = &g_al[g_aln++ & 7]; *p = v; return p; }
static void *fk_argnt(uint16_t v){ uint16_t *p = &g_au[g_aun++ & 7]; *p = v; return p; }

// 反射枚举 Dictionary<long,Entity> values（get_Values + CopyTo，零字典布局硬编码）
static int fk_dict_fail_log = 0;
static int fk_dict_values(void *dict, void **out, int max) {
    if (!dict || !fk_readable(dict, 0x58)) return 0; // 字典对象可读性探针
    void *cls = ((void*(*)(void*))p_object_get_class)(dict);
    const char *cn = cls ? ((const char*(*)(void*))p_class_get_name)(cls) : NULL;
    if (!cn || !strstr(cn, "Dictionary")) {
        if (fk_dict_fail_log++ < 5) flog(@"dict not Dictionary: ptr=%p cls=%s", dict, cn ? cn : "null");
        return 0;
    }
    void *mGV = fk_meth(cls, "get_Values", 0);
    void *mCnt  = fk_meth(cls, "get_Count", 0);
    if (!mGV || !mCnt) {
        if (fk_dict_fail_log++ < 5) flog(@"dict meth miss GV=%p Cnt=%p (%s)", mGV, mCnt, cn);
        return 0;
    }
    void *vc = fk_invoke(mGV, dict, NULL);
    if (!vc || !fk_readable(vc, 0x20)) return 0;
    void *vcCls = ((void*(*)(void*))p_object_get_class)(vc);
    void *mCopy = fk_meth(vcCls, "CopyTo", 2);
    if (!mCopy) {
        if (fk_dict_fail_log++ < 5) flog(@"CopyTo miss on %s", ((const char*(*)(void*))p_class_get_name)(vcCls));
        return 0;
    }
    int n = fk_box_get_int(fk_invoke(mCnt, dict, NULL));
    if (n <= 0 || n > 4096) return 0;
    void *arr = ((void*(*)(void*,long))p_array_new)(g_clsEntity, n);
    if (!arr) return 0;
    fk_invoke(mCopy, vc, (void*[]){arr, fk_argi(0)});
    if (!fk_readable(arr, 0x20)) return 0;
    int32_t nArr = *(int32_t*)((char*)arr + 0x18);
    if (nArr > n) nArr = n;
    void **elems = (void**)((char*)arr + 0x20);
    if (!fk_readable(elems, (uint64_t)nArr * 8)) return 0;
    int c = 0;
    for (int i = 0; i < nArr && c < max; i++) if (elems[i]) out[c++] = elems[i];
    return c;
}

static void ui_refresh(void);

#pragma mark - 主 tick（主线程 1s）
// v6 场景定位：组件树 DFS + class 指针直接比较（彻底绕开 GetComponent(Type) 的 Type 匹配）
//   Root.Scene --DFS(children+components)--> MainUnitComponent 实例
//   -> 验证其 domain 的 BattleComponent.IsFighting
//   -> unitRef.entity = 主角 -> domain = battleScene -> UnitComponent.FightUnits
static void *fk_comp_by_class(void *e, void *cls) {
    if (!e) return NULL;
    long offComps = fk_foff(g_clsEntity, "components");
    if (offComps < 0) return NULL;
    void *dict = *(void**)((char*)e + offComps);
    void *kids[256];
    int n = fk_dict_values(dict, kids, 256);
    for (int i = 0; i < n; i++)
        if (((void*(*)(void*))p_object_get_class)(kids[i]) == cls) return kids[i];
    return NULL;
}
static int fk_dfs_visited = 0;
static void *fk_dfs_find(void *e, void *targetCls, int depth) {
    if (!e || depth <= 0) return NULL;
    if (!fk_readable(e, 0x58)) return NULL;          // 实体可读性探针
    long iid = *(long*)((char*)e + 0x10);
    if (iid == 0) return NULL;                        // 已 Dispose 实体不递归
    fk_dfs_visited++;
    void *cls = ((void*(*)(void*))p_object_get_class)(e);
    if (cls == targetCls) return e;
    if (depth <= 1 || fk_dfs_visited > 4096) return NULL;
    void *kids[256];
    if (g_offChildren >= 0) {
        void *dict = *(void**)((char*)e + g_offChildren);
        int n = fk_dict_values(dict, kids, 256);
        for (int i = 0; i < n; i++) {
            void *r = fk_dfs_find(kids[i], targetCls, depth - 1);
            if (r) return r;
        }
    }
    if (g_offComps >= 0) {
        void *dict = *(void**)((char*)e + g_offComps);
        int n = fk_dict_values(dict, kids, 256);
        for (int i = 0; i < n; i++) {
            void *r = fk_dfs_find(kids[i], targetCls, depth - 1);
            if (r) return r;
        }
    }
    return NULL;
}


// v6 主 tick：DFS 找 MainUnitComponent（缓存 + InstanceId 存活验证）
static void *g_cMainComp = NULL;      // 缓存的 MainUnitComponent 实例
static int g_dfsThrottle = 0;         // DFS 节流（每3秒一次）
static long g_instId(void *e) { return e ? *(long*)((char*)e + 0x10) : 0; } // Entity.InstanceId @0x10

static void fk_tick(void) {
    @autoreleasepool {
        if (!g_resolved && !fk_resolve()) { g_status = 0; ui_refresh(); return; }

        static int diag = 0; diag++;
        BOOL ld = (diag <= 6 || diag % 10 == 1);

        // Root.Scene = CSC.Instance.domain
        void *mgr = NULL;
        ((void(*)(void*,void*))p_field_static_get_value)(g_fieldCSCInst, &mgr);
        if (!mgr) { g_status = 1; if (ld) flog(@"t%d CSC.Instance=NULL", diag); ui_refresh(); return; }
        void *root = *(void**)((char*)mgr + g_offDomain);
        if (!root) { if (ld) flog(@"t%d root=NULL", diag); return; }

        // 缓存验证：可读 + InstanceId != 0 视为存活
        if (g_cMainComp && (!fk_readable(g_cMainComp, 0x18) || g_instId(g_cMainComp) == 0)) g_cMainComp = NULL;

        // DFS 找 MainUnitComponent（无缓存时，节流 10s）
        if (!g_cMainComp && ++g_dfsThrottle % 10 == 1) {
            fk_dfs_visited = 0;
            void *comp = fk_dfs_find(root, g_clsMainUnitComp, 10);
            if (ld) flog(@"t%d DFS visited=%d hit=%p", diag, fk_dfs_visited, comp);
            if (comp) {
                // 该组件的 domain 场景必须 IsFighting 才算战斗场景
                void *scene = *(void**)((char*)comp + g_offDomain);
                void *bc = scene ? fk_comp_by_class(scene, g_clsBattleComp) : NULL;
                if (bc && g_offIsFighting >= 0 && *(BOOL*)((char*)bc + g_offIsFighting))
                    g_cMainComp = comp;
                else if (ld) flog(@"t%d hit but not fighting, keep searching", diag);
            }
        }

        void *battleScene = NULL, *mainUnit = NULL;
        BOOL fighting = NO;
        if (g_cMainComp) {
            battleScene = *(void**)((char*)g_cMainComp + g_offDomain);
            mainUnit = *(void**)((char*)g_cMainComp + g_offMainUnitRef + 0x8);
            if (((uintptr_t)mainUnit & 0x7) != 0) mainUnit = NULL;
            void *bc = fk_comp_by_class(battleScene, g_clsBattleComp);
            fighting = (bc && g_offIsFighting >= 0) ? (*(BOOL*)((char*)bc + g_offIsFighting)) : NO;
        }
        g_status = fighting ? 2 : 1;
        if (ld) flog(@"t%d root=%p bs=%p main=%p fight=%d", diag, root, battleScene, mainUnit, fighting);

        // 加速：场景重建后重新应用
        if (fighting && g_spd > 0 && battleScene != g_lastTSscene) {
            fk_invoke(g_mSetTS, NULL, (void*[]){battleScene, fk_argi(SPD_N[g_spd])});
            int now = fk_box_get_int(fk_invoke(g_mGetTS, NULL, (void*[]){battleScene}));
            if (now == SPD_N[g_spd]) { g_lastTSscene = battleScene; flog(@"timeScale=%d ok", now); }
            else flog(@"setTS fail cur=%d", now);
        } else if (g_spd == 0) {
            g_lastTSscene = NULL;
        }

        g_lastKilled = 0; g_lastHealed = 0;
        if (!fighting) { ui_refresh(); return; }

        // UnitComponent.FightUnits（class 指针直查组件）
        void *uc = fk_comp_by_class(battleScene, g_clsUnitComp);
        if (!uc || g_offFightUnits < 0) { if (ld) flog(@"t%d UnitComponent miss", diag); ui_refresh(); return; }
        void *arr = *(void**)((char*)uc + g_offFightUnits);
        if (!arr) { ui_refresh(); return; }
        int32_t size = *(int32_t*)((char*)arr + 0x18);
        if (size <= 0) { ui_refresh(); return; }
        void **elems = (void**)((char*)arr + 0x20);
        if (size > 256) size = 256;

        int mainCamp = 0;
        if (mainUnit) mainCamp = fk_box_get_int(fk_invoke(g_mGetCamp, NULL, (void*[]){mainUnit}));

        int killed = 0, healed = 0;
        for (int i = 0; i < size; i++) {
            void *u = elems[i];
            if (!u || u == mainUnit) continue;
            if (fk_box_get_bool(fk_invoke(g_mIsDead, NULL, (void*[]){u}))) continue;
            int camp = fk_box_get_int(fk_invoke(g_mGetCamp, NULL, (void*[]){u}));
            BOOL enemy = (mainUnit != NULL) && (camp != mainCamp);

            // 秒杀：敌方走官方 Hurt 管线（Damage 值类型参数 = 未装箱栈数据）
            if (atomic_load(&g_kill) && enemy) {
                uint8_t dmg[64];
                memset(dmg, 0, sizeof(dmg));
                *(long*)((char*)dmg + g_offDmgValue) = 1000000000L;
                if (g_offDmgSource >= 0 && mainUnit)
                    *(void**)((char*)dmg + g_offDmgSource) = mainUnit;
                fk_invoke(g_mHurt, NULL, (void*[]){u, dmg});
                killed++;
            }
            // 无敌：己方锁满血
            if (atomic_load(&g_inv) && !enemy) {
                void *nc = fk_comp_by_class(u, g_clsNumericComp);
                if (nc) {
                    long maxHp = fk_box_get_long(fk_invoke(g_mGetAsLong, NULL, (void*[]){nc, fk_argnt(NT_MaxHp)}));
                    if (maxHp > 0) {
                        fk_invoke(g_mSetNoEvent, NULL, (void*[]){nc, fk_argnt(NT_CurrentHp), fk_argl(maxHp)});
                        healed++;
                    }
                }
            }
        }
        if (killed) { g_killCnt += killed; flog(@"kill +%d total=%d", killed, g_killCnt); }
        g_lastKilled = killed; g_lastHealed = healed;
        ui_refresh();
    }
}

#pragma mark - UI
#define TAG_BALL  977001
#define TAG_PANEL 977002
#define TAG_ST    977003
#define TAG_MASK  977004
static UILabel *g_statusLabel = nil;
static UIButton *g_bKill = nil, *g_bInv = nil, *g_bSpd = nil;
static void ui_toggle_panel(void);
static void fk_make_ui(void);

@interface FKTickBox : NSObject
+ (instancetype)shared;
- (void)noop;
- (void)tapMask;
- (void)tapKill;
- (void)tapInv;
- (void)tapSpd;
- (void)tapBall;
- (void)dragBall:(UIPanGestureRecognizer *)g;
- (void)onTick;
@end


static UIColor *fk_color(int r, int g, int b, float a) {
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a];
}
static UIButton *fk_btn(NSString *title) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.layer.cornerRadius = 8;
    b.layer.borderWidth = 1;
    b.layer.borderColor = fk_color(90, 160, 255, 0.6).CGColor;
    b.backgroundColor = fk_color(28, 30, 40, 0.95);
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [b setTitleColor:fk_color(220, 225, 235, 1) forState:UIControlStateNormal];
    [b setTitle:title forState:UIControlStateNormal];
    return b;
}
static void fk_set_on(UIButton *b, BOOL on) {
    b.backgroundColor = on ? fk_color(24, 110, 60, 0.95) : fk_color(28, 30, 40, 0.95);
    b.layer.borderColor = (on ? fk_color(60, 220, 130, 0.9) : fk_color(90, 160, 255, 0.6)).CGColor;
}
static void ui_refresh(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_bKill) return;
        [g_bKill setTitle:[NSString stringWithFormat:@"秒杀  %@", atomic_load(&g_kill) ? @"开" : @"关"] forState:UIControlStateNormal];
        [g_bInv  setTitle:[NSString stringWithFormat:@"无敌  %@", atomic_load(&g_inv) ? @"开" : @"关"] forState:UIControlStateNormal];
        [g_bSpd  setTitle:[NSString stringWithFormat:@"加速  %dx", SPD_N[g_spd]] forState:UIControlStateNormal];
        fk_set_on(g_bKill, atomic_load(&g_kill));
        fk_set_on(g_bInv,  atomic_load(&g_inv));
        fk_set_on(g_bSpd,  g_spd > 0);
        NSString *st;
        if (g_status == 0)      st = @"状态：等待热更加载…";
        else if (g_status == 1) st = @"状态：运行时就绪，进关卡生效";
        else {
            NSMutableString *m = [NSMutableString stringWithString:@"状态：战斗中"];
            if (atomic_load(&g_kill) && g_lastKilled) [m appendFormat:@" | 秒杀%d", g_lastKilled];
            if (atomic_load(&g_inv) && g_lastHealed) [m appendFormat:@" | 锁血%d", g_lastHealed];
            if (g_spd > 0) [m appendFormat:@" | %dx", SPD_N[g_spd]];
            st = m;
        }
        g_statusLabel.text = st;
    });
}
static void ui_toggle_panel(void) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow ?: [UIApplication sharedApplication].windows.firstObject;
    UIView *p = [w viewWithTag:TAG_PANEL];
    if (p) {
        [[w viewWithTag:TAG_MASK] removeFromSuperview];
        [p removeFromSuperview];
        return;
    }
    // 紧凑面板：宽 212 / 高 196
    CGFloat pw = 212, ph = 196;
    // 全屏透明遮罩：点任意面板外区域收起（遮罩在悬浮球之下，球仍可点）
    UIView *mask = [[UIView alloc] initWithFrame:w.bounds];
    mask.tag = TAG_MASK;
    mask.backgroundColor = [UIColor clearColor];
    mask.userInteractionEnabled = YES;
    UITapGestureRecognizer *tgm = [[UITapGestureRecognizer alloc] initWithTarget:[FKTickBox shared] action:@selector(tapMask)];
    [mask addGestureRecognizer:tgm];

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(16, 90, pw, ph)];
    panel.tag = TAG_PANEL;
    panel.layer.cornerRadius = 14;
    panel.backgroundColor = fk_color(14, 16, 24, 0.92);
    panel.layer.borderColor = fk_color(70, 140, 255, 0.5).CGColor;
    panel.layer.borderWidth = 1;
    panel.userInteractionEnabled = YES;
    // 点面板本身不收起（吞掉点击）
    UITapGestureRecognizer *tg = [[UITapGestureRecognizer alloc] initWithTarget:[FKTickBox shared] action:@selector(noop)];
    [panel addGestureRecognizer:tg];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 8, pw, 20)];
    title.text = @"✦ 妖怪助手 ✦";
    title.textColor = fk_color(120, 200, 255, 1);
    title.font = [UIFont boldSystemFontOfSize:15];
    title.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:title];

    void (^mk)(int, NSString *, void (^)()) = ^(int row, NSString *t, void (^act)()) {
        UIButton *b = fk_btn(t);
        b.frame = CGRectMake(12, 34 + row * 40, pw - 24, 34);
        [panel addSubview:b];
        act(b);
    };
    mk(0, @"秒杀  关", ^(UIButton *b){ g_bKill = b;
        [b addTarget:[FKTickBox shared] action:@selector(tapKill) forControlEvents:UIControlEventTouchUpInside]; });
    mk(1, @"无敌  关", ^(UIButton *b){ g_bInv = b;
        [b addTarget:[FKTickBox shared] action:@selector(tapInv) forControlEvents:UIControlEventTouchUpInside]; });
    mk(2, @"加速  1x", ^(UIButton *b){ g_bSpd = b;
        [b addTarget:[FKTickBox shared] action:@selector(tapSpd) forControlEvents:UIControlEventTouchUpInside]; });
    g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, ph - 24, pw - 20, 16)];
    g_statusLabel.tag = TAG_ST;
    g_statusLabel.textColor = fk_color(150, 160, 175, 1);
    g_statusLabel.font = [UIFont systemFontOfSize:10];
    g_statusLabel.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:g_statusLabel];

    [w addSubview:mask];
    [w addSubview:panel];
    // 悬浮球保持在遮罩之上
    UIView *ball = [w viewWithTag:TAG_BALL];
    if (ball) [w bringSubviewToFront:ball];
    ui_refresh();
}
static void fk_make_ui(void) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow ?: [UIApplication sharedApplication].windows.firstObject;
    if (!w) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ fk_make_ui(); }); return; }
    if ([w viewWithTag:TAG_BALL]) return;
    UIButton *ball = [UIButton buttonWithType:UIButtonTypeCustom];
    ball.tag = TAG_BALL;
    ball.frame = CGRectMake(w.bounds.size.width - 76, 160, 48, 48);
    ball.backgroundColor = fk_color(20, 24, 36, 0.85);
    ball.layer.cornerRadius = 24;
    ball.layer.borderWidth = 1.5;
    ball.layer.borderColor = fk_color(80, 170, 255, 0.9).CGColor;
    [ball setTitle:@"妖" forState:UIControlStateNormal];
    ball.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    [ball setTitleColor:fk_color(130, 210, 255, 1) forState:UIControlStateNormal];
    [ball addTarget:[FKTickBox shared] action:@selector(tapBall) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[FKTickBox shared] action:@selector(dragBall:)];
    [ball addGestureRecognizer:pan];
    [w addSubview:ball];
    flog(@"UI ready");
}

#pragma mark - 事件盒（UI <-> C 桥）
@implementation FKTickBox
+ (instancetype)shared { static FKTickBox *b; static dispatch_once_t o; dispatch_once(&o, ^{ b = [self new]; }); return b; }
- (void)noop {}
- (void)tapMask { ui_toggle_panel(); }
- (void)tapKill { atomic_fetch_xor(&g_kill, 1); flog(@"kill -> %d", atomic_load(&g_kill)); ui_refresh(); }
- (void)tapInv  { atomic_fetch_xor(&g_inv, 1);  flog(@"inv -> %d",  atomic_load(&g_inv));  ui_refresh(); }
- (void)tapSpd  { g_spd = (g_spd + 1) % 4; g_lastTSscene = NULL; flog(@"spd -> %dx", SPD_N[g_spd]); ui_refresh(); }
- (void)tapBall { ui_toggle_panel(); }
- (void)dragBall:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
- (void)onTick { fk_tick(); }
@end

#pragma mark - 启动
static NSTimer *g_timer = NULL;
static void fk_start_timer(void) {
    if (g_timer) return;
    g_timer = [NSTimer timerWithTimeInterval:1.0 target:[FKTickBox shared] selector:@selector(onTick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:g_timer forMode:NSRunLoopCommonModes];
    flog(@"timer started");
}
__attribute__((constructor)) static void fkyg_ctor(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        flog(@"ctor pid=%d bid=%@", getpid(), bid);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!load_il2cpp_api()) { flog(@"UnityFramework 未加载，非 Unity 环境，静默退出"); return; }
            flog(@"il2cpp api ok");
            fk_start_timer();
            fk_make_ui();
        });
    }
}
