#!/usr/bin/env python3
"""
libsu 依赖注入器 — 在 flutter create 生成的 Gradle 脚手架里自动添加：
  1. JitPack maven 仓库（settings.gradle[.kts] 的 dependencyResolutionManagement.repositories）
  2. libsu:core 6.0.0 依赖（app/build.gradle[.kts] 的 dependencies 块）

使用方式：
    python3 libsu-injector.py \
        --settings-gradle  <path/to/android/settings.gradle[.kts]> \
        --app-gradle       <path/to/android/app/build.gradle[.kts]>

幂等：重复执行不会重复注入。
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path


def main() -> int:
    p = argparse.ArgumentParser(description="libsu 6.0.0 依赖自动注入器")
    p.add_argument("--settings-gradle", required=True,
                   help="android/settings.gradle 或 settings.gradle.kts 路径")
    p.add_argument("--app-gradle", required=True,
                   help="android/app/build.gradle 或 build.gradle.kts 路径")
    args = p.parse_args()

    settings_path = Path(args.settings_gradle)
    app_path = Path(args.app_gradle)

    if not settings_path.is_file():
        print(f"❌ [libsu-injector] settings.gradle 不存在：{settings_path}", file=sys.stderr)
        return 2
    if not app_path.is_file():
        print(f"❌ [libsu-injector] app/build.gradle 不存在：{app_path}", file=sys.stderr)
        return 2

    # 1) 注入 JitPack 仓库
    is_settings_kts = settings_path.suffix.lower() == ".kts"
    print(f"🔍 [libsu-injector] settings 格式：{'KTS' if is_settings_kts else 'Groovy'}")
    _inject_jitpack(settings_path, is_settings_kts)

    # 2) 注入 libsu 依赖
    is_app_kts = app_path.suffix.lower() == ".kts"
    print(f"🔍 [libsu-injector] app build 格式：{'KTS' if is_app_kts else 'Groovy'}")
    _inject_libsu_dependency(app_path, is_app_kts)

    print("✅ [libsu-injector] libsu 6.0.0 注入完成")
    return 0


# ================================================================
# 1. JitPack 仓库注入
# ================================================================

def _inject_jitpack(path: Path, is_kts: bool):
    """在 settings.gradle(.kts) 的 repositories 块里加 maven { url 'https://jitpack.io' }"""
    original = path.read_text(encoding="utf-8")
    bak = path.with_suffix(path.suffix + ".bak")
    shutil.copy2(path, bak)

    jitpack_already = "jitpack.io" in original
    if jitpack_already:
        print("ℹ️  [libsu-injector] JitPack 仓库已存在，跳过")
        return

    lines = original.splitlines(keepends=True)

    # 找 dependencyResolutionManagement { ... repositories { ... } }
    # AGP 8.x + Flutter 默认走这条路
    drm_re = re.compile(r"^\s*dependencyResolutionManagement\s*\{")
    i = 0
    repositories_insert_line = None

    while i < len(lines):
        m = drm_re.match(lines[i])
        if not m:
            i += 1
            continue
        # 括号平衡找到 dependencyResolutionManagement 的范围
        depth = 0
        started = False
        j = i
        drm_end = -1
        while j < len(lines):
            s = lines[j]
            start = m.end() - 1 if j == i else 0
            for k in range(start, len(s)):
                c = s[k]
                if c == "{":
                    depth += 1
                    started = True
                elif c == "}":
                    depth -= 1
                if started and depth == 0:
                    drm_end = j
                    break
            else:
                j += 1
                continue
            break

        if drm_end < 0:
            i += 1
            continue

        # 在 dependencyResolutionManagement[i..drm_end] 内部找 repositories { ... }
        sub = lines[i:drm_end + 1]
        rep_re = re.compile(r"^\s*repositories\s*\{")
        for si in range(len(sub)):
            rm = rep_re.match(sub[si])
            if not rm:
                continue
            rd = 0
            rs = False
            rj = si
            rep_end = -1
            while rj < len(sub):
                ss = sub[rj]
                sp = rm.end() - 1 if rj == si else 0
                for kk in range(sp, len(ss)):
                    c = ss[kk]
                    if c == "{":
                        rd += 1
                        rs = True
                    elif c == "}":
                        rd -= 1
                    if rs and rd == 0:
                        rep_end = rj
                        break
                else:
                    rj += 1
                    continue
                break
            if rep_end < 0:
                continue
            # 在 repositories 块内（rep_end 是 closing } 所在 sub 内索引）
            # 把 jitpack 插到 closing } 之前
            rep_abs_end = i + rep_end
            indent_match = re.match(r"^(\s*)", sub[si + 1] if si + 1 < len(sub) else sub[si])
            inner_indent = indent_match.group(1) if indent_match else "            "
            outer_indent_match = re.match(r"^(\s*)", sub[rep_end])
            outer_indent = outer_indent_match.group(1) if outer_indent_match else "        "

            if is_kts:
                jitpack_line = f'{inner_indent}maven(url = "https://jitpack.io")\n'
            else:
                jitpack_line = f'{inner_indent}maven {{ url "https://jitpack.io" }}\n'

            lines.insert(rep_abs_end, jitpack_line)
            print(f"✅ [libsu-injector] JitPack 仓库注入到 settings.gradle 的 repositories 块")
            path.write_text("".join(lines), encoding="utf-8")
            return

        i = drm_end + 1

    # 如果没找到 dependencyResolutionManagement，回退：找根级 allprojects/repositories
    print("⚠️  [libsu-injector] 未找到 dependencyResolutionManagement，尝试根级 allprojects")
    _inject_jitpack_fallback(lines, path, is_kts)


def _inject_jitpack_fallback(lines: list[str], path: Path, is_kts: bool):
    """在根 build.gradle 的 allprojects { repositories { ... } } 里加"""
    ap_re = re.compile(r"^\s*allprojects\s*\{")
    for i, ln in enumerate(lines):
        if ap_re.match(ln):
            depth = 0
            started = False
            j = i
            ap_end = -1
            m = ap_re.match(ln)
            while j < len(lines):
                s = lines[j]
                start = m.end() - 1 if j == i else 0
                for k in range(start, len(s)):
                    c = s[k]
                    if c == "{":
                        depth += 1
                        started = True
                    elif c == "}":
                        depth -= 1
                    if started and depth == 0:
                        ap_end = j
                        break
                else:
                    j += 1
                    continue
                break
            if ap_end < 0:
                continue

            sub = lines[i:ap_end + 1]
            rep_re = re.compile(r"^\s*repositories\s*\{")
            for si in range(len(sub)):
                rm = rep_re.match(sub[si])
                if not rm:
                    continue
                rd = 0
                rs = False
                rj = si
                rep_end = -1
                while rj < len(sub):
                    ss = sub[rj]
                    sp = rm.end() - 1 if rj == si else 0
                    for kk in range(sp, len(ss)):
                        c = ss[kk]
                        if c == "{":
                            rd += 1
                            rs = True
                        elif c == "}":
                            rd -= 1
                        if rs and rd == 0:
                            rep_end = rj
                            break
                    else:
                        rj += 1
                        continue
                    break
                if rep_end < 0:
                    continue
                rep_abs_end = i + rep_end
                indent_match = re.match(r"^(\s*)", sub[si + 1] if si + 1 < len(sub) else sub[si])
                inner_indent = indent_match.group(1) if indent_match else "            "

                if is_kts:
                    jitpack_line = f'{inner_indent}maven(url = "https://jitpack.io")\n'
                else:
                    jitpack_line = f'{inner_indent}maven {{ url "https://jitpack.io" }}\n'

                lines.insert(rep_abs_end, jitpack_line)
                print(f"✅ [libsu-injector] JitPack 仓库注入到 allprojects.repositories")
                path.write_text("".join(lines), encoding="utf-8")
                return

    print("❌ [libsu-injector] 无法找到 repositories 块来注入 JitPack", file=sys.stderr)
    path.write_text("".join(lines), encoding="utf-8")


# ================================================================
# 2. libsu 依赖注入
# ================================================================

def _inject_libsu_dependency(path: Path, is_kts: bool):
    """在 app/build.gradle(.kts) 的 dependencies {} 块里加 libsu:core:6.0.0"""
    original = path.read_text(encoding="utf-8")

    libsu_already = "topjohnwu.libsu" in original
    if libsu_already:
        print("ℹ️  [libsu-injector] libsu 依赖已存在，跳过")
        return

    lines = original.splitlines(keepends=True)
    dep_re = re.compile(r"^\s*dependencies\s*\{")

    for i, ln in enumerate(lines):
        m = dep_re.match(ln)
        if not m:
            continue
        depth = 0
        started = False
        j = i
        dep_end = -1
        while j < len(lines):
            s = lines[j]
            start = m.end() - 1 if j == i else 0
            for k in range(start, len(s)):
                c = s[k]
                if c == "{":
                    depth += 1
                    started = True
                elif c == "}":
                    depth -= 1
                if started and depth == 0:
                    dep_end = j
                    break
            else:
                j += 1
                continue
            break
        if dep_end < 0:
            continue

        # 缩进
        inner_indent = "    "
        if dep_end - 1 > i:
            prev_line = lines[dep_end - 1]
            im = re.match(r"^(\s*)", prev_line)
            if im and len(im.group(1)) > 0:
                inner_indent = im.group(1)
            else:
                im2 = re.match(r"^(\s*)", ln)
                inner_indent = (im2.group(1) if im2 else "") + "    "

        if is_kts:
            dep_line = f'{inner_indent}implementation("com.github.topjohnwu.libsu:core:6.0.0")\n'
        else:
            dep_line = f'{inner_indent}implementation "com.github.topjohnwu.libsu:core:6.0.0"\n'

        # 也加 AndroidX core 依赖（libsu 6.x 需要 Java 8 features，AGP 8 一般自带但保险）
        # 先只加 libsu
        lines.insert(dep_end, dep_line)
        print(f"✅ [libsu-injector] libsu:core:6.0.0 依赖注入到 dependencies 块")
        path.write_text("".join(lines), encoding="utf-8")
        return

    print("❌ [libsu-injector] 无法找到 dependencies 块", file=sys.stderr)
    path.write_text("".join(lines), encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
