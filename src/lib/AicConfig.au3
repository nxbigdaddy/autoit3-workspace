; AicConfig.au3 - aic 的模型 / Agent 配置领域层
;
; 对应 aic 真实读取的三个文件：
;   ~/.aic/config.yaml          stall_timeout 等全局项
;   ~/.aic/agents.yaml          host.command + agents.<名>.command / fit / 其它键
;   <repo>/.aic/project.yaml    按项目覆盖 agents.<名>.fit
;
; 两条硬规则：
;   1) 我们只改自己认识的键（command / fit / stall_timeout），其它键一律原样保留，
;      保存时是“重新解析原文件 -> 应用改动 -> 写出”，不会把用户的配置洗掉。
;   2) 模型不是独立 schema：aic 只读 command。所以界面上“模型”字段的做法是
;      在 token 列表里识别/维护 --model X、-m X、--model=X 这三种写法。

#include-once
#include <FileConstants.au3>
#include "MiniYaml.au3"

; Agent 模型列
;   $AG_MODELKEY = "1" 表示这个 agent 的模型写在独立的 model 键里（配置本来就这么写）；
;                  空表示模型写在 command 的 --model token 里。两种写法都支持并各自保留。
Enum $AG_NAME = 0, $AG_CMD = 1, $AG_FIT = 2, $AG_PROJFIT = 3, $AG_EXTRAS = 4, $AG_MODELKEY = 5, $AG_MODELVAL = 6, $AG_COLS

Global $g_aAgents[0][$AG_COLS]
Global $g_aHostCmd[0]
Global $g_sHostExtras = ""
Global $g_sStallTimeout = "10m"
Global $g_sAicError = ""
Global $g_sAicHome = ""
Global $g_sAicRepo = ""

; 允许的 fit 取值（设计文档里是“规划/实现/审查/集成”）
Global Const $AIC_FITS = "plan,write,review,integrate"

; ------------------------------------------------------------------ 路径
Func _Aic_DefaultHome()
    Return @UserProfileDir & "\.aic"
EndFunc   ;==>_Aic_DefaultHome

Func _Aic_SetHome($sHome)
    $g_sAicHome = $sHome
EndFunc   ;==>_Aic_SetHome

Func _Aic_SetRepo($sRepo)
    $g_sAicRepo = $sRepo
EndFunc   ;==>_Aic_SetRepo

Func _Aic_AgentsFile()
    Return $g_sAicHome & "\agents.yaml"
EndFunc   ;==>_Aic_AgentsFile

Func _Aic_ConfigFile()
    Return $g_sAicHome & "\config.yaml"
EndFunc   ;==>_Aic_ConfigFile

Func _Aic_ProjectFile()
    If $g_sAicRepo = "" Then Return ""
    Return $g_sAicRepo & "\.aic\project.yaml"
EndFunc   ;==>_Aic_ProjectFile

; ------------------------------------------------------------------ 读取
; 返回读到的 agent 个数；$g_sAicError 里是出错原因（空 = 正常）
Func _Aic_LoadAll()
    Local $aEmpty[0][$AG_COLS]
    $g_aAgents = $aEmpty
    Local $aNoHost[0]
    $g_aHostCmd = $aNoHost
    $g_sHostExtras = ""
    $g_sStallTimeout = "10m"
    $g_sAicError = ""

    If $g_sAicHome = "" Then
        $g_sAicError = "未设置 aic 目录"
        Return 0
    EndIf

    ; ---- config.yaml：stall_timeout ----
    If FileExists(_Aic_ConfigFile()) Then
        If Not _Yaml_ParseFile(_Aic_ConfigFile()) Then
            $g_sAicError = "config.yaml 解析失败：" & $g_sYamlError
            Return 0
        EndIf
        Local $sStall = _Yaml_Get("stall_timeout", "10m")
        If $sStall <> "" Then $g_sStallTimeout = $sStall
    EndIf

    ; ---- agents.yaml：host + agents ----
    If Not FileExists(_Aic_AgentsFile()) Then
        $g_sAicError = "还没有 agents.yaml（点击“新建配置”可以生成一份）"
        Return 0
    EndIf
    If Not _Yaml_ParseFile(_Aic_AgentsFile()) Then
        $g_sAicError = "agents.yaml 解析失败：" & $g_sYamlError
        Return 0
    EndIf

    Local $aHost = _Yaml_GetList("host.command")
    $g_aHostCmd = $aHost
    $g_sHostExtras = _Aic_ExtrasText("host", "command")

    Local $aNames = _Yaml_ChildKeys("agents")
    If UBound($aNames) = 0 Then
        $g_sAicError = "agents.yaml 里没有 agents 段落"
        Return 0
    EndIf

    ReDim $g_aAgents[UBound($aNames)][$AG_COLS]
    For $i = 0 To UBound($aNames) - 1
        Local $sName = $aNames[$i]
        $g_aAgents[$i][$AG_NAME] = $sName
        $g_aAgents[$i][$AG_CMD] = _Aic_JoinLines(_Yaml_GetList("agents." & $sName & ".command"))
        $g_aAgents[$i][$AG_FIT] = _Aic_JoinCsv(_Yaml_GetList("agents." & $sName & ".fit"))
        $g_aAgents[$i][$AG_PROJFIT] = ""
        ; model 单独处理，所以从“其它键”里排除，避免两处写同一个值
        $g_aAgents[$i][$AG_EXTRAS] = _Aic_ExtrasText("agents." & $sName, "command,fit,model")

        ; 模型两种写法都支持：独立 model 键 / command 里的 --model token
        Local $sKeyModel = _Yaml_Get("agents." & $sName & ".model")
        If $sKeyModel <> "" Then
            $g_aAgents[$i][$AG_MODELKEY] = "1"
            $g_aAgents[$i][$AG_MODELVAL] = $sKeyModel
        Else
            $g_aAgents[$i][$AG_MODELKEY] = ""
            Local $aCmdTmp = _Yaml_MakeList(StringReplace($g_aAgents[$i][$AG_CMD], @LF, ","))
            Local $aFoundTmp = _Aic_ExtractModel($aCmdTmp)
            $g_aAgents[$i][$AG_MODELVAL] = $aFoundTmp[0]
        EndIf
    Next

    ; ---- project.yaml：按项目覆盖 fit ----
    Local $sProject = _Aic_ProjectFile()
    If $sProject <> "" And FileExists($sProject) Then
        If _Yaml_ParseFile($sProject) Then
            For $i = 0 To UBound($g_aAgents, 1) - 1
                Local $sKey = "agents." & $g_aAgents[$i][$AG_NAME] & ".fit"
                If _Yaml_Has($sKey) Then
                    $g_aAgents[$i][$AG_PROJFIT] = _Aic_JoinCsv(_Yaml_GetList($sKey))
                EndIf
            Next
        EndIf
    EndIf

    Return UBound($g_aAgents, 1)
EndFunc   ;==>_Aic_LoadAll

; 把某个前缀下的其它键收集成 "键=值" 多行文本（用于保留和展示）
Func _Aic_ExtrasText($sPrefix, $sSkipCsv)
    Local $aSkip = _Yaml_MakeList($sSkipCsv)
    Local $sOut = ""
    For $i = 0 To UBound($g_aYamlPath) - 1
        Local $sPath = $g_aYamlPath[$i]
        If StringLeft($sPath, StringLen($sPrefix) + 1) <> $sPrefix & "." Then ContinueLoop
        Local $sRest = StringTrimLeft($sPath, StringLen($sPrefix) + 1)
        If StringInStr($sRest, ".") > 0 Then ContinueLoop
        Local $bSkip = False
        For $k = 0 To UBound($aSkip) - 1
            If $aSkip[$k] = $sRest Then $bSkip = True
        Next
        If $bSkip Then ContinueLoop
        Local $sVal = _Yaml_Get($sPath)
        If $sVal = "" Then $sVal = "(" & $g_aYamlKind[$i] & ")"
        If $sOut <> "" Then $sOut &= @LF
        $sOut &= $sRest & "=" & $sVal
    Next
    Return $sOut
EndFunc   ;==>_Aic_ExtrasText

Func _Aic_JoinLines($aItems)
    Local $s = ""
    For $i = 0 To UBound($aItems) - 1
        If $i > 0 Then $s &= @LF
        $s &= $aItems[$i]
    Next
    Return $s
EndFunc   ;==>_Aic_JoinLines

Func _Aic_JoinCsv($aItems)
    Local $s = ""
    For $i = 0 To UBound($aItems) - 1
        If $i > 0 Then $s &= ","
        $s &= $aItems[$i]
    Next
    Return $s
EndFunc   ;==>_Aic_JoinCsv

Func _Aic_AgentIndex($sName)
    For $i = 0 To UBound($g_aAgents, 1) - 1
        If $g_aAgents[$i][$AG_NAME] = $sName Then Return $i
    Next
    Return -1
EndFunc   ;==>_Aic_AgentIndex

Func _Aic_AgentNames()
    Local $aOut[UBound($g_aAgents, 1)]
    For $i = 0 To UBound($g_aAgents, 1) - 1
        $aOut[$i] = $g_aAgents[$i][$AG_NAME]
    Next
    Return $aOut
EndFunc   ;==>_Aic_AgentNames

Func _Aic_FindAgentsByFit($sFit)
    Local $aOut[0]
    For $i = 0 To UBound($g_aAgents, 1) - 1
        Local $sFitList = $g_aAgents[$i][$AG_FIT]
        If $g_aAgents[$i][$AG_PROJFIT] <> "" Then $sFitList = $g_aAgents[$i][$AG_PROJFIT]
        Local $aItems = _Yaml_MakeList($sFitList)
        For $k = 0 To UBound($aItems) - 1
            If $aItems[$k] = $sFit Then
                ReDim $aOut[UBound($aOut) + 1]
                $aOut[UBound($aOut) - 1] = $g_aAgents[$i][$AG_NAME]
                ExitLoop
            EndIf
        Next
    Next
    Return $aOut
EndFunc   ;==>_Aic_FindAgentsByFit

; --------------------------------------------------------- 模型参数的识别
; 支持 --model X / -m X / --model=X
Func _Aic_ExtractModel($aTokens)
    Local $aOut[3] = ["", "", ""]   ; [0]=值 [1]=写成哪种形式(长/短/等号) [2]=token 下标
    For $i = 0 To UBound($aTokens) - 1
        Local $sTok = $aTokens[$i]
        If $sTok = "--model" Or $sTok = "-m" Then
            If $i + 1 <= UBound($aTokens) - 1 Then
                $aOut[0] = $aTokens[$i + 1]
                If $sTok = "--model" Then
                    $aOut[1] = "long"
                Else
                    $aOut[1] = "short"
                EndIf
                $aOut[2] = $i
                Return $aOut
            EndIf
        ElseIf StringLeft($sTok, 8) = "--model=" Then
            $aOut[0] = StringTrimLeft($sTok, 8)
            $aOut[1] = "equals"
            $aOut[2] = $i
            Return $aOut
        EndIf
    Next
    Return $aOut
EndFunc   ;==>_Aic_ExtractModel

; 返回新的 token 数组：把模型设置成 $sModel（空值 = 移除模型参数）
Func _Aic_SetModelTokens($aTokens, $sModel)
    Local $aFound = _Aic_ExtractModel($aTokens)
    Local $aOut[0]

    For $i = 0 To UBound($aTokens) - 1
        If $aFound[2] <> "" And $i = Int($aFound[2]) Then
            If $sModel <> "" Then
                Switch $aFound[1]
                    Case "equals"
                        _Aic_Push($aOut, "--model=" & $sModel)
                    Case "short"
                        _Aic_Push($aOut, "-m")
                        _Aic_Push($aOut, $sModel)
                    Case Else
                        _Aic_Push($aOut, "--model")
                        _Aic_Push($aOut, $sModel)
                EndSwitch
            EndIf
            If $aFound[1] = "short" Or $aFound[1] = "long" Then
                $i += 1   ; 跳过原来的值 token
            EndIf
            ContinueLoop
        EndIf
        _Aic_Push($aOut, $aTokens[$i])
    Next

    ; 原来没有模型参数，但现在要设置 -> 追加到末尾
    If $aFound[2] = "" And $sModel <> "" Then
        _Aic_Push($aOut, "--model")
        _Aic_Push($aOut, $sModel)
    EndIf
    Return $aOut
EndFunc   ;==>_Aic_SetModelTokens

Func _Aic_Push(ByRef $aArr, $sValue)
    ReDim $aArr[UBound($aArr) + 1]
    $aArr[UBound($aArr) - 1] = $sValue
EndFunc   ;==>_Aic_Push

; ------------------------------------------------------------------ 校验
; 返回错误信息数组（空 = 通过）
Func _Aic_Validate()
    Local $aErrors[0]
    Local $aEmpty[0]

    If UBound($g_aHostCmd) = 0 Then
        _Aic_Push($aErrors, "host.command 为空：主持 agent 没有可执行的命令")
    EndIf

    If UBound($g_aAgents, 1) = 0 Then
        _Aic_Push($aErrors, "至少要配置一个 agent")
    EndIf

    For $i = 0 To UBound($g_aAgents, 1) - 1
        Local $sName = StringStripWS($g_aAgents[$i][$AG_NAME], 3)
        If $sName = "" Then
            _Aic_Push($aErrors, "第 " & ($i + 1) & " 个 agent 没有名字")
            ContinueLoop
        EndIf
        If StringRegExp($sName, '[\s\.\[\]]') Then
            _Aic_Push($aErrors, "agent 名不能含空格、点或方括号：" & $sName)
        EndIf
        For $k = $i + 1 To UBound($g_aAgents, 1) - 1
            If $g_aAgents[$k][$AG_NAME] = $sName Then
                _Aic_Push($aErrors, "agent 名重复：" & $sName)
                ExitLoop
            EndIf
        Next

        Local $aCmd = _Yaml_MakeList(StringReplace($g_aAgents[$i][$AG_CMD], @LF, ","))
        If UBound($aCmd) = 0 Then
            _Aic_Push($aErrors, "agent " & $sName & " 的 command 为空")
        EndIf

        Local $aFits = _Yaml_MakeList($g_aAgents[$i][$AG_FIT])
        For $k = 0 To UBound($aFits) - 1
            If StringInStr("," & $AIC_FITS & ",", "," & $aFits[$k] & ",") = 0 Then
                _Aic_Push($aErrors, "agent " & $sName & " 的 fit 值不认识：" & $aFits[$k] & "（可用：" & $AIC_FITS & "）")
            EndIf
        Next
    Next

    If _Aic_ParseDuration($g_sStallTimeout) <= 0 Then
        _Aic_Push($aErrors, "stall_timeout 格式不对：" & $g_sStallTimeout & "（示例 10m / 30s）")
    EndIf

    Return $aErrors
EndFunc   ;==>_Aic_Validate

; 与 aic/board.py 的 parse_duration 保持一致
Func _Aic_ParseDuration($sText)
    Local $sRaw = StringStripWS($sText, 3)
    If $sRaw = "" Then Return -1
    If StringRight($sRaw, 1) = "m" Then
        Local $sNum = StringLeft($sRaw, StringLen($sRaw) - 1)
        If Not StringRegExp($sNum, '^\d+(\.\d+)?$') Then Return -1
        Return Number($sNum) * 60
    EndIf
    If StringRight($sRaw, 1) = "s" Then
        Local $sNum2 = StringLeft($sRaw, StringLen($sRaw) - 1)
        If Not StringRegExp($sNum2, '^\d+(\.\d+)?$') Then Return -1
        Return Number($sNum2)
    EndIf
    If Not StringRegExp($sRaw, '^\d+(\.\d+)?$') Then Return -1
    Return Number($sRaw)
EndFunc   ;==>_Aic_ParseDuration

; ------------------------------------------------------------------ 修改模型
Func _Aic_AddAgent($sName)
    If $sName = "" Then Return -1
    If _Aic_AgentIndex($sName) >= 0 Then Return -1
    Local $iRow = UBound($g_aAgents, 1)
    ReDim $g_aAgents[$iRow + 1][$AG_COLS]
    $g_aAgents[$iRow][$AG_NAME] = $sName
    $g_aAgents[$iRow][$AG_CMD] = ""
    $g_aAgents[$iRow][$AG_FIT] = ""
    $g_aAgents[$iRow][$AG_PROJFIT] = ""
    $g_aAgents[$iRow][$AG_EXTRAS] = ""
    Return $iRow
EndFunc   ;==>_Aic_AddAgent

Func _Aic_RemoveAgent($sName)
    Local $iIdx = _Aic_AgentIndex($sName)
    If $iIdx < 0 Then Return False
    Local $aNew[UBound($g_aAgents, 1) - 1][$AG_COLS]
    Local $n = 0
    For $i = 0 To UBound($g_aAgents, 1) - 1
        If $i = $iIdx Then ContinueLoop
        For $c = 0 To $AG_COLS - 1
            $aNew[$n][$c] = $g_aAgents[$i][$c]
        Next
        $n += 1
    Next
    $g_aAgents = $aNew
    Return True
EndFunc   ;==>_Aic_RemoveAgent

; ------------------------------------------------------------------ 保存
; 保存策略：重新解析原 agents.yaml（保留未知键），只覆盖我们负责的键，再写出
Func _Aic_SaveAgents()
    Local $sFile = _Aic_AgentsFile()
    Local $sDir = $g_sAicHome
    If Not FileExists($sDir) Then DirCreate($sDir)

    If FileExists($sFile) Then
        If Not _Yaml_ParseFile($sFile) Then Return SetError(1, 0, "原文件解析失败，未保存：" & $g_sYamlError)
    Else
        _Yaml_Reset()
    EndIf

    ; host
    _Yaml_SetList("host.command", $g_aHostCmd)

    ; 先把原文件里已经不存在的 agent 删掉，再逐个写
    Local $aExisting = _Yaml_ChildKeys("agents")
    For $i = 0 To UBound($aExisting) - 1
        If _Aic_AgentIndex($aExisting[$i]) < 0 Then
            _Yaml_Remove("agents." & $aExisting[$i])
        EndIf
    Next

    For $i = 0 To UBound($g_aAgents, 1) - 1
        Local $sBase = "agents." & $g_aAgents[$i][$AG_NAME]
        Local $aCmd = _Yaml_MakeList(StringReplace($g_aAgents[$i][$AG_CMD], @LF, ","))
        _Yaml_SetList($sBase & ".command", $aCmd)
        Local $aFit = _Yaml_MakeList($g_aAgents[$i][$AG_FIT])
        _Yaml_SetList($sBase & ".fit", $aFit)
        _Aic_WriteExtras($sBase, $g_aAgents[$i][$AG_EXTRAS])

        ; 模型：独立键写法就改键，token 写法已经在 command 里，不动
        If $g_aAgents[$i][$AG_MODELKEY] = "1" Then
            If StringStripWS($g_aAgents[$i][$AG_MODELVAL], 3) = "" Then
                _Yaml_Remove($sBase & ".model")
            Else
                _Yaml_Set($sBase & ".model", $g_aAgents[$i][$AG_MODELVAL])
            EndIf
        EndIf
    Next

    If Not _Yaml_SaveFile($sFile) Then Return SetError(1, 0, $g_sYamlError)
    Return ""
EndFunc   ;==>_Aic_SaveAgents

; 把 "键=值" 多行文本写回（只覆盖这些键，其它保持原样）
Func _Aic_WriteExtras($sPrefix, $sExtras)
    If StringStripWS($sExtras, 3) = "" Then Return
    Local $aLines = StringSplit(StringReplace($sExtras, @CRLF, @LF), @LF, 2)
    For $i = 0 To UBound($aLines) - 1
        Local $sLine = StringStripWS($aLines[$i], 3)
        If $sLine = "" Then ContinueLoop
        Local $iEq = StringInStr($sLine, "=")
        If $iEq <= 1 Then ContinueLoop
        Local $sKey = StringStripWS(StringLeft($sLine, $iEq - 1), 3)
        Local $sVal = StringStripWS(StringMid($sLine, $iEq + 1), 3)
        _Yaml_Set($sPrefix & "." & $sKey, $sVal)
    Next
EndFunc   ;==>_Aic_WriteExtras

Func _Aic_SaveGlobal()
    Local $sFile = _Aic_ConfigFile()
    If Not FileExists($g_sAicHome) Then DirCreate($g_sAicHome)

    If FileExists($sFile) Then
        If Not _Yaml_ParseFile($sFile) Then Return SetError(1, 0, "原文件解析失败，未保存：" & $g_sYamlError)
    Else
        _Yaml_Reset()
    EndIf

    _Yaml_Set("stall_timeout", $g_sStallTimeout)
    If Not _Yaml_SaveFile($sFile) Then Return SetError(1, 0, $g_sYamlError)
    Return ""
EndFunc   ;==>_Aic_SaveGlobal

; 项目级 fit 覆盖：写 <repo>/.aic/project.yaml（只写有覆盖的 agent）
Func _Aic_SaveProject()
    Local $sFile = _Aic_ProjectFile()
    If $sFile = "" Then Return "未设置仓库路径"
    If Not FileExists($g_sAicRepo & "\.aic") Then DirCreate($g_sAicRepo & "\.aic")

    If FileExists($sFile) Then
        If Not _Yaml_ParseFile($sFile) Then Return "原文件解析失败，未保存：" & $g_sYamlError
    Else
        _Yaml_Reset()
    EndIf

    For $i = 0 To UBound($g_aAgents, 1) - 1
        Local $sKey = "agents." & $g_aAgents[$i][$AG_NAME] & ".fit"
        If StringStripWS($g_aAgents[$i][$AG_PROJFIT], 3) = "" Then
            If _Yaml_Has($sKey) Then _Yaml_Remove($sKey)
        Else
            _Yaml_SetList($sKey, _Yaml_MakeList($g_aAgents[$i][$AG_PROJFIT]))
        EndIf
    Next

    If Not _Yaml_SaveFile($sFile) Then Return $g_sYamlError
    Return ""
EndFunc   ;==>_Aic_SaveProject

; ------------------------------------------------------------------ 新建配置
; 生成一份可直接用的初始 agents.yaml（五家常客各一条命令）
Func _Aic_CreateDefaultAgents()
    Local $aEmpty[0][$AG_COLS]
    $g_aAgents = $aEmpty
    Local $aHost[3] = ["dsh", "--profile", "headless"]
    $g_aHostCmd = $aHost
    $g_sHostExtras = ""
    $g_sStallTimeout = "10m"

    _Aic_SeedAgent("codex", "codex,exec,--json", "write,review")
    _Aic_SeedAgent("opencode", "opencode,run,--format,json", "write")
    _Aic_SeedAgent("kimi", "kimi,-p,--output-format,stream-json", "review,integrate")
    _Aic_SeedAgent("dsh", "dsh,--profile,headless", "plan,write")
    _Aic_SeedAgent("pi", "pi,--mode,json", "write")
    Return UBound($g_aAgents, 1)
EndFunc   ;==>_Aic_CreateDefaultAgents

Func _Aic_SeedAgent($sName, $sCmdCsv, $sFitCsv)
    Local $iRow = _Aic_AddAgent($sName)
    If $iRow < 0 Then Return
    $g_aAgents[$iRow][$AG_CMD] = StringReplace($sCmdCsv, ",", @LF)
    $g_aAgents[$iRow][$AG_FIT] = $sFitCsv
EndFunc   ;==>_Aic_SeedAgent

; 供界面显示：某个 agent 当前生效的模型（两种写法统一）
Func _Aic_ModelForRow($iRow)
    If $iRow < 0 Or $iRow >= UBound($g_aAgents, 1) Then Return ""
    Return $g_aAgents[$iRow][$AG_MODELVAL]
EndFunc   ;==>_Aic_ModelForRow

; 供界面应用修改：按该 agent 原本的写法更新模型，返回新的 token 数组
Func _Aic_ApplyModel($iRow, $aTokens, $sModel)
    If $iRow < 0 Or $iRow >= UBound($g_aAgents, 1) Then Return $aTokens
    $g_aAgents[$iRow][$AG_MODELVAL] = $sModel
    If $g_aAgents[$iRow][$AG_MODELKEY] = "1" Then
        ; 独立键写法：命令原样不动
        Return $aTokens
    EndIf
    Return _Aic_SetModelTokens($aTokens, $sModel)
EndFunc   ;==>_Aic_ApplyModel

; 供界面显示：某个 agent 最终会执行什么命令
Func _Aic_CommandPreview($iRow)
    Local $aCmd = _Yaml_MakeList(StringReplace($g_aAgents[$iRow][$AG_CMD], @LF, ","))
    Local $s = ""
    For $i = 0 To UBound($aCmd) - 1
        If $i > 0 Then $s &= " "
        If StringInStr($aCmd[$i], " ") > 0 Then
            $s &= '"' & $aCmd[$i] & '"'
        Else
            $s &= $aCmd[$i]
        EndIf
    Next
    Return $s
EndFunc   ;==>_Aic_CommandPreview
