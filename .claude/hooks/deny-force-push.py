#!/usr/bin/env python3
"""PreToolUse 护栏：拦截 force push，普通 push 放行。

只检查每个 `git push` 子命令段（到 |、&、; 为止）内的 flag，
所以同一条命令里别处的 `rm -f` 不会误伤；flag 在段内任意位置
（`git push -f origin` / `git push origin main --force`）都拦得住。
"""
import json
import re
import sys

FORCE_FLAG = re.compile(r"(^|\s)(--force(-with-lease|-if-includes)?|-f)(\s|$|=)")

command = json.load(sys.stdin).get("tool_input", {}).get("command", "")
segments = [m.group(1) for m in re.finditer(r"git\s+push\b([^|&;]*)", command)]
if any(FORCE_FLAG.search(segment) for segment in segments):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason":
                "护栏：禁止 force push（--force/-f）。确需覆盖远端历史请自己在终端执行。",
        }
    }, ensure_ascii=False))
