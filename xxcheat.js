/**
 * XXCheat v4 — 下方了 (Cocos 3.8.7 jsb / V8 引擎)
 * native XXCFloat.dylib 经 se::ScriptEngine::evalString 注入
 *   秒杀   = 跟踪 BattleMonster，直写 _hp=0 + state=Die + 立即隐身 view + 分步移除（防卡顶/防卡过关）
 *   无敌   = 包装 BattleRoleBase/BattleWall/BattleLifeSummonedCreatures 的 hp setter（己方禁减血）
 *   攻速   = BattleSkill.getSkillCD × [1/0.5/0.25/0.125]（仅己方，挡位由 native 面板循环）
 *   免广告 = patch Channel.createRewardedVideoAd → 直接 successcb（跳过广告 SDK，奖励照发）
 *   变速   = patch Director._calculateDT 全局 dt 缩放 [1/2/4/8]；不可用时退化为战斗内 setTimeScale
 * UI 全在 native 面板；本文件只做逻辑 + __XXC 桥
 */
(function () {
    'use strict';
    var G = (typeof window !== 'undefined') ? window : globalThis;
    if (G.__XXC) return; // 防重复注入
    var TAG = '[XXC]';
    var VER = 'v4';

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

    // ---------- 标志（native 面板运行时覆盖） ----------
    // kill/inv/ad: bool；cd: 攻速挡位 0-3；eng: 变速挡位 0-3
    var F = {
        kill: lsGet('kill') === '1',
        inv:  lsGet('inv') === '1',
        ad:   lsGet('ad') === '1',
        cd:   parseInt(lsGet('cd') || '0', 10) || 0,
        eng:  parseInt(lsGet('eng') || '0', 10) || 0
    };
    var CD_MUL  = [1, 0.5, 0.25, 0.125]; // OFF/x2/x4/x8
    var ENG_MUL = [1, 2, 4, 8];          // OFF/x2/x4/x8
    var CD_LBL  = ['OFF', 'x2', 'x4', 'x8'];
    function lsGet(k) { try { return localStorage.getItem('xfc_' + k) || ''; } catch (e) { return ''; } }
    function lsSet(k, v) { try { localStorage.setItem('xfc_' + k, v); } catch (e) {} }

    // ---------- 全局桥 ----------
    G.__XXC = {
        ver: VER,
        setFlag: function (k, v) {
            if (k in F) {
                F[k] = !!v;
                lsSet(k, F[k] ? '1' : '0');
                log('setFlag', k, F[k]);
            }
        },
        setSpd: function (kind, lvl) {
            lvl = Math.max(0, Math.min(3, lvl | 0));
            if (kind === 'cd')  { F.cd = lvl;  lsSet('cd', lvl);  log('spd cd=', CD_LBL[lvl]); }
            if (kind === 'eng') { F.eng = lvl; lsSet('eng', lvl); log('spd eng=', CD_LBL[lvl]); }
        },
        getFlags: function () { return JSON.stringify(F); },
        stats: { kills: 0, monsters: 0 }
    };

    // ---------- SystemJS 模块定位 ----------
    var MOD = 'chunks:///_virtual/';
    var NEED = [
        ['monster', MOD + 'BattleMonster.ts',        'BattleMonster'],
        ['base',    MOD + 'BattleRoleBase.ts',       'BattleRoleBase'],
        ['skill',   MOD + 'BattleSkill.ts',          'BattleSkill'],
        ['wall',    MOD + 'BattleWall.ts',           'BattleWall'],
        ['life',    MOD + 'BattleLifeSummonedCreatures.ts', 'BattleLifeSummonedCreatures'],
        ['move',    MOD + 'MonsterMoveCtrl.ts',      'MonsterMoveCtrl'],
        ['sort',    MOD + 'MonsterSortCtrl.ts',      'MonsterSortCtrl'],
        ['drop',    MOD + 'BattleDropCtrl.ts',       'BattleDropCtrl'],
        ['rec',     MOD + 'BattleRecordPlugin.ts',   'BattleRecordPlugin'],
        ['chan',    MOD + 'ChannelCtrl.ts',          'channelCtrl']
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
    var engineSpdOk = false;   // 引擎级变速是否挂上（挂上则战斗内不重复加速）
    var lastBattle = null;

    function doPatch() {
        // ---- 无敌 ----
        wrapHp(CLS.base); wrapHp(CLS.wall); wrapHp(CLS.life);
        log('inv patch ok');
        // ---- 秒杀跟踪 ----
        var BM = CLS.monster;
        var oInit = BM.prototype.init;
        BM.prototype.init = function () {
            try { this.__xfwKilled = 0; MONS.add(this); } catch (e) {}
            return oInit.apply(this, arguments);
        };
        var oFree = BM.prototype.onFree;
        BM.prototype.onFree = function () { MONS.delete(this); return oFree.apply(this, arguments); };
        log('kill track ok');
        // ---- 攻速（挡位） ----
        var BS = CLS.skill;
        var oCD = BS.prototype.getSkillCD;
        BS.prototype.getSkillCD = function () {
            if (F.cd > 0 && (!this._src || this._src.roleType !== ROLE_MONSTER)) {
                return oCD.call(this) * CD_MUL[F.cd];
            }
            return oCD.call(this);
        };
        log('cd patch ok');
        // ---- 免广告：跳过广告 SDK 直接发奖（服务器次数限制不受影响） ----
        var chan = CLS.chan && CLS.chan.Channel;
        if (chan) {
            chan.createRewardedVideoAd = function (id, successcb, failcb) {
                if (F.ad) { try { successcb && successcb(); } catch (e) { log('ad cb exc', e); } return; }
                // 走原型原实现
                var p = Object.getPrototypeOf(chan);
                if (p && p.createRewardedVideoAd && p.createRewardedVideoAd !== arguments.callee) {
                    return p.createRewardedVideoAd.call(this, id, successcb, failcb);
                }
                try { successcb && successcb(); } catch (e) { log('ad cb2 exc', e); }
            };
            log('ad patch ok');
        } else {
            log('WARN channel not found, ad patch skip');
        }
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

    // ---------- 引擎级变速（全局 dt 缩放） ----------
    function enginePatch() {
        System.import('cc').then(function (cc) {
            try {
                var D = cc.Director;
                if (D && D.prototype && D.prototype._calculateDT) {
                    var oCalc = D.prototype._calculateDT;
                    D.prototype._calculateDT = function () {
                        var dt = oCalc.apply(this, arguments);
                        if (F.eng > 0) dt *= ENG_MUL[F.eng];
                        return dt;
                    };
                    engineSpdOk = true;
                    log('engine spd patch ok (_calculateDT)');
                } else {
                    log('WARN _calculateDT missing, engine spd fallback to battle timescale');
                }
            } catch (e) { log('engine spd exc', e); }
        }).catch(function () {});
    }

    // ---------- 秒杀 ----------
    function killOne(m) {
        m._hp = 0;
        m._state = ST_DIE;
        // 立即隐身 + 停掉动画：防"卡在屏幕顶部不动的怪"（出生动画中被打死时 playDie 回调链可能不完整）
        try {
            if (m.view && m.view.node) {
                m.view.node.active = false;
                var sk = m.view.getComponent && m.view.getComponent('sp.Skeleton');
                // 不强制清理 Skeleton 状态，交由 recoveryView/playDie 正常回池
            }
        } catch (e) {}
        try { if (m.recoveryView) m.recoveryView(); } catch (e) {}
        var bt = m.battle;
        if (!bt) return;
        lastBattle = bt;
        try { if (CLS.drop && bt.getCtrl) bt.getCtrl(CLS.drop).monsterDrop(m); } catch (e) {}
        try { if (CLS.move && bt.getCtrl) bt.getCtrl(CLS.move).removeMonster(m); } catch (e) {}
        try { if (CLS.sort && bt.getCtrl) bt.getCtrl(CLS.sort).removeMonster(m); } catch (e) {}
        try { if (CLS.rec && bt.getPlugin) bt.getPlugin(CLS.rec).removeMonster(m); } catch (e) {}
    }

    function battleSpdTick() {
        // 引擎级变速没挂上时，战斗内用 PveBattle.setTimeScale 兜底
        if (engineSpdOk || F.eng === 0) return;
        var bt = lastBattle;
        if (!bt) {
            MONS.forEach(function (m) { if (!bt && m.battle) bt = lastBattle = m.battle; });
        }
        if (bt && bt._timeScale !== ENG_MUL[F.eng]) {
            try { bt.setTimeScale(ENG_MUL[F.eng]); } catch (e) {}
        }
    }

    function killTick() {
        if (!F.kill || MONS.size === 0) { G.__XXC.stats.monsters = MONS.size; return; }
        var n = 0;
        MONS.forEach(function (m) {
            if (m.__xfwKilled) return;
            if (typeof m._hp !== 'number' || !m.battle) return;
            if (m._hp > 0) {
                try { killOne(m); n++; } catch (e) { log('kill exc', e); }
            }
        });
        if (n) { G.__XXC.stats.kills += n; log('kill n=' + n + ' total=' + G.__XXC.stats.kills); }
        G.__XXC.stats.monsters = MONS.size;
    }

    // ---------- 定时器 ----------
    function every(ms, fn) {
        if (typeof setInterval === 'function') return setInterval(fn, ms);
        System.import('cc').then(function (cc) {
            try { cc.director.on(cc.Director.EVENT_BEFORE_UPDATE, function () { fn(); }); } catch (e) {}
        }).catch(function () {});
    }
    var t0 = Date.now(), warned = false;
    function poll() {
        var patched = tryPatch();
        if (!patched && !warned && Date.now() - t0 > 90000) { warned = true; log('WARN class wait timeout'); }
        killTick();
        battleSpdTick();
    }
    every(250, poll);
    enginePatch();
    try {
        if (typeof jsb !== 'undefined' && jsb.fileUtils) {
            jsb.fileUtils.writeStringToFile(String(VER),
                jsb.fileUtils.getWritablePath() + 'xxcheat_injected.flag');
        }
    } catch (e) {}
    log('loaded', VER, 'flags', JSON.stringify(F));
})();
