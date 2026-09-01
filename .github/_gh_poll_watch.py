#!/usr/bin/env python3
"""查询并持续轮询一个 GitHub Actions run。无任何 shell 转义，用子进程跑 gh。"""
from __future__ import annotations

import json
import subprocess
import sys
import time
import re
import os

OWNER = sys.argv[1]
REPO  = sys.argv[2]
RID   = sys.argv[3]
MAX_ROUNDS = int(sys.argv[4]) if len(sys.argv) > 4 else 12
SLEEP_S    = int(sys.argv[5]) if len(sys.argv) > 5 else 40


def gh(*args: str) -> tuple[int, str, str]:
    r = subprocess.run(
        ["gh", *args], capture_output=True, text=True, timeout=120
    )
    return r.returncode, r.stdout, r.stderr


def gh_json_view(rid: str):
    rc, out, err = gh(
        "run", "view", "--repo", f"{OWNER}/{REPO}", rid,
        "--json", "status,conclusion,number,name,url,databaseId",
    )
    if rc != 0:
        return None, f"gh rc={rc} err={err.strip()[:300]}"
    try:
        return json.loads(out), None
    except Exception as e:
        return None, f"json err: {e}; raw={out[:200]!r}"


def fetch_log(rid: str, path: str) -> bool:
    rc, out, err = gh(
        "run", "view", "--repo", f"{OWNER}/{REPO}", rid, "--log",
    )
    if rc != 0:
        print(f"(gh run view --log rc={rc}, err={err.strip()[:200]})")
        return False
    with open(path, "w", encoding="utf-8") as f:
        f.write(out)
    return True


def fetch_view_text(rid: str) -> str:
    rc, out, err = gh("run", "view", "--repo", f"{OWNER}/{REPO}", rid)
    if rc != 0:
        return f"<view rc={rc} err={err.strip()[:300]}>"
    return out


def lines_between(whole: str, start_re: str, end_re: str | None) -> list[str]:
    sp = re.compile(start_re)
    ep = re.compile(end_re) if end_re else None
    out: list[str] = []
    on = False
    for ln in whole.splitlines():
        if not on and sp.search(ln):
            on = True
        if on:
            out.append(ln)
            if ep and ep.search(ln) and len(out) > 1:
                break
    return out


def main() -> int:
    for i in range(1, MAX_ROUNDS + 1):
        data, err = gh_json_view(RID)
        ts = time.strftime("%H:%M:%S")
        if data is None:
            print(f"[poll {i:02d}/{MAX_ROUNDS} @ {ts}] ERROR: {err}")
        else:
            st = data.get("status")
            cc = data.get("conclusion")
            url = data.get("url")
            print(f"[poll {i:02d}/{MAX_ROUNDS} @ {ts}] status={st}  conclusion={cc}  {url}")
            if st == "completed":
                print()
                print("== 跑完啦，结论：", cc, " ==")
                if cc != "success":
                    print()
                    print("--- Step 矩阵 (前 30 行) ---")
                    for ln in fetch_view_text(RID).splitlines()[:30]:
                        print("   ", ln)
                    log_path = f"/tmp/ci_{RID}.log"
                    print()
                    print(f"--- 抓全量 log → {log_path} ---")
                    if fetch_log(RID, log_path):
                        n = sum(1 for _ in open(log_path, encoding="utf-8"))
                        print(f"   共 {n} 行")
                        whole = open(log_path, encoding="utf-8").read()

                        print()
                        print("--- 错误/异常关键字 (前 80 条) ---")
                        pat = re.compile(
                            r"##\[error\]|exit code [1-9]|FAILURE:|BUILD FAILED|"
                            r"Error:|❌|Exception:|Undefined name|No such file|"
                            r"No named parameter|cannot access|signingConfig|"
                            r"Target .* failed|Execution failed|compile.*failed|"
                            r"flutter create.*failed|flutter build.*failed"
                        )
                        hits = 0
                        for idx, ln in enumerate(whole.splitlines(), 1):
                            if pat.search(ln):
                                print(f"   {idx}: {ln}")
                                hits += 1
                                if hits >= 80:
                                    break
                        if hits == 0:
                            print("   (没命中任何关键字，需要人工看关键段)")

                        def print_section(title, s_re, e_re=None, tail_n=40):
                            chunk = lines_between(whole, s_re, e_re)
                            if not chunk:
                                print(f"   {title}: (段未找到)")
                                return
                            print(f"--- {title} ---")
                            for ln in chunk[-tail_n:]:
                                print("   ", ln)

                        print_section(
                            "🔐 签名注入段尾部 (RELEASE 高亮行)",
                            r"最终 release buildType 段",
                            r"Build APK — release 签名",
                            tail_n=30,
                        )
                        print_section(
                            "🛠 Flutter build APK 段尾部",
                            r"Build APK — release 签名",
                            r"APK 签名指纹硬校验",
                            tail_n=60,
                        )
                        print_section(
                            "✅ APK 签名指纹硬校验段 (完整尾部)",
                            r"APK 签名指纹硬校验",
                            end_re=None,
                            tail_n=60,
                        )
                    return 1
                print("✅ Workflow GREEN — 所有 step 通过")
                return 0
        time.sleep(SLEEP_S)

    print()
    print(f"== 已等满 {MAX_ROUNDS * SLEEP_S} 秒还没跑完，最后 step 矩阵 ==")
    for ln in fetch_view_text(RID).splitlines()[:30]:
        print("   ", ln)
    return 2


if __name__ == "__main__":
    sys.exit(main())
