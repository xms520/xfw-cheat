/**
 * XXCheat v3 — 下方了 (Cocos 3.8.7 jsb / V8 引擎)
 * 注入方式：native dylib 通过 se::ScriptEngine::evalString 注入本文件
 *   秒杀  = 跟踪 BattleMonster 实例，tick 直写 _hp=0 + state=Die + recoveryView + battle.removeMonster
 *   无敌  = 包装 BattleRoleBase/BattleWall/BattleLifeSummonedCreatures 的 hp setter，己方(roleType!==Monster)禁减血
 *   无CD  = BattleSkill.getSkillCD 返回 0.01（仅己方，怪物技能保原CD）
 * UI 由 native FloatGlass 悬浮窗提供，本文件只做逻辑 + __XXC 桥
 * ⚠️ BattleDropCtrl.monsterDrop 无幂等保护 → 秒杀自带 __xfwKilled 防重
 */
(function () {
    'use strict';
    if (typeof window !== 'undefined' && window.__XXC) return; // 防重复注入
    var TAG = '[XXC]';
    var VER = 'v3';
    var G = (typeof window !== 'undefined') ? window : globalThis;

    function log() {
        var s = TAG + ' ' + Array.prototype.slice.call(arguments).map(function (x) {
            try { return (x instanceof Error) ? (x.message + '|' + (x.stack || '').split('\n')[1]) : String(x); }
            catch (e) { return '?'; }
        }).join(' ');
        try { console.log(s); } catch (e) {}
        try { jsbLog(s); } catch (e) {}
    }
    var _logLines = [];
    function jsbLog(s) {
        _logLines.push(s);
        if (_logLines.length > 300) _logLines.splice(0, _logLines.length - 300);
        if (_logLines.length % 20 === 1 && typeof jsb !== 'undefined' && jsb.fileUtils) {
            try {
                jsb.fileUtils.writeStringToFile(_logLines.join('\n'),
                    jsb.fileUtils.getWritablePath() + 'xxcheat.log');
            } catch (e) {}
        }
    }

    // ---------- 标志（native 面板可运行时覆盖） ----------
    var F = {
        kill: lsGet('kill') === '1',
        inv:  lsGet('inv') === '1',
        cd:   lsGet('cd') === '1'
    };
    function lsGet(k) { try { return localStorage.getItem('xfc_' + k) || ''; } catch (e) { return ''; } }
    function lsSet(k, v) { try { localStorage.setItem('xfc_' + k, v ? '1' : '0'); } catch (e) {} }

    // ---------- 全局桥（native 面板调用） ----------
    G.__XXC = {
        ver: VER,
        setFlag: function (k, v) {
            if (k in F) {
                F[k] = !!v;
                lsSet(k, F[k]);
                log('setFlag', k, F[k]);
            }
        },
        getFlags: function () { return { kill: F.kill, inv: F.inv, cd: F.cd }; },
        stats: { kills: 0, monsters: 0 }
    };

    // ---------- SystemJS 模块定位 ----------
    var MOD = 'chunks:///_virtual/';
    var NEED = [
        ['monster', MOD + 'BattleMonster.ts',        'BattleMonster'],
        ['base',    MOD + 'BattleRoleBase.ts',       'BattleRoleBase'],
        ['skill',   MOD + 'BattleSkill.ts',          'BattleSkill'],
        ['wall',    MOD + 'BattleWall.ts',           'BattleWall'],
        ['life',    MOD + 'BattleLifeSummonedCreatures.ts', 'BattleLifeSummonedCreatures']
    ];
    var CLS = {};
    function getNs(key, exp) {
        try {
            var ns = System.get(key);
            return (ns && ns[exp]) ? ns[exp] : null;
        } catch (e) { return null; }
    }
    var patchDone = false;
    function tryPatch() {
        var ok = true;
        for (var i = 0; i < NEED.length; i++) {
            var it = NEED[i];
            if (!CLS[it[0]]) {
                var c = getNs(it[1], it[2]);
                if (c) CLS[it[0]] = c; else ok = false;
            }
        }
        if (!ok) return false;
        if (patchDone) return true;
        patchDone = true;
        doPatch();
        return true;
    }

    var MONS = new Set();
    var ROLE_MONSTER = 3; // BattleRoleType.Monster
    var ST_DIE = 3;       // MonsterStateEnum.Die

    function doPatch() {
        // ---- 无敌：包装 hp setter（己方禁减血；不设 invincibleSemaphore，alive 会假死） ----
        wrapHp(CLS.base); wrapHp(CLS.wall); wrapHp(CLS.life);
        log('inv patch ok');
        // ---- 秒杀：跟踪怪物实例（池复用 init 清标记 / onFree 移除） ----
        var BM = CLS.monster;
        var oInit = BM.prototype.init;
        BM.prototype.init = function () {
            try { this.__xfwKilled = 0; MONS.add(this); } catch (e) {}
            return oInit.apply(this, arguments);
        };
        var oFree = BM.prototype.onFree;
        BM.prototype.onFree = function () { MONS.delete(this); return oFree.apply(this, arguments); };
        log('kill track ok');
        // ---- 无CD：getSkillCD → 0.01（仅己方） ----
        var BS = CLS.skill;
        var oCD = BS.prototype.getSkillCD;
        BS.prototype.getSkillCD = function () {
            if (F.cd && this._src && this._src.roleType !== ROLE_MONSTER) return 0.01;
            return oCD.call(this);
        };
        log('cd patch ok');
    }

    function wrapHp(cls) {
        var d = Object.getOwnPropertyDescriptor(cls.prototype, 'hp');
        if (!d || !d.set) { log('wrapHp FAIL', cls && cls.name); return; }
        var orig = d.set;
        Object.defineProperty(cls.prototype, 'hp', {
            get: d.get,
            set: function (v) {
                if (F.inv && this._hp > 0 && v < this._hp && this._roleType !== ROLE_MONSTER) return;
                orig.call(this, v);
            },
            configurable: true,
            enumerable: false
        });
    }

    // ---------- 秒杀 tick ----------
    function killTick() {
        if (!F.kill || MONS.size === 0) { G.__XXC.stats.monsters = MONS.size; return; }
        var n = 0;
        MONS.forEach(function (m) {
            if (m.__xfwKilled) return;
            if (typeof m._hp !== 'number' || !m.battle) return;
            if (m._hp > 0) {
                m.__xfwKilled = 1;
                try {
                    m._hp = 0;          // 直写字段：绕开 setter 的 Boss 战守卫
                    m._state = ST_DIE;
                    if (m.recoveryView) m.recoveryView();
                    m.battle.removeMonster(m);   // 掉落/移除/记录全真
                    n++;
                } catch (e) { log('kill exc', e); }
            }
        });
        if (n) { G.__XXC.stats.kills += n; log('kill n=' + n + ' total=' + G.__XXC.stats.kills); }
        G.__XXC.stats.monsters = MONS.size;
    }

    // ---------- 定时器（native setInterval 缺失时引擎帧驱动兜底） ----------
    function every(ms, fn) {
        if (typeof setInterval === 'function') return setInterval(fn, ms);
        System.import('cc').then(function (cc) {
            try { cc.director.on(cc.Director.EVENT_BEFORE_UPDATE, function () { fn(); }); } catch (e) { log('frame tick exc', e); }
        }).catch(function () {});
    }
    var t0 = Date.now(), warned = false;
    function poll() {
        var patched = tryPatch();
        if (!patched && !warned && Date.now() - t0 > 90000) { warned = true; log('WARN class wait timeout'); }
        killTick();
    }
    every(250, poll);
    // native 验证标记：注入成功后写文件
    try {
        if (typeof jsb !== 'undefined' && jsb.fileUtils) {
            jsb.fileUtils.writeStringToFile(String(VER),
                jsb.fileUtils.getWritablePath() + 'xxcheat_injected.flag');
        }
    } catch (e) {}
    log('loaded', VER, 'flags kill=' + F.kill, 'inv=' + F.inv, 'cd=' + F.cd);
})();
