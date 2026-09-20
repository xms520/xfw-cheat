/**
 * XXCheat v1 — 下方了 1.0.6 (Cocos Creator 3.8.7 jsb)
 * 注入点：main.js 在 require("src/system.bundle.js") 之后 require 本文件
 * 原理：轮询 SystemJS registry 拿游戏类 → 原型 patch
 *   秒杀  = 跟踪 BattleMonster 实例，tick 直接 _hp=0 + state=Die + recoveryView + battle.removeMonster
 *   无敌  = 包装 BattleRoleBase/BattleWall/BattleLifeSummonedCreatures 的 hp setter，己方(roleType!==Monster)禁减血
 *   无CD  = BattleSkill.getSkillCD 返回 0.01
 * ⚠️ 对象池复用：init 清标记 / onFree 移出集合
 * ⚠️ BattleDropCtrl.monsterDrop 无幂等保护 → 秒杀用 __xfwKilled 防重
 */
(function () {
    'use strict';
    var TAG = '[XXC]';
    var VER = 'v2';
    try { (typeof window !== 'undefined' ? window : this).__XXC = { ver: VER }; } catch (e) {}

    function log() {
        var s = TAG + ' ' + Array.prototype.slice.call(arguments).map(function (x) {
            try { return (x instanceof Error) ? (x.message + '|' + (x.stack || '').split('\n')[1]) : String(x); }
            catch (e) { return '?'; }
        }).join(' ');
        try { console.log(s); } catch (e) {}
        try { jsbLog(s); } catch (e) {}
    }

    // ---------- 文件日志（可写目录，方便真机取证） ----------
    var _logLines = [];
    function jsbLog(s) {
        _logLines.push(s);
        if (_logLines.length > 400) _logLines.splice(0, _logLines.length - 400);
        if (_logLines.length % 20 === 1 && typeof jsb !== 'undefined' && jsb.fileUtils) {
            try {
                jsb.fileUtils.writeStringToFile(_logLines.join('\n'),
                    jsb.fileUtils.getWritablePath() + 'xxcheat.log');
            } catch (e) {}
        }
    }

    // ---------- 开关持久化 ----------
    var F = {
        kill: lsGet('kill') === '1',
        inv:  lsGet('inv') === '1',
        cd:   lsGet('cd') === '1'
    };
    function lsGet(k) { try { return localStorage.getItem('xfc_' + k) || ''; } catch (e) { return ''; } }
    function lsSet(k, v) { try { localStorage.setItem('xfc_' + k, v ? '1' : '0'); } catch (e) {} }

    // ---------- 等待 SystemJS 模块 ----------
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

    // ---------- 主 patch ----------
    var MONS = new Set();
    var g_kills = 0;
    var ROLE_MONSTER = 3; // BattleRoleType.Monster
    var ST_DIE = 3;       // MonsterStateEnum.Die

    function doPatch() {
        // ---- 无敌：包装 hp setter（己方禁减血） ----
        wrapHp(CLS.base);
        wrapHp(CLS.wall);
        wrapHp(CLS.life);
        log('inv patch ok');

        // ---- 秒杀：跟踪怪物实例 ----
        var BM = CLS.monster;
        var oInit = BM.prototype.init;
        BM.prototype.init = function () {
            try { this.__xfwKilled = 0; MONS.add(this); } catch (e) {}
            return oInit.apply(this, arguments);
        };
        var oFree = BM.prototype.onFree;
        BM.prototype.onFree = function () {
            MONS.delete(this);
            return oFree.apply(this, arguments);
        };
        log('kill track ok');

        // ---- 无CD：getSkillCD -> 0.01（⚠️ 仅己方：怪物技能保持原CD，否则怪物也连发） ----
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
        var nd = {
            get: d.get,
            set: function (v) {
                if (F.inv && this._hp > 0 && v < this._hp && this._roleType !== ROLE_MONSTER) return;
                orig.call(this, v);
            },
            configurable: true,
            enumerable: false
        };
        Object.defineProperty(cls.prototype, 'hp', nd);
    }

    // ---------- 秒杀 tick ----------
    function killTick() {
        if (!F.kill || MONS.size === 0) return;
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
                    m.battle.removeMonster(m);
                    n++;
                } catch (e) { log('kill exc', e); }
            }
        });
        if (n) { g_kills += n; log('kill n=' + n + ' total=' + g_kills); }
    }

    // ================= UI =================
    var uiReady = false, ball = null, panel = null, statusLb = null;
    var W = 250, H = 296, ROWS = [];

    function buildUI(cc) {
        if (uiReady) return;
        var scene = cc.director.getScene();
        if (!scene) return;
        var canvas = null;
        try { canvas = scene.getChildByName('Canvas'); } catch (e) {}
        if (!canvas) { try { canvas = scene.getComponentInChildren(cc.Canvas) && scene.getComponentInChildren(cc.Canvas).node; } catch (e) {} }
        if (!canvas) return;
        var UI2D = (cc.Layers && cc.Layers.Enum && cc.Layers.Enum.UI_2D) || (1 << 25);

        function mkNode(name, w, h, parent) {
            var n = new cc.Node(name);
            n.layer = UI2D;
            var ut = n.addComponent(cc.UITransform);
            ut.setContentSize(w, h);
            if (parent) n.setParent(parent);
            return n;
        }
        function mkBg(n, color, r) {
            var g = n.addComponent(cc.Graphics);
            g.fillColor = color; g.strokeColor = color; g.lineWidth = 1;
            var ut = n.getComponent(cc.UITransform);
            g.roundRect(-ut.width / 2, -ut.height / 2, ut.width, ut.height, r === undefined ? 12 : r);
            g.fill();
            return g;
        }
        function mkLabel(parent, str, size, color, bold) {
            var n = mkNode('lb', 0, 0, parent);
            var lb = n.addComponent(cc.Label);
            lb.string = str; lb.fontSize = size; lb.lineHeight = size + 4;
            lb.color = color || cc.color(235, 235, 240, 255);
            lb.isBold = !!bold;
            lb.horizontalAlign = cc.Label.Align.CENTER;
            lb.verticalAlign = cc.Label.Align.CENTER;
            return { n: n, lb: lb };
        }

        // ---- 悬浮球 ----
        ball = mkNode('XXCBall', 54, 54, canvas);
        mkBg(ball, cc.color(20, 120, 240, 235), 14);
        var bl = mkLabel(ball, '改', 24, cc.color(255, 255, 255, 255), true);
        bl.n.setPosition(0, 0);
        var vs = cc.view.getVisibleSize();
        ball.setPosition(vs.width / 2 - 44, -vs.height / 2 + 120, 0);

        // ---- 面板 ----
        panel = mkNode('XXCPanel', W, H, canvas);
        mkBg(panel, cc.color(26, 28, 34, 242), 14);
        panel.active = false;
        var title = mkLabel(panel, '下方了改 ' + VER, 19, cc.color(120, 200, 255, 255), true);
        title.n.setPosition(0, H / 2 - 24);

        ROWS = [];
        var defs = [
            ['秒杀', 'kill', '全场怪物即死'],
            ['无敌', 'inv', '墙/英雄/召唤物不掉血'],
            ['技能无CD', 'cd', '技能冷却近乎为零']
        ];
        for (var i = 0; i < defs.length; i++) {
            (function (idx) {
                var d = defs[idx];
                var rn = mkNode('row' + idx, W - 20, 46, panel);
                mkBg(rn, cc.color(46, 50, 60, 255), 10);
                rn.setPosition(0, H / 2 - 66 - idx * 54);
                var lb = mkLabel(rn, '', 18, cc.color(255, 255, 255, 255), true);
                lb.n.setPosition(-(W - 20) / 2 + 14, 0);
                lb.lb.horizontalAlign = cc.Label.Align.LEFT;
                var hint = mkLabel(rn, d[2], 11, cc.color(150, 155, 165, 255));
                hint.n.setPosition(10, -15);
                hint.lb.horizontalAlign = cc.Label.Align.RIGHT;
                ROWS.push({ node: rn, key: d[1], name: d[0], lb: lb.lb });
            })(i);
        }
        var st = mkLabel(panel, '', 12, cc.color(160, 220, 160, 255));
        st.n.setPosition(0, -H / 2 + 34);
        statusLb = st.lb;
        var tip = mkLabel(panel, '面板可拖动 · 状态自动保存', 10, cc.color(120, 125, 135, 255));
        tip.n.setPosition(0, -H / 2 + 14);

        refreshRows();

        // ---- 统一手势：拖动 / 点按（END 时按 moved 区分，避免拖完误触发点击） ----
        function bindUI(node, onEnd) {
            var sx = 0, sy = 0, ox = 0, oy = 0, moved = false;
            node.on(cc.Node.EventType.TOUCH_START, function (e) {
                var p = e.getUILocation();
                sx = p.x; sy = p.y; ox = node.position.x; oy = node.position.y; moved = false;
            });
            node.on(cc.Node.EventType.TOUCH_MOVE, function (e) {
                var p = e.getUILocation();
                var dx = p.x - sx, dy = p.y - sy;
                if (Math.abs(dx) + Math.abs(dy) > 8) moved = true;
                if (moved) {
                    var vsz = cc.view.getVisibleSize();
                    var nx = Math.max(-vsz.width / 2 + 20, Math.min(vsz.width / 2 - 20, ox + dx));
                    var ny = Math.max(-vsz.height / 2 + 20, Math.min(vsz.height / 2 - 20, oy + dy));
                    node.setPosition(nx, ny, 0);
                }
            });
            node.on(cc.Node.EventType.TOUCH_END, function (e) {
                onEnd(moved, e.getUILocation());
            });
            node.on(cc.Node.EventType.TOUCH_CANCEL, function () {});
        }

        bindUI(ball, function (moved) { if (!moved) { panel.active = !panel.active; if (panel.active) statusTickUI(); } });
        // 面板：拖动由 bindUI 处理；未移动 = 判定开关行点击
        bindUI(panel, function (moved, uiP) {
            if (moved) return;
            var lp = panel.getComponent(cc.UITransform).convertToNodeSpaceAR(uiP);
            for (var i = 0; i < ROWS.length; i++) {
                var r = ROWS[i];
                var ry = r.node.position.y;
                if (Math.abs(lp.x) <= (W - 20) / 2 && lp.y <= ry + 23 && lp.y >= ry - 23) {
                    F[r.key] = !F[r.key];
                    lsSet(r.key, F[r.key]);
                    refreshRows();
                    log('toggle', r.key, F[r.key]);
                    statusTickUI();
                    return;
                }
            }
        });

        uiReady = true;
        log('ui ok');
    }

    function refreshRows() {
        for (var i = 0; i < ROWS.length; i++) {
            var r = ROWS[i];
            var on = !!F[r.key];
            r.lb.string = (on ? '[ON]  ' : '[OFF] ') + r.name;
            r.lb.color = on ? cc.color(90, 230, 130, 255) : cc.color(210, 210, 215, 255);
        }
    }

    function statusTickUI() {
        if (statusLb && panel && panel.active) {
            statusLb.string = '怪物:' + MONS.size + ' 已杀:' + g_kills;
        }
    }

    // ---------- 引擎等待 + 主循环 ----------
    var t0 = Date.now(), ccTried = 0, warned = false;
    function poll() {
        // 1) 等游戏类注册并 patch
        var patched = tryPatch();
        if (!patched && !warned && Date.now() - t0 > 90000) { warned = true; log('WARN 类等待超时'); }
        // 2) 拿 cc 建 UI
        if (!uiReady && typeof System !== 'undefined') {
            ccTried++;
            if (ccTried % 20 === 1) {
                System.import('cc').then(function (cc) {
                    try { buildUI(cc); } catch (e) { log('ui exc', e); }
                }).catch(function () {});
            }
        }
        killTick();
        statusTickUI();
    }

    function ensureUIAlive() {
        if (!uiReady) return;
        try {
            if (!ball || !ball.isValid || !ball.parent) uiReady = false; // 场景切换后重建
            if (uiReady && panel && panel.active) statusTickUI();
        } catch (e) { uiReady = false; }
    }

    // 定时器抽象：native jsb 无 setInterval 时用引擎帧驱动兜底（dylib 注入场景）
    function every(ms, fn) {
        if (typeof setInterval === 'function') return setInterval(fn, ms);
        System.import('cc').then(function (cc) {
            try { cc.director.on(cc.Director.EVENT_BEFORE_UPDATE, function () { fn(); }); } catch (e) { log('frame tick exc', e); }
        }).catch(function () {});
    }
    every(250, poll);
    every(1000, ensureUIAlive);
    log('loaded', VER, 'flags kill=' + F.kill, 'inv=' + F.inv, 'cd=' + F.cd);
})();
