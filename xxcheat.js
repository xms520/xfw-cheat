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
    // kill/inv/ad: bool；cd: 攻速挡位 0-4；eng: 变速挡位 0-3
    // ⚠️ 默认全关：native 不再持久化恢复功能开关，仅卡密持久化
    var F = {
        kill: false,
        inv:  false,
        ad:   false,
        cd:   0,
        eng:  0
    };
    var CD_MUL  = [1, 0.5, 0.25, 0.125, 0.0625]; // OFF/x2/x4/x8/x16
    var ENG_MUL = [1, 2, 4, 8];          // OFF/x2/x4/x8
    var CD_LBL  = ['OFF', 'x2', 'x4', 'x8', 'x16'];
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
            if (kind === 'cd')  { F.cd = Math.max(0, Math.min(4, lvl|0)); lsSet('cd', F.cd);  updateCdMul(); log('spd cd=', CD_LBL[F.cd]); }
            if (kind === 'eng') { F.eng = Math.max(0, Math.min(3, lvl|0)); lsSet('eng', F.eng); log('spd eng=', CD_LBL[F.eng]); }
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
        ['chan',    MOD + 'ChannelCtrl.ts',          'channelCtrl'],
        ['herov',   MOD + 'BattleHeroView.ts',       'BattleHeroView'],
        ['mainv',   MOD + 'BattleMainRoleView.ts',   'BattleMainRoleView'],
        ['hotview', MOD + 'HotUpdateView.ts',        'HotUpdateView'],
        ['loginl',  MOD + 'LoginLayer.ts',           'LoginLayer'],
        ['evtmgr',  MOD + 'EventMgr.ts',             'eventMgr']
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
    var cdMul = 1;             // 当前攻速倍率缓存

    function updateCdMul() { cdMul = CD_MUL[F.cd] || 1; }

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
        // ---- 攻速（挡位）：压 CD；⚠️ getSkillReleaseTime 不压（它是 Release 态看门狗，压小了技能未释放就被回收） ----
        var BS = CLS.skill;
        var oCD = BS.prototype.getSkillCD;
        BS.prototype.getSkillCD = function () {
            var v = oCD.call(this);
            if (cdMul > 1 && (!this._src || this._src.roleType !== ROLE_MONSTER)) v = v * cdMul;
            return v;
        };
        // 英雄/主角色施法动画加速：wrap 基类 playSkillCasting（子类必经），施法时 spine 提速，playIdle 恢复
        // （英雄普攻节奏 = CD + spine 动画时长，动画不加速则攻速被封顶）
        var ROLE_VIEWS = [CLS.herov, CLS.mainv];
        ROLE_VIEWS.forEach(function (V) {
            if (!V || !V.prototype) return;
            var psc = V.prototype.playSkillCasting;
            if (psc) {
                V.prototype.playSkillCasting = function (a, cb, t) {
                    var r = psc.call(this, a, cb, t);
                    // HeroView 单/多段动作都在 playSkillCasting 内部播放：提速
                    try {
                        var base = (this.entity && this.entity.getTimeScale) ? this.entity.getTimeScale() : 1;
                        if (this.spine) this.spine.timeScale = base * cdMul;
                        if (this.skillAnimateSpines) this.skillAnimateSpines.forEach(function (s) { s.timeScale = base * cdMul; });
                    } catch (e) {}
                    return r;
                };
            }
            var pi = V.prototype.playIdle;
            if (pi) {
                V.prototype.playIdle = function () {
                    try {
                        var base = (this.entity && this.entity.getTimeScale) ? this.entity.getTimeScale() : 1;
                        if (this.spine) this.spine.timeScale = base;
                        if (this.skillAnimateSpines) this.skillAnimateSpines.forEach(function (s) { s.timeScale = base; });
                    } catch (e) {}
                    return pi.apply(this, arguments);
                };
            }
        });
        updateCdMul();
        log('cd patch ok (CD + anim speed)');
        // ---- 修"更新失败"：CDN 已 404，跳过热更检查直接进游戏 ----
        // HotUpdateView.checkUpdate → 不发远端检查，直接 emit HotUpdateComplete（原 ALREADY_UP_TO_DATE 分支行为）
        try {
            var HV = CLS.hotview;
            var EM = CLS.evtmgr;
            if (HV && HV.prototype) {
                HV.prototype.checkUpdate = function () {
                    log('hotupdate skipped -> goto game');
                    try { if (EM) EM.emit('HotUpdateComplete'); } catch (e) { log('emit exc', e); }
                };
                log('hotupdate patch ok');
            }
        } catch (e) { log('hotupdate patch exc', e); }
        // ---- 免广告 ----
        var chan = CLS.chan && CLS.chan.Channel;
        if (chan) {
            chan.createRewardedVideoAd = function (id, successcb, failcb) {
                if (F.ad) { try { successcb && successcb(); } catch (e) { log('ad cb exc', e); } return; }
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

    // ---------- 引擎级变速（cc.game._calculateDT，实例方法非 prototype） ----------
    function enginePatch() {
        System.import('cc').then(function (cc) {
            try {
                var g = cc.game;
                // 3.8.x: cc.game 是 Director 实例（mainLoop 里 o.game._calculateDT(!1)）
                if (g && typeof g._calculateDT === 'function') {
                    var oCalc = g._calculateDT.bind(g);
                    g._calculateDT = function (t) {
                        var dt = oCalc(t);
                        if (F.eng > 0) dt *= ENG_MUL[F.eng];
                        return dt;
                    };
                    engineSpdOk = true;
                    log('engine spd patch ok (game._calculateDT)');
                    return;
                }
                // 兜底：Director.prototype 上找
                var D = cc.Director;
                if (D && D.prototype && D.prototype._calculateDT) {
                    var oCalc2 = D.prototype._calculateDT;
                    D.prototype._calculateDT = function () {
                        var dt = oCalc2.apply(this, arguments);
                        if (F.eng > 0) dt *= ENG_MUL[F.eng];
                        return dt;
                    };
                    engineSpdOk = true;
                    log('engine spd patch ok (Director.prototype._calculateDT)');
                    return;
                }
                log('WARN _calculateDT missing, engine spd fallback to battle timescale');
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
