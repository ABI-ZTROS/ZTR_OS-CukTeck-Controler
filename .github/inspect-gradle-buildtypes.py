#!/usr/bin/env python3
"""打印 Gradle app build.gradle(.kts) 的 buildTypes 段，内部 release 子块用 RELEASE >> 前缀高亮。

CI 专用调试脚本：flutter create 生成的脚本 + signing-injector.py 注入后，
用此脚本核对 release 块是否确实指向 signingConfigs.release，
以及是否残留 debug signingConfig / 未替换的 getByName("debug") 等。

用法:
  python3 inspect-gradle-buildtypes.py path/to/app/build.gradle[.kts]

输出示例（节选）：
  42:     buildTypes {
  43:         debug { ... }
  44: RELEASE >>     release {
  45: RELEASE >>         signingConfig = signingConfigs.release
  ...
  51: RELEASE >>     }
  52:     }
"""

from __future__ import annotations

import re
import sys


def _find_matching_block(
    lines: list[str],
    start_line: int,
    brace_open_idx: int,
) -> int:
    """返回与 lines[start_line][brace_open_idx] 处 '{' 配对的 '}' 所在行号。

    找不到返回 -1。忽略字符串/注释 —— 足够用于 Gradle/Groovy/KTS 诊断。
    """
    depth = 0
    started = False
    j = start_line
    while j < len(lines):
        s = lines[j]
        start_pos = brace_open_idx if j == start_line else 0
        for k in range(start_pos, len(s)):
            c = s[k]
            if c == "{":
                depth += 1
                started = True
            elif c == "}":
                depth -= 1
            if started and depth == 0:
                return j
        j += 1
    return -1


def inspect(path: str) -> int:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.read().splitlines(keepends=True)

    bt_re = re.compile(r"\bbuildTypes\s*\{")
    rel_re = re.compile(
        r"(\brelease\s*\{)"
        r"|(getByName\s*\(\s*[\"']release[\"']\s*\)\s*\{)"
        r"|(named\s*\(\s*[\"']release[\"']\s*\)\s*\{)"
    )

    i = 0
    found_any = False
    while i < len(lines):
        m = bt_re.search(lines[i])
        if not m:
            i += 1
            continue
        found_any = True
        brace_open_idx_in_line = m.end() - 1
        bt_end = _find_matching_block(lines, i, brace_open_idx_in_line)
        if bt_end < 0:
            print(f"[warn] buildTypes 块花括号未闭合，start≈line {i + 1}")
            i += 1
            continue

        sub = lines[i : bt_end + 1]

        # 定位所有 release 子块区间（相对 sub）
        rel_ranges: list[tuple[int, int]] = []
        si = 0
        while si < len(sub):
            mm = rel_re.search(sub[si])
            if not mm:
                si += 1
                continue
            inner_brace = mm.end() - 1
            re_end = _find_matching_block(sub, si, inner_brace)
            if re_end < 0:
                print(f"[warn] release 子块花括号未闭合，start≈line {i + si + 1}")
                si += 1
                continue
            rel_ranges.append((si, re_end))
            si = re_end + 1

        # 打印
        for li in range(len(sub)):
            idx = i + li + 1  # 1-based 源文件行号
            ln = sub[li].rstrip("\n")
            in_rel = any(a <= li <= b for a, b in rel_ranges)
            flag = "RELEASE >> " if in_rel else ""
            print(f"{idx:>3}: {flag}{ln}")

        i = bt_end + 1

    if not found_any:
        print(f"[error] 文件内未找到任何 buildTypes {{ ... }} 块：{path}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: inspect-gradle-buildtypes.py <path/to/app/build.gradle[.kts]>",
              file=sys.stderr)
        sys.exit(2)
    sys.exit(inspect(sys.argv[1]))
