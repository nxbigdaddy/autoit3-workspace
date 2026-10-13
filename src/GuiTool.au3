; GuiTool.au3 - 批量重命名工具（GUI）
;
;   运行： au3 src\GuiTool.au3          （或双击 src\GuiTool.au3）
;   自检： au3 src\GuiTool.au3 /selftest （不弹界面，跑核心逻辑并返回失败数）
;   编译： au3build src\GuiTool.au3
;
; 界面要点：
;   * GUIOnEventMode 事件驱动，不用 While/Select 轮询
;   * 执行时用 AdlibRegister 分片处理，界面全程不冻结
;   * 先扫描出“计划”再执行，预览与执行分离，冲突自动跳过，绝不覆盖文件

#include <WindowsConstants.au3>
#include <GUIConstantsEx.au3>
#include <TrayConstants.au3>
#include <MsgBoxConstants.au3>
#include <EditConstants.au3>
#include <StaticConstants.au3>
#include <ButtonConstants.au3>
#include <ListViewConstants.au3>
#include <ScrollBarsConstants.au3>
#include <FileConstants.au3>
#include <GuiEdit.au3>
#include <GuiListView.au3>
#include <GuiComboBox.au3>
#include "lib\FileTools.au3"

Opt("GUIOnEventMode", 1)
Opt("TrayMenuMode", 3)
Opt("TrayOnEventMode", 1)
Opt("MustDeclareVars", 1)

; ------------------------------------------------------------------ 全局状态
Global $g_sIni = @ScriptDir & "\GuiTool.ini"

Global $g_hGui, $g_idFolder, $g_idBrowse, $g_idFilter, $g_idRecurse, $g_idMode, $g_idDryRun
Global $g_idLabel1, $g_idLabel2, $g_idArg1, $g_idArg2
Global $g_idList, $g_idProgress, $g_idStatus, $g_idLog
Global $g_idScan, $g_idRun, $g_idClear, $g_idOpenFolder
Global $g_idTrayToggle, $g_idTrayExit

Global $g_aPlan[0][4]
Global $g_aRows[0]
Global $g_iCursor = 0, $g_iApplied = 0, $g_iSkipped = 0, $g_iFailed = 0
Global $g_bBusy = False

; 自检计数器：必须在下面的命令行分支之前声明。
; AutoIt 的全局变量是“执行到那一行”才存在的，/selftest 会在创建界面之前 Exit。
Global $g_iSelfFail = 0

; /selftest 在创建界面之前就返回，方便无人值守验证
If $CmdLine[0] > 0 And StringLower($CmdLine[1]) = "/selftest" Then
    Exit _SelfTest()
EndIf

; -------------------------------------------------------------------- 创建界面
$g_hGui = GUICreate("AutoIt 批量重命名工具", 780, 650, -1, -1, BitOR($WS_OVERLAPPEDWINDOW, $WS_CLIPCHILDREN))
GUISetFont(9, 400, 0, "Microsoft YaHei UI")
GUISetOnEvent($GUI_EVENT_CLOSE, "_OnQuit")
GUISetOnEvent($GUI_EVENT_MINIMIZE, "_OnMinimize")

GUICtrlCreateLabel("目标文件夹", 15, 18, 70, 20)
$g_idFolder = GUICtrlCreateInput("", 90, 15, 560, 24)
$g_idBrowse = GUICtrlCreateButton("浏览...", 660, 14, 105, 26)

GUICtrlCreateLabel("文件筛选", 15, 52, 60, 20)
$g_idFilter = GUICtrlCreateInput("*.*", 90, 49, 110, 24)
$g_idRecurse = GUICtrlCreateCheckbox("包含子文件夹", 212, 51, 110, 22)
GUICtrlCreateLabel("重命名模式", 330, 52, 76, 20)
$g_idMode = GUICtrlCreateCombo("", 410, 49, 150, 200, $CBS_DROPDOWNLIST)
$g_idDryRun = GUICtrlCreateCheckbox("仅预览（不修改文件）", 575, 51, 180, 22)

$g_idLabel1 = GUICtrlCreateLabel("查找内容", 15, 86, 120, 20)
$g_idArg1 = GUICtrlCreateInput("", 140, 83, 210, 24)
$g_idLabel2 = GUICtrlCreateLabel("替换为", 365, 86, 120, 20)
$g_idArg2 = GUICtrlCreateInput("", 490, 83, 275, 24)

$g_idList = GUICtrlCreateListView("原文件|新文件|状态", 15, 118, 750, 300)
_GUICtrlListView_SetColumnWidth($g_idList, 0, 300)
_GUICtrlListView_SetColumnWidth($g_idList, 1, 300)
_GUICtrlListView_SetColumnWidth($g_idList, 2, 140)
_GUICtrlListView_SetExtendedListViewStyle($g_idList, $LVS_EX_FULLROWSELECT)

$g_idProgress = GUICtrlCreateProgress(15, 428, 750, 18)
$g_idStatus = GUICtrlCreateLabel("就绪", 15, 452, 750, 20)

$g_idScan = GUICtrlCreateButton("扫描并预览", 15, 478, 120, 30)
$g_idRun = GUICtrlCreateButton("开始执行", 145, 478, 120, 30)
$g_idClear = GUICtrlCreateButton("清空列表", 275, 478, 100, 30)
$g_idOpenFolder = GUICtrlCreateButton("打开目标文件夹", 385, 478, 140, 30)

GUICtrlCreateLabel("日志", 15, 518, 60, 20)
$g_idLog = GUICtrlCreateEdit("", 15, 538, 750, 95, BitOR($ES_MULTILINE, $ES_READONLY, $WS_VSCROLL, $ES_AUTOVSCROLL))

; 托盘菜单
$g_idTrayToggle = TrayCreateItem("显示 / 隐藏窗口")
TrayItemSetOnEvent($g_idTrayToggle, "_OnTrayToggle")
TrayCreateItem("")
$g_idTrayExit = TrayCreateItem("退出")
TrayItemSetOnEvent($g_idTrayExit, "_OnQuit")
TraySetOnEvent($TRAY_EVENT_PRIMARYDOUBLE, "_OnTrayToggle")
TraySetToolTip("AutoIt 批量重命名工具")

GUICtrlSetOnEvent($g_idBrowse, "_OnBrowse")
GUICtrlSetOnEvent($g_idScan, "_OnScan")
GUICtrlSetOnEvent($g_idRun, "_OnRun")
GUICtrlSetOnEvent($g_idClear, "_OnClear")
GUICtrlSetOnEvent($g_idOpenFolder, "_OnOpenFolder")
GUICtrlSetOnEvent($g_idMode, "_OnModeChange")

GUICtrlSetData($g_idMode, "查找替换|添加前缀|添加后缀|序号重命名", "查找替换")
_LoadConfig()
_OnModeChange()
_Log("就绪。选择文件夹 → 扫描并预览 → 取消“仅预览”后执行。")

GUISetState(@SW_SHOW, $g_hGui)

While 1
    Sleep(50)
WEnd

; ------------------------------------------------------------------ 界面辅助
Func _Log($sMessage)
    _GUICtrlEdit_AppendText($g_idLog, "[" & @HOUR & ":" & @MIN & ":" & @SEC & "] " & $sMessage & @CRLF)
    _GUICtrlEdit_Scroll($g_idLog, $SB_SCROLLCARET)
EndFunc   ;==>_Log

Func _SetStatus($sText)
    GUICtrlSetData($g_idStatus, $sText)
EndFunc   ;==>_SetStatus

Func _SetBusy($bBusy)
    $g_bBusy = $bBusy
    Local $iState = $GUI_ENABLE
    If $bBusy Then $iState = $GUI_DISABLE
    GUICtrlSetState($g_idScan, $iState)
    GUICtrlSetState($g_idRun, $iState)
    GUICtrlSetState($g_idClear, $iState)
    GUICtrlSetState($g_idBrowse, $iState)
    GUICtrlSetState($g_idFolder, $iState)
EndFunc   ;==>_SetBusy

Func _CurrentMode()
    Return _GUICtrlComboBox_GetCurSel($g_idMode)
EndFunc   ;==>_CurrentMode

; 列表里显示相对路径，避免整行被长路径挤掉
Func _RelPath($sPath)
    Local $sRoot = StringStripWS(GUICtrlRead($g_idFolder), 3)
    If $sRoot <> "" And StringInStr($sPath, $sRoot, 0) = 1 Then
        Return StringTrimLeft($sPath, StringLen($sRoot) + 1)
    EndIf
    Return $sPath
EndFunc   ;==>_RelPath

Func _RowText($iIndex)
    Return _RelPath($g_aPlan[$iIndex][0]) & "|" & _RelPath($g_aPlan[$iIndex][1]) & "|" & $g_aPlan[$iIndex][3]
EndFunc   ;==>_RowText

; ------------------------------------------------------------------ 事件处理
Func _OnModeChange()
    Switch _CurrentMode()
        Case $RENAME_REPLACE
            GUICtrlSetData($g_idLabel1, "查找内容")
            GUICtrlSetData($g_idLabel2, "替换为")
            GUICtrlSetState($g_idArg2, $GUI_ENABLE)
        Case $RENAME_PREFIX
            GUICtrlSetData($g_idLabel1, "前缀")
            GUICtrlSetData($g_idLabel2, "（未使用）")
            GUICtrlSetState($g_idArg2, $GUI_DISABLE)
        Case $RENAME_SUFFIX
            GUICtrlSetData($g_idLabel1, "后缀")
            GUICtrlSetData($g_idLabel2, "（未使用）")
            GUICtrlSetState($g_idArg2, $GUI_DISABLE)
        Case $RENAME_INDEX
            GUICtrlSetData($g_idLabel1, "新名称基础名")
            GUICtrlSetData($g_idLabel2, "起始序号")
            GUICtrlSetState($g_idArg2, $GUI_ENABLE)
    EndSwitch
EndFunc   ;==>_OnModeChange

Func _OnBrowse()
    Local $sFolder = FileSelectFolder("选择要处理的文件夹", "", 1, GUICtrlRead($g_idFolder))
    If @error Or $sFolder = "" Then Return
    GUICtrlSetData($g_idFolder, $sFolder)
    _Log("目标文件夹：" & $sFolder)
EndFunc   ;==>_OnBrowse

Func _OnOpenFolder()
    Local $sFolder = StringStripWS(GUICtrlRead($g_idFolder), 3)
    If $sFolder = "" Or Not FileExists($sFolder) Then
        _Log("请先选择有效的目标文件夹。")
        Return
    EndIf
    Run('explorer.exe "' & $sFolder & '"')
EndFunc   ;==>_OnOpenFolder

Func _OnClear()
    _GUICtrlListView_DeleteAllItems($g_idList)
    Local $aEmpty[0][4]
    $g_aPlan = $aEmpty
    Local $aNoRows[0]
    $g_aRows = $aNoRows
    GUICtrlSetData($g_idProgress, 0)
    _SetStatus("就绪")
    _Log("已清空列表。")
EndFunc   ;==>_OnClear

Func _OnScan()
    Local $sFolder = StringStripWS(GUICtrlRead($g_idFolder), 3)
    If $sFolder = "" Or Not FileExists($sFolder) Then
        _Log("错误：请先选择存在的目标文件夹。")
        Return
    EndIf

    _OnClear()

    Local $iMode = _CurrentMode()
    Local $sArg1 = GUICtrlRead($g_idArg1)
    Local $sArg2 = GUICtrlRead($g_idArg2)
    Local $bRecurse = (GUICtrlRead($g_idRecurse) = $GUI_CHECKED)

    Local $iStart = 1
    If $iMode = $RENAME_INDEX Then
        $iStart = Int(StringStripWS($sArg2, 3))
        If $iStart < 1 Then $iStart = 1
    EndIf

    $g_aPlan = _Rename_BuildPlan($sFolder, StringStripWS(GUICtrlRead($g_idFilter), 3), $bRecurse, $iMode, $sArg1, $sArg2, $iStart)
    If @error = 1 Then
        _Log("错误：文件夹不存在。")
        Return
    EndIf

    Local $iTotal = UBound($g_aPlan, 1)
    If $iTotal = 0 Then
        _Log("没有找到匹配的文件。")
        _SetStatus("0 个文件")
        Return
    EndIf

    ReDim $g_aRows[$iTotal]
    Local $iOk = 0, $iConflict = 0, $iOther = 0
    For $i = 0 To $iTotal - 1
        $g_aRows[$i] = GUICtrlCreateListViewItem(_RowText($i), $g_idList)
        Switch $g_aPlan[$i][2]
            Case $RENAME_OK
                $iOk += 1
            Case $RENAME_CONFLICT
                $iConflict += 1
            Case Else
                $iOther += 1
        EndSwitch
    Next

    _Log(StringFormat("扫描完成：共 %d 项，待改名 %d，冲突 %d，无需修改 %d", $iTotal, $iOk, $iConflict, $iOther))
    _SetStatus(StringFormat("共 %d 项 / 待改名 %d / 冲突 %d", $iTotal, $iOk, $iConflict))
EndFunc   ;==>_OnScan

Func _OnRun()
    If UBound($g_aPlan, 1) = 0 Then
        _Log("请先点击“扫描并预览”。")
        Return
    EndIf
    If GUICtrlRead($g_idDryRun) = $GUI_CHECKED Then
        _Log("当前勾选了“仅预览”，不会修改任何文件。取消勾选后再执行。")
        Return
    EndIf

    Local $iTodo = _Rename_CountActionable($g_aPlan)
    If $iTodo = 0 Then
        _Log("没有可执行的项目（可能全部冲突或无需修改）。")
        Return
    EndIf

    Local $iAnswer = MsgBox(BitOR($MB_ICONQUESTION, $MB_YESNO, $MB_DEFBUTTON2), "确认执行", _
            "即将重命名 " & $iTodo & " 个文件。" & @CRLF & @CRLF & "已存在的目标文件会被自动跳过，不会被覆盖。" & @CRLF & @CRLF & "继续吗？")
    If $iAnswer <> $IDYES Then
        _Log("已取消执行。")
        Return
    EndIf

    $g_iCursor = 0
    $g_iApplied = 0
    $g_iSkipped = 0
    $g_iFailed = 0
    GUICtrlSetData($g_idProgress, 0)
    _SetBusy(True)
    _Log("开始执行……")
    AdlibRegister("_ProcessStep", 15)
EndFunc   ;==>_OnRun

; 每 15ms 处理最多 5 个文件，界面在此期间保持可响应
Func _ProcessStep()
    Local $iTotal = UBound($g_aPlan, 1)
    Local $iDone = 0

    While $g_iCursor < $iTotal And $iDone < 5
        If $g_aPlan[$g_iCursor][2] = $RENAME_OK Then
            Local $iResult = _Rename_ApplyOne($g_aPlan[$g_iCursor][0], $g_aPlan[$g_iCursor][1])
            Local $iErr = @error
            If $iResult = 1 Then
                $g_iApplied += 1
                $g_aPlan[$g_iCursor][3] = "已重命名"
            Else
                $g_iFailed += 1
                $g_aPlan[$g_iCursor][3] = "失败(错误 " & $iErr & ")"
            EndIf
        Else
            $g_iSkipped += 1
            $g_aPlan[$g_iCursor][3] = "已跳过(" & $g_aPlan[$g_iCursor][3] & ")"
        EndIf

        If $g_iCursor < UBound($g_aRows) Then
            GUICtrlSetData($g_aRows[$g_iCursor], _RowText($g_iCursor))
        EndIf

        $g_iCursor += 1
        $iDone += 1
    WEnd

    GUICtrlSetData($g_idProgress, Int($g_iCursor * 100 / $iTotal))
    _SetStatus(StringFormat("进度 %d/%d  已改名 %d  跳过 %d  失败 %d", $g_iCursor, $iTotal, $g_iApplied, $g_iSkipped, $g_iFailed))

    If $g_iCursor >= $iTotal Then
        AdlibUnRegister("_ProcessStep")
        GUICtrlSetData($g_idProgress, 100)
        _SetBusy(False)
        _Log(StringFormat("执行完成：改名 %d，跳过 %d，失败 %d", $g_iApplied, $g_iSkipped, $g_iFailed))
    EndIf
EndFunc   ;==>_ProcessStep

Func _OnMinimize()
    GUISetState(@SW_HIDE, $g_hGui)
    TrayTip("批量重命名工具", "窗口已最小化到托盘，双击托盘图标可恢复。", 3)
EndFunc   ;==>_OnMinimize

Func _OnTrayToggle()
    If BitAND(WinGetState($g_hGui), 2) Then
        GUISetState(@SW_HIDE, $g_hGui)
    Else
        GUISetState(@SW_SHOW, $g_hGui)
        GUISetState(@SW_RESTORE, $g_hGui)
        WinActivate($g_hGui)
    EndIf
EndFunc   ;==>_OnTrayToggle

Func _SaveConfig()
    IniWrite($g_sIni, "gui", "folder", GUICtrlRead($g_idFolder))
    IniWrite($g_sIni, "gui", "filter", GUICtrlRead($g_idFilter))
    IniWrite($g_sIni, "gui", "mode", String(_CurrentMode()))
    IniWrite($g_sIni, "gui", "arg1", GUICtrlRead($g_idArg1))
    IniWrite($g_sIni, "gui", "arg2", GUICtrlRead($g_idArg2))
    IniWrite($g_sIni, "gui", "recurse", String(GUICtrlRead($g_idRecurse) = $GUI_CHECKED))
    IniWrite($g_sIni, "gui", "dryrun", String(GUICtrlRead($g_idDryRun) = $GUI_CHECKED))
EndFunc   ;==>_SaveConfig

Func _LoadConfig()
    GUICtrlSetData($g_idFolder, IniRead($g_sIni, "gui", "folder", ""))
    GUICtrlSetData($g_idFilter, IniRead($g_sIni, "gui", "filter", "*.*"))
    GUICtrlSetData($g_idArg1, IniRead($g_sIni, "gui", "arg1", ""))
    GUICtrlSetData($g_idArg2, IniRead($g_sIni, "gui", "arg2", "1"))

    Local $iMode = Int(IniRead($g_sIni, "gui", "mode", "0"))
    If $iMode < 0 Or $iMode > 3 Then $iMode = 0
    _GUICtrlComboBox_SetCurSel($g_idMode, $iMode)

    If IniRead($g_sIni, "gui", "recurse", "False") = "True" Then
        GUICtrlSetState($g_idRecurse, $GUI_CHECKED)
    EndIf
    ; 安全默认：首次运行一定是“仅预览”
    If IniRead($g_sIni, "gui", "dryrun", "True") = "True" Then
        GUICtrlSetState($g_idDryRun, $GUI_CHECKED)
    EndIf
EndFunc   ;==>_LoadConfig

Func _OnQuit()
    _SaveConfig()
    Exit
EndFunc   ;==>_OnQuit

; -------------------------------------------------------------------- 自检模式
; 注意：$g_iSelfFail 在文件顶部的全局区声明（这里声明会因为提前 Exit 而失效）

Func _SelfLog($sText)
    ConsoleWrite($sText & @CRLF)
    FileWrite(@ScriptDir & "\..\out\selftest.log", $sText & @CRLF)
EndFunc   ;==>_SelfLog

Func _Assert($sName, $bOk)
    If $bOk Then
        _SelfLog("[ ok ] " & $sName)
    Else
        _SelfLog("[FAIL] " & $sName)
        $g_iSelfFail += 1
    EndIf
EndFunc   ;==>_Assert

Func _CountItems($aPlan)
    If UBound($aPlan, 1) = 0 Then Return 0
    Return UBound($aPlan, 1)
EndFunc   ;==>_CountItems

Func _CountStatus($aPlan, $iStatus)
    Local $iCount = 0
    For $i = 0 To UBound($aPlan, 1) - 1
        If $aPlan[$i][2] = $iStatus Then $iCount += 1
    Next
    Return $iCount
EndFunc   ;==>_CountStatus

Func _ApplyPlan($aPlan)
    Local $iApplied = 0
    For $i = 0 To UBound($aPlan, 1) - 1
        If $aPlan[$i][2] = $RENAME_OK Then
            If _Rename_ApplyOne($aPlan[$i][0], $aPlan[$i][1]) = 1 Then $iApplied += 1
        EndIf
    Next
    Return $iApplied
EndFunc   ;==>_ApplyPlan

Func _SelfTest()
    Local $sRoot = @ScriptDir & "\..\out\selftest"
    Local $sLog = @ScriptDir & "\..\out\selftest.log"

    If FileExists($sLog) Then FileDelete($sLog)
    If FileExists($sRoot) Then DirRemove($sRoot, 1)
    DirCreate($sRoot)

    _SelfLog("=== GuiTool 核心逻辑自检 ===")
    _Assert("非法字符被替换", _Rename_Sanitize("a:b*c?d") = "a_b_c_d")
    _Assert("保留设备名被拒绝", _Rename_IsValidName("CON.txt") = False)

    ; --- 1) 查找替换 -------------------------------------------------------
    FileWrite($sRoot & "\file1.txt", "x")
    FileWrite($sRoot & "\file2.txt", "x")
    FileWrite($sRoot & "\file3.txt", "x")
    FileWrite($sRoot & "\keep.log", "x")

    Local $aPlan = _Rename_BuildPlan($sRoot, "*.txt", False, $RENAME_REPLACE, "file1", "doc1")
    _Assert("筛选 *.txt 只取到 3 个文件", _CountItems($aPlan) = 3)
    _Assert("查找替换只有 1 项需要改名", _CountStatus($aPlan, $RENAME_OK) = 1)
    _Assert("执行返回 1", _ApplyPlan($aPlan) = 1)
    _Assert("doc1.txt 已生成", FileExists($sRoot & "\doc1.txt"))
    _Assert("file1.txt 已消失", Not FileExists($sRoot & "\file1.txt"))
    _Assert("keep.log 未受影响", FileExists($sRoot & "\keep.log"))

    ; --- 2) 加前缀 ---------------------------------------------------------
    $aPlan = _Rename_BuildPlan($sRoot, "*.txt", False, $RENAME_PREFIX, "p_", "")
    _Assert("前缀模式 3 项待改名", _CountStatus($aPlan, $RENAME_OK) = 3)
    _Assert("执行返回 3", _ApplyPlan($aPlan) = 3)
    _Assert("p_doc1.txt 已生成", FileExists($sRoot & "\p_doc1.txt"))
    _Assert("p_file3.txt 已生成", FileExists($sRoot & "\p_file3.txt"))

    ; --- 3) 冲突保护 -------------------------------------------------------
    FileWrite($sRoot & "\same1.txt", "x")
    FileWrite($sRoot & "\same2.txt", "x")
    $aPlan = _Rename_BuildPlan($sRoot, "same1.txt", False, $RENAME_REPLACE, "same1", "same2")
    _Assert("冲突被识别出来", _CountStatus($aPlan, $RENAME_CONFLICT) = 1)
    _Assert("冲突项不会被应用", _ApplyPlan($aPlan) = 0)
    _Assert("same1.txt 仍在（未被覆盖）", FileExists($sRoot & "\same1.txt"))
    _Assert("same2.txt 内容未被改写", FileRead($sRoot & "\same2.txt") = "x")

    ; --- 4) 序号重命名 -----------------------------------------------------
    Local $sIdx = $sRoot & "\idx"
    DirCreate($sIdx)
    FileWrite($sIdx & "\a.txt", "x")
    FileWrite($sIdx & "\b.txt", "x")
    FileWrite($sIdx & "\c.txt", "x")
    $aPlan = _Rename_BuildPlan($sIdx, "*.txt", False, $RENAME_INDEX, "img", "", 1)
    _Assert("序号模式 3 项待改名", _CountStatus($aPlan, $RENAME_OK) = 3)
    _Assert("执行返回 3", _ApplyPlan($aPlan) = 3)
    _Assert("img_001.txt 已生成", FileExists($sIdx & "\img_001.txt"))
    _Assert("img_003.txt 已生成", FileExists($sIdx & "\img_003.txt"))

    ; --- 5) 递归子文件夹 ---------------------------------------------------
    Local $sNest = $sRoot & "\nest\deep"
    DirCreate($sNest)
    FileWrite($sNest & "\deep.txt", "x")
    $aPlan = _Rename_BuildPlan($sRoot, "deep.txt", False, $RENAME_PREFIX, "z_", "")
    _Assert("不递归时找不到深层文件", _CountItems($aPlan) = 0)
    $aPlan = _Rename_BuildPlan($sRoot, "deep.txt", True, $RENAME_PREFIX, "z_", "")
    _Assert("递归时找到 1 个深层文件", _CountStatus($aPlan, $RENAME_OK) = 1)
    _Assert("执行返回 1", _ApplyPlan($aPlan) = 1)
    _Assert("z_deep.txt 已生成", FileExists($sNest & "\z_deep.txt"))

    ; --- 6) 参数为空时不动任何东西 ----------------------------------------
    $aPlan = _Rename_BuildPlan($sRoot, "*.txt", True, $RENAME_REPLACE, "", "")
    _Assert("查找内容为空时不产生改名项", _CountStatus($aPlan, $RENAME_OK) = 0)

    _SelfLog("")
    If $g_iSelfFail = 0 Then
        _SelfLog("自检结果：全部通过")
    Else
        _SelfLog("自检结果：失败 " & $g_iSelfFail & " 项")
    EndIf
    Return $g_iSelfFail
EndFunc   ;==>_SelfTest
