; FileTools.au3 - 批量重命名的核心逻辑（与界面无关，可单独测试）
; 设计原则：先“生成计划”，再“执行计划”，执行前可以完整预览，绝不覆盖已有文件。

#include-once
#include <File.au3>
#include <FileConstants.au3>

; 重命名模式
Enum $RENAME_REPLACE = 0, $RENAME_PREFIX, $RENAME_SUFFIX, $RENAME_INDEX

; 计划里每一项的状态
Enum $RENAME_OK = 0, $RENAME_UNCHANGED, $RENAME_CONFLICT, $RENAME_INVALID

; 状态常量 -> 中文说明
Func _Rename_StatusText($iStatus)
    Switch $iStatus
        Case $RENAME_OK
            Return "待处理"
        Case $RENAME_UNCHANGED
            Return "无需修改"
        Case $RENAME_CONFLICT
            Return "冲突(目标已存在)"
        Case $RENAME_INVALID
            Return "非法名称"
    EndSwitch
    Return "未知"
EndFunc   ;==>_Rename_StatusText

; 去掉 Windows 文件名中不允许的字符
Func _Rename_Sanitize($sName)
    Return StringRegExpReplace($sName, '[\\/:*?"<>|]', '_')
EndFunc   ;==>_Rename_Sanitize

; 判断文件名是否合法（空、非法字符、结尾点号、保留设备名）
Func _Rename_IsValidName($sName)
    If $sName = "" Then Return False
    If StringRegExp($sName, '[\\/:*?"<>|]') Then Return False
    If StringRight($sName, 1) = "." Then Return False

    Local $sStem = $sName
    Local $iDot = StringInStr($sStem, ".")
    If $iDot > 0 Then $sStem = StringLeft($sStem, $iDot - 1)
    If StringRegExp($sStem, '(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') Then Return False
    Return True
EndFunc   ;==>_Rename_IsValidName

; 按模式计算新的“主文件名”（不含扩展名）。
; 返回 "" 表示按此模式无需改动。
Func _Rename_NewBaseName($sBaseName, $iMode, $sArg1, $sArg2, $iIndex, $iTotal)
    Local $sNew = ""

    Switch $iMode
        Case $RENAME_REPLACE
            If $sArg1 = "" Then Return ""
            $sNew = StringReplace($sBaseName, $sArg1, $sArg2)
        Case $RENAME_PREFIX
            If $sArg1 = "" Then Return ""
            $sNew = $sArg1 & $sBaseName
        Case $RENAME_SUFFIX
            If $sArg1 = "" Then Return ""
            $sNew = $sBaseName & $sArg1
        Case $RENAME_INDEX
            If $sArg1 = "" Then Return ""
            Local $iPad = 3
            If $iTotal >= 1000 Then $iPad = 4
            If $iPad = 4 Then
                $sNew = $sArg1 & "_" & StringFormat("%04d", $iIndex)
            Else
                $sNew = $sArg1 & "_" & StringFormat("%03d", $iIndex)
            EndIf
        Case Else
            Return ""
    EndSwitch

    If $sNew = $sBaseName Then Return ""
    Return _Rename_Sanitize($sNew)
EndFunc   ;==>_Rename_NewBaseName

; 扫描文件夹，生成重命名计划。
; 返回二维数组 [n][4]：0=源全路径 1=目标全路径 2=状态常量 3=状态文字
Func _Rename_BuildPlan($sFolder, $sFilter, $bRecursive, $iMode, $sArg1, $sArg2, $iStartIndex = 1)
    Local $aPlan[0][4]

    If $sFolder = "" Or Not FileExists($sFolder) Then Return SetError(1, 0, $aPlan)
    If $sFilter = "" Then $sFilter = "*.*"

    Local $iRecur = $FLTAR_NORECUR
    If $bRecursive Then $iRecur = $FLTAR_RECUR

    Local $aFiles = _FileListToArrayRec($sFolder, $sFilter, $FLTAR_FILES, $iRecur, $FLTAR_SORT, $FLTAR_FULLPATH)
    If @error Then Return SetError(2, @error, $aPlan)

    Local $iCount = $aFiles[0]
    Local $iIndex = $iStartIndex
    Local $iUsed = 0
    ReDim $aPlan[$iCount][4]

    For $i = 1 To $iCount
        Local $sSrc = $aFiles[$i]
        Local $sDir = StringLeft($sSrc, StringInStr($sSrc, "\", 0, -1))
        Local $sName = StringTrimLeft($sSrc, StringLen($sDir))

        ; 拆分主名与扩展名（只按最后一个点拆分，dotfile 保持不变）
        Local $sBase = $sName
        Local $sExt = ""
        Local $iDot = StringInStr($sName, ".", 0, -1)
        If $iDot > 1 Then
            $sBase = StringLeft($sName, $iDot - 1)
            $sExt = StringMid($sName, $iDot)
        EndIf

        Local $sNewBase = _Rename_NewBaseName($sBase, $iMode, $sArg1, $sArg2, $iIndex, $iCount)
        If $sNewBase <> "" Then $iIndex += 1

        Local $sDst = $sSrc
        Local $iStatus = $RENAME_UNCHANGED

        If $sNewBase <> "" Then
            Local $sNewName = $sNewBase & $sExt
            If $sNewName <> $sName Then
                $sDst = $sDir & $sNewName
                If Not _Rename_IsValidName($sNewName) Then
                    $iStatus = $RENAME_INVALID
                ElseIf FileExists($sDst) Then
                    $iStatus = $RENAME_CONFLICT
                Else
                    $iStatus = $RENAME_OK
                EndIf
            EndIf
        EndIf

        $aPlan[$iUsed][0] = $sSrc
        $aPlan[$iUsed][1] = $sDst
        $aPlan[$iUsed][2] = $iStatus
        $aPlan[$iUsed][3] = _Rename_StatusText($iStatus)
        $iUsed += 1
    Next

    If $iUsed = 0 Then Return SetError(0, 0, $aPlan)
    ReDim $aPlan[$iUsed][4]
    Return $aPlan
EndFunc   ;==>_Rename_BuildPlan

; 执行一次重命名。成功返回 1，失败返回 0 并设置 @error。
Func _Rename_ApplyOne($sSrc, $sDst)
    If Not FileExists($sSrc) Then Return SetError(1, 0, 0)
    If FileExists($sDst) Then Return SetError(2, 0, 0)
    If Not FileMove($sSrc, $sDst, 0) Then Return SetError(3, 0, 0)
    Return 1
EndFunc   ;==>_Rename_ApplyOne

; 统计计划中可执行（状态为待处理）的条目数
Func _Rename_CountActionable($aPlan)
    If UBound($aPlan, 1) = 0 Then Return 0
    Local $iCount = 0
    For $i = 0 To UBound($aPlan, 1) - 1
        If $aPlan[$i][2] = $RENAME_OK Then $iCount += 1
    Next
    Return $iCount
EndFunc   ;==>_Rename_CountActionable
