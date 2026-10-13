; MiniJson.au3 - 最小 JSON 解析器（读 state.json / control.json）
;
; 数据表示与 MiniYaml 一致：扁平路径 + 平行数组
;   $g_aJsonPath[i] = "tasks[0].status"
;   $g_aJsonKind[i] = "str" | "num" | "bool" | "null" | "obj" | "arr"
;   $g_aJsonVal[i]  = 值的文本形式（str 已反转义；bool 为 True/False；null 为空）
;
; 路径规则：对象成员用 .key，数组元素用 [下标]。
; 只做解析与取值；写文件用 _Json_Escape() 自行拼装（control.json 结构是固定的）。

#include-once
#include <FileConstants.au3>

Global $g_aJsonPath[0]
Global $g_aJsonKind[0]
Global $g_aJsonVal[0]
Global $g_sJsonError = ""
Global $g_sJsonSrc = ""
Global $g_iJsonPos = 1

; ------------------------------------------------------------------ 基础
Func _Json_Reset()
    Local $aE[0]
    $g_aJsonPath = $aE
    $g_aJsonKind = $aE
    $g_aJsonVal = $aE
    $g_sJsonError = ""
EndFunc   ;==>_Json_Reset

Func _Json_Error($sMessage)
    $g_sJsonError = $sMessage
    Return False
EndFunc   ;==>_Json_Error

Func _Json_Count()
    Return UBound($g_aJsonPath)
EndFunc   ;==>_Json_Count

Func _Json_Index($sPath)
    For $i = 0 To UBound($g_aJsonPath) - 1
        If $g_aJsonPath[$i] = $sPath Then Return $i
    Next
    Return -1
EndFunc   ;==>_Json_Index

Func _Json_Has($sPath)
    Return _Json_Index($sPath) >= 0
EndFunc   ;==>_Json_Has

Func _Json_Kind($sPath)
    Local $i = _Json_Index($sPath)
    If $i < 0 Then Return ""
    Return $g_aJsonKind[$i]
EndFunc   ;==>_Json_Kind

Func _Json_Add($sPath, $sKind, $sValue)
    If $sPath = "" Then Return -1
    Local $i = _Json_Index($sPath)
    If $i >= 0 Then
        $g_aJsonKind[$i] = $sKind
        $g_aJsonVal[$i] = $sValue
        Return $i
    EndIf
    Local $n = UBound($g_aJsonPath)
    ReDim $g_aJsonPath[$n + 1]
    ReDim $g_aJsonKind[$n + 1]
    ReDim $g_aJsonVal[$n + 1]
    $g_aJsonPath[$n] = $sPath
    $g_aJsonKind[$n] = $sKind
    $g_aJsonVal[$n] = $sValue
    Return $n
EndFunc   ;==>_Json_Add

; 取文本值；对象/数组返回默认值
Func _Json_Get($sPath, $sDefault = "")
    Local $i = _Json_Index($sPath)
    If $i < 0 Then Return $sDefault
    Switch $g_aJsonKind[$i]
        Case "obj", "arr"
            Return $sDefault
        Case "null"
            Return $sDefault
        Case Else
            Return $g_aJsonVal[$i]
    EndSwitch
EndFunc   ;==>_Json_Get

Func _Json_GetNum($sPath, $sDefault = 0)
    Local $i = _Json_Index($sPath)
    If $i < 0 Then Return $sDefault
    If $g_aJsonKind[$i] <> "num" Then
        Local $sText = $g_aJsonVal[$i]
        If Not StringRegExp($sText, '^-?\d+(\.\d+)?$') Then Return $sDefault
    EndIf
    Return Number($g_aJsonVal[$i])
EndFunc   ;==>_Json_GetNum

; 数组元素个数（按 path[i] 的下标最大值 +1）
Func _Json_ArrayCount($sPath)
    Local $iMax = -1
    For $i = 0 To UBound($g_aJsonPath) - 1
        Local $s = $g_aJsonPath[$i]
        If StringLeft($s, StringLen($sPath) + 1) = $sPath & "[" Then
            Local $sRest = StringTrimLeft($s, StringLen($sPath) + 1)
            Local $iEnd = StringInStr($sRest, "]")
            If $iEnd > 0 Then
                Local $iIdx = Int(StringLeft($sRest, $iEnd - 1))
                If $iIdx > $iMax Then $iMax = $iIdx
            EndIf
        EndIf
    Next
    Return $iMax + 1
EndFunc   ;==>_Json_ArrayCount

; 直接子节点的路径（只返回一层）
Func _Json_Children($sPrefix)
    Local $aOut[0]
    For $i = 0 To UBound($g_aJsonPath) - 1
        Local $s = $g_aJsonPath[$i]
        If $sPrefix <> "" And StringLeft($s, StringLen($sPrefix) + 1) <> $sPrefix & "." Then ContinueLoop
        Local $sRest = $s
        If $sPrefix <> "" Then $sRest = StringTrimLeft($s, StringLen($sPrefix) + 1)
        If StringInStr($sRest, ".") > 0 Then ContinueLoop
        If StringInStr($sRest, "[") > 0 Then ContinueLoop
        ReDim $aOut[UBound($aOut) + 1]
        $aOut[UBound($aOut) - 1] = $s
    Next
    Return $aOut
EndFunc   ;==>_Json_Children

; 便于界面展示：把前缀去掉，返回“键 = 值/类型”
Func _Json_ShortName($sPath, $sPrefix)
    Local $s = $sPath
    If $sPrefix <> "" And StringLeft($s, StringLen($sPrefix) + 1) = $sPrefix & "." Then
        $s = StringTrimLeft($s, StringLen($sPrefix) + 1)
    EndIf
    Return $s
EndFunc   ;==>_Json_ShortName

Func _Json_DisplayValue($sPath)
    Local $i = _Json_Index($sPath)
    If $i < 0 Then Return ""
    Switch $g_aJsonKind[$i]
        Case "obj"
            Return "{...}"
        Case "arr"
            Return "[...]"
        Case "null"
            Return "null"
        Case Else
            Return $g_aJsonVal[$i]
    EndSwitch
EndFunc   ;==>_Json_DisplayValue

; ------------------------------------------------------------------ 解析
Func _Json_ParseFile($sFile)
    If Not FileExists($sFile) Then Return _Json_Error("文件不存在: " & $sFile)
    Local $hFile = FileOpen($sFile, $FO_READ)
    If $hFile = -1 Then Return _Json_Error("无法打开: " & $sFile)
    Local $sText = FileRead($hFile)
    FileClose($hFile)
    Return _Json_ParseText($sText)
EndFunc   ;==>_Json_ParseFile

Func _Json_ParseText($sText)
    _Json_Reset()
    $g_sJsonSrc = $sText
    $g_iJsonPos = 1

    _Json_SkipWs()
    If $g_iJsonPos > StringLen($g_sJsonSrc) Then Return _Json_Error("内容是空的")

    Local $c = _Json_Peek()
    If $c = "{" Then
        If Not _Json_ParseObjectMembers("") Then Return False
    ElseIf $c = "[" Then
        If Not _Json_ParseArrayItems("") Then Return False
    Else
        Return _Json_Error("顶层必须是对象或数组")
    EndIf

    _Json_SkipWs()
    If $g_iJsonPos <= StringLen($g_sJsonSrc) Then
        Return _Json_Error("末尾有多余内容（位置 " & $g_iJsonPos & "）")
    EndIf
    Return True
EndFunc   ;==>_Json_ParseText

Func _Json_SkipWs()
    While $g_iJsonPos <= StringLen($g_sJsonSrc)
        Local $c = StringMid($g_sJsonSrc, $g_iJsonPos, 1)
        If $c = " " Or $c = @TAB Or $c = @CR Or $c = @LF Then
            $g_iJsonPos += 1
        Else
            ExitLoop
        EndIf
    WEnd
EndFunc   ;==>_Json_SkipWs

Func _Json_Peek()
    If $g_iJsonPos > StringLen($g_sJsonSrc) Then Return ""
    Return StringMid($g_sJsonSrc, $g_iJsonPos, 1)
EndFunc   ;==>_Json_Peek

Func _Json_Expect($sChar)
    If _Json_Peek() <> $sChar Then Return _Json_Error("期望 '" & $sChar & "'（位置 " & $g_iJsonPos & "）")
    $g_iJsonPos += 1
    Return True
EndFunc   ;==>_Json_Expect

Func _Json_ParseValue($sPath)
    _Json_SkipWs()
    Local $c = _Json_Peek()

    Switch $c
        Case "{"
            If $sPath <> "" Then _Json_Add($sPath, "obj", "")
            Return _Json_ParseObjectMembers($sPath)
        Case "["
            If $sPath <> "" Then _Json_Add($sPath, "arr", "")
            Return _Json_ParseArrayItems($sPath)
        Case '"'
            Local $sText = _Json_ParseStringRaw()
            If @error Then Return False
            If $sPath <> "" Then _Json_Add($sPath, "str", $sText)
            Return True
        Case "t"
            Return _Json_ParseLiteral("true", "bool", "True", $sPath)
        Case "f"
            Return _Json_ParseLiteral("false", "bool", "False", $sPath)
        Case "n"
            Return _Json_ParseLiteral("null", "null", "", $sPath)
        Case Else
            Local $sNum = _Json_ParseNumberRaw()
            If $sNum = "" Then Return _Json_Error("无法识别的值（位置 " & $g_iJsonPos & "）")
            If $sPath <> "" Then _Json_Add($sPath, "num", $sNum)
            Return True
    EndSwitch
EndFunc   ;==>_Json_ParseValue

Func _Json_ParseObjectMembers($sPath)
    If Not _Json_Expect("{") Then Return False
    _Json_SkipWs()
    If _Json_Peek() = "}" Then
        $g_iJsonPos += 1
        Return True
    EndIf

    While True
        _Json_SkipWs()
        If _Json_Peek() <> '"' Then Return _Json_Error("对象的键必须是字符串（位置 " & $g_iJsonPos & "）")
        Local $sKey = _Json_ParseStringRaw()
        If @error Then Return False
        _Json_SkipWs()
        If Not _Json_Expect(":") Then Return False

        Local $sChild = $sKey
        If $sPath <> "" Then $sChild = $sPath & "." & $sKey
        If Not _Json_ParseValue($sChild) Then Return False

        _Json_SkipWs()
        Local $c = _Json_Peek()
        If $c = "," Then
            $g_iJsonPos += 1
            ContinueLoop
        EndIf
        If $c = "}" Then
            $g_iJsonPos += 1
            Return True
        EndIf
        Return _Json_Error("对象中期望 , 或 }（位置 " & $g_iJsonPos & "）")
    WEnd
EndFunc   ;==>_Json_ParseObjectMembers

Func _Json_ParseArrayItems($sPath)
    If Not _Json_Expect("[") Then Return False
    _Json_SkipWs()
    If _Json_Peek() = "]" Then
        $g_iJsonPos += 1
        Return True
    EndIf

    Local $iIndex = 0
    While True
        Local $sChild = "[" & $iIndex & "]"
        If $sPath <> "" Then $sChild = $sPath & "[" & $iIndex & "]"
        If Not _Json_ParseValue($sChild) Then Return False
        $iIndex += 1

        _Json_SkipWs()
        Local $c = _Json_Peek()
        If $c = "," Then
            $g_iJsonPos += 1
            ContinueLoop
        EndIf
        If $c = "]" Then
            $g_iJsonPos += 1
            Return True
        EndIf
        Return _Json_Error("数组中期望 , 或 ]（位置 " & $g_iJsonPos & "）")
    WEnd
EndFunc   ;==>_Json_ParseArrayItems

Func _Json_ParseLiteral($sLiteral, $sKind, $sValue, $sPath)
    If StringMid($g_sJsonSrc, $g_iJsonPos, StringLen($sLiteral)) <> $sLiteral Then
        Return _Json_Error("期望 " & $sLiteral & "（位置 " & $g_iJsonPos & "）")
    EndIf
    $g_iJsonPos += StringLen($sLiteral)
    If $sPath <> "" Then _Json_Add($sPath, $sKind, $sValue)
    Return True
EndFunc   ;==>_Json_ParseLiteral

Func _Json_ParseNumberRaw()
    Local $sNum = ""
    While $g_iJsonPos <= StringLen($g_sJsonSrc)
        Local $c = StringMid($g_sJsonSrc, $g_iJsonPos, 1)
        If StringInStr("0123456789eE+-.", $c) > 0 Then
            $sNum &= $c
            $g_iJsonPos += 1
        Else
            ExitLoop
        EndIf
    WEnd
    Return $sNum
EndFunc   ;==>_Json_ParseNumberRaw

Func _Json_ParseStringRaw()
    If Not _Json_Expect('"') Then Return SetError(1, 0, "")
    Local $sOut = ""
    While $g_iJsonPos <= StringLen($g_sJsonSrc)
        Local $c = StringMid($g_sJsonSrc, $g_iJsonPos, 1)
        If $c = '"' Then
            $g_iJsonPos += 1
            Return $sOut
        EndIf
        If $c = "\" Then
            $g_iJsonPos += 1
            Local $e = StringMid($g_sJsonSrc, $g_iJsonPos, 1)
            Switch $e
                Case "n"
                    $sOut &= @LF
                Case "r"
                    $sOut &= @CR
                Case "t"
                    $sOut &= @TAB
                Case "b"
                    $sOut &= Chr(8)
                Case "f"
                    $sOut &= Chr(12)
                Case "/"
                    $sOut &= "/"
                Case "\"
                    $sOut &= "\"
                Case '"'
                    $sOut &= '"'
                Case "u"
                    Local $sHex = StringMid($g_sJsonSrc, $g_iJsonPos + 1, 4)
                    If StringLen($sHex) < 4 Or Not StringRegExp($sHex, '^[0-9A-Fa-f]{4}$') Then
                        _Json_Error("无效的 \u 转义（位置 " & $g_iJsonPos & "）")
                        Return SetError(1, 0, "")
                    EndIf
                    $sOut &= ChrW(Number("0x" & $sHex))
                    $g_iJsonPos += 4
                Case Else
                    $sOut &= $e
            EndSwitch
            $g_iJsonPos += 1
        Else
            $sOut &= $c
            $g_iJsonPos += 1
        EndIf
    WEnd
    _Json_Error("字符串没有闭合（位置 " & $g_iJsonPos & "）")
    Return SetError(1, 0, "")
EndFunc   ;==>_Json_ParseStringRaw

; ------------------------------------------------------------------ 写出辅助
Func _Json_Escape($sText)
    Local $s = StringReplace($sText, "\", "\\")
    $s = StringReplace($s, '"', '\"')
    $s = StringReplace($s, @CR, '\r')
    $s = StringReplace($s, @LF, '\n')
    $s = StringReplace($s, @TAB, '\t')
    Return $s
EndFunc   ;==>_Json_Escape

; JSON 用 UTF-8 无 BOM 写出（标准做法，别的程序读起来最省事）
Func _Json_WriteFile($sFile, $sText)
    Local $sDir = ""
    Local $iPos = StringInStr($sFile, "\", 0, -1)
    If $iPos > 0 Then $sDir = StringLeft($sFile, $iPos - 1)
    If $sDir <> "" And Not FileExists($sDir) Then DirCreate($sDir)

    Local $hFile = FileOpen($sFile, $FO_OVERWRITE + $FO_CREATEPATH + $FO_UTF8_NOBOM)
    If $hFile = -1 Then Return _Json_Error("无法写入: " & $sFile)
    FileWrite($hFile, $sText)
    FileClose($hFile)
    Return True
EndFunc   ;==>_Json_WriteFile
