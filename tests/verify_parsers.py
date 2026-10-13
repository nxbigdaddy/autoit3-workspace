"""verify_parsers.py - 用 pyyaml / json 当裁判，验证 AutoIt 解析器的往返一致性。

由 tests\\test-parsers.ps1 调用，不单独使用。

判定三件事：
  1. project.yaml / config.yaml 的“纯往返”结果必须与原文件语义完全一致
     （包括类型：log_tail_kib 必须还是整数 64，不能变成字符串 "64"）
  2. agents-sample.yaml 应用测试脚本里的两处改动后，往返结果必须与预期一致
  3. AutoIt 写出的 control.json 必须是合法 JSON，且转义（引号、换行）正确

结果同时写入 out\\verify-parsers.log（UTF-8），方便在中文控制台下查看。
"""

import json
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "out"
FIX = ROOT / "tests" / "fixtures"
LOG = OUT / "verify-parsers.log"

fails: list[str] = []
lines: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    tag = "[ ok ]" if ok else "[FAIL]"
    line = f"{tag} {name}"
    if not ok and detail:
        line += f"\n        {detail}"
    lines.append(line)
    if not ok:
        fails.append(name)


def load_yaml(path: Path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


OUT.mkdir(exist_ok=True)

lines.append("=== Python 裁判：YAML/JSON 往返一致性 ===")

# --- 1) 纯往返（脚本未改动这两个文件） -------------------------------------
for stem in ("project-sample", "config-sample"):
    rt_path = OUT / f"yaml-{stem}-roundtrip.yaml"
    if not rt_path.exists():
        check(f"往返文件存在: {stem}", False, str(rt_path))
        continue
    original = load_yaml(FIX / f"{stem}.yaml")
    roundtrip = load_yaml(rt_path)
    check(
        f"语义一致: {stem}",
        original == roundtrip,
        f"原={original!r}\n        往返={roundtrip!r}",
    )
    check(
        f"类型一致: {stem}",
        json.dumps(original, sort_keys=True, default=str)
        == json.dumps(roundtrip, sort_keys=True, default=str),
        "值的类型发生了变化（例如整数变成了字符串）",
    )

# --- 2) agents-sample：脚本里改了 host.model 与 opencode.fit ----------------
agents_rt = OUT / "yaml-roundtrip.yaml"
if not agents_rt.exists():
    check("往返文件存在: agents-sample", False, str(agents_rt))
else:
    original = load_yaml(FIX / "agents-sample.yaml")
    roundtrip = load_yaml(agents_rt)

    expected = json.loads(json.dumps(original))  # 深拷贝
    expected["host"]["model"] = "deepseek-v5"
    expected["agents"]["opencode"]["fit"] = ["write", "integrate"]

    check(
        "语义一致: agents-sample（含脚本的两处改动）",
        expected == roundtrip,
        f"预期={expected!r}\n        实际={roundtrip!r}",
    )

    # 未被改动的部分必须逐项保持
    for agent in ("codex", "kimi"):
        check(
            f"未改动项保持: agents.{agent}",
            expected["agents"].get(agent) == roundtrip["agents"].get(agent),
            f"预期={expected['agents'].get(agent)!r}\n        实际={roundtrip['agents'].get(agent)!r}",
        )
    check("未改动项保持: host.command", expected["host"]["command"] == roundtrip["host"]["command"])
    check("块的列表项类型保持为字符串", all(isinstance(x, str) for x in roundtrip["agents"]["kimi"]["command"]))

# --- 3) control.json ---------------------------------------------------------
ctrl_path = OUT / "control-test.json"
if not ctrl_path.exists():
    check("control.json 存在", False, str(ctrl_path))
else:
    raw = ctrl_path.read_text(encoding="utf-8")
    try:
        ctrl = json.loads(raw)
        check("control.json 是合法 JSON", True)
    except Exception as exc:  # noqa: BLE001
        check("control.json 是合法 JSON", False, str(exc))
        ctrl = None
    if ctrl is not None:
        check("answers[0].text", ctrl["answers"][0]["text"] == "用 XLSX", repr(ctrl["answers"][0]))
        check("cancels[0].reason", ctrl["cancels"][0]["reason"] == "人取消", repr(ctrl["cancels"][0]))
        check("note 保留了引号", '"' in ctrl["note"], repr(ctrl["note"]))
        check("note 保留了换行", "\n" in ctrl["note"], repr(ctrl["note"]))
        check("note 没有多余转义残留", "\\n" not in ctrl["note"].replace("\n", ""), repr(ctrl["note"]))

lines.append("")
if fails:
    lines.append(f"裁判判定：失败 {len(fails)} 项")
else:
    lines.append("裁判判定：全部一致")

LOG.write_text("\n".join(lines) + "\n", encoding="utf-8")

# 控制台只输出 ASCII，避免中文代码页干扰
print("verify_parsers: " + ("FAIL" if fails else "OK") + f" (fails={len(fails)})")
sys.exit(1 if fails else 0)
