; AicRuns.au3 - 运行 / 任务板 / 日志 / 控制通道 领域层
;
; 目录结构（来自 aic/board.py 的 run_paths）：
;   ~/.aic/runs/<run-id>/state.json      任务板唯一事实来源
;   ~/.aic/runs/<run-id>/control.json    人->调度程序 的控制通道（本文件写入）
;   ~/.aic/runs/<run-id>/logs/           工人完整日志
;   ~/.aic/runs/<run-id>/briefs/        简报
;   ~/.aic/runs/<run-id>/worktrees/     每任务一个 worktree
;
; control.json 契约（本项目定义，调度程序按此实现）：
;   {
;     "answers": [ {"task_id": "T2", "text": "...", "at": "..."} ],   // 回答 ask_human
;     "cancels": [ {"task_id": "T3", "reason": "...", "at": "..."} ], // 取消任务；task_id 为 "*" 表示整次运行
;   }
; 调度程序处理完一条后应把它从数组里移除（界面据此显示“待处理”）。

#include-once
#include <FileConstants.au3>
#include "MiniJson.au3"

; 任务板显示列（用宽容映射：字段名可能不同）
Enum $TK_ID = 0, $TK_TITLE, $TK_KIND, $TK_STATUS, $TK_AGENT, $TK_PATHS, $TK_DEPENDS, $TK_SUMMARY, $TK_BLOCKED, $TK_COLS

Global $g_aRuns[0]
Global $g_aTasks[0][$TK_COLS]
Global $g_sRunId = ""
Global $g_sRunError = ""
Global $g_aRunLogs[0]

; ------------------------------------------------------------------ 运行列表
Func _Run_ListRuns($sHome)
    Local $aOut[0]
    Local $sRunsDir = $sHome & "\runs"
    If Not FileExists($sRunsDir) Then Return $aOut

    Local $aSearch = FileFindFirstFile($sRunsDir & "\*")
    If $aSearch = -1 Then Return $aOut

    Local $aNames[0], $aTimes[0]
    While True
        Local $sName = FileFindNextFile($aSearch)
        If @error Then ExitLoop
        If StringInStr(FileGetAttrib($sRunsDir & "\" & $sName), "D") = 0 Then ContinueLoop
        ReDim $aNames[UBound($aNames) + 1]
        ReDim $aTimes[UBound($aTimes) + 1]
        $aNames[UBound($aNames) - 1] = $sName
        Local $sState = $sRunsDir & "\" & $sName & "\state.json"
        If FileExists($sState) Then
            $aTimes[UBound($aTimes) - 1] = FileGetTime($sState, 0, 1)
        Else
            $aTimes[UBound($aTimes) - 1] = "00000000000000"
        EndIf
    WEnd
    FileClose($aSearch)

    ; 按 state.json 修改时间倒序（最近的运行排最前）
    For $i = 0 To UBound($aNames) - 1
        For $k = $i + 1 To UBound($aNames) - 1
            If $aTimes[$k] > $aTimes[$i] Then
                Local $tName = $aNames[$i], $tTime = $aTimes[$i]
                $aNames[$i] = $aNames[$k]
                $aTimes[$i] = $aTimes[$k]
                $aNames[$k] = $tName
                $aTimes[$k] = $tTime
            EndIf
        Next
    Next

    $g_aRuns = $aNames
    Return $aNames
EndFunc   ;==>_Run_ListRuns

Func _Run_StateFile($sHome, $sRunId)
    Return $sHome & "\runs\" & $sRunId & "\state.json"
EndFunc   ;==>_Run_StateFile

Func _Run_ControlFile($sHome, $sRunId)
    Return $sHome & "\runs\" & $sRunId & "\control.json"
EndFunc   ;==>_Run_ControlFile

Func _Run_LogsDir($sHome, $sRunId)
    Return $sHome & "\runs\" & $sRunId & "\logs"
EndFunc   ;==>_Run_LogsDir

; ------------------------------------------------------------------ 读取运行
; 设为当前运行，解析 state.json，填充任务板。返回任务数，失败返回 -1
Func _Run_LoadState($sHome, $sRunId)
    $g_sRunError = ""
    $g_sRunId = $sRunId
    Local $aEmpty[0][$TK_COLS]
    $g_aTasks = $aEmpty

    Local $sFile = _Run_StateFile($sHome, $sRunId)
    If Not FileExists($sFile) Then
        $g_sRunError = "找不到 state.json：" & $sFile
        Return -1
    EndIf
    _Json_Reset()
    If Not _Json_ParseFile($sFile) Then
        $g_sRunError = "state.json 解析失败：" & $g_sJsonError
        Return -1
    EndIf

    Local $iCount = _Json_ArrayCount("tasks")
    If $iCount > 0 Then
        ReDim $g_aTasks[$iCount][$TK_COLS]
        For $i = 0 To $iCount - 1
            Local $sBase = "tasks[" & $i & "]"
            $g_aTasks[$i][$TK_ID] = _Run_Pick($sBase, "id,task_id,task,number,index", String($i + 1))
            $g_aTasks[$i][$TK_TITLE] = _Run_Pick($sBase, "title,name,goal,summary_title", "")
            $g_aTasks[$i][$TK_KIND] = _Run_Pick($sBase, "kind,type,role", "")
            $g_aTasks[$i][$TK_STATUS] = _Run_Pick($sBase, "status,state", "")
            $g_aTasks[$i][$TK_AGENT] = _Run_Pick($sBase, "agent,worker,assignee", "")
            $g_aTasks[$i][$TK_PATHS] = _Run_JoinArrayPath($sBase, "paths,files,owns,scope")
            $g_aTasks[$i][$TK_DEPENDS] = _Run_JoinArrayPath($sBase, "depends,dependencies,needs,after")
            $g_aTasks[$i][$TK_SUMMARY] = _Run_Pick($sBase, "summary,note,result,brief_summary", "")
            $g_aTasks[$i][$TK_BLOCKED] = _Run_Pick($sBase, "blocked,block_reason,blocker,reason", "")
        Next
    EndIf
    Return $iCount
EndFunc   ;==>_Run_LoadState

; 依次尝试多个键名，返回第一个存在的文本值
Func _Run_Pick($sBase, $sKeysCsv, $sDefault)
    Local $aKeys = StringSplit($sKeysCsv, ",", 2)
    For $i = 0 To UBound($aKeys) - 1
        Local $sPath = $aKeys[$i]
        If $sBase <> "" Then $sPath = $sBase & "." & $aKeys[$i]
        If _Json_Has($sPath) And _Json_Kind($sPath) <> "obj" And _Json_Kind($sPath) <> "arr" Then
            Return _Json_Get($sPath, $sDefault)
        EndIf
    Next
    Return $sDefault
EndFunc   ;==>_Run_Pick

; 数组字段 -> "a, b, c"
Func _Run_JoinArrayPath($sBase, $sKeysCsv)
    Local $aKeys = StringSplit($sKeysCsv, ",", 2)
    For $i = 0 To UBound($aKeys) - 1
        Local $sPath = $aKeys[$i]
        If $sBase <> "" Then $sPath = $sBase & "." & $aKeys[$i]
        If _Json_Has($sPath) And _Json_Kind($sPath) = "arr" Then
            Local $iCount = _Json_ArrayCount($sPath)
            Local $s = ""
            For $k = 0 To $iCount - 1
                If $k > 0 Then $s &= ", "
                $s &= _Json_Get($sPath & "[" & $k & "]", "")
            Next
            Return $s
        EndIf
        ; 也可能写成单个字符串
        If _Json_Has($sPath) And _Json_Kind($sPath) = "str" Then Return _Json_Get($sPath, "")
    Next
    Return ""
EndFunc   ;==>_Run_JoinArrayPath

Func _Run_Field($sKey, $sDefault = "")
    Return _Run_Pick("", $sKey, $sDefault)
EndFunc   ;==>_Run_Field

; 顶层字段里的任务统计
Func _Run_CountByStatus($sStatus)
    Local $iCount = 0
    For $i = 0 To UBound($g_aTasks, 1) - 1
        If $g_aTasks[$i][$TK_STATUS] = $sStatus Then $iCount += 1
    Next
    Return $iCount
EndFunc   ;==>_Run_CountByStatus

; ask_human 待回答的问题（human.pending_question / question / 顶层 pending_question）
Func _Run_PendingQuestion()
    Local $aKeys[4] = ["human.pending_question", "human.question", "pending_question", "question"]
    For $i = 0 To UBound($aKeys) - 1
        If _Json_Has($aKeys[$i]) Then
            Local $sText = _Json_Get($aKeys[$i], "")
            If $sText <> "" Then Return $sText
        EndIf
    Next
    Return ""
EndFunc   ;==>_Run_PendingQuestion

Func _Run_PendingQuestionTask()
    Local $aKeys[3] = ["human.task_id", "pending_question_task", "human.task"]
    For $i = 0 To UBound($aKeys) - 1
        If _Json_Has($aKeys[$i]) Then
            Local $sText = _Json_Get($aKeys[$i], "")
            If $sText <> "" Then Return $sText
        EndIf
    Next
    Return ""
EndFunc   ;==>_Run_PendingQuestionTask

; 该任务的一行“原始 JSON 字段”清单（详情页用，未知字段也能看到）
Func _Run_TaskRawFields($iTask)
    Local $aOut[0]
    If $iTask < 0 Or $iTask >= UBound($g_aTasks, 1) Then Return $aOut
    Local $sBase = "tasks[" & $iTask & "]"
    Local $aKids = _Json_Children($sBase)
    For $i = 0 To UBound($aKids) - 1
        ReDim $aOut[UBound($aOut) + 1]
        $aOut[UBound($aOut) - 1] = _Json_ShortName($aKids[$i], $sBase) & " = " & _Json_DisplayValue($aKids[$i])
    Next
    Return $aOut
EndFunc   ;==>_Run_TaskRawFields

; ------------------------------------------------------------------ 日志
; 列出 logs 目录下的文件（按修改时间倒序）
Func _Run_ListLogs($sHome, $sRunId)
    Local $aOut[0]
    Local $sDir = _Run_LogsDir($sHome, $sRunId)
    $g_aRunLogs = $aOut
    If Not FileExists($sDir) Then Return $aOut

    Local $aSearch = FileFindFirstFile($sDir & "\*")
    If $aSearch = -1 Then Return $aOut
    While True
        Local $sName = FileFindNextFile($aSearch)
        If @error Then ExitLoop
        If StringInStr(FileGetAttrib($sDir & "\" & $sName), "D") > 0 Then ContinueLoop
        ReDim $aOut[UBound($aOut) + 1]
        $aOut[UBound($aOut) - 1] = $sName
    WEnd
    FileClose($aSearch)

    ; 简单排序：名字倒序（日志名一般带任务号或时间）
    For $i = 0 To UBound($aOut) - 1
        For $k = $i + 1 To UBound($aOut) - 1
            If $aOut[$k] > $aOut[$i] Then
                Local $t = $aOut[$i]
                $aOut[$i] = $aOut[$k]
                $aOut[$k] = $t
            EndIf
        Next
    Next
    $g_aRunLogs = $aOut
    Return $aOut
EndFunc   ;==>_Run_ListLogs

; 优先返回与任务号同名的日志（T1.log / T1.txt / T1*）
Func _Run_GuessLog($sHome, $sRunId, $sTaskId)
    If $sTaskId = "" Then Return ""
    Local $sDir = _Run_LogsDir($sHome, $sRunId)
    Local $aCands[4] = [$sTaskId & ".log", $sTaskId & ".txt", $sTaskId & ".jsonl", $sTaskId & ".out"]
    For $i = 0 To UBound($aCands) - 1
        If FileExists($sDir & "\" & $aCands[$i]) Then Return $sDir & "\" & $aCands[$i]
    Next
    Local $aSearch = FileFindFirstFile($sDir & "\" & $sTaskId & "*")
    If $aSearch <> -1 Then
        Local $sName = FileFindNextFile($aSearch)
        FileClose($aSearch)
        If Not @error And $sName <> "" Then Return $sDir & "\" & $sName
    EndIf
    Return ""
EndFunc   ;==>_Run_GuessLog

; 读取文件末尾约 $iKiB 的内容（日志跟随用，不整份读进来）
Func _Run_TailFile($sFile, $iKiB = 64)
    If $sFile = "" Or Not FileExists($sFile) Then Return ""
    Local $hFile = FileOpen($sFile, $FO_READ)
    If $hFile = -1 Then Return ""
    Local $iSize = FileGetSize($sFile)
    Local $iWant = $iKiB * 1024
    If $iSize > $iWant Then
        FileSetPos($hFile, $iSize - $iWant, 0)
    EndIf
    Local $sText = FileRead($hFile)
    FileClose($hFile)
    If $iSize > $iWant Then $sText = "...(仅显示末尾 " & $iKiB & " KiB)..." & @CRLF & $sText
    Return $sText
EndFunc   ;==>_Run_TailFile

; ------------------------------------------------------------------ 控制通道
; 读 control.json，返回 [cancels 文本, answers 文本]
Func _Run_ReadControl($sHome, $sRunId)
    Local $aOut[2] = ["", ""]
    Local $sFile = _Run_ControlFile($sHome, $sRunId)
    If Not FileExists($sFile) Then Return $aOut

    _Json_Reset()
    If Not _Json_ParseFile($sFile) Then
        $aOut[0] = "(control.json 解析失败：" & $g_sJsonError & ")"
        Return $aOut
    EndIf

    Local $iCancels = _Json_ArrayCount("cancels")
    For $i = 0 To $iCancels - 1
        Local $sBase = "cancels[" & $i & "]"
        If $aOut[0] <> "" Then $aOut[0] &= @CRLF
        $aOut[0] &= _Run_Pick($sBase, "task_id,task,id", "?") & "  " & _Run_Pick($sBase, "reason", "") & "  " & _Run_Pick($sBase, "at", "")
    Next

    Local $iAnswers = _Json_ArrayCount("answers")
    For $i = 0 To $iAnswers - 1
        Local $sBase2 = "answers[" & $i & "]"
        If $aOut[1] <> "" Then $aOut[1] &= @CRLF
        $aOut[1] &= _Run_Pick($sBase2, "task_id,task,id", "?") & "  " & _Run_Pick($sBase2, "text,answer,message", "") & "  " & _Run_Pick($sBase2, "at", "")
    Next
    Return $aOut
EndFunc   ;==>_Run_ReadControl

; 追加一条取消命令。$sTaskId = "*" 表示整次运行
Func _Run_AppendCancel($sHome, $sRunId, $sTaskId, $sReason)
    Return _Run_AppendControl($sHome, $sRunId, "cancels", $sTaskId, "reason", $sReason)
EndFunc   ;==>_Run_AppendCancel

Func _Run_AppendAnswer($sHome, $sRunId, $sTaskId, $sText)
    Return _Run_AppendControl($sHome, $sRunId, "answers", $sTaskId, "text", $sText)
EndFunc   ;==>_Run_AppendAnswer

; 读旧文件 -> 追加一条 -> 整体重写（保持已有条目，不覆盖别人写的）
Func _Run_AppendControl($sHome, $sRunId, $sArrayName, $sTaskId, $sFieldName, $sValue)
    Local $sFile = _Run_ControlFile($sHome, $sRunId)
    Local $aOldCancels[0], $aOldAnswers[0]

    If FileExists($sFile) Then
        _Json_Reset()
        If _Json_ParseFile($sFile) Then
            $aOldCancels = _Run_CollectArray("cancels")
            $aOldAnswers = _Run_CollectArray("answers")
        EndIf
    EndIf

    Local $sNow = @YEAR & "-" & @MON & "-" & @MDAY & "T" & @HOUR & ":" & @MIN & ":" & @SEC
    Local $sEntry = '{"task_id": "' & _Json_Escape($sTaskId) & '", "' & $sFieldName & '": "' & _Json_Escape($sValue) & '", "at": "' & $sNow & '"}'

    If $sArrayName = "cancels" Then
        Local $aTmp[UBound($aOldCancels) + 1]
        For $i = 0 To UBound($aOldCancels) - 1
            $aTmp[$i] = $aOldCancels[$i]
        Next
        $aTmp[UBound($aTmp) - 1] = $sEntry
        $aOldCancels = $aTmp
    Else
        Local $aTmp2[UBound($aOldAnswers) + 1]
        For $i = 0 To UBound($aOldAnswers) - 1
            $aTmp2[$i] = $aOldAnswers[$i]
        Next
        $aTmp2[UBound($aTmp2) - 1] = $sEntry
        $aOldAnswers = $aTmp2
    EndIf

    Local $sJson = "{" & @CRLF
    $sJson &= '  "answers": [' & @CRLF
    $sJson &= _Run_RenderEntries($aOldAnswers, "    ")
    $sJson &= "  ]," & @CRLF
    $sJson &= '  "cancels": [' & @CRLF
    $sJson &= _Run_RenderEntries($aOldCancels, "    ")
    $sJson &= "  ]" & @CRLF
    $sJson &= "}" & @CRLF

    If Not _Json_WriteFile($sFile, $sJson) Then Return $g_sJsonError
    Return ""
EndFunc   ;==>_Run_AppendControl

Func _Run_RenderEntries($aEntries, $sIndent)
    Local $s = ""
    For $i = 0 To UBound($aEntries) - 1
        $s &= $sIndent & $aEntries[$i]
        If $i < UBound($aEntries) - 1 Then $s &= ","
        $s &= @CRLF
    Next
    Return $s
EndFunc   ;==>_Run_RenderEntries

; 把数组里每条对象重新序列化成一行 JSON（避免依赖原始切片）
Func _Run_CollectArray($sArrayName)
    Local $aOut[0]
    Local $iCount = _Json_ArrayCount($sArrayName)
    For $i = 0 To $iCount - 1
        Local $sBase = $sArrayName & "[" & $i & "]"
        Local $aKids = _Json_Children($sBase)
        If UBound($aKids) = 0 Then ContinueLoop
        Local $sEntry = "{"
        For $k = 0 To UBound($aKids) - 1
            Local $sKey = _Json_ShortName($aKids[$k], $sBase)
            Local $sKind = _Json_Kind($aKids[$k])
            If $k > 0 Then $sEntry &= ", "
            If $sKind = "num" Then
                $sEntry &= '"' & _Json_Escape($sKey) & '": ' & _Json_Get($aKids[$k], "0")
            ElseIf $sKind = "bool" Then
                Local $sBool = "false"
                If _Json_Get($aKids[$k], "") = "True" Then $sBool = "true"
                $sEntry &= '"' & _Json_Escape($sKey) & '": ' & $sBool
            ElseIf $sKind = "null" Then
                $sEntry &= '"' & _Json_Escape($sKey) & '": null'
            Else
                $sEntry &= '"' & _Json_Escape($sKey) & '": "' & _Json_Escape(_Json_Get($aKids[$k], "")) & '"'
            EndIf
        Next
        $sEntry &= "}"
        ReDim $aOut[UBound($aOut) + 1]
        $aOut[UBound($aOut) - 1] = $sEntry
    Next
    Return $aOut
EndFunc   ;==>_Run_CollectArray

; ------------------------------------------------------------------ 演示环境
; 造一份假的 ~/.aic（含 run / 任务 / 日志 / 控制文件），供无真实运行时验证界面
Func _Run_BuildDemoHome($sHome)
    If FileExists($sHome) Then DirRemove($sHome, 1)
    DirCreate($sHome)

    Local $sRun1 = $sHome & "\runs\20260922-1601-abcd1234"
    DirCreate($sRun1 & "\logs")
    DirCreate($sRun1 & "\worktrees\T1")
    DirCreate($sRun1 & "\briefs")

    Local $sState = FileRead(@ScriptDir & "\..\tests\fixtures\state-sample.json")
    Local $hFile = FileOpen($sRun1 & "\state.json", $FO_OVERWRITE + $FO_CREATEPATH + $FO_UTF8_NOBOM)
    If $hFile <> -1 Then
        FileWrite($hFile, $sState)
        FileClose($hFile)
    EndIf

    Local $sLog = "[16:01:12] codex 启动，worktree=...\worktrees\T1" & @CRLF & _
            "[16:01:40] 读取 src/order/routes.ts" & @CRLF & _
            "[16:02:05] 新增 src/order/export.ts" & @CRLF & _
            "[16:03:11] 改写 src/order/routes.ts（挂载 /orders/export）" & @CRLF & _
            "[16:04:02] npm test -- export" & @CRLF & _
            "[16:04:20] 12 passed" & @CRLF
    Local $hLog = FileOpen($sRun1 & "\logs\T1.log", $FO_OVERWRITE + $FO_CREATEPATH + $FO_UTF8)
    If $hLog <> -1 Then
        FileWrite($hLog, $sLog)
        FileClose($hLog)
    EndIf

    ; 第二个运行：已结束
    Local $sRun2 = $sHome & "\runs\20260922-1530-9f8e7d6c"
    DirCreate($sRun2 & "\logs")
    Local $sState2 = '{"id": "9f8e7d6c", "status": "finished", "goal": "修复登录超时", "task_count": 1, ' & _
            '"tasks": [{"id": "T1", "title": "修 setTimeout", "kind": "write", "status": "merged", "agent": "opencode", ' & _
            '"paths": ["src/auth/session.ts"], "acceptance": ["npm test -- auth"], "summary": "已合并进集成分支"}], ' & _
            '"delta": ["任务完成: T1"]}'
    Local $hState2 = FileOpen($sRun2 & "\state.json", $FO_OVERWRITE + $FO_CREATEPATH + $FO_UTF8_NOBOM)
    If $hState2 <> -1 Then
        FileWrite($hState2, $sState2)
        FileClose($hState2)
    EndIf

    Return True
EndFunc   ;==>_Run_BuildDemoHome
