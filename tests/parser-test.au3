; parser-test.au3 - MiniYaml / MiniJson 的独立验证脚本
;   运行： au3 tools\au3-run.ps1 -Path tests\parser-test.au3
;   返回： 失败项数（0 = 全通过）
;
; 验证方式：
;   1) 断言具体的取值（键、列表元素、引号串、注释剥离、\u 转义、null）
;   2) 把解析结果重新生成 YAML 写到 out\yaml-roundtrip.yaml，
;      再由 Python + pyyaml 与原文件做语义比对（见 tests\test-parsers.ps1）
;   3) 写出 control.json，由 Python 的 json 模块确认是合法 JSON

#include <FileConstants.au3>
#include "..\src\lib\MiniYaml.au3"
#include "..\src\lib\MiniJson.au3"

Global $g_sRoot = @ScriptDir & "\.."
Global $g_sOutDir = $g_sRoot & "\out"
Global $g_sLog = $g_sOutDir & "\parser-test.log"
Global $g_iFail = 0

If Not FileExists($g_sOutDir) Then DirCreate($g_sOutDir)
FileDelete($g_sLog)

Func _Log($sText)
    ConsoleWrite($sText & @CRLF)
    Local $hFile = FileOpen($g_sLog, $FO_APPEND + $FO_CREATEPATH + $FO_UTF8)
    If $hFile <> -1 Then
        FileWrite($hFile, $sText & @CRLF)
        FileClose($hFile)
    EndIf
EndFunc   ;==>_Log

Func _Check($sName, $bOk, $sDetail = "")
    If $bOk Then
        _Log("[ ok ] " & $sName)
    Else
        _Log("[FAIL] " & $sName & "    " & $sDetail)
        $g_iFail += 1
    EndIf
EndFunc   ;==>_Check

Func _ListText($aItems)
    Return "[" & _ArrayJoin($aItems, ", ") & "]"
EndFunc   ;==>_ListText

Func _ArrayJoin($aItems, $sSep)
    Local $s = ""
    For $i = 0 To UBound($aItems) - 1
        If $i > 0 Then $s &= $sSep
        $s &= $aItems[$i]
    Next
    Return $s
EndFunc   ;==>_ArrayJoin

_Log("=== MiniYaml / MiniJson 解析器验证 ===")
_Log("")

; ---------------------------------------------------------------- YAML 解析
Local $sAgents = @ScriptDir & "\fixtures\agents-sample.yaml"
_Check("agents.yaml 解析成功", _Yaml_ParseFile($sAgents), $g_sYamlError)

_Check("host.command 是列表", _Yaml_Kind("host.command") = "list")
Local $aCmd = _Yaml_GetList("host.command")
_Check("host.command 有 3 项", UBound($aCmd) = 3, _ListText($aCmd))
_Check("host.command[0] = dsh", UBound($aCmd) > 0 And $aCmd[0] = "dsh")
_Check("host.command[1] = --profile", UBound($aCmd) > 1 And $aCmd[1] = "--profile")
_Check("host.command[2] = headless", UBound($aCmd) > 2 And $aCmd[2] = "headless")

_Check("host.model 保留未知键", _Yaml_Get("host.model") = "deepseek-v4")

_Check("agents.codex 是 map", _Yaml_Kind("agents.codex") = "map")
Local $aFit = _Yaml_GetList("agents.codex.fit")
_Check("codex.fit = write,review", UBound($aFit) = 2 And $aFit[0] = "write" And $aFit[1] = "review", _ListText($aFit))

Local $aBlk = _Yaml_GetList("agents.codex.command")
_Check("块式列表解析出 3 项", UBound($aBlk) = 3, _ListText($aBlk))
_Check("块式列表末项 = --json", UBound($aBlk) > 2 And $aBlk[2] = "--json")

Local $aKimi = _Yaml_GetList("agents.kimi.command")
_Check("kimi 命令里的引号项正确", UBound($aKimi) = 4 And $aKimi[2] = "--output-format", _ListText($aKimi))
_Check("kimi.note 里的冒号和 # 未被破坏", StringInStr(_Yaml_Get("agents.kimi.note"), ":") > 0 And StringInStr(_Yaml_Get("agents.kimi.note"), "#") > 0, _Yaml_Get("agents.kimi.note"))

_Check("agents 下正好 3 个 agent", _Yaml_CountChildren("agents") = 3, String(_Yaml_CountChildren("agents")))

; 回写：先改一个值，再生成
_Yaml_Set("agents.opencode.fit", "", 0)
_Yaml_SetList("agents.opencode.fit", _Yaml_MakeList("write,integrate"))
_Yaml_Set("host.model", "deepseek-v5")
Local $sRound = $g_sOutDir & "\yaml-roundtrip.yaml"
_Check("回写 YAML 成功", _Yaml_SaveFile($sRound), $g_sYamlError)
_Check("回写文件已生成", FileExists($sRound))

; 重新解析回写结果，确认自洽
Local $aFit2 = _Yaml_GetList("agents.opencode.fit")
_Check("回写后重新解析 fit 正确", UBound($aFit2) = 2 And $aFit2[1] = "integrate", _ListText($aFit2))

; ---------------------------------------------------------------- YAML 边角
Local $sProject = @ScriptDir & "\fixtures\project-sample.yaml"
_Check("项目级 project.yaml 解析成功", _Yaml_ParseFile($sProject), $g_sYamlError)
Local $aProjCodex = _Yaml_GetList("agents.codex.fit")
_Check("流映射里 codex.fit 覆盖值", UBound($aProjCodex) = 1 And $aProjCodex[0] = "review", _ListText($aProjCodex))
Local $aProjKimi = _Yaml_GetList("agents.kimi.fit")
_Check("流映射里 kimi.fit 有两项", UBound($aProjKimi) = 2 And $aProjKimi[1] = "review", _ListText($aProjKimi))
_Check("项目级纯往返文件写出", _Yaml_SaveFile($g_sOutDir & "\yaml-project-sample-roundtrip.yaml"))

Local $sConfig = @ScriptDir & "\fixtures\config-sample.yaml"
_Check("config.yaml 解析成功", _Yaml_ParseFile($sConfig), $g_sYamlError)
_Check("stall_timeout = 10m", _Yaml_Get("stall_timeout") = "10m")
_Check("第二行标量也读到", _Yaml_Get("log_tail_kib") = "64")
_Check("全局配置纯往返文件写出", _Yaml_SaveFile($g_sOutDir & "\yaml-config-sample-roundtrip.yaml"))

; ---------------------------------------------------------------- JSON 解析
Local $sState = @ScriptDir & "\fixtures\state-sample.json"
_Check("state.json 解析成功", _Json_ParseFile($sState), $g_sJsonError)

_Check("id = abcd1234", _Json_Get("id") = "abcd1234")
_Check("顶层 goal 中文正确", _Json_Get("goal") = "给订单模块加导出功能", _Json_Get("goal"))
_Check("tasks 是数组且有 2 项", _Json_Kind("tasks") = "arr" And _Json_ArrayCount("tasks") = 2, String(_Json_ArrayCount("tasks")))

_Check("tasks[0].agent = codex", _Json_Get("tasks[0].agent") = "codex")
_Check("tasks[0].paths[1] 正确", _Json_Get("tasks[0].paths[1]") = "src/order/routes.ts")
_Check("tasks[0].acceptance[0] 正确", _Json_Get("tasks[0].acceptance[0]") = "npm test -- export")
_Check("worktree 里的反斜杠转义正确", StringInStr(_Json_Get("tasks[0].worktree"), "\.aic") > 0, _Json_Get("tasks[0].worktree"))
_Check("null 被识别为 null", _Json_Kind("tasks[0].stall_since") = "null")
_Check("tasks[1].depends[0] = T1", _Json_Get("tasks[1].depends[0]") = "T1")
_Check("tasks[1].blocked 中文正确", _Json_Get("tasks[1].blocked") = "依赖 T1 未完成")
_Check("\\u 转义解码正确", _Json_Get("tasks[1].note") = "中文转义测试", _Json_Get("tasks[1].note"))
_Check("delta 数组 2 项", _Json_ArrayCount("delta") = 2)
_Check("delta[1] 正确", _Json_Get("delta[1]") = "进程失败: T3")
_Check("human.pending_question 正确", StringInStr(_Json_Get("human.pending_question"), "CSV") > 0)
_Check("数字类型与取值", _Json_Kind("task_count") = "num" And _Json_GetNum("task_count") = 2)

; 子节点枚举（界面详情用）
Local $aKids = _Json_Children("tasks[0]")
_Check("tasks[0] 直接子节点 >= 10", UBound($aKids) >= 10, String(UBound($aKids)))

; ---------------------------------------------------------------- 写 control.json
Local $sControl = $g_sOutDir & "\control-test.json"
Local $sJson = "{" & @CRLF
$sJson &= '  "answers": [' & @CRLF
$sJson &= '    {"task_id": "T2", "text": "用 XLSX", "at": "2026-09-22T16:10:00"}' & @CRLF
$sJson &= "  ]," & @CRLF
$sJson &= '  "cancels": [' & @CRLF
$sJson &= '    {"task_id": "T3", "reason": "人取消", "at": "2026-09-22T16:10:05"}' & @CRLF
$sJson &= "  ]," & @CRLF
$sJson &= '  "note": "' & _Json_Escape("带引号""和换行" & @LF & "第二行") & '"' & @CRLF
$sJson &= "}" & @CRLF
_Check("control.json 写出成功", _Json_WriteFile($sControl, $sJson), $g_sJsonError)
_Check("control.json 文件已生成", FileExists($sControl))

_Json_Reset()
_Check("回读 control.json 成功", _Json_ParseFile($sControl), $g_sJsonError)
_Check("回读 answers[0].text", _Json_Get("answers[0].text") = "用 XLSX")
_Check("回读 cancels[0].reason", _Json_Get("cancels[0].reason") = "人取消")
_Check("回读转义 note 含换行", StringInStr(_Json_Get("note"), @LF) > 0)

; ---------------------------------------------------------------- 错误路径
_Yaml_Reset()
_Check("YAML 非法行会被报错", Not _Yaml_ParseText("agents: [a, b") And $g_sYamlError <> "", $g_sYamlError)
_Json_Reset()
_Check("JSON 非法内容会被报错", Not _Json_ParseText('{"a": }') And $g_sJsonError <> "", $g_sJsonError)

_Log("")
If $g_iFail = 0 Then
    _Log("解析器验证：全部通过")
Else
    _Log("解析器验证：失败 " & $g_iFail & " 项")
EndIf
Exit $g_iFail
