/* GYZWCheat v2 - 光阴之外 JS 逻辑层
 * v2 修复:
 *  1. 挂点修正: 模块为命名导出 exports.default(BtDmgMgr) / exports.BattleViewHelper / exports.AdHelper
 *     v1 挂在 exports 顶层 = 没挂上(日志 dmg:false 实锤)
 *  2. 每 tick 验证 wrap 存活(引用比对), 丢失自动重挂
 *  3. 重注入幂等(桥重建覆盖, patch 有 __gyzwW 标记)
 * 挂点:
 *  - BtDmgMgr.prototype.updateTargetHp(dmg,target,attacker,shield,skillId)  [实例方法, 类=exports.default]
 *  - BattleViewHelper.getBattleSpeed(scene).trueSpeed                       [静态]
 *  - AdHelper.isAdFree()                                                    [静态]
 * EUnitType: Lord=1 Hero=2 Monster=3 Bullet=4 Trap=5 Tower=6 AffairNpc=7
 */
(function () {
  var F = { kill: false, inv: false, spd: 0, ad: false }; // spd: 0=官方 1=x2 2=x4 3=x8 4=x16
  var SPD = [1, 2, 4, 8, 16];
  var S = { kill: 0, hit: 0 };
  var UTYPE_HERO = 2, UTYPE_MONSTER = 3;
  var patched = { dmg: false, spd: false, ad: false };

  function wlog(msg) {
    try {
      var t = new Date().toISOString().substr(11, 8);
      var p = jsb.fileUtils.getWritablePath() + "gyzw.log";
      var old = jsb.fileUtils.isFileExist(p) ? (jsb.fileUtils.getStringFromFile(p) || "") : "";
      if (old.length > 60000) old = old.substr(old.length - 30000); // 防无限膨胀
      jsb.fileUtils.writeStringToFile(old + "[" + t + "] " + msg + "\n", p);
    } catch (e) {}
  }

  // 命名导出模块获取: __require("X").Sub 或 __require("X").default
  function getMod(name, sub) {
    try {
      var m = window.__require(name);
      if (!m) return null;
      if (sub) return m[sub] || null;
      return m;
    } catch (e) { return null; }
  }

  // ---------- patch: 广告 ----------
  function patchAd() {
    var AH = getMod("AdHelper", "AdHelper") || getMod("AdHelper");
    if (!AH || typeof AH.isAdFree !== "function") return;
    if (AH.__gyzwW) { patched.ad = true; return; } // 已 wrap
    var orig = AH.isAdFree;
    AH.isAdFree = function () {
      try { if (F.ad) return true; } catch (e) {}
      return orig.apply(this, arguments);
    };
    AH.__gyzwW = orig;
    patched.ad = true;
    wlog("patch AdHelper.isAdFree ok(v2)");
  }

  // ---------- patch: 战斗速度 ----------
  function patchSpeed() {
    var BVH = getMod("BattleViewHelper", "BattleViewHelper") || getMod("BattleViewHelper");
    if (!BVH || typeof BVH.getBattleSpeed !== "function") return;
    if (BVH.__gyzwW) { patched.spd = true; return; }
    var orig = BVH.getBattleSpeed;
    BVH.getBattleSpeed = function (scene) {
      var r = null;
      try { r = orig.apply(this, arguments); } catch (e) {}
      if (!r) r = { trueSpeed: 1 };
      if (F.spd > 0 && SPD[F.spd]) {
        r = Object.assign({}, r);
        r.trueSpeed = SPD[F.spd];
        if ("speed" in r) r.speed = SPD[F.spd];
        if ("name" in r) r.name = "x" + SPD[F.spd];
      }
      return r;
    };
    BVH.__gyzwW = orig;
    patched.spd = true;
    wlog("patch BattleViewHelper.getBattleSpeed ok(v2)");
  }

  // ---------- patch: 伤害(秒杀/无敌) ----------
  function patchDmg() {
    var BDM = getMod("BtDmgMgr", "default") || getMod("BtDmgMgr");
    if (!BDM || !BDM.prototype || typeof BDM.prototype.updateTargetHp !== "function") return;
    if (BDM.prototype.__gyzwW) { patched.dmg = true; return; }
    var orig = BDM.prototype.updateTargetHp;
    BDM.prototype.updateTargetHp = function (dmg, target, attacker, shieldDecHp, skillId) {
      try {
        if (target && dmg < 0) {
          // 无敌: 己方(Lord=1/Hero=2)承伤直接吞掉(不进原函数=不触发后续)
          if (F.inv && (target.type === 1 || target.type === UTYPE_HERO)) {
            S.hit++;
            return;
          }
          // 秒杀: 我方打怪 -> 清空剩余HP(走正常死亡/掉落/统计流程)
          if (F.kill && target.type === UTYPE_MONSTER && attacker &&
            (attacker.type === UTYPE_HERO || attacker.type === 1)) {
            dmg = -(target.curHp || 0) - 1;
            S.kill++;
            maybeFlush();
          }
        }
      } catch (e) { wlog("dmg exc " + e); }
      return orig.call(this, dmg, target, attacker, shieldDecHp, skillId);
    };
    BDM.prototype.__gyzwW = orig;
    patched.dmg = true;
    wlog("patch BtDmgMgr.updateTargetHp ok(v2)");
  }

  // ---------- 统计落盘 ----------
  function flushStats() {
    try {
      jsb.fileUtils.writeStringToFile(JSON.stringify({ ts: Date.now(), kill: S.kill, hit: S.hit, flags: F, patched: patched }),
        jsb.fileUtils.getWritablePath() + "gyzw_stats.json");
    } catch (e) {}
  }
  var _lastFlush = 0;
  function maybeFlush() {
    var now = Date.now();
    if (now - _lastFlush > 2000) { _lastFlush = now; flushStats(); }
  }

  // ---------- 轮询 patch + 存活校验 ----------
  var tickN = 0;
  function tick() {
    tickN++;
    patchDmg(); patchSpeed(); patchAd();
    if (tickN === 3 || tickN === 30 || tickN % 600 === 0) {
      wlog("tick " + tickN + " patched:" + JSON.stringify(patched));
    }
  }
  try {
    cc.director.on(cc.Director.EVENT_BEFORE_UPDATE, tick);
  } catch (e) { wlog("director hook fail " + e); }
  try { setInterval(tick, 500); } catch (e) {}
  try { setInterval(flushStats, 3000); } catch (e) {}
  tick();
  flushStats();

  // ---------- native 桥 (重注入时覆盖重建, flags 由 native syncFlags 恢复) ----------
  window.__GYZW = {
    ver: "v2",
    setFlag: function (k, v) {
      if (k in F) { F[k] = v; wlog("flag " + k + "=" + v); flushStats(); }
      return true;
    },
    getFlags: function () { return JSON.stringify(F); },
    getStats: function () { return JSON.stringify(S); },
    ping: function () { return "pong-v2"; }
  };
  try {
    jsb.fileUtils.writeStringToFile("ok", jsb.fileUtils.getWritablePath() + "gyzw_injected.flag");
  } catch (e) {}
  wlog("GYZWCheat v2 injected, flags=" + JSON.stringify(F));
})();
