"""verify_aic.py - 用 pyyaml / json 独立验证 AIC 控制台的写入结果。

由 tests\\test-aic.ps1 调用。验证三件事：
  1. 控制台“保存 agents.yaml / config.yaml”之后的文件，pyyaml 仍能正常解析，
     并且关键内容与类型都对（既有改动生效，也有未改动项与未知键被保留）
  2. config.yaml 的类型保真（log_tail_kib 仍是整数、audit 仍是布尔、owner 仍是字符串）
  3. 控制台追加的 control.json 是合法 JSON，条目完整且没有覆盖旧条目

结果同时写入 out\\verify-aic.log（UTF-8）。
"""

import json
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "out"
DEMO_HOME = OUT / "aic-demo-home"
DEMO_REPO = OUT / "aic-demo-repo"
LOG = OUT / "verify-aic.log"

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


lines.append("=== Python 裁判：AIC 控制台写入结果 ===")

# ---------------------------------------------------------------- agents.yaml
agents_path = DEMO_HOME / "agents.yaml"
if not agents_path.exists():
    check("agents.yaml 存在", False, str(agents_path))
else:
    try:
        doc = yaml.safe_load(agents_path.read_text(encoding="utf-8"))
        check("agents.yaml 是合法 YAML", isinstance(doc, dict))
    except Exception as exc:  # noqa: BLE001
        check("agents.yaml 是合法 YAML", False, str(exc))
        doc = None

    if doc:
        agents = doc.get("agents") or {}
        check("三个 agent 都在", sorted(agents.keys()) == ["codex", "kimi", "opencode"], repr(sorted(agents.keys())))

        codex = agents.get("codex") or {}
        check("codex.command 保持字符串列表", codex.get("command") == ["codex", "exec", "--json"], repr(codex.get("command")))
        check(
            "codex.fit 已被控制台改动并落盘",
            codex.get("fit") == ["write", "review", "integrate"],
            repr(codex.get("fit")),
        )
        check("codex.model 独立键被保留", codex.get("model") == "gpt-5-codex", repr(codex.get("model")))

        kimi = agents.get("kimi") or {}
        check(
            "kimi.command 保持原样（含带引号的项）",
            kimi.get("command") == ["kimi", "-p", "--output-format", "stream-json"],
            repr(kimi.get("command")),
        )
        check("kimi.note 里的冒号与 # 未被破坏", isinstance(kimi.get("note"), str) and "#" in kimi["note"], repr(kimi.get("note")))
        check("kimi.fit 保持原样", kimi.get("fit") == ["review", "integrate"], repr(kimi.get("fit")))

        host = doc.get("host") or {}
        check("host.command 保持三 token", host.get("command") == ["dsh", "--profile", "headless"], repr(host.get("command")))
        check("host.model 未知键被保留", host.get("model") == "deepseek-v4", repr(host.get("model")))

# ---------------------------------------------------------------- config.yaml
config_path = DEMO_HOME / "config.yaml"
if not config_path.exists():
    check("config.yaml 存在", False, str(config_path))
else:
    cfg = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    check("stall_timeout 已被控制台改成 5m", cfg.get("stall_timeout") == "5m", repr(cfg.get("stall_timeout")))
    check("log_tail_kib 仍是整数（类型保真）", cfg.get("log_tail_kib") == 64 and isinstance(cfg.get("log_tail_kib"), int), repr(cfg.get("log_tail_kib")))
    check("audit 仍是布尔 True", cfg.get("audit") is True, repr(cfg.get("audit")))
    check("owner 仍是字符串 '123'", cfg.get("owner") == "123" and isinstance(cfg.get("owner"), str), repr(cfg.get("owner")))
    check("empty 仍是空字符串", cfg.get("empty") == "" and isinstance(cfg.get("empty"), str), repr(cfg.get("empty")))
    check("ratio 仍是浮点 1.5", cfg.get("ratio") == 1.5 and isinstance(cfg.get("ratio"), float), repr(cfg.get("ratio")))

# --------------------------------------------------------------- project.yaml
project_path = DEMO_REPO / ".aic" / "project.yaml"
if project_path.exists():
    proj = yaml.safe_load(project_path.read_text(encoding="utf-8"))
    check("project.yaml 可解析且 codex.fit 覆盖为 review", (proj.get("agents") or {}).get("codex", {}).get("fit") == ["review"], repr(proj))
else:
    check("project.yaml 存在", False, str(project_path))

# --------------------------------------------------------------- control.json
ctrl_path = DEMO_HOME / "runs" / "20260922-1601-abcd1234" / "control.json"
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
        check("顶层只有 answers / cancels", sorted(ctrl.keys()) == ["answers", "cancels"], repr(sorted(ctrl.keys())))
        cancels = ctrl.get("cancels") or []
        answers = ctrl.get("answers") or []
        check("cancels 有 2 条（追加未覆盖）", len(cancels) == 2, repr(cancels))
        if len(cancels) == 2:
            check("第一条取消是 T2", cancels[0].get("task_id") == "T2", repr(cancels[0]))
            check("第一条原因正确", cancels[0].get("reason") == "人取消", repr(cancels[0]))
            check("第二条取消是 T1", cancels[1].get("task_id") == "T1", repr(cancels[1]))
        check("answers 有 1 条", len(answers) == 1, repr(answers))
        if answers:
            check("回答关联 T2", answers[0].get("task_id") == "T2", repr(answers[0]))
            check("回答内容正确", answers[0].get("text") == "用 XLSX", repr(answers[0]))
        for item in cancels + answers:
            check(
                f"条目 {item.get('task_id')} 带 at 时间戳",
                isinstance(item.get("at"), str) and len(item["at"]) >= 19,
                repr(item.get("at")),
            )

lines.append("")
lines.append(f"裁判判定：{'全部一致' if not fails else '失败 ' + str(len(fails)) + ' 项'}")
LOG.write_text("\n".join(lines) + "\n", encoding="utf-8")

print("verify_aic: " + ("FAIL" if fails else "OK") + f" (fails={len(fails)})")
sys.exit(1 if fails else 0)
