; DiskData.au3 - 磁盘参数与健康数据采集（与界面无关，可单独测试）
;
; 数据源分四层，逐层降级，任一层不可用都不影响其它层：
;   1) root\cimv2                       : 型号/容量/序列号/固件/接口/分区/卷（普通权限即可）
;   2) root\Microsoft\Windows\Storage   : SSD或HDD/总线/健康/温度/通电/磨损/各类错误计数（通常需管理员）
;   3) root\wmi                          : SMART 预测故障 + ATA SMART 属性表（通常需管理员）
;   4) \\.\PhysicalDriveN 原始访问探测   : 判断是否需要提权，并在报告中明确说明
;
; 关键设计：
;   * 不同 WMI 类的磁盘 ID 格式不一致（"0" / "Disk #0, Partition #1" / "...\_0"），
;     必须用 _Disk_MatchRow() 做多重匹配，否则数据会静默合并不上 —— 表现为“很多字段是空的”。
;   * 任何取不到的值都保留为空，并记录该数据源的状态与原因，绝不伪造。

#include-once
#include <Array.au3>
#include <FileConstants.au3>
#include <WinAPI.au3>

; ---------------------------------------------------------------- 物理磁盘列
Enum $D_ID = 0, $D_MODEL, $D_MEDIA, $D_SIZE, $D_BUS, $D_HEALTH, $D_OPSTATUS, $D_VERDICT, _
        $D_TEMP, $D_TEMPMAX, $D_POWERON, $D_WEAR, _
        $D_READERR, $D_WRITEERR, $D_READTOTAL, $D_WRITETOTAL, $D_READCORR, $D_WRITECORR, _
        $D_STARTSTOP, $D_STARTSTOPMAX, $D_LOADUNLOAD, $D_LOADUNLOADMAX, _
        $D_READLAT, $D_WRITELAT, $D_FLUSHLAT, $D_MANUDATE, $D_SPEED, $D_USAGE, $D_LOCATION, _
        $D_SERIAL, $D_FIRMWARE, $D_PARTSTYLE, $D_PARTITIONS, $D_SECTORSIZE, _
        $D_SMART, $D_RAWDISK, $D_PNPID, $D_CAPS, $D_COLS

; -------------------------------------------------------------------- 分区列
Enum $P_DISK = 0, $P_INDEX, $P_TYPE, $P_SIZE, $P_OFFSET, $P_BOOTABLE, $P_PRIMARY, $P_NAME, $P_COLS

; ---------------------------------------------------------------------- 卷列
Enum $V_LETTER = 0, $V_LABEL, $V_FS, $V_SIZE, $V_FREE, $V_USEDPCT, $V_TYPE, $V_SIZEB, $V_FREEB, _
        $V_HEALTH, $V_DISK, $V_SERIAL, $V_COLS

; ------------------------------------------------------------- SMART 属性列
Enum $SM_DISK = 0, $SM_ID, $SM_NAME, $SM_CUR, $SM_WORST, $SM_THRESH, $SM_RAW, $SM_STATE, $SM_COLS

; ------------------------------------------------------------------ 数据源列
Enum $S_NAME = 0, $S_STATE, $S_DETAIL, $S_COLS

Global $g_aDisks[0][$D_COLS]
Global $g_aParts[0][$P_COLS]
Global $g_aVols[0][$V_COLS]
Global $g_aSmart[0][$SM_COLS]
Global $g_aSources[0][$S_COLS]
Global $g_bRawAccess = False
Global $g_bAccessDenied = False
Global $g_sLastComError = ""

; COM 错误处理器：没有它，一次失败的 WMI 调用会直接终止脚本
Global $oMyError = ObjEvent("AutoIt.Error", "_ComErrHandler")

Func _ComErrHandler()
    $g_sLastComError = "0x" & Hex($oMyError.number, 8) & " " & $oMyError.description & " (第 " & $oMyError.scriptline & " 行)"
    If _Disk_IsAccessDenied($g_sLastComError) Then $g_bAccessDenied = True
    Return
EndFunc   ;==>_ComErrHandler

Func _Disk_IsAccessDenied($sText)
    If StringInStr($sText, "拒绝访问") Then Return True
    If StringInStr($sText, "Access is denied") Then Return True
    If StringInStr($sText, "Access denied") Then Return True
    If StringInStr($sText, "80070005") Then Return True
    If StringInStr($sText, "80041003") Then Return True
    Return False
EndFunc   ;==>_Disk_IsAccessDenied

Func _Disk_Max($iA, $iB)
    If $iA >= $iB Then Return $iA
    Return $iB
EndFunc   ;==>_Disk_Max

; ------------------------------------------------------------------ 取值辅助
Func _Disk_Str($vValue)
    If IsObj($vValue) Then Return ""
    If IsArray($vValue) Then
        Local $sJoin = ""
        For $i = 0 To UBound($vValue) - 1
            If $sJoin <> "" Then $sJoin &= ", "
            $sJoin &= _Disk_Str($vValue[$i])
        Next
        Return StringStripWS($sJoin, 3)
    EndIf
    Return StringStripWS(String($vValue), 3)
EndFunc   ;==>_Disk_Str

Func _Disk_Num($vValue)
    If IsObj($vValue) Then Return 0
    Local $sText = StringStripWS(String($vValue), 3)
    If $sText = "" Then Return 0
    If Not StringRegExp($sText, '^-?\d+(\.\d+)?$') Then Return 0
    Return Number($sText)
EndFunc   ;==>_Disk_Num

Func _Disk_EnumName($iValue, $aTable)
    If $iValue < 0 Or $iValue > UBound($aTable) - 1 Then Return "未知(" & $iValue & ")"
    If $aTable[$iValue] = "" Then Return "未知(" & $iValue & ")"
    Return $aTable[$iValue]
EndFunc   ;==>_Disk_EnumName

Func _Disk_MediaName($iValue)
    Local $aTable[6] = ["未指定", "未知", "未知", "机械硬盘 HDD", "固态硬盘 SSD", "存储级内存 SCM"]
    Return _Disk_EnumName($iValue, $aTable)
EndFunc   ;==>_Disk_MediaName

Func _Disk_BusName($iValue)
    Local $aTable[20] = ["未知", "SCSI", "ATAPI", "ATA", "1394", "SSA", "光纤通道", "USB", "RAID", _
            "iSCSI", "SAS", "SATA", "SD", "MMC", "虚拟", "文件虚拟", "存储空间", "NVMe", "SCM", "UFS"]
    Return _Disk_EnumName($iValue, $aTable)
EndFunc   ;==>_Disk_BusName

Func _Disk_HealthName($iValue)
    Switch $iValue
        Case 0
            Return "Healthy"
        Case 1
            Return "Warning"
        Case 2
            Return "Unhealthy"
        Case Else
            Return "Unknown"
    EndSwitch
EndFunc   ;==>_Disk_HealthName

Func _Disk_UsageName($iValue)
    Switch $iValue
        Case 1
            Return "保留"
        Case 2
            Return "系统"
        Case 3
            Return "本地存储"
        Case 4
            Return "远程"
        Case 5
            Return "临时"
        Case 6
            Return "数据"
        Case 7
            Return "启动/恢复"
        Case 8
            Return "页面文件"
        Case 9
            Return "休眠"
        Case 10
            Return "崩溃转储"
        Case Else
            Return "未知(" & $iValue & ")"
    EndSwitch
EndFunc   ;==>_Disk_UsageName

Func _Disk_OpStatusText($vValue)
    Local $sResult = ""
    If IsArray($vValue) Then
        For $i = 0 To UBound($vValue) - 1
            If $sResult <> "" Then $sResult &= ", "
            $sResult &= _Disk_OpStatusOne(_Disk_Num($vValue[$i]))
        Next
    Else
        $sResult = _Disk_OpStatusOne(_Disk_Num($vValue))
    EndIf
    Return $sResult
EndFunc   ;==>_Disk_OpStatusText

Func _Disk_OpStatusOne($iValue)
    Switch $iValue
        Case 0
            Return "Unknown"
        Case 2
            Return "OK"
        Case 3
            Return "Degraded"
        Case 4
            Return "Stressed"
        Case 5
            Return "Predictive Failure"
        Case 6
            Return "Error"
        Case 8
            Return "Starting"
        Case 9
            Return "Stopping"
        Case 10
            Return "Stopped"
        Case 11
            Return "In Service"
        Case 12
            Return "No Contact"
        Case 13
            Return "Lost Communication"
        Case 15
            Return "Dormant"
        Case 17
            Return "Completed"
        Case 18
            Return "Power Mode"
        Case Else
            Return "状态" & $iValue
    EndSwitch
EndFunc   ;==>_Disk_OpStatusOne

; ------------------------------------------------------------------ 显示格式
Func _Disk_FmtSize($iBytes)
    If $iBytes <= 0 Then Return "—"
    Local $aUnits[5] = ["B", "KB", "MB", "GB", "TB"]
    Local $fValue = $iBytes
    Local $iUnit = 0
    While $fValue >= 1024 And $iUnit < 4
        $fValue = $fValue / 1024
        $iUnit += 1
    Wend
    If $iUnit = 0 Then Return Int($fValue) & " B"

    Local $sText = ""
    If $fValue < 10 Then
        $sText = StringFormat("%.1f", $fValue)
        If StringRight($sText, 2) = ".0" Then $sText = StringLeft($sText, StringLen($sText) - 2)
    Else
        $sText = StringFormat("%.0f", $fValue)
    EndIf
    Return $sText & " " & $aUnits[$iUnit]
EndFunc   ;==>_Disk_FmtSize

Func _Disk_FmtHours($iHours)
    If $iHours <= 0 Then Return "—"
    Local $iDays = Int($iHours / 24)
    If $iDays < 1 Then Return $iHours & " 小时"
    Return $iHours & " 小时 / " & $iDays & " 天"
EndFunc   ;==>_Disk_FmtHours

Func _Disk_FmtNum($vValue, $sSuffix = "")
    Local $iValue = _Disk_Num($vValue)
    If $iValue <= 0 Then Return "—"
    If $sSuffix = "" Then Return String(Int($iValue))
    Return Int($iValue) & " " & $sSuffix
EndFunc   ;==>_Disk_FmtNum

Func _Disk_FmtText($sValue)
    If StringStripWS($sValue, 3) = "" Then Return "—"
    Return $sValue
EndFunc   ;==>_Disk_FmtText

Func _Disk_SpeedText($sSpeed)
    Local $iSpeed = _Disk_Num($sSpeed)
    If $iSpeed <= 0 Then Return "—"
    If $iSpeed >= 10000 Then Return StringFormat("%.1f 万转/分", $iSpeed / 1000)
    Return $iSpeed & " 转/分"
EndFunc   ;==>_Disk_SpeedText

; ------------------------------------------------------------------ 匹配辅助
Func _Disk_FindByDeviceId($sDeviceId)
    For $i = 0 To UBound($g_aDisks, 1) - 1
        If $g_aDisks[$i][$D_ID] = $sDeviceId Then Return $i
    Next
    Return -1
EndFunc   ;==>_Disk_FindByDeviceId

Func _Disk_MatchRow($sIdentifier, $iOrdinal = -1)
    If $iOrdinal >= 0 And $iOrdinal < UBound($g_aDisks, 1) Then
        If $g_aDisks[$iOrdinal][$D_ID] = $sIdentifier Then Return $iOrdinal
    EndIf

    ; 1) 标识完全相同
    Local $iRow = _Disk_FindByDeviceId($sIdentifier)
    If $iRow >= 0 Then Return $iRow

    ; 2) 取标识里的数字逐个尝试（"...\4&2b3c4d5e&0&000000_1" 里最后一个数字才是磁盘号）
    Local $aNums = StringRegExp($sIdentifier, '(\d+)', 3)
    If Not @error And UBound($aNums) > 0 Then
        For $i = UBound($aNums) - 1 To 0 Step -1
            $iRow = _Disk_FindByDeviceId(String(Int($aNums[$i])))
            If $iRow >= 0 Then Return $iRow
        Next
    EndIf

    ; 3) 退化为按出现顺序
    If $iOrdinal >= 0 And $iOrdinal < UBound($g_aDisks, 1) Then Return $iOrdinal
    Return -1
EndFunc   ;==>_Disk_MatchRow

Func _Disk_AppendDisk($sDeviceId)
    Local $iRow = UBound($g_aDisks, 1)
    ReDim $g_aDisks[$iRow + 1][$D_COLS]
    If $sDeviceId = "" Then
        $g_aDisks[$iRow][$D_ID] = String($iRow)
    Else
        $g_aDisks[$iRow][$D_ID] = $sDeviceId
    EndIf
    $g_aDisks[$iRow][$D_VERDICT] = "正常"
    Return $iRow
EndFunc   ;==>_Disk_AppendDisk

; ------------------------------------------------------------------ 健康结论
Func _Disk_Verdict($aDisks, $iRow)
    Local $iLevel = 0
    Local $sHealth = $aDisks[$iRow][$D_HEALTH]

    If $aDisks[$iRow][$D_SMART] = "预测故障" Then Return "严重"
    If StringInStr($sHealth, "Unhealthy") Then Return "严重"
    If StringInStr($sHealth, "Warning") Then $iLevel = _Disk_Max($iLevel, 1)

    Local $sOp = $aDisks[$iRow][$D_OPSTATUS]
    If StringInStr($sOp, "Predictive Failure") Or StringInStr($sOp, "Error") Then Return "严重"
    If StringInStr($sOp, "Degraded") Or StringInStr($sOp, "Stressed") Then $iLevel = _Disk_Max($iLevel, 1)

    Local $iTemp = _Disk_Num($aDisks[$iRow][$D_TEMP])
    If $iTemp >= 70 Then
        $iLevel = _Disk_Max($iLevel, 2)
    ElseIf $iTemp >= 60 Then
        $iLevel = _Disk_Max($iLevel, 1)
    EndIf

    Local $iWear = _Disk_Num($aDisks[$iRow][$D_WEAR])
    If $iWear >= 90 Then
        $iLevel = _Disk_Max($iLevel, 2)
    ElseIf $iWear >= 80 Then
        $iLevel = _Disk_Max($iLevel, 1)
    EndIf

    If _Disk_Num($aDisks[$iRow][$D_READERR]) > 0 Or _Disk_Num($aDisks[$iRow][$D_WRITEERR]) > 0 Then $iLevel = _Disk_Max($iLevel, 2)
    If _Disk_Num($aDisks[$iRow][$D_POWERON]) >= 40000 Then $iLevel = _Disk_Max($iLevel, 1)

    ; SMART 属性表的结论优先级最高（阈值被突破 = 警告）
    For $r = 0 To UBound($g_aSmart, 1) - 1
        If $g_aSmart[$r][$SM_DISK] = $iRow Then
            If $g_aSmart[$r][$SM_STATE] = "警告" Then Return "警告"
            If $g_aSmart[$r][$SM_STATE] = "注意" Then $iLevel = _Disk_Max($iLevel, 1)
        EndIf
    Next

    Switch $iLevel
        Case 0
            Return "正常"
        Case 1
            Return "注意"
        Case Else
            Return "警告"
    EndSwitch
EndFunc   ;==>_Disk_Verdict

; ------------------------------------------------------------------ 采集主流程
Func _Disk_AddSource($sName, $bOk, $sDetail, $sStateOverride = "")
    Local $iRow = UBound($g_aSources, 1)
    ReDim $g_aSources[$iRow + 1][$S_COLS]
    $g_aSources[$iRow][$S_NAME] = $sName
    If $sStateOverride <> "" Then
        $g_aSources[$iRow][$S_STATE] = $sStateOverride
    ElseIf $bOk Then
        $g_aSources[$iRow][$S_STATE] = "可用"
    Else
        $g_aSources[$iRow][$S_STATE] = "不可用"
    EndIf
    $g_aSources[$iRow][$S_DETAIL] = $sDetail
EndFunc   ;==>_Disk_AddSource

Func _Disk_CollectAll()
    Local $aE1[0][$D_COLS], $aE2[0][$P_COLS], $aE3[0][$V_COLS], $aE4[0][$SM_COLS], $aE5[0][$S_COLS]
    $g_aDisks = $aE1
    $g_aParts = $aE2
    $g_aVols = $aE3
    $g_aSmart = $aE4
    $g_aSources = $aE5
    $g_bRawAccess = False
    $g_bAccessDenied = False

    _Disk_CollectCimV2()
    _Disk_CollectStorage()
    _Disk_CollectSmart()
    _Disk_ProbeRawAccess()

    For $i = 0 To UBound($g_aDisks, 1) - 1
        $g_aDisks[$i][$D_VERDICT] = _Disk_Verdict($g_aDisks, $i)
    Next

    Return UBound($g_aDisks, 1)
EndFunc   ;==>_Disk_CollectAll

; --- 第一层：cimv2（普通权限）----------------------------------------------
Func _Disk_CollectCimV2()
    Local $oWmi = ObjGet("winmgmts:\\.\root\cimv2")
    If Not IsObj($oWmi) Then
        _Disk_AddSource("WMI root\cimv2", False, "连接失败 " & $g_sLastComError)
        Return
    EndIf

    ; ---- 物理磁盘 ----
    $g_sLastComError = ""
    Local $oDrives = $oWmi.ExecQuery("SELECT * FROM Win32_DiskDrive")
    If Not IsObj($oDrives) Then
        _Disk_AddSource("Win32_DiskDrive", False, $g_sLastComError)
    ElseIf $oDrives.Count = 0 Then
        _Disk_AddSource("Win32_DiskDrive", False, "查询成功但没有返回任何磁盘")
    Else
        Local $iCount = $oDrives.Count
        ReDim $g_aDisks[$iCount][$D_COLS]
        Local $i = 0
        For $oDrive In $oDrives
            $g_aDisks[$i][$D_ID] = _Disk_Str($oDrive.Index)
            $g_aDisks[$i][$D_MODEL] = _Disk_Str($oDrive.Model)
            $g_aDisks[$i][$D_SIZE] = _Disk_Num($oDrive.Size)
            $g_aDisks[$i][$D_SERIAL] = _Disk_Str($oDrive.SerialNumber)
            $g_aDisks[$i][$D_FIRMWARE] = _Disk_Str($oDrive.FirmwareRevision)
            $g_aDisks[$i][$D_PARTITIONS] = _Disk_Str($oDrive.Partitions)
            $g_aDisks[$i][$D_PNPID] = _Disk_Str($oDrive.PNPDeviceID)
            $g_aDisks[$i][$D_SECTORSIZE] = _Disk_Str($oDrive.BytesPerSector)
            $g_aDisks[$i][$D_CAPS] = _Disk_Str($oDrive.CapabilityDescriptions)
            $g_aDisks[$i][$D_BUS] = _Disk_Str($oDrive.InterfaceType)
            $g_aDisks[$i][$D_MEDIA] = _Disk_Str($oDrive.MediaType)
            $g_aDisks[$i][$D_VERDICT] = "正常"

            Local $sStatus = _Disk_Str($oDrive.Status)
            If $sStatus = "" Then $sStatus = "Unknown"
            $g_aDisks[$i][$D_HEALTH] = $sStatus
            If $sStatus = "Pred Fail" Then $g_aDisks[$i][$D_SMART] = "预测故障"

            $i += 1
        Next
        _Disk_AddSource("Win32_DiskDrive", True, $iCount & " 块物理磁盘（型号/容量/序列号/固件/接口）")
    EndIf

    ; ---- 分区 ----
    $g_sLastComError = ""
    Local $oParts = $oWmi.ExecQuery("SELECT * FROM Win32_DiskPartition")
    If Not IsObj($oParts) Then
        _Disk_AddSource("Win32_DiskPartition", False, $g_sLastComError)
    ElseIf $oParts.Count = 0 Then
        _Disk_AddSource("Win32_DiskPartition", False, "没有返回分区")
    Else
        Local $iParts = 0
        ReDim $g_aParts[$oParts.Count][$P_COLS]
        Local $aStyles[UBound($g_aDisks, 1)]
        For $oPart In $oParts
            Local $iDisk = _Disk_MatchRow(_Disk_Str($oPart.DiskIndex))
            $g_aParts[$iParts][$P_DISK] = $iDisk
            $g_aParts[$iParts][$P_INDEX] = _Disk_Str($oPart.Index)
            $g_aParts[$iParts][$P_TYPE] = _Disk_Str($oPart.Type)
            $g_aParts[$iParts][$P_SIZE] = _Disk_Num($oPart.Size)
            $g_aParts[$iParts][$P_OFFSET] = _Disk_Num($oPart.StartingOffset)
            $g_aParts[$iParts][$P_PRIMARY] = _Disk_Str($oPart.PrimaryPartition)
            If String($oPart.Bootable) = "True" Then
                $g_aParts[$iParts][$P_BOOTABLE] = "是"
            Else
                $g_aParts[$iParts][$P_BOOTABLE] = "否"
            EndIf
            $g_aParts[$iParts][$P_NAME] = _Disk_Str($oPart.Name)

            ; 由分区类型推断分区样式（MSFT_Disk 不可用时的兜底）
            If $iDisk >= 0 Then
                Local $sType = _Disk_Str($oPart.Type)
                If StringInStr($sType, "GPT") Then
                    $aStyles[$iDisk] = "GPT"
                ElseIf $aStyles[$iDisk] <> "GPT" And $sType <> "" Then
                    $aStyles[$iDisk] = "MBR"
                EndIf
            EndIf
            $iParts += 1
        Next
        If $iParts < UBound($g_aParts, 1) Then ReDim $g_aParts[$iParts][$P_COLS]
        For $i = 0 To UBound($g_aDisks, 1) - 1
            If $aStyles[$i] <> "" Then $g_aDisks[$i][$D_PARTSTYLE] = $aStyles[$i]
        Next
        _Disk_AddSource("Win32_DiskPartition", True, $iParts & " 个分区（类型/大小/偏移/是否启动）")
    EndIf

    ; ---- 卷 ----
    $g_sLastComError = ""
    Local $oVols = $oWmi.ExecQuery("SELECT * FROM Win32_LogicalDisk WHERE DriveType=2 OR DriveType=3 OR DriveType=4 OR DriveType=5")
    If Not IsObj($oVols) Then
        _Disk_AddSource("Win32_LogicalDisk", False, $g_sLastComError)
    ElseIf $oVols.Count = 0 Then
        _Disk_AddSource("Win32_LogicalDisk", False, "没有返回卷")
    Else
        Local $iVols = 0
        ReDim $g_aVols[$oVols.Count][$V_COLS]
        For $oVol In $oVols
            Local $iSize = _Disk_Num($oVol.Size)
            Local $iFree = _Disk_Num($oVol.FreeSpace)
            $g_aVols[$iVols][$V_LETTER] = _Disk_Str($oVol.DeviceID)
            $g_aVols[$iVols][$V_LABEL] = _Disk_Str($oVol.VolumeName)
            $g_aVols[$iVols][$V_FS] = _Disk_Str($oVol.FileSystem)
            $g_aVols[$iVols][$V_SIZE] = _Disk_FmtSize($iSize)
            $g_aVols[$iVols][$V_FREE] = _Disk_FmtSize($iFree)
            If $iSize > 0 Then
                $g_aVols[$iVols][$V_USEDPCT] = StringFormat("%.1f%%", (1 - $iFree / $iSize) * 100)
            Else
                $g_aVols[$iVols][$V_USEDPCT] = "—"
            EndIf
            $g_aVols[$iVols][$V_TYPE] = _Disk_VolumeTypeName(_Disk_Num($oVol.DriveType))
            $g_aVols[$iVols][$V_SIZEB] = $iSize
            $g_aVols[$iVols][$V_FREEB] = $iFree
            $g_aVols[$iVols][$V_SERIAL] = _Disk_Str($oVol.VolumeSerialNumber)
            $iVols += 1
        Next
        If $iVols < UBound($g_aVols, 1) Then ReDim $g_aVols[$iVols][$V_COLS]
        _Disk_AddSource("Win32_LogicalDisk", True, $iVols & " 个卷")
    EndIf

    ; ---- 卷 -> 物理磁盘 映射 ----
    _Disk_MapVolumesToDisks($oWmi)
EndFunc   ;==>_Disk_CollectCimV2

Func _Disk_MapVolumesToDisks($oWmi)
    $g_sLastComError = ""
    Local $oAssoc = $oWmi.ExecQuery("SELECT * FROM Win32_LogicalDiskToPartition")
    If Not IsObj($oAssoc) Then
        _Disk_AddSource("卷与磁盘的对应关系", False, $g_sLastComError)
        Return
    EndIf

    Local $iMapped = 0
    For $oLink In $oAssoc
        Local $sPart = _Disk_Str($oLink.Antecedent)
        Local $sVol = _Disk_Str($oLink.Dependent)
        Local $aDiskNums = StringRegExp($sPart, 'Disk #(\d+)', 3)
        Local $aVolNames = StringRegExp($sVol, '="([A-Za-z]:)"', 3)
        If Not @error And UBound($aDiskNums) > 0 And UBound($aVolNames) > 0 Then
            For $i = 0 To UBound($g_aVols, 1) - 1
                If $g_aVols[$i][$V_LETTER] = $aVolNames[0] Then
                    $g_aVols[$i][$V_DISK] = "磁盘 " & $aDiskNums[0]
                    $iMapped += 1
                EndIf
            Next
        EndIf
    Next
    _Disk_AddSource("卷与磁盘的对应关系", $iMapped > 0, $iMapped & " 个卷已对应到物理磁盘")
EndFunc   ;==>_Disk_MapVolumesToDisks

Func _Disk_VolumeTypeName($iDriveType)
    Switch $iDriveType
        Case 2
            Return "可移动磁盘"
        Case 3
            Return "本地磁盘"
        Case 4
            Return "网络驱动器"
        Case 5
            Return "光驱"
        Case Else
            Return "类型" & $iDriveType
    EndSwitch
EndFunc   ;==>_Disk_VolumeTypeName

; --- 第二层：Storage 命名空间（健康/温度/磨损，通常需管理员）-----------------
Func _Disk_CollectStorage()
    Local $oStore = ObjGet("winmgmts:\\.\root\Microsoft\Windows\Storage")
    If Not IsObj($oStore) Then
        _Disk_AddSource("Storage 命名空间", False, "连接失败 " & $g_sLastComError & "（SSD/HDD 判定、健康、温度、磨损都在这里，需要管理员）")
        Return
    EndIf

    ; ---- 物理磁盘：介质类型 / 总线 / 健康 / 转速 / 用途 ----
    $g_sLastComError = ""
    Local $oDisks = $oStore.ExecQuery("SELECT * FROM MSFT_PhysicalDisk")
    If Not IsObj($oDisks) Then
        _Disk_AddSource("MSFT_PhysicalDisk", False, $g_sLastComError)
    ElseIf $oDisks.Count = 0 Then
        _Disk_AddSource("MSFT_PhysicalDisk", False, "查询成功但没有返回数据")
    Else
        Local $iOrdinal = 0
        Local $iMatched = 0
        For $oDisk In $oDisks
            Local $sId = _Disk_Str($oDisk.DeviceId)
            Local $iIdx = _Disk_MatchRow($sId, $iOrdinal)
            If $iIdx < 0 Then $iIdx = _Disk_AppendDisk($sId)

            If $g_aDisks[$iIdx][$D_MODEL] = "" Then $g_aDisks[$iIdx][$D_MODEL] = _Disk_Str($oDisk.FriendlyName)
            If _Disk_Num($g_aDisks[$iIdx][$D_SIZE]) <= 0 Then $g_aDisks[$iIdx][$D_SIZE] = _Disk_Num($oDisk.Size)
            If $g_aDisks[$iIdx][$D_SERIAL] = "" Then $g_aDisks[$iIdx][$D_SERIAL] = _Disk_Str($oDisk.SerialNumber)
            If $g_aDisks[$iIdx][$D_FIRMWARE] = "" Then $g_aDisks[$iIdx][$D_FIRMWARE] = _Disk_Str($oDisk.FirmwareVersion)

            $g_aDisks[$iIdx][$D_MEDIA] = _Disk_MediaName(_Disk_Num($oDisk.MediaType))
            $g_aDisks[$iIdx][$D_BUS] = _Disk_BusName(_Disk_Num($oDisk.BusType))
            $g_aDisks[$iIdx][$D_HEALTH] = _Disk_HealthName(_Disk_Num($oDisk.HealthStatus))
            $g_aDisks[$iIdx][$D_OPSTATUS] = _Disk_OpStatusText($oDisk.OperationalStatus)
            $g_aDisks[$iIdx][$D_SPEED] = _Disk_Str($oDisk.SpindleSpeed)
            $g_aDisks[$iIdx][$D_USAGE] = _Disk_UsageName(_Disk_Num($oDisk.Usage))
            $g_aDisks[$iIdx][$D_LOCATION] = _Disk_Str($oDisk.PhysicalLocation)

            $iOrdinal += 1
            $iMatched += 1
        Next
        _Disk_AddSource("MSFT_PhysicalDisk", True, $iMatched & " 块磁盘（介质/总线/健康/转速/用途）")
    EndIf

    ; ---- 可靠性计数器：温度、通电时间、磨损、各类错误 ----
    $g_sLastComError = ""
    Local $oCounters = $oStore.ExecQuery("SELECT * FROM MSFT_StorageReliabilityCounter")
    If Not IsObj($oCounters) Then
        _Disk_AddSource("MSFT_StorageReliabilityCounter", False, $g_sLastComError & "（温度/通电时间/磨损/错误计数）")
    ElseIf $oCounters.Count = 0 Then
        _Disk_AddSource("MSFT_StorageReliabilityCounter", False, "驱动/硬盘未提供可靠性计数器（部分 RAID 或老驱动会这样）")
    Else
        Local $iOrdinal = 0
        Local $iFilled = 0
        For $oCounter In $oCounters
            Local $iIdx = _Disk_MatchRow(_Disk_Str($oCounter.DeviceId), $iOrdinal)
            If $iIdx >= 0 Then
                $g_aDisks[$iIdx][$D_TEMP] = _Disk_Str($oCounter.Temperature)
                $g_aDisks[$iIdx][$D_TEMPMAX] = _Disk_Str($oCounter.TemperatureMax)
                $g_aDisks[$iIdx][$D_POWERON] = _Disk_Str($oCounter.PowerOnHours)
                $g_aDisks[$iIdx][$D_WEAR] = _Disk_Str($oCounter.Wear)
                $g_aDisks[$iIdx][$D_READERR] = _Disk_Str($oCounter.ReadErrorsUncorrected)
                $g_aDisks[$iIdx][$D_WRITEERR] = _Disk_Str($oCounter.WriteErrorsUncorrected)
                $g_aDisks[$iIdx][$D_READTOTAL] = _Disk_Str($oCounter.ReadErrorsTotal)
                $g_aDisks[$iIdx][$D_WRITETOTAL] = _Disk_Str($oCounter.WriteErrorsTotal)
                $g_aDisks[$iIdx][$D_READCORR] = _Disk_Str($oCounter.ReadErrorsCorrected)
                $g_aDisks[$iIdx][$D_WRITECORR] = _Disk_Str($oCounter.WriteErrorsCorrected)
                $g_aDisks[$iIdx][$D_STARTSTOP] = _Disk_Str($oCounter.StartStopCycleCount)
                $g_aDisks[$iIdx][$D_STARTSTOPMAX] = _Disk_Str($oCounter.StartStopCycleCountMax)
                $g_aDisks[$iIdx][$D_LOADUNLOAD] = _Disk_Str($oCounter.LoadUnloadCycleCount)
                $g_aDisks[$iIdx][$D_LOADUNLOADMAX] = _Disk_Str($oCounter.LoadUnloadCycleCountMax)
                $g_aDisks[$iIdx][$D_READLAT] = _Disk_Str($oCounter.ReadLatencyMax)
                $g_aDisks[$iIdx][$D_WRITELAT] = _Disk_Str($oCounter.WriteLatencyMax)
                $g_aDisks[$iIdx][$D_FLUSHLAT] = _Disk_Str($oCounter.FlushLatencyMax)
                $g_aDisks[$iIdx][$D_MANUDATE] = _Disk_Str($oCounter.ManufactureDate)
                $iFilled += 1
            EndIf
            $iOrdinal += 1
        Next
        If $iFilled > 0 Then
            _Disk_AddSource("MSFT_StorageReliabilityCounter", True, $iFilled & " 块磁盘的温度/通电时间/磨损/错误计数")
        Else
            _Disk_AddSource("MSFT_StorageReliabilityCounter", False, "取到数据但无法与磁盘对应（ID 格式不匹配）")
        EndIf
    EndIf

    ; ---- MSFT_Disk：分区样式 ----
    $g_sLastComError = ""
    Local $oMsDisks = $oStore.ExecQuery("SELECT * FROM MSFT_Disk")
    If IsObj($oMsDisks) Then
        Local $iOrdinal = 0
        Local $iStyled = 0
        For $oMsDisk In $oMsDisks
            Local $iIdx = _Disk_MatchRow(_Disk_Str($oMsDisk.Number), $iOrdinal)
            If $iIdx >= 0 Then
                Switch _Disk_Num($oMsDisk.PartitionStyle)
                    Case 1
                        $g_aDisks[$iIdx][$D_PARTSTYLE] = "MBR"
                    Case 2
                        $g_aDisks[$iIdx][$D_PARTSTYLE] = "GPT"
                EndSwitch
                $iStyled += 1
            EndIf
            $iOrdinal += 1
        Next
        _Disk_AddSource("MSFT_Disk", $iStyled > 0, "分区样式(GPT/MBR)：识别 " & $iStyled & " 块")
    Else
        _Disk_AddSource("MSFT_Disk", False, $g_sLastComError)
    EndIf

    ; ---- MSFT_Volume：卷健康状态 ----
    $g_sLastComError = ""
    Local $oMsVols = $oStore.ExecQuery("SELECT * FROM MSFT_Volume")
    If IsObj($oMsVols) Then
        Local $iFilled = 0
        For $oMsVol In $oMsVols
            Local $sLetter = _Disk_Str($oMsVol.DriveLetter)
            If $sLetter <> "" Then
                For $i = 0 To UBound($g_aVols, 1) - 1
                    If $g_aVols[$i][$V_LETTER] = $sLetter & ":" Then
                        $g_aVols[$i][$V_HEALTH] = _Disk_HealthName(_Disk_Num($oMsVol.HealthStatus))
                        $iFilled += 1
                    EndIf
                Next
            EndIf
        Next
        _Disk_AddSource("MSFT_Volume", $iFilled > 0, "卷健康状态：" & $iFilled & " 个")
    Else
        _Disk_AddSource("MSFT_Volume", False, $g_sLastComError)
    EndIf
EndFunc   ;==>_Disk_CollectStorage

; --- 第三层：SMART（root\wmi，通常需管理员）--------------------------------
Func _Disk_CollectSmart()
    $g_sLastComError = ""
    Local $oWmi = ObjGet("winmgmts:\\.\root\wmi")
    If Not IsObj($oWmi) Then
        _Disk_AddSource("root\wmi (SMART)", False, "连接失败 " & $g_sLastComError & "（需要管理员）")
        Return
    EndIf

    ; 预测故障状态
    $g_sLastComError = ""
    Local $oStatus = $oWmi.ExecQuery("SELECT * FROM MSStorageDriver_FailurePredictStatus")
    If Not IsObj($oStatus) Then
        _Disk_AddSource("SMART 预测故障", False, $g_sLastComError & "（需要管理员）")
    ElseIf $oStatus.Count = 0 Then
        _Disk_AddSource("SMART 预测故障", False, "该驱动/NVMe 未通过 WMI 暴露 SMART 预测状态")
    Else
        Local $iOrdinal = 0
        Local $iCount = 0
        For $oItem In $oStatus
            Local $iIdx = _Disk_MatchRow(_Disk_Str($oItem.InstanceName), $iOrdinal)
            If $iIdx >= 0 Then
                If String($oItem.PredictFailure) = "True" Then
                    $g_aDisks[$iIdx][$D_SMART] = "预测故障"
                Else
                    $g_aDisks[$iIdx][$D_SMART] = "正常"
                EndIf
                $iCount += 1
            EndIf
            $iOrdinal += 1
        Next
        _Disk_AddSource("SMART 预测故障", True, $iCount & " 块磁盘")
    EndIf

    ; ATA SMART 属性表（NVMe 不走这条路）
    $g_sLastComError = ""
    Local $oSmart = $oWmi.ExecQuery("SELECT * FROM MSStorageDriver_ATAPISmartData")
    If Not IsObj($oSmart) Then
        _Disk_AddSource("SMART 属性表", False, $g_sLastComError & "（ATA/SATA 才有；NVMe 请看可靠性计数器）")
        Return
    EndIf
    If $oSmart.Count = 0 Then
        _Disk_AddSource("SMART 属性表", False, "没有返回数据（NVMe 或 RAID 控制器下常见）")
        Return
    EndIf

    ; 阈值表：按 InstanceName 建索引
    $g_sLastComError = ""
    Local $oThresh = $oWmi.ExecQuery("SELECT * FROM MSStorageDriver_FailurePredictThresholds")
    Local $aThreshNames[0], $aThreshData[0]
    If IsObj($oThresh) Then
        For $oItem In $oThresh
            Local $aBytes[0]
            If _Disk_SmartToBytes($oItem.VendorSpecific, $aBytes) Then
                ReDim $aThreshNames[UBound($aThreshNames) + 1]
                ReDim $aThreshData[UBound($aThreshData) + 1]
                $aThreshNames[UBound($aThreshNames) - 1] = _Disk_Str($oItem.InstanceName)
                $aThreshData[UBound($aThreshData) - 1] = $aBytes
            EndIf
        Next
    EndIf

    Local $iOrdinal = 0
    Local $iParsed = 0
    For $oItem In $oSmart
        Local $sInstance = _Disk_Str($oItem.InstanceName)
        Local $iIdx = _Disk_MatchRow($sInstance, $iOrdinal)
        Local $aData[0]
        If $iIdx >= 0 And _Disk_SmartToBytes($oItem.VendorSpecific, $aData) Then
            Local $aThresholds[0]
            For $t = 0 To UBound($aThreshNames) - 1
                If $aThreshNames[$t] = $sInstance Then
                    $aThresholds = $aThreshData[$t]
                    ExitLoop
                EndIf
            Next
            $iParsed += _Disk_ParseSmartAttrs($iIdx, $aData, $aThresholds)
        EndIf
        $iOrdinal += 1
    Next

    If $iParsed > 0 Then
        _Disk_AddSource("SMART 属性表", True, $iParsed & " 条属性（ID/当前/最差/阈值/原始值）")
    Else
        _Disk_AddSource("SMART 属性表", False, "WMI 返回的数据无法解析为属性表（驱动只提供预测状态）")
    EndIf
EndFunc   ;==>_Disk_CollectSmart

; WMI 的字节数组通常直接映射为 AutoIt 数组；不是数组就放弃（不猜）
Func _Disk_SmartToBytes($vData, ByRef $aBytes)
    ReDim $aBytes[0]
    If Not IsArray($vData) Then Return False
    Local $iCount = UBound($vData)
    If $iCount < 362 Then Return False
    ReDim $aBytes[$iCount]
    For $i = 0 To $iCount - 1
        $aBytes[$i] = _Disk_Num($vData[$i])
    Next
    Return True
EndFunc   ;==>_Disk_SmartToBytes

; ATA SMART 数据布局：2 字节版本号 + 30 条 × 12 字节
; 每条：[0]=属性ID [1..2]=标志 [3]=当前值 [4]=最差值 [5..10]=原始值(6字节小端) [11]=保留
Func _Disk_ParseSmartAttrs($iDiskRow, $aData, $aThresholds)
    Local $iAdded = 0
    For $i = 0 To 29
        Local $iBase = 2 + $i * 12
        If $iBase + 11 > UBound($aData) - 1 Then ExitLoop
        Local $iId = $aData[$iBase]
        If $iId = 0 Then ContinueLoop

        Local $iValue = $aData[$iBase + 3]
        Local $iWorst = $aData[$iBase + 4]
        Local $iRaw = 0
        For $b = 5 To 10
            $iRaw += $aData[$iBase + $b] * (256 ^ ($b - 5))
        Next

        Local $iThresh = 0
        If UBound($aThresholds) > ($iBase + 1) Then $iThresh = $aThresholds[$iBase + 1]

        _Disk_SmartAdd($iDiskRow, $iId, $iValue, $iWorst, $iThresh, $iRaw)
        $iAdded += 1
    Next
    Return $iAdded
EndFunc   ;==>_Disk_ParseSmartAttrs

Func _Disk_SmartAdd($iDiskRow, $iId, $iCur, $iWorst, $iThresh, $iRaw)
    Local $iRow = UBound($g_aSmart, 1)
    ReDim $g_aSmart[$iRow + 1][$SM_COLS]
    $g_aSmart[$iRow][$SM_DISK] = $iDiskRow
    $g_aSmart[$iRow][$SM_ID] = $iId
    $g_aSmart[$iRow][$SM_NAME] = _Disk_SmartAttrName($iId)
    $g_aSmart[$iRow][$SM_CUR] = $iCur
    $g_aSmart[$iRow][$SM_WORST] = $iWorst
    $g_aSmart[$iRow][$SM_THRESH] = $iThresh
    $g_aSmart[$iRow][$SM_RAW] = $iRaw

    Local $sState = "正常"
    If $iThresh > 0 And $iCur <= $iThresh Then
        $sState = "警告"
    ElseIf _Disk_SmartIsCritical($iId) And $iRaw > 0 Then
        $sState = "注意"
    EndIf
    $g_aSmart[$iRow][$SM_STATE] = $sState
EndFunc   ;==>_Disk_SmartAdd

Func _Disk_SmartIsCritical($iId)
    Switch $iId
        Case 5, 10, 184, 187, 188, 196, 197, 198, 199
            Return True
    EndSwitch
    Return False
EndFunc   ;==>_Disk_SmartIsCritical

Func _Disk_SmartAttrName($iId)
    Switch $iId
        Case 1
            Return "底层读取错误率"
        Case 2
            Return "吞吐量性能"
        Case 3
            Return "主轴起转时间"
        Case 4
            Return "启动/停止计数"
        Case 5
            Return "重映射扇区计数"
        Case 7
            Return "寻道错误率"
        Case 8
            Return "寻道时间性能"
        Case 9
            Return "通电时间"
        Case 10
            Return "主轴重试计数"
        Case 11
            Return "校准重试计数"
        Case 12
            Return "通电周期计数"
        Case 13
            Return "读取软错误率"
        Case 22
            Return "氦气液位"
        Case 170
            Return "保留块计数"
        Case 171
            Return "程序失败计数"
        Case 172
            Return "擦除失败计数"
        Case 173
            Return "磨损均衡计数"
        Case 174
            Return "意外断电计数"
        Case 175
            Return "程序失败计数(总)"
        Case 176
            Return "擦除失败计数(总)"
        Case 177
            Return "磨损均衡计数"
        Case 178
            Return "已用保留块计数"
        Case 179
            Return "已用保留块总数"
        Case 180
            Return "未用保留块总数"
        Case 181
            Return "程序失败计数"
        Case 182
            Return "擦除失败计数"
        Case 183
            Return "运行时坏块"
        Case 184
            Return "端到端错误"
        Case 185
            Return "磁头稳定性"
        Case 187
            Return "报告的无法纠正错误"
        Case 188
            Return "命令超时"
        Case 190
            Return "气流温度"
        Case 191
            Return "冲击错误率"
        Case 192
            Return "断电回收计数"
        Case 193
            Return "磁头加载计数"
        Case 194
            Return "温度"
        Case 195
            Return "硬件 ECC 恢复"
        Case 196
            Return "重映射事件计数"
        Case 197
            Return "当前待映射扇区"
        Case 198
            Return "脱机无法纠正扇区"
        Case 199
            Return "UDMA CRC 错误计数"
        Case 200
            Return "多区域错误率"
        Case 201
            Return "软读取错误率"
        Case 202
            Return "数据地址标记错误"
        Case 220
            Return "磁盘位移"
        Case 222
            Return "加载时长"
        Case 223
            Return "加载重试计数"
        Case 224
            Return "加载摩擦"
        Case 225
            Return "加载计数"
        Case 226
            Return "加载时间"
        Case 227
            Return "扭矩放大计数"
        Case 228
            Return "断电回收计数"
        Case 230
            Return "磁头幅度"
        Case 231
            Return "SSD 剩余寿命"
        Case 232
            Return "可用备用空间"
        Case 233
            Return "介质磨损指示"
        Case 234
            Return "热传感器读数"
        Case 235
            Return "断电恢复计数"
        Case 240
            Return "磁头飞行时间"
        Case 241
            Return "主机写入总量(LBA)"
        Case 242
            Return "主机读取总量(LBA)"
        Case 249
            Return "NAND 写入总量"
    EndSwitch
    Return "属性 " & $iId
EndFunc   ;==>_Disk_SmartAttrName

; --- 第四层：原始磁盘访问探测 ----------------------------------------------
Func _Disk_ProbeRawAccess()
    Local $iCount = UBound($g_aDisks, 1)
    If $iCount = 0 Then
        _Disk_AddSource("原始磁盘访问", False, "没有磁盘可探测")
        Return
    EndIf

    Local $iOk = 0
    Local $sFirstError = ""
    For $i = 0 To $iCount - 1
        Local $sPath = "\\.\PhysicalDrive" & $g_aDisks[$i][$D_ID]
        Local $hFile = _WinAPI_CreateFile($sPath, 3, 0x80000000, 3)
        Local $iErr = @error
        If $hFile <> 0 Then
            _WinAPI_CloseHandle($hFile)
            $g_aDisks[$i][$D_RAWDISK] = "可读"
            $iOk += 1
        Else
            $g_aDisks[$i][$D_RAWDISK] = "受限"
            If $sFirstError = "" Then $sFirstError = "错误码 " & $iErr
        EndIf
    Next

    If $iOk > 0 Then
        $g_bRawAccess = True
        _Disk_AddSource("原始磁盘访问", True, $iOk & "/" & $iCount & " 块磁盘可直接读取")
    Else
        $g_bRawAccess = False
        $g_bAccessDenied = True
        _Disk_AddSource("原始磁盘访问", False, "全部受限（" & $sFirstError & "），以管理员身份运行可获得深度 SMART 数据")
    EndIf
EndFunc   ;==>_Disk_ProbeRawAccess

; ------------------------------------------------------------------ 文本报告
Func _RptAdd(ByRef $aLines, $sLine)
    Local $i = UBound($aLines)
    ReDim $aLines[$i + 1]
    $aLines[$i] = $sLine
EndFunc   ;==>_RptAdd

; 计算字符串的显示宽度：中文/全角算 2 格，其余算 1 格。
; 直接用 StringFormat 的 %-20s 对齐中文会错位，因为 C 的宽度按“字符数”而不是显示宽度算。
Func _Disk_Width($sText)
    Local $iWidth = 0
    For $i = 1 To StringLen($sText)
        Local $iCode = AscW(StringMid($sText, $i, 1))
        If $iCode < 0 Then $iCode += 65536
        If ($iCode >= 0x1100 And $iCode <= 0x115F) Or _
                ($iCode >= 0x2E80 And $iCode <= 0xA4CF) Or _
                ($iCode >= 0xAC00 And $iCode <= 0xD7A3) Or _
                ($iCode >= 0xF900 And $iCode <= 0xFAFF) Or _
                ($iCode >= 0xFE30 And $iCode <= 0xFE6F) Or _
                ($iCode >= 0xFF00 And $iCode <= 0xFF60) Or _
                ($iCode >= 0xFFE0 And $iCode <= 0xFFE6) Then
            $iWidth += 2
        Else
            $iWidth += 1
        EndIf
    Next
    Return $iWidth
EndFunc   ;==>_Disk_Width

; 按显示宽度右侧补空格
Func _Disk_PadR($sText, $iWidth)
    Local $iPad = $iWidth - _Disk_Width($sText)
    If $iPad <= 0 Then Return $sText
    Local $sSpaces = ""
    For $p = 1 To $iPad
        $sSpaces &= " "
    Next
    Return $sText & $sSpaces
EndFunc   ;==>_Disk_PadR

Func _Disk_BuildReport()
    Local $aLines[0]

    _RptAdd($aLines, "================================================================")
    _RptAdd($aLines, " 磁盘参数与健康报告")
    _RptAdd($aLines, " 采集时间 : " & @YEAR & "-" & @MON & "-" & @MDAY & " " & @HOUR & ":" & @MIN & ":" & @SEC)
    _RptAdd($aLines, " 计算机   : " & @ComputerName & "   用户: " & @UserName)
    _RptAdd($aLines, " 系统     : " & @OSVersion & " build " & @OSBuild & " " & @OSArch)
    If $g_bRawAccess Then
        _RptAdd($aLines, " 权限     : 原始磁盘访问可用（SMART 数据完整）")
    Else
        _RptAdd($aLines, " 权限     : 原始磁盘访问受限 —— 以管理员身份运行可获得完整 SMART 数据")
    EndIf
    _RptAdd($aLines, "================================================================")

    Local $iDisks = UBound($g_aDisks, 1)
    Local $iTotalBytes = 0
    _RptAdd($aLines, "")
    _RptAdd($aLines, "【总览】物理磁盘 " & $iDisks & " 块")
    For $i = 0 To $iDisks - 1
        $iTotalBytes += _Disk_Num($g_aDisks[$i][$D_SIZE])
        _RptAdd($aLines, "  " & _Disk_PadR($g_aDisks[$i][$D_ID], 4) & _Disk_PadR($g_aDisks[$i][$D_MODEL], 32) & _
                _Disk_PadR(_Disk_FmtSize($g_aDisks[$i][$D_SIZE]), 12) & _Disk_PadR($g_aDisks[$i][$D_MEDIA], 16) & _
                _Disk_PadR($g_aDisks[$i][$D_BUS], 12) & $g_aDisks[$i][$D_VERDICT])
    Next
    If $iDisks > 0 Then _RptAdd($aLines, "  合计容量：" & _Disk_FmtSize($iTotalBytes))

    For $i = 0 To $iDisks - 1
        _RptAdd($aLines, "")
        _RptAdd($aLines, "--------------------------------------------------------------")
        _RptAdd($aLines, " 磁盘 " & $g_aDisks[$i][$D_ID] & "  " & $g_aDisks[$i][$D_MODEL])
        _RptAdd($aLines, "--------------------------------------------------------------")
        _RptAdd($aLines, "  [基本参数]")
        _RptAdd($aLines, "    介质类型   : " & _Disk_FmtText($g_aDisks[$i][$D_MEDIA]))
        _RptAdd($aLines, "    容量       : " & _Disk_FmtSize($g_aDisks[$i][$D_SIZE]))
        _RptAdd($aLines, "    接口 / 总线: " & _Disk_FmtText($g_aDisks[$i][$D_BUS]))
        _RptAdd($aLines, "    转速       : " & _Disk_SpeedText($g_aDisks[$i][$D_SPEED]))
        _RptAdd($aLines, "    固件版本   : " & _Disk_FmtText($g_aDisks[$i][$D_FIRMWARE]))
        _RptAdd($aLines, "    序列号     : " & _Disk_FmtText($g_aDisks[$i][$D_SERIAL]))
        _RptAdd($aLines, "    分区样式   : " & _Disk_FmtText($g_aDisks[$i][$D_PARTSTYLE]) & "    分区数: " & _Disk_FmtText($g_aDisks[$i][$D_PARTITIONS]))
        _RptAdd($aLines, "    扇区大小   : " & _Disk_FmtNum($g_aDisks[$i][$D_SECTORSIZE], "字节"))
        _RptAdd($aLines, "    用途       : " & _Disk_FmtText($g_aDisks[$i][$D_USAGE]))
        _RptAdd($aLines, "    物理位置   : " & _Disk_FmtText($g_aDisks[$i][$D_LOCATION]))
        _RptAdd($aLines, "    能力       : " & _Disk_FmtText($g_aDisks[$i][$D_CAPS]))
        _RptAdd($aLines, "    设备实例   : " & _Disk_FmtText($g_aDisks[$i][$D_PNPID]))

        _RptAdd($aLines, "  [健康]")
        _RptAdd($aLines, "    综合结论   : " & $g_aDisks[$i][$D_VERDICT])
        _RptAdd($aLines, "    健康状态   : " & _Disk_FmtText($g_aDisks[$i][$D_HEALTH]))
        _RptAdd($aLines, "    运行状态   : " & _Disk_FmtText($g_aDisks[$i][$D_OPSTATUS]))
        _RptAdd($aLines, "    SMART 预测 : " & _Disk_FmtText($g_aDisks[$i][$D_SMART]))
        _RptAdd($aLines, "    原始磁盘   : " & _Disk_FmtText($g_aDisks[$i][$D_RAWDISK]))

        _RptAdd($aLines, "  [可靠性计数]")
        _RptAdd($aLines, "    当前温度   : " & _Disk_FmtNum($g_aDisks[$i][$D_TEMP], "°C") & "      历史最高: " & _Disk_FmtNum($g_aDisks[$i][$D_TEMPMAX], "°C"))
        _RptAdd($aLines, "    通电时间   : " & _Disk_FmtHours(_Disk_Num($g_aDisks[$i][$D_POWERON])))
        _RptAdd($aLines, "    磨损度     : " & _Disk_FmtNum($g_aDisks[$i][$D_WEAR], "%"))
        _RptAdd($aLines, "    启停次数   : " & _Disk_FmtNum($g_aDisks[$i][$D_STARTSTOP]) & "      上限设计值: " & _Disk_FmtNum($g_aDisks[$i][$D_STARTSTOPMAX]))
        _RptAdd($aLines, "    加载/卸载  : " & _Disk_FmtNum($g_aDisks[$i][$D_LOADUNLOAD]) & "      上限设计值: " & _Disk_FmtNum($g_aDisks[$i][$D_LOADUNLOADMAX]))
        _RptAdd($aLines, "    读错误     : 总 " & _Disk_FmtNum($g_aDisks[$i][$D_READTOTAL]) & " / 已纠正 " & _Disk_FmtNum($g_aDisks[$i][$D_READCORR]) & " / 不可纠正 " & _Disk_FmtNum($g_aDisks[$i][$D_READERR]))
        _RptAdd($aLines, "    写错误     : 总 " & _Disk_FmtNum($g_aDisks[$i][$D_WRITETOTAL]) & " / 已纠正 " & _Disk_FmtNum($g_aDisks[$i][$D_WRITECORR]) & " / 不可纠正 " & _Disk_FmtNum($g_aDisks[$i][$D_WRITEERR]))
        _RptAdd($aLines, "    最大延迟   : 读 " & _Disk_FmtNum($g_aDisks[$i][$D_READLAT], "ms") & "  写 " & _Disk_FmtNum($g_aDisks[$i][$D_WRITELAT], "ms") & "  刷新 " & _Disk_FmtNum($g_aDisks[$i][$D_FLUSHLAT], "ms"))
        _RptAdd($aLines, "    生产日期   : " & _Disk_FmtText($g_aDisks[$i][$D_MANUDATE]))

        Local $iAttrs = 0
        For $r = 0 To UBound($g_aSmart, 1) - 1
            If $g_aSmart[$r][$SM_DISK] = $i Then
                If $iAttrs = 0 Then
                    _RptAdd($aLines, "  [SMART 属性]")
                    _RptAdd($aLines, "    ID  属性名称                 当前 最差 阈值 原始值        状态")
                EndIf
                _RptAdd($aLines, "    " & _Disk_PadR(String($g_aSmart[$r][$SM_ID]), 5) & _
                        _Disk_PadR($g_aSmart[$r][$SM_NAME], 26) & _
                        _Disk_PadR(String($g_aSmart[$r][$SM_CUR]), 6) & _
                        _Disk_PadR(String($g_aSmart[$r][$SM_WORST]), 6) & _
                        _Disk_PadR(String($g_aSmart[$r][$SM_THRESH]), 6) & _
                        _Disk_PadR(String($g_aSmart[$r][$SM_RAW]), 15) & $g_aSmart[$r][$SM_STATE])
                $iAttrs += 1
            EndIf
        Next
        If $iAttrs = 0 Then
            _RptAdd($aLines, "  [SMART 属性] 未取得（NVMe/RAID 或未提权）")
        EndIf
    Next

    _RptAdd($aLines, "")
    _RptAdd($aLines, "【分区】共 " & UBound($g_aParts, 1) & " 个")
    For $i = 0 To UBound($g_aParts, 1) - 1
        _RptAdd($aLines, "  磁盘 " & _Disk_PadR(String($g_aParts[$i][$P_DISK]), 5) & _
                "分区 " & _Disk_PadR(String($g_aParts[$i][$P_INDEX]), 5) & _
                _Disk_PadR(_Disk_FmtText($g_aParts[$i][$P_TYPE]), 26) & _
                "大小 " & _Disk_PadR(_Disk_FmtSize($g_aParts[$i][$P_SIZE]), 11) & _
                "偏移 " & _Disk_PadR(_Disk_FmtSize($g_aParts[$i][$P_OFFSET]), 13) & _
                "启动 " & _Disk_PadR($g_aParts[$i][$P_BOOTABLE], 5) & _
                "主分区 " & _Disk_PadR($g_aParts[$i][$P_PRIMARY], 5) & $g_aParts[$i][$P_NAME])
    Next

    _RptAdd($aLines, "")
    _RptAdd($aLines, "【分区 / 卷】共 " & UBound($g_aVols, 1) & " 个")
    For $i = 0 To UBound($g_aVols, 1) - 1
        _RptAdd($aLines, "  " & _Disk_PadR($g_aVols[$i][$V_LETTER], 5) & _
                _Disk_PadR($g_aVols[$i][$V_LABEL], 18) & _Disk_PadR($g_aVols[$i][$V_FS], 8) & _
                "总 " & _Disk_PadR($g_aVols[$i][$V_SIZE], 11) & "可用 " & _Disk_PadR($g_aVols[$i][$V_FREE], 11) & _
                "已用 " & _Disk_PadR($g_aVols[$i][$V_USEDPCT], 8) & _Disk_PadR($g_aVols[$i][$V_TYPE], 12) & _
                _Disk_PadR($g_aVols[$i][$V_DISK], 10) & "健康 " & _Disk_PadR(_Disk_FmtText($g_aVols[$i][$V_HEALTH]), 10) & _
                "序列号 " & $g_aVols[$i][$V_SERIAL])
    Next

    _RptAdd($aLines, "")
    _RptAdd($aLines, "【数据源状态】")
    For $i = 0 To UBound($g_aSources, 1) - 1
        _RptAdd($aLines, "  " & _Disk_PadR($g_aSources[$i][$S_NAME], 36) & _
                _Disk_PadR($g_aSources[$i][$S_STATE], 10) & $g_aSources[$i][$S_DETAIL])
    Next

    Local $iWarn = 0, $iWatch = 0
    For $i = 0 To $iDisks - 1
        If $g_aDisks[$i][$D_VERDICT] = "严重" Or $g_aDisks[$i][$D_VERDICT] = "警告" Then
            $iWarn += 1
        ElseIf $g_aDisks[$i][$D_VERDICT] = "注意" Then
            $iWatch += 1
        EndIf
    Next
    _RptAdd($aLines, "")
    _RptAdd($aLines, "【总体结论】")
    If $iDisks = 0 Then
        _RptAdd($aLines, "  无法读取磁盘数据，请以管理员身份重新运行。")
    ElseIf $iWarn > 0 Then
        _RptAdd($aLines, "  发现 " & $iWarn & " 块磁盘需要关注，建议尽快备份重要数据并做一次完整表面检测。")
    ElseIf $iWatch > 0 Then
        _RptAdd($aLines, "  有 " & $iWatch & " 块磁盘指标偏高（温度/磨损/时长），目前不影响使用，建议持续观察。")
    Else
        _RptAdd($aLines, "  所有磁盘当前未发现异常指标。")
    EndIf
    If Not $g_bRawAccess Then
        _RptAdd($aLines, "  注意：未取得原始磁盘访问权限，SMART 深度数据可能不完整；以管理员身份运行可获取更多信息。")
    EndIf
    _RptAdd($aLines, "")
    _RptAdd($aLines, "说明：这里读取的是 Windows 存储子系统与 SMART 预测状态；")
    _RptAdd($aLines, "     要判断具体坏道/扇区，还需厂商工具（如 CrystalDiskInfo、厂商 SSD 工具箱）做完整检测。")

    Return _ArrayToString($aLines, @CRLF)
EndFunc   ;==>_Disk_BuildReport

; ------------------------------------------------- 原始能力转储（诊断用）
; 把所有相关 WMI 类的全部属性原样写出来，用于确认“到底哪些字段这台机器能给”。
Func _Disk_DumpAll($sPath)
    Local $aLines[0]
    _RptAdd($aLines, "================================================================")
    _RptAdd($aLines, " AutoIt 磁盘信息原始转储（诊断用）")
    _RptAdd($aLines, " 时间: " & @YEAR & "-" & @MON & "-" & @MDAY & " " & @HOUR & ":" & @MIN & ":" & @SEC)
    _RptAdd($aLines, " 计算机: " & @ComputerName & "  用户: " & @UserName & "  系统: " & @OSVersion & " build " & @OSBuild & " " & @OSArch)
    _RptAdd($aLines, " 解释器64位: " & @AutoItX64)
    _RptAdd($aLines, "================================================================")

    _Disk_Dump_Namespace($aLines, "winmgmts:\\.\root\cimv2", _
            "Win32_DiskDrive|Win32_DiskPartition|Win32_LogicalDisk|Win32_PhysicalMedia|Win32_LogicalDiskToPartition")
    _Disk_Dump_Namespace($aLines, "winmgmts:\\.\root\Microsoft\Windows\Storage", _
            "MSFT_PhysicalDisk|MSFT_StorageReliabilityCounter|MSFT_Disk|MSFT_Partition|MSFT_Volume")
    _Disk_Dump_Namespace($aLines, "winmgmts:\\.\root\wmi", _
            "MSStorageDriver_FailurePredictStatus|MSStorageDriver_ATAPISmartData|MSStorageDriver_FailurePredictThresholds")

    _RptAdd($aLines, "")
    _RptAdd($aLines, "###### 原始磁盘设备访问探测 ######")
    For $i = 0 To 9
        Local $sDev = "\\.\PhysicalDrive" & $i
        Local $hFile = _WinAPI_CreateFile($sDev, 3, 0x80000000, 3)
        Local $iErr = @error
        If $hFile <> 0 Then
            _WinAPI_CloseHandle($hFile)
            _RptAdd($aLines, "  " & $sDev & "  ->  可打开（权限充足）")
        Else
            _RptAdd($aLines, "  " & $sDev & "  ->  失败，错误码 " & $iErr & "（通常表示需要管理员）")
        EndIf
    Next

    Local $sText = _ArrayToString($aLines, @CRLF)
    Local $hOut = FileOpen($sPath, $FO_OVERWRITE + $FO_CREATEPATH + $FO_UTF8)
    If $hOut = -1 Then Return False
    FileWrite($hOut, $sText)
    FileClose($hOut)
    Return True
EndFunc   ;==>_Disk_DumpAll

Func _Disk_Dump_Namespace(ByRef $aLines, $sNamespace, $sClasses)
    _RptAdd($aLines, "")
    _RptAdd($aLines, "###### 命名空间 " & $sNamespace & " ######")

    $g_sLastComError = ""
    Local $oWmi = ObjGet($sNamespace)
    If Not IsObj($oWmi) Then
        _RptAdd($aLines, "  连接失败: " & $g_sLastComError)
        Return
    EndIf
    _RptAdd($aLines, "  连接成功")

    Local $aClasses = StringSplit($sClasses, "|", 2)
    For $c = 0 To UBound($aClasses) - 1
        Local $sClass = $aClasses[$c]
        $g_sLastComError = ""
        Local $oItems = $oWmi.ExecQuery("SELECT * FROM " & $sClass)
        If Not IsObj($oItems) Then
            _RptAdd($aLines, "  [" & $sClass & "] 查询失败: " & $g_sLastComError)
            ContinueLoop
        EndIf

        _RptAdd($aLines, "  [" & $sClass & "] 实例数 = " & $oItems.Count)
        Local $iInstance = 0
        For $oItem In $oItems
            If $iInstance >= 8 Then
                _RptAdd($aLines, "    (实例过多，仅列出前 8 个)")
                ExitLoop
            EndIf
            _RptAdd($aLines, "    --- 实例 " & $iInstance & " ---")
            _Disk_Dump_Instance($aLines, $oItem)
            $iInstance += 1
        Next
    Next
EndFunc   ;==>_Disk_Dump_Namespace

Func _Disk_Dump_Instance(ByRef $aLines, $oItem)
    Local $oProps = $oItem.Properties_
    If Not IsObj($oProps) Then
        _RptAdd($aLines, "      (无法枚举属性)")
        Return
    EndIf
    For $oProp In $oProps
        Local $sName = $oProp.Name
        If StringInStr($sName, "VendorSpecific") Then
            Local $vBytes = $oProp.Value
            If IsArray($vBytes) Then
                _RptAdd($aLines, "      " & $sName & " = [字节数组, 长度 " & UBound($vBytes) & "]")
            Else
                _RptAdd($aLines, "      " & $sName & " = (非数组类型)")
            EndIf
        Else
            _RptAdd($aLines, "      " & $sName & " = " & _Disk_Str($oProp.Value))
        EndIf
    Next
EndFunc   ;==>_Disk_Dump_Instance

; ------------------------------------------------------- 合成演示数据
; 把“有磁盘数据”的整条代码路径变成任何环境下都能测的东西。
Func _Disk_InjectDemoData()
    ReDim $g_aDisks[3][$D_COLS]

    $g_aDisks[0][$D_ID] = "0"
    $g_aDisks[0][$D_MODEL] = "Samsung SSD 990 PRO 1TB"
    $g_aDisks[0][$D_MEDIA] = "固态硬盘 SSD"
    $g_aDisks[0][$D_SIZE] = 1000204886016
    $g_aDisks[0][$D_BUS] = "NVMe"
    $g_aDisks[0][$D_HEALTH] = "Healthy"
    $g_aDisks[0][$D_OPSTATUS] = "OK"
    $g_aDisks[0][$D_TEMP] = "38"
    $g_aDisks[0][$D_TEMPMAX] = "61"
    $g_aDisks[0][$D_POWERON] = "1234"
    $g_aDisks[0][$D_WEAR] = "3"
    $g_aDisks[0][$D_READERR] = "0"
    $g_aDisks[0][$D_WRITEERR] = "0"
    $g_aDisks[0][$D_READTOTAL] = "0"
    $g_aDisks[0][$D_WRITETOTAL] = "0"
    $g_aDisks[0][$D_READCORR] = "0"
    $g_aDisks[0][$D_WRITECORR] = "0"
    $g_aDisks[0][$D_STARTSTOP] = "321"
    $g_aDisks[0][$D_LOADUNLOAD] = "0"
    $g_aDisks[0][$D_READLAT] = "12"
    $g_aDisks[0][$D_WRITELAT] = "18"
    $g_aDisks[0][$D_FLUSHLAT] = "7"
    $g_aDisks[0][$D_MANUDATE] = "2023-05-11"
    $g_aDisks[0][$D_SPEED] = "0"
    $g_aDisks[0][$D_USAGE] = "系统"
    $g_aDisks[0][$D_LOCATION] = "PCI Slot 1"
    $g_aDisks[0][$D_SERIAL] = "S6Z1NJ0T123456"
    $g_aDisks[0][$D_FIRMWARE] = "4B2QJXD7"
    $g_aDisks[0][$D_PARTSTYLE] = "GPT"
    $g_aDisks[0][$D_PARTITIONS] = "3"
    $g_aDisks[0][$D_SECTORSIZE] = "512"
    $g_aDisks[0][$D_SMART] = "正常"
    $g_aDisks[0][$D_RAWDISK] = "可读"
    $g_aDisks[0][$D_CAPS] = "SMART Notification"
    $g_aDisks[0][$D_PNPID] = "SCSI\DISK&VEN_NVME&PROD_SAMSUNG_SSD_990\5&1A2B3C4D&0&000000"

    $g_aDisks[1][$D_ID] = "1"
    $g_aDisks[1][$D_MODEL] = "WDC WD20EZBX-00AYRA0"
    $g_aDisks[1][$D_MEDIA] = "机械硬盘 HDD"
    $g_aDisks[1][$D_SIZE] = 2000398934016
    $g_aDisks[1][$D_BUS] = "SATA"
    $g_aDisks[1][$D_HEALTH] = "Healthy"
    $g_aDisks[1][$D_OPSTATUS] = "OK"
    $g_aDisks[1][$D_TEMP] = "52"
    $g_aDisks[1][$D_TEMPMAX] = "63"
    $g_aDisks[1][$D_POWERON] = "21000"
    $g_aDisks[1][$D_WEAR] = "0"
    $g_aDisks[1][$D_READERR] = "0"
    $g_aDisks[1][$D_WRITEERR] = "2"
    $g_aDisks[1][$D_READTOTAL] = "5"
    $g_aDisks[1][$D_WRITETOTAL] = "9"
    $g_aDisks[1][$D_READCORR] = "5"
    $g_aDisks[1][$D_WRITECORR] = "7"
    $g_aDisks[1][$D_STARTSTOP] = "4210"
    $g_aDisks[1][$D_LOADUNLOAD] = "18320"
    $g_aDisks[1][$D_LOADUNLOADMAX] = "600000"
    $g_aDisks[1][$D_READLAT] = "230"
    $g_aDisks[1][$D_WRITELAT] = "410"
    $g_aDisks[1][$D_FLUSHLAT] = "88"
    $g_aDisks[1][$D_MANUDATE] = "2021-08-02"
    $g_aDisks[1][$D_SPEED] = "7200"
    $g_aDisks[1][$D_USAGE] = "数据"
    $g_aDisks[1][$D_LOCATION] = "SATA Port 2"
    $g_aDisks[1][$D_SERIAL] = "WD-WCC4N1234567"
    $g_aDisks[1][$D_FIRMWARE] = "01.01A01"
    $g_aDisks[1][$D_PARTSTYLE] = "MBR"
    $g_aDisks[1][$D_PARTITIONS] = "2"
    $g_aDisks[1][$D_SECTORSIZE] = "512"
    $g_aDisks[1][$D_SMART] = "正常"
    $g_aDisks[1][$D_RAWDISK] = "可读"
    $g_aDisks[1][$D_CAPS] = "SMART Notification"
    $g_aDisks[1][$D_PNPID] = "SCSI\DISK&VEN_WDC&PROD_WD20EZBX\4&2B3C4D5E&0&010000"

    $g_aDisks[2][$D_ID] = "2"
    $g_aDisks[2][$D_MODEL] = "KINGSTON SA400S37240G"
    $g_aDisks[2][$D_MEDIA] = "固态硬盘 SSD"
    $g_aDisks[2][$D_SIZE] = 240057409536
    $g_aDisks[2][$D_BUS] = "SATA"
    $g_aDisks[2][$D_HEALTH] = "Warning"
    $g_aDisks[2][$D_OPSTATUS] = "OK"
    $g_aDisks[2][$D_TEMP] = "63"
    $g_aDisks[2][$D_TEMPMAX] = "71"
    $g_aDisks[2][$D_POWERON] = "41800"
    $g_aDisks[2][$D_WEAR] = "94"
    $g_aDisks[2][$D_READERR] = "7"
    $g_aDisks[2][$D_WRITEERR] = "0"
    $g_aDisks[2][$D_READTOTAL] = "41"
    $g_aDisks[2][$D_WRITETOTAL] = "12"
    $g_aDisks[2][$D_READCORR] = "34"
    $g_aDisks[2][$D_WRITECORR] = "12"
    $g_aDisks[2][$D_STARTSTOP] = "1890"
    $g_aDisks[2][$D_LOADUNLOAD] = "0"
    $g_aDisks[2][$D_READLAT] = "640"
    $g_aDisks[2][$D_WRITELAT] = "1200"
    $g_aDisks[2][$D_FLUSHLAT] = "310"
    $g_aDisks[2][$D_MANUDATE] = "2019-11-20"
    $g_aDisks[2][$D_SPEED] = "0"
    $g_aDisks[2][$D_USAGE] = "数据"
    $g_aDisks[2][$D_SERIAL] = "50026B7683A1B2C3"
    $g_aDisks[2][$D_FIRMWARE] = "SBFKB1D1"
    $g_aDisks[2][$D_PARTSTYLE] = "GPT"
    $g_aDisks[2][$D_PARTITIONS] = "1"
    $g_aDisks[2][$D_SECTORSIZE] = "512"
    $g_aDisks[2][$D_SMART] = "预测故障"
    $g_aDisks[2][$D_RAWDISK] = "可读"
    $g_aDisks[2][$D_CAPS] = "SMART Notification"
    $g_aDisks[2][$D_PNPID] = "SCSI\DISK&VEN_KINGSTON&PROD_SA400S37\3&3C4D5E6F&0&020000"

    ; 分区
    ReDim $g_aParts[5][$P_COLS]
    _Disk_DemoPart(0, 0, 0, "GPT: System", 104857600, 1048576, "是", "是")
    _Disk_DemoPart(1, 0, 1, "GPT: Basic Data", 536870912000, 105906176, "否", "否")
    _Disk_DemoPart(2, 0, 2, "GPT: Basic Data", 462000000000, 537000000000, "否", "否")
    _Disk_DemoPart(3, 1, 0, "Installable File System", 2097152000000, 1048576, "否", "否")
    _Disk_DemoPart(4, 2, 0, "GPT: Basic Data", 240000000000, 1048576, "否", "否")

    ; 卷
    ReDim $g_aVols[3][$V_COLS]
    _Disk_DemoVolume(0, "C:", "系统", "NTFS", 511000000000, 129000000000, "本地磁盘", "磁盘 0", "Healthy", "A1B2C3D4")
    _Disk_DemoVolume(1, "D:", "数据", "NTFS", 2000000000000, 980000000000, "本地磁盘", "磁盘 1", "Healthy", "B2C3D4E5")
    _Disk_DemoVolume(2, "E:", "备份", "exFAT", 1000000000000, 760000000000, "本地磁盘", "磁盘 2", "Healthy", "C3D4E5F6")

    ; SMART 属性表
    ReDim $g_aSmart[0][$SM_COLS]
    _Disk_DemoSmart(1, 5, 100, 100, 10, 0)
    _Disk_DemoSmart(1, 9, 85, 85, 0, 21000)
    _Disk_DemoSmart(1, 12, 97, 97, 0, 4210)
    _Disk_DemoSmart(1, 187, 100, 100, 0, 0)
    _Disk_DemoSmart(1, 193, 76, 76, 0, 18320)
    _Disk_DemoSmart(1, 194, 52, 47, 0, 52)
    _Disk_DemoSmart(1, 197, 100, 100, 0, 0)
    _Disk_DemoSmart(1, 198, 98, 98, 0, 2)
    _Disk_DemoSmart(1, 199, 100, 100, 0, 0)
    _Disk_DemoSmart(2, 5, 100, 100, 10, 3)
    _Disk_DemoSmart(2, 9, 62, 62, 0, 41800)
    _Disk_DemoSmart(2, 177, 6, 6, 0, 94)
    _Disk_DemoSmart(2, 187, 99, 99, 0, 7)
    _Disk_DemoSmart(2, 194, 63, 55, 0, 63)
    _Disk_DemoSmart(2, 197, 94, 94, 0, 12)
    _Disk_DemoSmart(2, 198, 100, 100, 0, 0)

    For $i = 0 To UBound($g_aDisks, 1) - 1
        $g_aDisks[$i][$D_VERDICT] = _Disk_Verdict($g_aDisks, $i)
    Next

    Local $aEmptySources[0][$S_COLS]
    $g_aSources = $aEmptySources
    _Disk_AddSource("演示数据", False, "这是 /demo 或 /demogui 生成的示例磁盘，不是你的真实硬件", "已注入")
    _Disk_AddSource("root\cimv2", False, "演示模式不访问 WMI", "已跳过")
    _Disk_AddSource("Storage 命名空间", False, "演示模式不访问 WMI", "已跳过")
    _Disk_AddSource("root\wmi (SMART)", False, "演示模式不访问 WMI", "已跳过")

    $g_bRawAccess = True
    Return UBound($g_aDisks, 1)
EndFunc   ;==>_Disk_InjectDemoData

Func _Disk_DemoPart($iRow, $iDisk, $iIndex, $sType, $iSize, $iOffset, $sBootable, $sPrimary)
    $g_aParts[$iRow][$P_DISK] = $iDisk
    $g_aParts[$iRow][$P_INDEX] = $iIndex
    $g_aParts[$iRow][$P_TYPE] = $sType
    $g_aParts[$iRow][$P_SIZE] = $iSize
    $g_aParts[$iRow][$P_OFFSET] = $iOffset
    $g_aParts[$iRow][$P_BOOTABLE] = $sBootable
    $g_aParts[$iRow][$P_PRIMARY] = $sPrimary
    $g_aParts[$iRow][$P_NAME] = "Disk #" & $iDisk & ", Partition #" & $iIndex
EndFunc   ;==>_Disk_DemoPart

Func _Disk_DemoVolume($iRow, $sLetter, $sLabel, $sFs, $iSize, $iFree, $sType, $sDisk, $sHealth, $sSerial)
    $g_aVols[$iRow][$V_LETTER] = $sLetter
    $g_aVols[$iRow][$V_LABEL] = $sLabel
    $g_aVols[$iRow][$V_FS] = $sFs
    $g_aVols[$iRow][$V_SIZE] = _Disk_FmtSize($iSize)
    $g_aVols[$iRow][$V_FREE] = _Disk_FmtSize($iFree)
    If $iSize > 0 Then
        $g_aVols[$iRow][$V_USEDPCT] = StringFormat("%.1f%%", (1 - $iFree / $iSize) * 100)
    Else
        $g_aVols[$iRow][$V_USEDPCT] = "—"
    EndIf
    $g_aVols[$iRow][$V_TYPE] = $sType
    $g_aVols[$iRow][$V_SIZEB] = $iSize
    $g_aVols[$iRow][$V_FREEB] = $iFree
    $g_aVols[$iRow][$V_HEALTH] = $sHealth
    $g_aVols[$iRow][$V_DISK] = $sDisk
    $g_aVols[$iRow][$V_SERIAL] = $sSerial
EndFunc   ;==>_Disk_DemoVolume

Func _Disk_DemoSmart($iDisk, $iId, $iCur, $iWorst, $iThresh, $iRaw)
    _Disk_SmartAdd($iDisk, $iId, $iCur, $iWorst, $iThresh, $iRaw)
EndFunc   ;==>_Disk_DemoSmart
