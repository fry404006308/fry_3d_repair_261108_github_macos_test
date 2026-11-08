#!/bin/bash
# ★170 在 macOS 真机（GitHub Actions 的 macOS 机器，或任何一台 Mac）上验收 macOS 便携包：
#   ① 解包 → 审计（包里有没有本项目 .py）② 软件自检 --selftest ③ 原生库对拍 verify_native（加网 / 仿真与 Windows 逐字节）
#   ④ 4 个模型检测 + 修复，和 Windows 源码的结果逐项比（xplat_compare，与 166 / 169 同一把尺子）
# 用法：bash run_mac_ci.sh <下载目录（含 *_macos-xxx.zip 与 mac_ci_kit.zip）> <macos-arm64|macos-x64> <结果目录>
# 在自己的 Mac 上也能直接跑（不需要 GitHub）：把两个 zip 放进同一个文件夹，bash run_mac_ci.sh 那个文件夹 macos-arm64 结果
set -u
DL="$1"; TARGET="$2"; OUT="$(mkdir -p "$3" && cd "$3" && pwd)"
W="$(mktemp -d)"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/run.log"; }
log "机器：$(uname -m) / macOS $(sw_vers -productVersion 2>/dev/null) / $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
PKG_ZIP="$(ls "$DL"/*_"$TARGET".zip | head -1)"
log "包：$PKG_ZIP"
ditto -x -k "$PKG_ZIP" "$W/pkg"                     # ditto 保留可执行位与符号链接（unzip 也行）
ditto -x -k "$DL/mac_ci_kit.zip" "$W/kit"
APPDIR="$(ls -d "$W"/pkg/*/*.app | head -1)"
NAME="$(basename "$APPDIR" .app)"
APP="$APPDIR/Contents/MacOS/$NAME"
RES="$APPDIR/Contents/Resources"
xattr -dr com.apple.quarantine "$APPDIR" 2>/dev/null
# ① 包里不该有本项目的业务 .py（只许 Blender 脚本 3 个 + 启动壳 7 个 + 根引导 + fry_package 自检 / 入口）
find "$RES/app" -name '*.py' | sed "s|$RES/app/||" | sort > "$OUT/py_in_package.txt"
find "$RES/app" -name '*.cpython-312-darwin.so' | wc -l | tr -d ' ' > "$OUT/n_ext.txt"
log ".py $(wc -l < "$OUT/py_in_package.txt" | tr -d ' ') 个，本项目扩展 $(cat "$OUT/n_ext.txt") 个"
# Blender（可选）：kit 里写了版本；装官方 DMG + 3D Print Toolbox 扩展，HA400 十项与交付才和 Windows 参考机可比
BV="$(cat "$W/kit/blender_version.txt" 2>/dev/null)"
if [ -n "$BV" ]; then
  ARCH=arm64; [ "$TARGET" = "macos-x64" ] && ARCH=x64
  URL="https://download.blender.org/release/Blender${BV%.*}/blender-${BV}-macos-${ARCH}.dmg"
  log "装 Blender $BV：$URL"
  if curl -fsSL -o "$W/blender.dmg" "$URL" && hdiutil attach -nobrowse -quiet -mountpoint "$W/bmnt" "$W/blender.dmg"; then
    cp -R "$W/bmnt/Blender.app" "$HOME/Applications/" 2>/dev/null || { mkdir -p "$HOME/Applications"; cp -R "$W/bmnt/Blender.app" "$HOME/Applications/"; }
    hdiutil detach -quiet "$W/bmnt"
    EXT="$HOME/Library/Application Support/Blender/${BV%.*}/extensions/blender_org"
    mkdir -p "$EXT" && [ -d "$W/kit/print3d_toolbox" ] && cp -R "$W/kit/print3d_toolbox" "$EXT/"
    export FRY_BLENDER_EXE="$HOME/Applications/Blender.app/Contents/MacOS/Blender"
    log "Blender：$("$FRY_BLENDER_EXE" --version 2>/dev/null | head -1)"
  else
    log "Blender 没装上（结果里 HA400 / 交付会和 Windows 不同，单独看）"
  fi
fi
# ⓪ ★172 渲染压力测试：同一进程反复建删 pyrender 离屏渲染器（pyglet issue #1089 在 arm64 上的触发条件）
HERE_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE_DIR/render_stress.py" ]; then
  "$APP" "$HERE_DIR/render_stress.py" "$OUT/render_stress" 80 > "$OUT/render_stress.log" 2>&1; RC0=$?
else
  RC0=0; echo "没有 render_stress.py，跳过" > "$OUT/render_stress.log"
fi
log "渲染压力测试退出码 $RC0：$(tail -1 "$OUT/render_stress.log")"
# ② 自检 ③ 原生库对拍
"$APP" --selftest "$OUT/selftest" > "$OUT/selftest.log" 2>&1; RC1=$?
log "自检退出码 $RC1（= 失败项数）"
"$APP" "$RES/app/fry_package/portable/verify_native.py" "$OUT/verify_native" > "$OUT/verify_native.log" 2>&1; RC2=$?
log "原生库对拍退出码 $RC2"
# ④ 4 模型检测 + 修复 → 和 Windows 源码比
"$RES/python/bin/python3" -X utf8 "$W/kit/xplat_compare.py" run "$APP" --input "$W/kit/models" --out "$OUT/xp" \
    --label "$TARGET" > "$OUT/xplat_run.log" 2>&1; RC3=$?
"$RES/python/bin/python3" -X utf8 "$W/kit/xplat_compare.py" compare "$W/kit/xplat_windows_source.json" "$OUT/xp/xplat_$TARGET.json" \
    --json "$OUT/compare.json" > "$OUT/compare.log" 2>&1; RC4=$?
log "4 模型：运行 $RC3，比较 $RC4（0 = 与 Windows 源码 0 处不同）"
{
  echo "## $TARGET（$(uname -m)，macOS $(sw_vers -productVersion 2>/dev/null)）"
  echo ""
  echo "| 项 | 结果 |"
  echo "| --- | --- |"
  echo "| 包里的 .py / 本项目扩展 | $(wc -l < "$OUT/py_in_package.txt" | tr -d ' ') / $(cat "$OUT/n_ext.txt") |"
  echo "| 渲染压力测试（80 次建删渲染器） | $(tail -1 "$OUT/render_stress.log") |"
  echo "| 自检失败项 | $RC1 |"
  echo "| 原生库对拍 | $RC2（0 = 逐字节同） |"
  echo "| 4 模型 vs Windows 源码 | $(tail -1 "$OUT/compare.log") |"
  echo ""
  echo '```'; tail -20 "$OUT/selftest.log"; echo '```'
  echo '```'; cat "$OUT/verify_native.log" | tail -12; echo '```'
  echo '```'; cat "$OUT/compare.log"; echo '```'
} > "$OUT/summary.md"
cat "$OUT/summary.md"
exit $(( RC0 + RC1 + RC2 + RC4 > 0 ? 1 : 0 ))
