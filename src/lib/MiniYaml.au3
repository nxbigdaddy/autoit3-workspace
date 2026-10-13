; MiniYaml.au3 - 最小 YAML 子集解析 / 生成（专为 aic 配置文件的编辑而写）
;
; 为什么不用第三方：AutoIt 没有 YAML 库；而 aic 的配置文件结构固定为
; “嵌套映射 + 字符串列表 + 标量”，用一个小而可控的实现最稳。
;
; 数据表示：三个（+1）平行数组，路径为点分字符串
;   $g_aYamlPath[i]  = "agents.codex.command"
;   $g_aYamlKind[i]  = "str" | "list" | "map"
;   $g_aYamlVal[i]   = str: 文本；list: 元素用 @LF 连接；map: ""
;   $g_aYamlQuoted[i]= 1 表示原文件里这个标量带引号（回写时保持引号，避免类型被改变）
;
; 支持的语法（够用且明确）：
;   * 块映射            key: value / key:
;   * 块序列            - item
;   * 流序列            key: [a, b, c]
;   * 流映射            key: {a: 1, b: [2]}
;   * 单/双引号标量、行内注释、空行、# 注释行
;   * 2 空格或任意空格缩进（按层级相对缩进处理）
; 明确不支持的：多行标量（| / >）、锚点别名（& / *）、列表中的映射项。
; 遇到不支持的结构会给出带行号的错误，而不是猜。

#include-once
#include <Array.au3>
#include <FileConstants.au3>

Global $g_aYamlPath[0]
Global $g_aYamlKind[0]
Global $g_aYamlVal[0]
Global $g_aYamlQuoted[0]
Global $g_sYamlError = ""

; ------------------------------------------------------------------ 基础
Func _Yaml_Reset()
    Local $aE[0]
    $g_aYamlPath = $aE
    $g_aYamlKind = $aE
    $g_aYamlVal = $aE
    $g_aYamlQuoted = $aE
    $g_sYamlError = ""
EndFunc   ;==>_Yaml_Reset

Func _Yaml_Error($sMessage)
    $g_sYamlError = $sMessage
    Return False
EndFunc   ;==>_Yaml_Error

Func _Yaml_Count()
    Return UBound($g_aYamlPath)
EndFunc   ;==>_Yaml_Count

Func _Yaml_Index($sPath)
    For $i = 0 To UBound($g_aYamlPath) - 1
        If $g_aYamlPath[$i] = $sPath Then Return $i
    Next
    Return -1
EndFunc   ;==>_Yaml_Index

Func _Yaml_Has($sPath)
    Return _Yaml_Index($sPath) >= 0
EndFunc   ;==>_Yaml_Has

Func _Yaml_Kind($sPath)
    Local $i = _Yaml_Index($sPath)
    If $i < 0 Then Return ""
    Return $g_aYamlKind[$i]
EndFunc   ;==>_Yaml_Kind

Func _Yaml_Get($sPath, $sDefault = "")
    Local $i = _Yaml_Index($sPath)
    If $i < 0 Then Return $sDefault
    If $g_aYamlKind[$i] <> "str" Then Return $sDefault
    Return $g_aYamlVal[$i]
EndFunc   ;==>_Yaml_Get

; 返回 0 基数组；路径不存在返回空数组
Func _Yaml_GetList($sPath)
    Local $aEmpty[0]
    Local $i = _Yaml_Index($sPath)
    If $i < 0 Then Return $aEmpty
    If $g_aYamlKind[$i] <> "list" Then Return $aEmpty
    If $g_aYamlVal[$i] = "" Then Return $aEmpty
    Return StringSplit($g_aYamlVal[$i], @LF, 2)
EndFunc   ;==>_Yaml_GetList

Func _Yaml_Add($sPath, $sKind, $sValue, $bQuoted = 0)
    Local $i = _Yaml_Index($sPath)
    If $i >= 0 Then
        $g_aYamlKind[$i] = $sKind
        $g_aYamlVal[$i] = $sValue
        $g_aYamlQuoted[$i] = $bQuoted
        Return $i
    EndIf
    Local $n = UBound($g_aYamlPath)
    ReDim $g_aYamlPath[$n + 1]
    ReDim $g_aYamlKind[$n + 1]
    ReDim $g_aYamlVal[$n + 1]
    ReDim $g_aYamlQuoted[$n + 1]
    $g_aYamlPath[$n] = $sPath
    $g_aYamlKind[$n] = $sKind
    $g_aYamlVal[$n] = $sValue
    $g_aYamlQuoted[$n] = $bQuoted
    Return $n
EndFunc   ;==>_Yaml_Add

; 设置标量（保持原有插入位置）
Func _Yaml_Set($sPath, $sValue, $bQuoted = 0)
    Local $i = _Yaml_Index($sPath)
    If $i >= 0 Then
        $g_aYamlKind[$i] = "str"
        $g_aYamlVal[$i] = $sValue
        $g_aYamlQuoted[$i] = $bQuoted
        Return True
    EndIf
    _Yaml_Add($sPath, "str", $sValue, $bQuoted)
    Return True
EndFunc   ;==>_Yaml_Set

Func _Yaml_SetList($sPath, $aItems)
    Local $sJoined = ""
    For $i = 0 To UBound($aItems) - 1
        If $i > 0 Then $sJoined &= @LF
        $sJoined &= String($aItems[$i])
    Next
    _Yaml_Add($sPath, "list", $sJoined, 0)
    Return True
EndFunc   ;==>_Yaml_SetList

; 删除一个节点及其所有子节点
Func _Yaml_Remove($sPath)
    Local $aKeepPath[0], $aKeepKind[0], $aKeepVal[0], $aKeepQuoted[0], $n = 0
    For $i = 0 To UBound($g_aYamlPath) - 1
        Local $sCur = $g_aYamlPath[$i]
        Local $bHit = ($sCur = $sPath) Or (StringLeft($sCur, StringLen($sPath) + 1) = $sPath & ".")
        If Not $bHit Then
            ReDim $aKeepPath[$n + 1]
            ReDim $aKeepKind[$n + 1]
            ReDim $aKeepVal[$n + 1]
            ReDim $aKeepQuoted[$n + 1]
            $aKeepPath[$n] = $g_aYamlPath[$i]
            $aKeepKind[$n] = $g_aYamlKind[$i]
            $aKeepVal[$n] = $g_aYamlVal[$i]
            $aKeepQuoted[$n] = $g_aYamlQuoted[$i]
            $n += 1
        EndIf
    Next
    $g_aYamlPath = $aKeepPath
    $g_aYamlKind = $aKeepKind
    $g_aYamlVal = $aKeepVal
    $g_aYamlQuoted = $aKeepQuoted
EndFunc   ;==>_Yaml_Remove

; ------------------------------------------------------------------ 解析
Func _Yaml_ParseFile($sFile)
    If Not FileExists($sFile) Then Return _Yaml_Error("文件不存在: " & $sFile)
    Local $hFile = FileOpen($sFile, $FO_READ)
    If $hFile = -1 Then Return _Yaml_Error("无法打开文件: " & $sFile)
    Local $sText = FileRead($hFile)
    FileClose($hFile)
    Return _Yaml_ParseText($sText)
EndFunc   ;==>_Yaml_ParseFile

Func _Yaml_ParseText($sText)
    _Yaml_Reset()

    Local $sNorm = StringReplace(StringReplace($sText, @CRLF, @LF), @CR, @LF)
    Local $aLines = StringSplit($sNorm, @LF, 2)

    ; 缩进栈：栈顶是“最近一个 key:”节点
    Local $aStackPath[1] = [""]
    Local $aStackIndent[1] = [-1]
    Local $aStackKind[1] = ["root"]
    Local $iTop = 0

    For $i = 0 To UBound($aLines) - 1
        Local $sLine = $aLines[$i]
        Local $iLineNo = $i + 1

        ; 去注释（引号外的 #）
        $sLine = _Yaml_StripComment($sLine)
        If StringStripWS($sLine, 3) = "" Then ContinueLoop

        ; 缩进
        Local $iIndent = 0
        While $iIndent < StringLen($sLine) And StringMid($sLine, $iIndent + 1, 1) = " "
            $iIndent += 1
        WEnd
        If StringInStr($sLine, @TAB) > 0 Then Return _Yaml_Error("第 " & $iLineNo & " 行：不支持 Tab 缩进，请用空格")

        Local $sBody = StringStripWS(StringMid($sLine, $iIndent + 1), 3)

        ; 弹栈：父节点必须是缩进更小的那个
        While $iTop > 0 And $aStackIndent[$iTop] >= $iIndent
            $iTop -= 1
        WEnd
        Local $sParent = $aStackPath[$iTop]

        If $sBody = "-" Or StringLeft($sBody, 2) = "- " Then
            ; ---- 块序列项 ----
            If $iTop = 0 Then Return _Yaml_Error("第 " & $iLineNo & " 行：序列项没有所属的键")
            If $aStackKind[$iTop] <> "map" And $aStackKind[$iTop] <> "list" Then
                Return _Yaml_Error("第 " & $iLineNo & " 行：序列项所属的键不是列表")
            EndIf
            ; 确认该键下没有子映射
            If $aStackKind[$iTop] = "map" And _Yaml_HasChildren($sParent) Then
                Return _Yaml_Error("第 " & $iLineNo & " 行：键 " & $sParent & " 下面既有映射又有列表，暂不支持")
            EndIf
            $aStackKind[$iTop] = "list"
            Local $sItem = StringStripWS(StringMid($sBody, 2), 3)
            If StringRight($sItem, 1) = ":" Or StringInStr($sItem, ": ") > 0 Then
                Return _Yaml_Error("第 " & $iLineNo & " 行：暂不支持列表中的映射项（" & $sItem & "）")
            EndIf
            Local $sItemVal = _Yaml_Unquote($sItem)
            Local $sOld = _Yaml_GetListJoined($sParent)
            If $sOld = "" Then
                _Yaml_Add($sParent, "list", $sItemVal, 0)
            Else
                _Yaml_Add($sParent, "list", $sOld & @LF & $sItemVal, 0)
            EndIf
        Else
            ; ---- 映射项 key: value ----
            Local $iColon = _Yaml_FindColon($sBody)
            If $iColon <= 0 Then Return _Yaml_Error("第 " & $iLineNo & " 行：不是 key: value 形式（" & $sBody & "）")
            Local $sKey = StringStripWS(StringLeft($sBody, $iColon - 1), 3)
            Local $sValue = StringStripWS(StringMid($sBody, $iColon + 1), 3)
            If $sKey = "" Then Return _Yaml_Error("第 " & $iLineNo & " 行：键名为空")

            Local $sPath = $sKey
            If $sParent <> "" Then $sPath = $sParent & "." & $sKey

            If $sValue = "" Then
                _Yaml_Add($sPath, "map", "", 0)
                $iTop += 1
                If $iTop > UBound($aStackPath) - 1 Then
                    ReDim $aStackPath[$iTop + 1]
                    ReDim $aStackIndent[$iTop + 1]
                    ReDim $aStackKind[$iTop + 1]
                EndIf
                $aStackPath[$iTop] = $sPath
                $aStackIndent[$iTop] = $iIndent
                $aStackKind[$iTop] = "map"
            Else
                Local $bOk = _Yaml_SetValue($sPath, $sValue)
                If Not $bOk Then Return _Yaml_Error("第 " & $iLineNo & " 行：" & $g_sYamlError)
            EndIf
        EndIf
    Next

    Return True
EndFunc   ;==>_Yaml_ParseText

Func _Yaml_HasChildren($sPath)
    For $i = 0 To UBound($g_aYamlPath) - 1
        If StringLeft($g_aYamlPath[$i], StringLen($sPath) + 1) = $sPath & "." Then Return True
    Next
    Return False
EndFunc   ;==>_Yaml_HasChildren

Func _Yaml_GetListJoined($sPath)
    Local $i = _Yaml_Index($sPath)
    If $i < 0 Then Return ""
    If $g_aYamlKind[$i] <> "list" Then Return ""
    Return $g_aYamlVal[$i]
EndFunc   ;==>_Yaml_GetListJoined

; 直接子节点个数（界面里用来判断 agents 有几个）
Func _Yaml_CountChildren($sPath)
    Local $iCount = 0
    For $i = 0 To UBound($g_aYamlPath) - 1
        Local $s = $g_aYamlPath[$i]
        If StringLeft($s, StringLen($sPath) + 1) <> $sPath & "." Then ContinueLoop
        Local $sRest = StringTrimLeft($s, StringLen($sPath) + 1)
        If StringInStr($sRest, ".") = 0 Then $iCount += 1
    Next
    Return $iCount
EndFunc   ;==>_Yaml_CountChildren

; 直接子键名列表（不含更深层级，去重，保持出现顺序）
Func _Yaml_ChildKeys($sPath)
    Local $aOut[0]
    For $i = 0 To UBound($g_aYamlPath) - 1
        Local $s = $g_aYamlPath[$i]
        If $sPath <> "" And StringLeft($s, StringLen($sPath) + 1) <> $sPath & "." Then ContinueLoop
        Local $sRest = $s
        If $sPath <> "" Then $sRest = StringTrimLeft($s, StringLen($sPath) + 1)
        If StringInStr($sRest, ".") > 0 Then ContinueLoop
        Local $bDup = False
        For $k = 0 To UBound($aOut) - 1
            If $aOut[$k] = $sRest Then $bDup = True
        Next
        If Not $bDup Then
            ReDim $aOut[UBound($aOut) + 1]
            $aOut[UBound($aOut) - 1] = $sRest
        EndIf
    Next
    Return $aOut
EndFunc   ;==>_Yaml_ChildKeys

; 逗号分隔文本 -> 数组（界面输入 "a, b, c" 用）
Func _Yaml_MakeList($sCsv)
    Local $aOut[0]
    If StringStripWS($sCsv, 3) = "" Then Return $aOut
    Local $aParts = StringSplit($sCsv, ",", 2)
    For $i = 0 To UBound($aParts) - 1
        Local $sItem = StringStripWS($aParts[$i], 3)
        If $sItem = "" Then ContinueLoop
        ReDim $aOut[UBound($aOut) + 1]
        $aOut[UBound($aOut) - 1] = $sItem
    Next
    Return $aOut
EndFunc   ;==>_Yaml_MakeList

; 把 "值" 部分写入路径：标量 / 流序列 / 流映射
Func _Yaml_SetValue($sPath, $sValue)
    Local $sFirst = StringLeft($sValue, 1)

    If $sFirst = "[" Then
        If StringRight($sValue, 1) <> "]" Then Return _Yaml_Error("流序列缺少 ]")
        Local $aItems = _Yaml_SplitFlow(StringMid($sValue, 2, StringLen($sValue) - 2))
        If @error Then Return _Yaml_Error($g_sYamlError)
        Local $sJoined = ""
        For $i = 0 To UBound($aItems) - 1
            If $i > 0 Then $sJoined &= @LF
            $sJoined &= _Yaml_Unquote($aItems[$i])
        Next
        _Yaml_Add($sPath, "list", $sJoined, 0)
        Return True
    EndIf

    If $sFirst = "{" Then
        If StringRight($sValue, 1) <> "}" Then Return _Yaml_Error("流映射缺少 }")
        Local $aPairs = _Yaml_SplitFlow(StringMid($sValue, 2, StringLen($sValue) - 2))
        If @error Then Return _Yaml_Error($g_sYamlError)
        _Yaml_Add($sPath, "map", "", 0)
        For $i = 0 To UBound($aPairs) - 1
            Local $sPair = StringStripWS($aPairs[$i], 3)
            If $sPair = "" Then ContinueLoop
            Local $iColon = _Yaml_FindColon($sPair)
            If $iColon <= 0 Then Return _Yaml_Error("流映射项不是 key: value: " & $sPair)
            Local $sSubKey = _Yaml_Unquote(StringStripWS(StringLeft($sPair, $iColon - 1), 3))
            Local $sSubVal = StringStripWS(StringMid($sPair, $iColon + 1), 3)
            If Not _Yaml_SetValue($sPath & "." & $sSubKey, $sSubVal) Then Return False
        Next
        Return True
    EndIf

    Local $bQuoted = 0
    If $sFirst = '"' Or $sFirst = "'" Then $bQuoted = 1
    _Yaml_Add($sPath, "str", _Yaml_Unquote($sValue), $bQuoted)
    Return True
EndFunc   ;==>_Yaml_SetValue

; 找 key: value 的分隔冒号（跳过引号内的冒号）
Func _Yaml_FindColon($sBody)
    Local $bInSingle = False, $bInDouble = False
    For $i = 1 To StringLen($sBody)
        Local $c = StringMid($sBody, $i, 1)
        If $c = "'" And Not $bInDouble Then
            $bInSingle = Not $bInSingle
        ElseIf $c = '"' And Not $bInSingle Then
            $bInDouble = Not $bInDouble
        ElseIf $c = ":" And Not $bInSingle And Not $bInDouble Then
            ; 必须是行尾或后面跟空格，才算分隔符（避免把 C:\path 当键）
            If $i = StringLen($sBody) Then Return $i
            If StringMid($sBody, $i + 1, 1) = " " Then Return $i
        EndIf
    Next
    Return -1
EndFunc   ;==>_Yaml_FindColon

Func _Yaml_Unquote($sText)
    Local $s = StringStripWS($sText, 3)
    If StringLen($s) < 2 Then Return $s
    Local $sFirst = StringLeft($s, 1)
    Local $sLast = StringRight($s, 1)

    If $sFirst = "'" And $sLast = "'" Then
        Return StringReplace(StringMid($s, 2, StringLen($s) - 2), "''", "'")
    EndIf
    If $sFirst = '"' And $sLast = '"' Then
        Local $sBody = StringMid($s, 2, StringLen($s) - 2)
        $sBody = StringReplace($sBody, '\\', Chr(1))
        $sBody = StringReplace($sBody, '\"', '"')
        $sBody = StringReplace($sBody, '\n', @LF)
        $sBody = StringReplace($sBody, '\t', @TAB)
        $sBody = StringReplace($sBody, '\r', @CR)
        $sBody = StringReplace($sBody, Chr(1), '\')
        Return $sBody
    EndIf
    Return $s
EndFunc   ;==>_Yaml_Unquote

; 按顶层逗号切分流式内容（尊重引号与嵌套括号）
Func _Yaml_SplitFlow($sText)
    Local $aOut[0], $sCur = "", $iDepth = 0, $bInSingle = False, $bInDouble = False
    For $i = 1 To StringLen($sText)
        Local $c = StringMid($sText, $i, 1)
        If $c = "'" And Not $bInDouble Then
            $bInSingle = Not $bInSingle
        ElseIf $c = '"' And Not $bInSingle Then
            $bInDouble = Not $bInDouble
        ElseIf Not $bInSingle And Not $bInDouble Then
            If $c = "[" Or $c = "{" Then
                $iDepth += 1
            ElseIf $c = "]" Or $c = "}" Then
                $iDepth -= 1
            ElseIf $c = "," And $iDepth = 0 Then
                ReDim $aOut[UBound($aOut) + 1]
                $aOut[UBound($aOut) - 1] = StringStripWS($sCur, 3)
                $sCur = ""
                ContinueLoop
            EndIf
        EndIf
        $sCur &= $c
    Next
    ReDim $aOut[UBound($aOut) + 1]
    $aOut[UBound($aOut) - 1] = StringStripWS($sCur, 3)
    If $bInSingle Or $bInDouble Then
        $g_sYamlError = "流式内容里的引号没有闭合"
        Return SetError(1, 0, $aOut)
    EndIf
    Return $aOut
EndFunc   ;==>_Yaml_SplitFlow

; 去掉行内注释（引号外的 #，且 # 前是空白或行首）
Func _Yaml_StripComment($sLine)
    Local $bInSingle = False, $bInDouble = False
    For $i = 1 To StringLen($sLine)
        Local $c = StringMid($sLine, $i, 1)
        If $c = "'" And Not $bInDouble Then
            $bInSingle = Not $bInSingle
        ElseIf $c = '"' And Not $bInSingle Then
            $bInDouble = Not $bInDouble
        ElseIf $c = "#" And Not $bInSingle And Not $bInDouble Then
            If $i = 1 Then Return ""
            If StringMid($sLine, $i - 1, 1) = " " Or StringMid($sLine, $i - 1, 1) = @TAB Then
                Return StringLeft($sLine, $i - 1)
            EndIf
        EndIf
    Next
    Return $sLine
EndFunc   ;==>_Yaml_StripComment

; ------------------------------------------------------------------ 生成
Func _Yaml_PathDepth($sPath)
    Local $iDepth = 0
    For $i = 1 To StringLen($sPath)
        If StringMid($sPath, $i, 1) = "." Then $iDepth += 1
    Next
    Return $iDepth
EndFunc   ;==>_Yaml_PathDepth

Func _Yaml_PathKey($sPath)
    Local $iPos = StringInStr($sPath, ".", 0, -1)
    If $iPos = 0 Then Return $sPath
    Return StringTrimLeft($sPath, $iPos)
EndFunc   ;==>_Yaml_PathKey

Func _Yaml_Spaces($iCount)
    Local $s = ""
    For $i = 1 To $iCount
        $s &= " "
    Next
    Return $s
EndFunc   ;==>_Yaml_Spaces

; 需要引号的情形：空、首尾空格、含会改变解析结果的特殊字符、以 - 开头。
; 刻意不包含“长得像数字/布尔就加引号”：裸的 64 本来就该写回裸的 64（保持整数类型），
; 而原本带引号的 "64"/"true" 由 $bWasQuoted 标记保证仍是字符串。
Func _Yaml_NeedsQuote($sValue)
    If $sValue = "" Then Return True
    If StringStripWS($sValue, 3) <> $sValue Then Return True
    If StringRegExp($sValue, '[][:#{},&*!|>%@`]') Then Return True
    If StringInStr($sValue, "'") > 0 Then Return True
    If StringInStr($sValue, '"') > 0 Then Return True
    If StringInStr($sValue, @LF) > 0 Or StringInStr($sValue, @CR) > 0 Or StringInStr($sValue, @TAB) > 0 Then Return True
    If StringLeft($sValue, 1) = "-" Then Return True
    Return False
EndFunc   ;==>_Yaml_NeedsQuote

Func _Yaml_Quote($sValue, $bWasQuoted = 0)
    If $bWasQuoted Then
        Local $sEsc = StringReplace($sValue, '\', '\\')
        $sEsc = StringReplace($sEsc, '"', '\"')
        $sEsc = StringReplace($sEsc, @LF, '\n')
        $sEsc = StringReplace($sEsc, @CR, '\r')
        $sEsc = StringReplace($sEsc, @TAB, '\t')
        Return '"' & $sEsc & '"'
    EndIf
    If _Yaml_NeedsQuote($sValue) Then
        Local $sEsc = StringReplace($sValue, '\', '\\')
        $sEsc = StringReplace($sEsc, '"', '\"')
        $sEsc = StringReplace($sEsc, @LF, '\n')
        $sEsc = StringReplace($sEsc, @CR, '\r')
        $sEsc = StringReplace($sEsc, @TAB, '\t')
        Return '"' & $sEsc & '"'
    EndIf
    Return $sValue
EndFunc   ;==>_Yaml_Quote

; 生成规范 YAML 文本（块风格，2 空格缩进）
Func _Yaml_Dump()
    Local $sOut = ""
    For $i = 0 To UBound($g_aYamlPath) - 1
        Local $sPath = $g_aYamlPath[$i]
        Local $sKind = $g_aYamlKind[$i]
        Local $iDepth = _Yaml_PathDepth($sPath)
        Local $sKey = _Yaml_PathKey($sPath)
        Local $sIndent = _Yaml_Spaces($iDepth * 2)

        Switch $sKind
            Case "map"
                If _Yaml_HasChildren($sPath) Then
                    $sOut &= $sIndent & $sKey & ":" & @CRLF
                Else
                    $sOut &= $sIndent & $sKey & ": {}" & @CRLF
                EndIf
            Case "list"
                Local $aItems = _Yaml_GetList($sPath)
                If UBound($aItems) = 0 Then
                    $sOut &= $sIndent & $sKey & ": []" & @CRLF
                Else
                    $sOut &= $sIndent & $sKey & ":" & @CRLF
                    For $k = 0 To UBound($aItems) - 1
                        $sOut &= _Yaml_Spaces(($iDepth + 1) * 2) & "- " & _Yaml_Quote($aItems[$k]) & @CRLF
                    Next
                EndIf
            Case Else
                $sOut &= $sIndent & $sKey & ": " & _Yaml_Quote($g_aYamlVal[$i], $g_aYamlQuoted[$i]) & @CRLF
        EndSwitch
    Next
    Return $sOut
EndFunc   ;==>_Yaml_Dump

Func _Yaml_SaveFile($sFile)
    Local $sDir = _Yaml_ParentDir($sFile)
    If $sDir <> "" And Not FileExists($sDir) Then DirCreate($sDir)
    Local $hFile = FileOpen($sFile, $FO_OVERWRITE + $FO_CREATEPATH + $FO_UTF8)
    If $hFile = -1 Then Return _Yaml_Error("无法写入: " & $sFile)
    FileWrite($hFile, _Yaml_Dump())
    FileClose($hFile)
    Return True
EndFunc   ;==>_Yaml_SaveFile

Func _Yaml_ParentDir($sFile)
    Local $iPos = StringInStr($sFile, "\", 0, -1)
    If $iPos = 0 Then Return ""
    Return StringLeft($sFile, $iPos - 1)
EndFunc   ;==>_Yaml_ParentDir
