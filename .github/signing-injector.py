#!/usr/bin/env python3
"""
签名注入器 — 解决 Flutter stable 「生成 Groovy 还是 KTS」不确定导致 CI 签名失败的问题。

使用方式：
    python3 signing-injector.py \
        --gradle          <path/to/android/app/build.gradle[.kts]> \
        --keystore        <path/to/upload-keystore.jks>             \
        --properties-out  <path/to/android/key.properties>         \
        --storePass  cuktech123   --keyPass cuktech123              \
        --alias      dev.cloud.ztr_os                               \
        [--alias-must-exist]

行为：
  1. 自动检测 --gradle 的扩展名是 Groovy (.gradle) 还是 Kotlin DSL (.gradle.kts)
  2. 生成并写出 android/key.properties
  3. 用 AST-free 的文本级重写，把 release signingConfig 注入 build.gradle[.kts]：
     - 加 Properties 读取 block（Groovy 直接 def props=...，KTS 需要 import）
     - 加 signingConfigs { release { ... } }（如果没有）
     - 找到 buildTypes.release 或 buildTypes.getByName("release") 块：
         a) 删除原有 release 块里的「signingConfig = signingConfigs.debug」/
            「signingConfig signingConfigs.debug」(Groovy)
         b) 在第一行加 signingConfig = signingConfigs.release（Groovy 可省略 =）
  4. --alias-must-exist：用 keytool -list 校验 keystore 中 alias 存在且密码正确。
     不通过立即退出 1，给出明确中文报错。
  5. 写回 --gradle（原地修改，保留一份 .bak）
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional, Tuple


# ================================================================
# 文本级注入模版
# ================================================================

SIGNING_BLOCK_GROOVY = """\
// === 自动注入：读取 android/key.properties 中的 release 签名 ===
def keystorePropertiesFile = rootProject.file("key.properties")
def keystoreProperties = new Properties()
keystoreProperties.load(new FileInputStream(keystorePropertiesFile))

android.signingConfigs {
    release {
        keyAlias     keystoreProperties['keyAlias']
        keyPassword  keystoreProperties['keyPassword']
        storeFile    file(rootProject.projectDir.absolutePath + "/app/" + keystoreProperties['storeFile'])
        storePassword keystoreProperties['storePassword']
    }
}
// ================================================================
"""

SIGNING_BLOCK_KTS = """\
// === 自动注入：读取 android/key.properties 中的 release 签名 ===
import java.util.Properties

private val __injectKeystoreProperties by lazy {
    val f = rootProject.file("key.properties")
    Properties().also { p -> f.inputStream().use { s -> p.load(s) } }
}

android.signingConfigs {
    val props = __injectKeystoreProperties
    create("release") {
        keyAlias = props.getProperty("keyAlias")
        keyPassword = props.getProperty("keyPassword")
        storeFile = file(rootProject.projectDir.absolutePath + "/app/" + props.getProperty("storeFile"))
        storePassword = props.getProperty("storePassword")
    }
}
// ================================================================
"""


def main() -> int:
    p = argparse.ArgumentParser(description="Flutter Android release 签名自动注入器")
    p.add_argument("--gradle", required=True, help="app/build.gradle 或 app/build.gradle.kts 路径")
    p.add_argument("--keystore", required=True, help="keystore (.jks) 文件路径（已存在）")
    p.add_argument("--properties-out", required=True, help="key.properties 输出路径（通常为 android/key.properties）")
    p.add_argument("--storePass", required=True)
    p.add_argument("--keyPass", required=True)
    p.add_argument("--alias", required=True)
    p.add_argument("--alias-must-exist", action="store_true",
                   help="用 keytool -list 预校验 keystore + alias 正确")
    args = p.parse_args()

    gradle_path = Path(args.gradle)
    if not gradle_path.is_file():
        print(f"❌ [signing-injector] build.gradle 文件不存在：{gradle_path}", file=sys.stderr)
        print("ℹ️  可能原因：flutter create 没有生成该文件，或者文件后缀 (.gradle/.gradle.kts) 与预期不符。", file=sys.stderr)
        gradle_dir = gradle_path.parent
        if gradle_dir.is_dir():
            print("   当前 app/build* 目录下已检测到的文件：", file=sys.stderr)
            for f in sorted(gradle_dir.glob("build.gradle*")):
                print(f"     - {f}", file=sys.stderr)
        return 2

    keystore_path = Path(args.keystore)
    if not keystore_path.is_file():
        print(f"❌ [signing-injector] keystore 不存在：{keystore_path}", file=sys.stderr)
        return 2

    is_kts = gradle_path.suffix.lower() == ".kts"
    syntax = "Kotlin DSL (.gradle.kts)" if is_kts else "Groovy (.gradle)"
    print(f"🔍 [signing-injector] 检测到 {syntax} 格式：{gradle_path}")

    # ------------------------------------------------------------------
    # 0. 可选：keytool 预校验 alias 存在
    # ------------------------------------------------------------------
    if args.alias_must_exist:
        rc, out, err = keytool_list(keystore_path, args.storePass, args.alias)
        if rc != 0:
            print(f"❌ [signing-injector] keytool 校验失败：\n{err}", file=sys.stderr)
            if "Keystore password was incorrect" in err:
                print("   → 具体：storePassword 不正确", file=sys.stderr)
            if "Alias not found" in err:
                print(f"   → 具体：keystore 中不存在 alias='{args.alias}'", file=sys.stderr)
            if "Invalid keystore format" in err or "not a valid key store" in err:
                print("   → 具体：.jks 文件损坏或不是 JKS/PKCS12 格式", file=sys.stderr)
            return 3
        print(f"✅ [signing-injector] keytool 预校验通过：alias '{args.alias}' 存在")

    # ------------------------------------------------------------------
    # 1. 写出 key.properties
    # ------------------------------------------------------------------
    prop_path = Path(args.properties_out)
    prop_path.parent.mkdir(parents=True, exist_ok=True)
    store_file_name = keystore_path.name
    content = (
        f"storePassword={args.storePass}\n"
        f"keyPassword={args.keyPass}\n"
        f"keyAlias={args.alias}\n"
        f"storeFile={store_file_name}\n"
    )
    prop_path.write_text(content, encoding="utf-8")
    print(f"✅ [signing-injector] 已写 key.properties → {prop_path}")

    # ------------------------------------------------------------------
    # 2. 注入/修复 build.gradle[.kts]
    # ------------------------------------------------------------------
    original = gradle_path.read_text(encoding="utf-8")
    bak = gradle_path.with_suffix(gradle_path.suffix + ".bak")
    shutil.copy2(gradle_path, bak)
    print(f"💾 [signing-injector] 备份：{bak}")

    new_text = inject(original, is_kts=is_kts)
    gradle_path.write_text(new_text, encoding="utf-8")
    print(f"✅ [signing-injector] 写回 → {gradle_path}")

    # 3. 后置 sanity 检查
    # 3a) 最终文件里有 release signingConfig 行
    has_release_ref = (
        "signingConfigs.release" in new_text
        or 'signingConfigs.getByName("release")' in new_text
        or "signingConfigs.getByName('release')" in new_text
    )
    if not has_release_ref:
        print("⚠️  [signing-injector] WARNING：最终文件未发现 signingConfigs.release 的引用，"
              "请人工核对。", file=sys.stderr)

    # 3b) **buildTypes.release 块内**不能再有 signingConfigs.debug（被注释掉的除外）。
    #     这里重新用上下文方式扫一遍，比简单 grep 严格。
    bad_release = _find_uncommented_debug_inside_release(new_text)
    if bad_release:
        print("❌ [signing-injector] FATAL：buildTypes.release 块内仍存在未注释的 "
              "signingConfigs.debug 引用，会导致打包继续用 debug key！", file=sys.stderr)
        for line_no, line_txt in bad_release:
            print(f"   → 第 {line_no} 行：{line_txt.rstrip()}", file=sys.stderr)
        return 11
    else:
        print("✅ [signing-injector] 后置校验：buildTypes.release 中不存在未注释的 debug 签名")

    # 3c) 简单提示 buildTypes.debug 本身存在 signingConfigs.debug 是正常的
    any_debug = (
        re.search(r"signingConfig\s*=\s*signingConfigs\.debug", new_text) is not None
        or re.search(r"signingConfig\s+signingConfigs\.debug", new_text) is not None
    )
    if any_debug:
        print("ℹ️  [signing-injector] buildTypes.debug 仍在使用 signingConfigs.debug（正常现象，无需处理）")

    return 0


def _find_uncommented_debug_inside_release(text: str) -> list[tuple[int, str]]:
    """返回 buildTypes → release 块内的未注释 signingConfigs.debug 行 [(行号, 行文本)]。
    行号 1-based。"""
    lines = text.splitlines(keepends=True)
    n = len(lines)

    # 先找 buildTypes { ... }
    bt_re = re.compile(r"\bbuildTypes\s*\{")
    results: list[tuple[int, str]] = []
    i = 0
    while i < n:
        m = bt_re.search(lines[i])
        if not m:
            i += 1
            continue
        brace_open_idx_in_line = m.end() - 1
        depth = 0
        started = False
        j = i
        bt_end = -1
        while j < n:
            s = lines[j]
            start_pos = brace_open_idx_in_line if j == i else 0
            for k in range(start_pos, len(s)):
                c = s[k]
                if c == "{":
                    depth += 1
                    started = True
                elif c == "}":
                    depth -= 1
                if started and depth == 0:
                    bt_end = j
                    break
            else:
                j += 1
                continue
            break
        if bt_end < 0:
            i += 1
            continue

        # 在 buildTypes[i..bt_end] 内部找 release 块
        sub = lines[i:bt_end + 1]
        rel_ranges: list[tuple[int, int]] = []  # sub 内的索引
        si = 0
        sn = len(sub)
        while si < sn:
            mm = None
            for rx, _ in _RELEASE_PATTERNS:
                m2 = rx.search(sub[si])
                if m2:
                    mm = m2
                    break
            if mm is None:
                si += 1
                continue
            brace_open_idx_in_line = mm.end() - 1
            d2 = 0
            s2 = False
            jj = si
            rel_end = -1
            while jj < sn:
                ss = sub[jj]
                sp = brace_open_idx_in_line if jj == si else 0
                for kk in range(sp, len(ss)):
                    c = ss[kk]
                    if c == "{":
                        d2 += 1
                        s2 = True
                    elif c == "}":
                        d2 -= 1
                    if s2 and d2 == 0:
                        rel_end = jj
                        break
                else:
                    jj += 1
                    continue
                break
            if rel_end < 0:
                si += 1
                continue

            # 扫 release 块内的未注释 signingConfigs.debug
            for li in range(si, rel_end + 1):
                ln = sub[li]
                stripped = ln.lstrip()
                if stripped.startswith("//") or stripped.startswith("/*"):
                    continue
                has_bad = re.search(
                    r"\bsigningConfig\b\s*(?:=)?\s*\(?\s*signingConfigs\.(?:"
                    r"debug\b"
                    r"|getByName\s*\(\s*[\"']debug[\"']\s*\)"
                    r"|named\s*\(\s*[\"']debug[\"']\s*\)"
                    r"|maybeCreate\s*\(\s*[\"']debug[\"']\s*\)"
                    r")\)?\s*[;,]?\s*$",
                    ln,
                ) is not None
                if has_bad:
                    real_line_no = i + li + 1  # 1-based 全局行号
                    results.append((real_line_no, ln))
            si = rel_end + 1
        i = bt_end + 1
    return results


# ================================================================
# 注入核心
# ================================================================

def inject(text: str, *, is_kts: bool) -> str:
    block = SIGNING_BLOCK_KTS if is_kts else SIGNING_BLOCK_GROOVY

    # 1) 移除旧的注入块（防止重复注入）
    text = _remove_previously_injected(text)

    # 2) 如果是 KTS 且文件里已经有 `import java.util.Properties`，
    #    就把注入块里的这一行删掉，避免重复 import（Gradle/Kotlin 对重复 import 容忍但会 warning）。
    if is_kts:
        has_import = re.search(r"^\s*import\s+java\.util\.Properties\s*$", text, re.MULTILINE) is not None
        if has_import:
            block_lines = block.splitlines(keepends=True)
            block_lines = [
                ln for ln in block_lines
                if not re.match(r"^\s*import\s+java\.util\.Properties\s*$", ln)
            ]
            block = "".join(block_lines)

    # 3) 插入全局 signing 加载 block（在文件最顶部，避免 android {} 内作用域问题）
    #    但如果文件开头有 plugins {} 块 / buildscript {}，我们把 block 放在 plugins/buildscript 之后。
    text = _insert_signing_block_after_plugins(text, block)

    # 4) buildTypes.release 修复 — **只处理 buildTypes 内部的 release 块**，
    #    避免误触 signingConfigs.release 或其他上下文的 release。
    text = _patch_build_types_release(text, is_kts=is_kts)

    return text


def _insert_signing_block_after_plugins(text: str, block: str) -> str:
    """把签名 block 插到 plugins {} / buildscript {} 之后，避免放在最顶部引发 Kotlin/Groovy
    「plugins {} must be the first statement」类报错。"""

    lines = text.splitlines(keepends=True)
    i = 0
    n = len(lines)
    # 跳过顶部空白 / 注释 / import
    while i < n:
        stripped = lines[i].lstrip()
        if stripped == "" or stripped.startswith("//") or stripped.startswith("/*") \
                or stripped.startswith("*") or stripped.startswith("import "):
            i += 1
            continue
        break

    # 尝试匹配 plugins { / buildscript { / pluginManagement { 块，跳过它们
    plugins_like_re = re.compile(r"^\s*(plugins|buildscript|pluginManagement)\s*\{")
    while i < n:
        m = plugins_like_re.match(lines[i])
        if not m:
            break
        # 括号平衡找结尾
        depth = 0
        started = False
        j = i
        while j < n:
            s = lines[j]
            start = 0
            if j == i:
                start = m.end() - 1
            for k in range(start, len(s)):
                c = s[k]
                if c == "{":
                    depth += 1
                    started = True
                elif c == "}":
                    depth -= 1
                if started and depth == 0:
                    # 到 j 行 k 列结束
                    i = j + 1
                    # 跳过紧跟的换行
                    while i < n and lines[i].strip() == "":
                        i += 1
                    break
            else:
                j += 1
                continue
            break
        else:
            # 没找到 plugins 匹配的闭合，回退
            break

    prefix = "".join(lines[:i]).rstrip("\n") + "\n\n"
    suffix = "".join(lines[i:]).lstrip("\n")
    return prefix + block.rstrip() + "\n\n" + suffix


_INJECT_MARK_START = "=== 自动注入：读取 android/key.properties 中的 release 签名 ==="
_INJECT_MARK_END   = "// ================================================================"

def _remove_previously_injected(text: str) -> str:
    # 去掉从 `// === 自动注入 ... ===` 到下一个 `// ===============`
    lines = text.splitlines(keepends=True)
    out = []
    i = 0
    while i < len(lines):
        if _INJECT_MARK_START in lines[i]:
            # 跳过直到 INJECT_MARK_END
            while i < len(lines) and _INJECT_MARK_END not in lines[i]:
                i += 1
            if i < len(lines):
                i += 1  # 跳过结尾分隔行
            continue
        out.append(lines[i])
        i += 1
    return "".join(out).rstrip() + "\n"


# buildTypes {
#     release {
#         signingConfig signingConfigs.debug
#         ...
#     }
# }
# 或者 KTS：
# buildTypes {
#     getByName("release") {
#         signingConfig = signingConfigs.debug
#         ...
#     }
# }

# 关键：**只在 buildTypes { ... } 这个父块内部**找 release / getByName("release") / named("release")，
# 避免误命中 signingConfigs { release { } } 或其他上下文。

def _patch_build_types_release(text: str, *, is_kts: bool) -> str:
    lines = text.splitlines(keepends=True)
    n = len(lines)

    # 1) 用括号平衡找到所有 buildTypes { ... } 块的区间
    buildtypes_ranges: list[tuple[int, int]] = []  # (start_line_idx, end_line_idx inclusive)
    bt_re = re.compile(r"\bbuildTypes\s*\{")
    i = 0
    while i < n:
        m = bt_re.search(lines[i])
        if not m:
            i += 1
            continue
        brace_open_idx_in_line = m.end() - 1
        depth = 0
        started = False
        j = i
        while j < n:
            s = lines[j]
            start_pos = brace_open_idx_in_line if j == i else 0
            for k in range(start_pos, len(s)):
                c = s[k]
                if c == "{":
                    depth += 1
                    started = True
                elif c == "}":
                    depth -= 1
                if started and depth == 0:
                    buildtypes_ranges.append((i, j))
                    i = j + 1
                    break
            else:
                j += 1
                continue
            break

    # 2) 对每个 buildTypes 区间，找到内部的 release / getByName("release") / named("release") 块，
    #    依次 patch（每个 buildTypes 中遇到的 release 都修）。
    #    注意：从后往前 patch 以保持行号偏移稳定。
    for bt_start, bt_end in reversed(buildtypes_ranges):
        sub = lines[bt_start:bt_end + 1]
        sub = _patch_release_blocks_inside(sub, is_kts=is_kts)
        lines[bt_start:bt_end + 1] = sub

    return "".join(lines)


# release 起始模式（只在 buildTypes 内部使用）
_RELEASE_PATTERNS = [
    # release { / release{
    (re.compile(r"(\brelease\s*\{)"), "release_bare"),
    # getByName("release") { / getByName('release'){
    (re.compile(r'(getByName\s*\(\s*["\']release["\']\s*\)\s*\{)'), "getByName"),
    # named("release") {
    (re.compile(r'(named\s*\(\s*["\']release["\']\s*\)\s*\{)'), "named"),
    # maybeCreate("release")
    (re.compile(r'(maybeCreate\s*\(\s*["\']release["\']\s*\)\s*\{)'), "maybeCreate"),
]


def _patch_release_blocks_inside(lines: list[str], *, is_kts: bool) -> list[str]:
    """lines 是 buildTypes { ... } 的整体（包含 buildTypes 自己那一行）。
    在它内部找 release 起始，括号平衡后 patch。支持多个 release 块（虽然通常只有一个）。"""

    n = len(lines)
    # 收集 [(start, end, kind)] 后从后往前 patch
    release_blocks: list[tuple[int, int]] = []

    i = 0
    while i < n:
        matched_kind = None
        mm = None
        for rx, kind in _RELEASE_PATTERNS:
            m = rx.search(lines[i])
            if m:
                mm = m
                matched_kind = kind
                break
        if mm is None:
            i += 1
            continue

        brace_open_idx_in_line = mm.end() - 1
        depth = 0
        started = False
        j = i
        while j < n:
            s = lines[j]
            start_pos = brace_open_idx_in_line if j == i else 0
            for k in range(start_pos, len(s)):
                c = s[k]
                if c == "{":
                    depth += 1
                    started = True
                elif c == "}":
                    depth -= 1
                if started and depth == 0:
                    release_blocks.append((i, j))
                    i = j + 1
                    break
            else:
                j += 1
                continue
            break
        else:
            i += 1

    # 从后往前 patch（保持前面的行号不变）
    for start, end in reversed(release_blocks):
        patched = _patch_release_block(lines[start:end + 1], is_kts=is_kts)
        lines[start:end + 1] = patched

    return lines


def _patch_release_block(block_lines: list[str], *, is_kts: bool) -> list[str]:
    """block_lines 包含整个 release { ... }，即首行是 '    release {' 一类。"""
    # 1) 把 release 块中出现的 signingConfig(...)= signingConfigs.debug **整行注释**，
    #    不碰其他行的字符（避免 \s* 吞掉后续代码行）。
    cleaned: list[str] = []
    for ln in block_lines:
        stripped = ln.lstrip()
        if stripped.startswith("//") or stripped.startswith("/*"):
            cleaned.append(ln)
            continue
        # 匹配行内 **未注释** 的 signingConfigs.debug 引用（所有常见写法都要覆盖）。
        # 命中则整行注释化，避免 release 继续复用 debug key。
        # 必须覆盖的变体：
        #   A. signingConfig = signingConfigs.debug                 (KTS 直接赋值)
        #   B. signingConfig signingConfigs.debug                   (Groovy 省略 =)
        #   C. signingConfig = signingConfigs.getByName("debug")    (KTS 命名域查找)
        #   D. signingConfig signingConfigs.getByName('debug')      (Groovy 单引号版命名域)
        #   E. signingConfig = (signingConfigs.debug)               (括号包装)
        # 支持行尾带 ; , 以及尾随空白。
        debug_ref_re = re.compile(
            r"\bsigningConfig\b"
            r"\s*(?:=)?"
            r"\s*\(?"
            r"\s*signingConfigs\.(?:"
            r"debug\b"
            r"|getByName\s*\(\s*[\"']debug[\"']\s*\)"
            r"|named\s*\(\s*[\"']debug[\"']\s*\)"
            r"|maybeCreate\s*\(\s*[\"']debug[\"']\s*\)"
            r")\)?"
            r"\s*[;,]?\s*$"
        )
        if debug_ref_re.search(ln):
            # 整行注释化（保留原缩进、保留原行内容）
            indent = re.match(r"^([ \t]*)", ln).group(1)
            # 去掉尾部换行做处理
            no_nl = ln.rstrip("\n").rstrip("\r")
            rest = no_nl[len(indent):]
            commented = f"{indent}// (removed by signing-injector: 禁止 release 复用 debug key) {rest}\n"
            cleaned.append(commented)
        else:
            cleaned.append(ln)

    # 2) 如果 cleaned 里已经有 release signingConfig 的引用，就不加（幂等）。
    any_release_signing = any(
        ("signingConfigs.release" in ln and "removed by signing-injector" not in ln)
        or ('getByName("release")' in ln and "signingConfig" in ln and "removed by signing-injector" not in ln)
        or ('getByName(\'release\')' in ln and "signingConfig" in ln and "removed by signing-injector" not in ln)
        for ln in cleaned
    )
    if any_release_signing:
        return cleaned

    # 3) 在 release { 结束花括号前插入 signingConfig 行。
    #    好处：不会干扰首行可能已经有的「同开 {」（如 release { signingConfig = ... }）
    #    也不需要计算复杂的首行后插。
    indent_str = ""
    # 缩进：cleaned[0] 是 release 起始行，内部内容缩进 = cleaned[0] 的缩进 + 更深 4/8 spaces。
    outer = re.match(r"^([ \t]*)", cleaned[0]).group(1)
    if len(cleaned) > 1:
        inner = re.match(r"^([ \t]*)", cleaned[1]).group(1)
        if len(inner) > len(outer):
            indent_str = inner
    if not indent_str:
        indent_str = outer + "        "

    # 末尾行是 closing '}'（带它的换行）
    closing_line = cleaned[-1]
    newline = "\n" if closing_line.endswith("\n") else ""
    if is_kts:
        release_line = f"{indent_str}signingConfig = signingConfigs.getByName(\"release\"){newline or os.linesep}"
    else:
        release_line = f"{indent_str}signingConfig signingConfigs.release{newline or os.linesep}"

    # 把 release_line 插入到 closing_line 之前
    return cleaned[:-1] + [release_line, closing_line]


# ================================================================
# keytool 预校验
# ================================================================

def keytool_list(jks: Path, storePass: str, alias: str) -> Tuple[int, str, str]:
    cmd = [
        "keytool", "-list",
        "-keystore", str(jks),
        "-storepass", storePass,
        "-alias", alias,
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return r.returncode, r.stdout, r.stderr
    except FileNotFoundError:
        return 127, "", "keytool 可执行文件不存在：请确保 PATH 包含 JAVA_HOME/bin（CI 已 actions/setup-java 提供）"
    except subprocess.TimeoutExpired:
        return 124, "", "keytool 调用超时 30s"


if __name__ == "__main__":
    raise SystemExit(main())
