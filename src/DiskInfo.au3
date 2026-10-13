; DiskInfo.au3 - 本机磁盘参数与健康检测工具（GUI，主从布局）
;
;   运行     : au3 src\DiskInfo.au3            或直接双击 build\DiskInfo.exe
;   自检     : au3 src\DiskInfo.au3 /selftest   （不弹界面，跑逻辑 + 合成数据检查）
;   报告     : au3 src\DiskInfo.au3 /report     （不弹界面，导出 out\diskinfo.txt）
;   诊断转储 : au3 src\DiskInfo.au3 /dump       （把所有 WMI 原始字段写出来，用于确认缺什么）
;   演示报告 : au3 src\DiskInfo.au3 /demo       （合成数据出报告）
;   演示界面 : au3 src\DiskInfo.au3 /demogui    （合成数据开界面，任何权限都能验证界面）
;   编译     : au3build src\DiskInfo.au3
;
; 界面结构（主从布局，信息密度优先）：
;   顶部    : 标题 + 刷新 / 导出报告 / 导出诊断 / 以管理员身份重启 + 状态条
;   左侧    : 物理磁盘列表（序号 / 型号 / 容量 / 结论）
;   右侧    : 选中磁盘的全部参数（基本参数 / 健康 / 可靠性计数）
;   下侧页签: SMART 属性表、分区与卷、分区表、数据源状态
;
; 权限说明：SMART 深度数据（温度/通电时间/磨损/属性表）需要管理员，
;           工具会自动探测，拿不到时逐项标注原因，并提供提权按钮。

#include <WindowsConstants.au3>
#include <StructureConstants.au3>
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
#include <Array.au3>
#include "lib\DiskData.au3"

Opt("GUIOnEventMode", 1)
Opt("TrayMenuMode", 3)
Opt("TrayOnEventMode", 1)
Opt("MustDeclareVars", 1)

; ------------------------------------------------------------------ 全局状态
; 重要：所有 Global 声明必须放在命令行分支之前。
; AutoIt 的全局变量是“执行到那一行”才存在的，提前 Exit 会让后面的声明失效。
Global $g_iSelftestFail = 0
Global $g_bDemoMode = False
Global $g_bAskedElevate = False

Global $g_sIni = @ScriptDir & "\DiskInfo.ini"
Global $g_hGui, $g_idSummary, $g_idRefresh, $g_idExport, $g_idDump, $g_idElevate
Global $g_idDiskList, $g_idDetailList
Global $g_idTabs
Global $g_idSmartList, $g_idSmartNote
Global $g_idVolList, $g_idVolNote
Global $g_idPartList, $g_idPartNote
Global $g_idSourceList, $g_idSourceNote
Global $g_idTrayShow, $g_idTrayExit
Global $g_bRefreshing = False
Global $g_iSelectedDisk = -1

; ------------------------------------------------------- 命令行（无界面）模式
If $CmdLine[0] > 0 Then
    Switch StringLower(StringStripWS($CmdLine[1], 3))
        Case "/report"
            Exit _RunReport(False)
        Case "/demo"
            Exit _RunReport(True)
        Case "/dump"
            Exit _RunDump()
        Case "/selftest"
            Exit _RunSelfTest()
        Case "/demogui"
            $g_bDemoMode = True
    EndSwitch
EndIf

; -------------------------------------------------------------------- 创建界面
$g_hGui = GUICreate("磁盘参数与健康检测", 1140, 810, -1, -1, BitOR($WS_OVERLAPPEDWINDOW, $WS_CLIPCHILDREN))
GUISetFont(10, 400, 0, "Microsoft YaHei UI")
GUISetOnEvent($GUI_EVENT_CLOSE, "_OnQuit")
GUISetOnEvent($GUI_EVENT_MINIMIZE, "_OnMinimize")

Local $idTitle = GUICtrlCreateLabel("本机磁盘参数与健康状态", 15, 12, 330, 26)
GUICtrlSetFont($idTitle, 13, 700)

$g_idRefresh = GUICtrlCreateButton("刷新", 660, 10, 84, 30)
$g_idExport = GUICtrlCreateButton("导出报告", 750, 10, 96, 30)
$g_idDump = GUICtrlCreateButton("导出诊断", 852, 10, 96, 30)
$g_idElevate = GUICtrlCreateButton("以管理员身份重启", 954, 10, 170, 30)
GUICtrlSetState($g_idElevate, $GUI_HIDE)

$g_idSummary = GUICtrlCreateLabel("准备中……", 15, 48, 1110, 22)

; ---- 左：磁盘列表 ----
Local $idLblLeft = GUICtrlCreateLabel("物理磁盘（点选查看右侧完整参数）", 15, 76, 340, 20)
GUICtrlSetColor($idLblLeft, 0x555555)
$g_idDiskList = GUICtrlCreateListView("磁盘|型号|容量|结论", 15, 98, 340, 400)
_GUICtrlListView_SetColumnWidth($g_idDiskList, 0, 48)
_GUICtrlListView_SetColumnWidth($g_idDiskList, 1, 148)
_GUICtrlListView_SetColumnWidth($g_idDiskList, 2, 78)
_GUICtrlListView_SetColumnWidth($g_idDiskList, 3, 60)
_GUICtrlListView_SetExtendedListViewStyle($g_idDiskList, BitOR($LVS_EX_FULLROWSELECT, $LVS_EX_GRIDLINES))

; ---- 右：选中磁盘的全部参数 ----
Local $idLblRight = GUICtrlCreateLabel("选中磁盘的全部参数", 370, 76, 400, 20)
GUICtrlSetColor($idLblRight, 0x555555)
$g_idDetailList = GUICtrlCreateListView("参数|值", 370, 98, 755, 465)
_GUICtrlListView_SetColumnWidth($g_idDetailList, 0, 190)
_GUICtrlListView_SetColumnWidth($g_idDetailList, 1, 540)
_GUICtrlListView_SetExtendedListViewStyle($g_idDetailList, BitOR($LVS_EX_FULLROWSELECT, $LVS_EX_GRIDLINES))

; ---- 下：页签 ----
$g_idTabs = GUICtrlCreateTab(15, 575, 1110, 220)

GUICtrlCreateTabItem("SMART 属性")
$g_idSmartList = GUICtrlCreateListView("ID|属性名称|当前|最差|阈值|原始值|状态", 25, 605, 1090, 145)
_GUICtrlListView_SetColumnWidth($g_idSmartList, 0, 50)
_GUICtrlListView_SetColumnWidth($g_idSmartList, 1, 230)
_GUICtrlListView_SetColumnWidth($g_idSmartList, 2, 70)
_GUICtrlListView_SetColumnWidth($g_idSmartList, 3, 70)
_GUICtrlListView_SetColumnWidth($g_idSmartList, 4, 70)
_GUICtrlListView_SetColumnWidth($g_idSmartList, 5, 440)
_GUICtrlListView_SetColumnWidth($g_idSmartList, 6, 150)
_GUICtrlListView_SetExtendedListViewStyle($g_idSmartList, BitOR($LVS_EX_FULLROWSELECT, $LVS_EX_GRIDLINES))
$g_idSmartNote = GUICtrlCreateLabel("", 25, 754, 1090, 36)

GUICtrlCreateTabItem("分区与卷")
$g_idVolList = GUICtrlCreateListView("盘符|卷标|文件系统|总容量|可用空间|已用|类型|所属磁盘|健康|卷序列号", 25, 605, 1090, 145)
_GUICtrlListView_SetColumnWidth($g_idVolList, 0, 60)
_GUICtrlListView_SetColumnWidth($g_idVolList, 1, 150)
_GUICtrlListView_SetColumnWidth($g_idVolList, 2, 90)
_GUICtrlListView_SetColumnWidth($g_idVolList, 3, 110)
_GUICtrlListView_SetColumnWidth($g_idVolList, 4, 110)
_GUICtrlListView_SetColumnWidth($g_idVolList, 5, 80)
_GUICtrlListView_SetColumnWidth($g_idVolList, 6, 110)
_GUICtrlListView_SetColumnWidth($g_idVolList, 7, 110)
_GUICtrlListView_SetColumnWidth($g_idVolList, 8, 90)
_GUICtrlListView_SetColumnWidth($g_idVolList, 9, 170)
_GUICtrlListView_SetExtendedListViewStyle($g_idVolList, BitOR($LVS_EX_FULLROWSELECT, $LVS_EX_GRIDLINES))
$g_idVolNote = GUICtrlCreateLabel("", 25, 754, 1090, 36)

GUICtrlCreateTabItem("分区表")
$g_idPartList = GUICtrlCreateListView("磁盘|分区|类型|大小|起始偏移|启动|主分区|设备名", 25, 605, 1090, 145)
_GUICtrlListView_SetColumnWidth($g_idPartList, 0, 60)
_GUICtrlListView_SetColumnWidth($g_idPartList, 1, 60)
_GUICtrlListView_SetColumnWidth($g_idPartList, 2, 200)
_GUICtrlListView_SetColumnWidth($g_idPartList, 3, 120)
_GUICtrlListView_SetColumnWidth($g_idPartList, 4, 150)
_GUICtrlListView_SetColumnWidth($g_idPartList, 5, 60)
_GUICtrlListView_SetColumnWidth($g_idPartList, 6, 80)
_GUICtrlListView_SetColumnWidth($g_idPartList, 7, 340)
_GUICtrlListView_SetExtendedListViewStyle($g_idPartList, BitOR($LVS_EX_FULLROWSELECT, $LVS_EX_GRIDLINES))
$g_idPartNote = GUICtrlCreateLabel("", 25, 754, 1090, 36)

GUICtrlCreateTabItem("数据源状态")
$g_idSourceList = GUICtrlCreateListView("数据源|状态|说明", 25, 605, 1090, 145)
_GUICtrlListView_SetColumnWidth($g_idSourceList, 0, 290)
_GUICtrlListView_SetColumnWidth($g_idSourceList, 1, 90)
_GUICtrlListView_SetColumnWidth($g_idSourceList, 2, 690)
_GUICtrlListView_SetExtendedListViewStyle($g_idSourceList, BitOR($LVS_EX_FULLROWSELECT, $LVS_EX_GRIDLINES))
$g_idSourceNote = GUICtrlCreateLabel("", 25, 754, 1090, 36)

GUICtrlCreateTabItem("")

; 托盘
$g_idTrayShow = TrayCreateItem("显示 / 隐藏窗口")
TrayItemSetOnEvent($g_idTrayShow, "_OnTrayToggle")
TrayCreateItem("")
$g_idTrayExit = TrayCreateItem("退出")
TrayItemSetOnEvent($g_idTrayExit, "_OnQuit")
TraySetOnEvent($TRAY_EVENT_PRIMARYDOUBLE, "_OnTrayToggle")
TraySetToolTip("磁盘参数与健康检测")

GUICtrlSetOnEvent($g_idRefresh, "_OnRefresh")
GUICtrlSetOnEvent($g_idExport, "_OnExport")
GUICtrlSetOnEvent($g_idDump, "_OnDump")
GUICtrlSetOnEvent($g_idElevate, "_RestartElevated")
GUIRegisterMsg($WM_NOTIFY, "_WM_NOTIFY")

GUISetState(@SW_SHOW, $g_hGui)
_OnRefresh()

While 1
    Sleep(50)
WEnd

; ---------------------------------------------------------------------- 刷新
Func _OnRefresh()
    If $g_bRefreshing Then Return
    $g_bRefreshing = True
    GUICtrlSetState($g_idRefresh, $GUI_DISABLE)
    GUICtrlSetData($g_idSummary, "正在采集磁盘数据……")
    GUICtrlSetColor($g_idSummary, 0x000000)
    AdlibRegister("_DoRefresh", 60)
EndFunc   ;==>_OnRefresh

Func _DoRefresh()
    AdlibUnRegister("_DoRefresh")

    If $g_bDemoMode Then
        _Disk_InjectDemoData()
    Else
        _Disk_CollectAll()
    EndIf

    _FillDiskList()
    _FillVolumeList()
    _FillPartList()
    _FillSourceList()

    If UBound($g_aDisks, 1) > 0 Then
        _GUICtrlListView_SetItemSelected($g_idDiskList, 0, True, True)
        _SelectDisk(0)
    Else
        _ClearDetail("未获取到磁盘数据。请看“数据源状态”页，或点击“以管理员身份重启”。")
    EndIf

    _SetSummary()

    If $g_bRawAccess Then
        GUICtrlSetState($g_idElevate, $GUI_HIDE)
    Else
        GUICtrlSetState($g_idElevate, $GUI_SHOW)
    EndIf

    GUICtrlSetState($g_idRefresh, $GUI_ENABLE)
    $g_bRefreshing = False

    ; 首次发现权限受限时，主动询问是否提权（可记住“不再提示”）
    If Not $g_bAskedElevate And Not $g_bDemoMode Then
        $g_bAskedElevate = True
        _MaybeAskElevate()
    EndIf
EndFunc   ;==>_DoRefresh

Func _Cell($sText)
    Return StringReplace($sText, "|", "/")
EndFunc   ;==>_Cell

; 空值要说明原因，不能只显示一个破折号让人猜
Func _Show($sValue, $bAdminNeeded = False)
    Local $sText = StringStripWS($sValue, 3)
    If $sText <> "" And $sText <> "—" Then Return $sText
    If $bAdminNeeded And Not $g_bRawAccess Then Return "—（需管理员权限）"
    Return "—（该硬盘/驱动未提供）"
EndFunc   ;==>_Show

Func _FillDiskList()
    _GUICtrlListView_DeleteAllItems($g_idDiskList)
    For $i = 0 To UBound($g_aDisks, 1) - 1
        Local $sRow = "磁盘 " & $g_aDisks[$i][$D_ID] & "|" & _Cell($g_aDisks[$i][$D_MODEL]) & "|" & _
                _Disk_FmtSize($g_aDisks[$i][$D_SIZE]) & "|" & $g_aDisks[$i][$D_VERDICT]
        GUICtrlCreateListViewItem($sRow, $g_idDiskList)
    Next
EndFunc   ;==>_FillDiskList

; 右侧：把选中磁盘的全部字段铺开
Func _SelectDisk($iRow)
    If $iRow < 0 Or $iRow >= UBound($g_aDisks, 1) Then Return
    $g_iSelectedDisk = $iRow

    _GUICtrlListView_DeleteAllItems($g_idDetailList)
    Local $a = $g_aDisks

    ; 顺序刻意先放“健康 / 可靠性”，再放基本参数：
    ; 这两块才是这台工具存在的理由，不能让它们被十几行基本参数挤到折叠线以下。
    _DetailAdd("── 健康 ──", "")
    _DetailAdd("综合结论", $a[$iRow][$D_VERDICT])
    _DetailAdd("健康状态", _Show($a[$iRow][$D_HEALTH], True))
    _DetailAdd("运行状态", _Show($a[$iRow][$D_OPSTATUS], True))
    _DetailAdd("SMART 预测故障", _Show($a[$iRow][$D_SMART], True))
    _DetailAdd("原始磁盘访问", _Show($a[$iRow][$D_RAWDISK]))

    _DetailAdd("── 可靠性计数 ──", "")
    _DetailAdd("当前温度", _Disk_FmtNum($a[$iRow][$D_TEMP], "°C"))
    _DetailAdd("历史最高温度", _Disk_FmtNum($a[$iRow][$D_TEMPMAX], "°C"))
    _DetailAdd("通电时间", _Disk_FmtHours(_Disk_Num($a[$iRow][$D_POWERON])))
    _DetailAdd("磨损度", _Disk_FmtNum($a[$iRow][$D_WEAR], "%"))
    _DetailAdd("启停次数 / 设计上限", _Disk_FmtNum($a[$iRow][$D_STARTSTOP]) & " / " & _Disk_FmtNum($a[$iRow][$D_STARTSTOPMAX]))
    _DetailAdd("加载卸载 / 设计上限", _Disk_FmtNum($a[$iRow][$D_LOADUNLOAD]) & " / " & _Disk_FmtNum($a[$iRow][$D_LOADUNLOADMAX]))
    _DetailAdd("读错误 总 / 已纠正 / 不可纠正", _Disk_FmtNum($a[$iRow][$D_READTOTAL]) & " / " & _Disk_FmtNum($a[$iRow][$D_READCORR]) & " / " & _Disk_FmtNum($a[$iRow][$D_READERR]))
    _DetailAdd("写错误 总 / 已纠正 / 不可纠正", _Disk_FmtNum($a[$iRow][$D_WRITETOTAL]) & " / " & _Disk_FmtNum($a[$iRow][$D_WRITECORR]) & " / " & _Disk_FmtNum($a[$iRow][$D_WRITEERR]))
    _DetailAdd("最大延迟 读 / 写 / 刷新", _Disk_FmtNum($a[$iRow][$D_READLAT], "ms") & " / " & _Disk_FmtNum($a[$iRow][$D_WRITELAT], "ms") & " / " & _Disk_FmtNum($a[$iRow][$D_FLUSHLAT], "ms"))
    _DetailAdd("生产日期", _Show($a[$iRow][$D_MANUDATE], True))
    _DetailAdd("SMART 属性条数", String(_CountSmart($iRow)))

    _DetailAdd("── 基本参数 ──", "")
    _DetailAdd("磁盘序号", String($a[$iRow][$D_ID]))
    _DetailAdd("型号", _Show($a[$iRow][$D_MODEL]))
    _DetailAdd("介质类型", _Show($a[$iRow][$D_MEDIA], True))
    _DetailAdd("容量", _Disk_FmtSize($a[$iRow][$D_SIZE]))
    _DetailAdd("接口 / 总线", _Show($a[$iRow][$D_BUS], True))
    _DetailAdd("转速", _Disk_SpeedText($a[$iRow][$D_SPEED]))
    _DetailAdd("固件版本", _Show($a[$iRow][$D_FIRMWARE]))
    _DetailAdd("序列号", _Show($a[$iRow][$D_SERIAL]))
    _DetailAdd("分区样式", _Show($a[$iRow][$D_PARTSTYLE]))
    _DetailAdd("分区数量", _Show($a[$iRow][$D_PARTITIONS]))
    _DetailAdd("扇区大小", _Disk_FmtNum($a[$iRow][$D_SECTORSIZE], "字节"))
    _DetailAdd("用途", _Show($a[$iRow][$D_USAGE], True))
    _DetailAdd("物理位置", _Show($a[$iRow][$D_LOCATION], True))
    _DetailAdd("设备能力", _Show($a[$iRow][$D_CAPS]))
    _DetailAdd("设备实例", _Show($a[$iRow][$D_PNPID]))

    _FillSmartList($iRow)
EndFunc   ;==>_SelectDisk

Func _DetailAdd($sName, $sValue)
    GUICtrlCreateListViewItem(_Cell($sName) & "|" & _Cell($sValue), $g_idDetailList)
EndFunc   ;==>_DetailAdd

Func _ClearDetail($sMessage)
    _GUICtrlListView_DeleteAllItems($g_idDetailList)
    _DetailAdd("提示", $sMessage)
    _GUICtrlListView_DeleteAllItems($g_idSmartList)
    GUICtrlSetData($g_idSmartNote, $sMessage)
EndFunc   ;==>_ClearDetail

Func _CountSmart($iDiskRow)
    Local $iCount = 0
    For $r = 0 To UBound($g_aSmart, 1) - 1
        If $g_aSmart[$r][$SM_DISK] = $iDiskRow Then $iCount += 1
    Next
    Return $iCount
EndFunc   ;==>_CountSmart

Func _FillSmartList($iDiskRow)
    _GUICtrlListView_DeleteAllItems($g_idSmartList)
    Local $iCount = 0
    For $r = 0 To UBound($g_aSmart, 1) - 1
        If $g_aSmart[$r][$SM_DISK] = $iDiskRow Then
            GUICtrlCreateListViewItem(String($g_aSmart[$r][$SM_ID]) & "|" & _Cell($g_aSmart[$r][$SM_NAME]) & "|" & _
                    String($g_aSmart[$r][$SM_CUR]) & "|" & String($g_aSmart[$r][$SM_WORST]) & "|" & _
                    String($g_aSmart[$r][$SM_THRESH]) & "|" & String($g_aSmart[$r][$SM_RAW]) & "|" & _
                    $g_aSmart[$r][$SM_STATE], $g_idSmartList)
            $iCount += 1
        EndIf
    Next

    If $iCount > 0 Then
        GUICtrlSetData($g_idSmartNote, "共 " & $iCount & " 条 SMART 属性。阈值列大于 0 且“当前”不大于阈值即为警告；" & _
                "5/187/197/198/199 等关键属性原始值非 0 会标为注意。")
    ElseIf $g_bRawAccess Then
        GUICtrlSetData($g_idSmartNote, "该硬盘没有 ATA SMART 属性表（NVMe 硬盘属正常，请看上面的“可靠性计数”；" & _
                "RAID 控制器后面的硬盘也可能读不到）。")
    Else
        GUICtrlSetData($g_idSmartNote, "未取得 SMART 属性表：需要管理员权限。点击右上角“以管理员身份重启”后重试。")
    EndIf
EndFunc   ;==>_FillSmartList

Func _FillVolumeList()
    _GUICtrlListView_DeleteAllItems($g_idVolList)
    Local $iLocalSize = 0, $iLocalFree = 0
    For $i = 0 To UBound($g_aVols, 1) - 1
        GUICtrlCreateListViewItem($g_aVols[$i][$V_LETTER] & "|" & _Cell($g_aVols[$i][$V_LABEL]) & "|" & _
                $g_aVols[$i][$V_FS] & "|" & $g_aVols[$i][$V_SIZE] & "|" & $g_aVols[$i][$V_FREE] & "|" & _
                $g_aVols[$i][$V_USEDPCT] & "|" & $g_aVols[$i][$V_TYPE] & "|" & _Show($g_aVols[$i][$V_DISK]) & "|" & _
                _Show($g_aVols[$i][$V_HEALTH]) & "|" & $g_aVols[$i][$V_SERIAL], $g_idVolList)
        If $g_aVols[$i][$V_TYPE] = "本地磁盘" Then
            $iLocalSize += _Disk_Num($g_aVols[$i][$V_SIZEB])
            $iLocalFree += _Disk_Num($g_aVols[$i][$V_FREEB])
        EndIf
    Next

    Local $sNote = "本地磁盘合计 " & _Disk_FmtSize($iLocalSize) & "，可用 " & _Disk_FmtSize($iLocalFree)
    If $iLocalSize > 0 Then
        $sNote &= StringFormat("（已用 %.1f%%）", (1 - $iLocalFree / $iLocalSize) * 100)
    EndIf
    GUICtrlSetData($g_idVolNote, $sNote)
EndFunc   ;==>_FillVolumeList

Func _FillPartList()
    _GUICtrlListView_DeleteAllItems($g_idPartList)
    For $i = 0 To UBound($g_aParts, 1) - 1
        GUICtrlCreateListViewItem("磁盘 " & $g_aParts[$i][$P_DISK] & "|" & $g_aParts[$i][$P_INDEX] & "|" & _
                _Cell($g_aParts[$i][$P_TYPE]) & "|" & _Disk_FmtSize($g_aParts[$i][$P_SIZE]) & "|" & _
                _Disk_FmtSize($g_aParts[$i][$P_OFFSET]) & "|" & $g_aParts[$i][$P_BOOTABLE] & "|" & _
                $g_aParts[$i][$P_PRIMARY] & "|" & _Cell($g_aParts[$i][$P_NAME]), $g_idPartList)
    Next
    GUICtrlSetData($g_idPartNote, "共 " & UBound($g_aParts, 1) & " 个分区。“启动=是”表示该分区标记为活动/启动分区。")
EndFunc   ;==>_FillPartList

Func _FillSourceList()
    _GUICtrlListView_DeleteAllItems($g_idSourceList)
    For $i = 0 To UBound($g_aSources, 1) - 1
        GUICtrlCreateListViewItem(_Cell($g_aSources[$i][$S_NAME]) & "|" & $g_aSources[$i][$S_STATE] & "|" & _
                _Cell($g_aSources[$i][$S_DETAIL]), $g_idSourceList)
    Next

    Local $sNote = "数据源速查：root\cimv2 给基础参数（普通权限）；Storage 命名空间给 SSD/HDD 判定、健康、温度、磨损（需管理员）；" & _
            "root\wmi 给 SMART 预测与属性表（需管理员）；原始磁盘访问决定能否读深度 SMART。"
    If Not $g_bRawAccess Then
        $sNote &= "  当前权限受限：点击右上角“以管理员身份重启”可获得完整数据。"
    EndIf
    GUICtrlSetData($g_idSourceNote, $sNote)
EndFunc   ;==>_FillSourceList

Func _SetSummary()
    Local $iDisks = UBound($g_aDisks, 1)
    Local $iBytes = 0, $iWarn = 0, $iWatch = 0
    For $i = 0 To $iDisks - 1
        $iBytes += _Disk_Num($g_aDisks[$i][$D_SIZE])
        If $g_aDisks[$i][$D_VERDICT] = "警告" Or $g_aDisks[$i][$D_VERDICT] = "严重" Then
            $iWarn += 1
        ElseIf $g_aDisks[$i][$D_VERDICT] = "注意" Then
            $iWatch += 1
        EndIf
    Next

    Local $sPerm = "权限：受限（SMART 深度数据需要管理员）"
    If $g_bRawAccess Then $sPerm = "权限：充足（原始磁盘可读）"
    If $g_bDemoMode Then $sPerm = "权限：演示数据（非真实硬件）"

    Local $sText = $sPerm & "    ·    磁盘 " & $iDisks & " 块，合计 " & _Disk_FmtSize($iBytes) & _
            "    ·    分区 " & UBound($g_aParts, 1) & " 个，卷 " & UBound($g_aVols, 1) & " 个" & _
            "    ·    采集于 " & @HOUR & ":" & @MIN & ":" & @SEC
    If $iDisks > 0 Then
        If $iWarn > 0 Then
            $sText &= "    ·    需要关注 " & $iWarn & " 块"
        ElseIf $iWatch > 0 Then
            $sText &= "    ·    指标偏高 " & $iWatch & " 块"
        Else
            $sText &= "    ·    未发现异常指标"
        EndIf
    EndIf
    GUICtrlSetData($g_idSummary, $sText)

    If $iDisks = 0 Then
        GUICtrlSetColor($g_idSummary, 0xB00000)
    ElseIf $iWarn > 0 Then
        GUICtrlSetColor($g_idSummary, 0xB00000)
    ElseIf $iWatch > 0 Then
        GUICtrlSetColor($g_idSummary, 0xC06000)
    Else
        GUICtrlSetColor($g_idSummary, 0x007000)
    EndIf
EndFunc   ;==>_SetSummary

; ------------------------------------------------------------------ 交互事件
Func _WM_NOTIFY($hWnd, $iMsg, $wParam, $lParam)
    Local $tNMHDR = DllStructCreate($tagNMHDR, $lParam)
    Local $hFrom = HWnd(DllStructGetData($tNMHDR, "hWndFrom"))
    Local $iCode = DllStructGetData($tNMHDR, "Code")

    If $hFrom = $g_idDiskList And $iCode = $LVN_ITEMCHANGED Then
        Local $iSel = _GUICtrlListView_GetNextItem($g_idDiskList, -1, $LVNI_SELECTED)
        If $iSel >= 0 And $iSel < UBound($g_aDisks, 1) Then _SelectDisk($iSel)
    EndIf

    Return $GUI_RUNDEFMSG
EndFunc   ;==>_WM_NOTIFY

Func _MaybeAskElevate()
    If IniRead($g_sIni, "gui", "askElevate", "True") <> "True" Then Return

    Local $iAnswer = MsgBox(BitOR($MB_ICONQUESTION, $MB_YESNOCANCEL), "权限受限", _
            "当前以普通权限运行，以下数据拿不到：" & @CRLF & _
            "SSD/HDD 判定、健康状态、温度、通电时间、磨损度、SMART 属性表。" & @CRLF & @CRLF & _
            "是否以管理员身份重新启动以获取完整数据？" & @CRLF & @CRLF & _
            "是 = 提权重启    否 = 先看现有数据    取消 = 以后不再提示")
    Switch $iAnswer
        Case $IDYES
            _RestartElevated()
        Case $IDCANCEL
            IniWrite($g_sIni, "gui", "askElevate", "False")
    EndSwitch
EndFunc   ;==>_MaybeAskElevate

Func _RestartElevated()
    If @Compiled Then
        ShellExecute(@ScriptFullPath, "", @ScriptDir, "runas")
    Else
        ShellExecute(@AutoItExe, '"' & @ScriptFullPath & '"', @ScriptDir, "runas")
    EndIf
    If @error Then
        MsgBox(BitOR($MB_ICONERROR, $MB_OK), "提权失败", "提权请求被取消或被系统拒绝。")
        Return
    EndIf
    Exit
EndFunc   ;==>_RestartElevated

Func _OnExport()
    Local $sReport = _Disk_BuildReport()
    Local $sDefault = "diskinfo_" & @YEAR & @MON & @MDAY & "_" & @HOUR & @MIN & ".txt"
    Local $sPath = FileSaveDialog("保存磁盘报告", @ScriptDir, "文本文件 (*.txt)", $FD_PATHMUSTEXIST, $sDefault)
    If @error Or $sPath = "" Then Return
    If _WriteUtf8($sPath, $sReport) Then
        MsgBox(BitOR($MB_ICONINFORMATION, $MB_OK), "导出成功", "报告已保存到：" & @CRLF & $sPath)
    Else
        MsgBox(BitOR($MB_ICONERROR, $MB_OK), "导出失败", "无法写入文件：" & @CRLF & $sPath)
    EndIf
EndFunc   ;==>_OnExport

Func _OnDump()
    Local $sPath = @ScriptDir & "\..\out\diskinfo-dump.txt"
    If _Disk_DumpAll($sPath) Then
        MsgBox(BitOR($MB_ICONINFORMATION, $MB_OK), "诊断已导出", _
                "已把 Windows 能提供的全部原始磁盘字段写入：" & @CRLF & $sPath & @CRLF & @CRLF & _
                "如果界面上仍有字段显示缺失，把这个文件发给开发者即可定位原因。")
    Else
        MsgBox(BitOR($MB_ICONERROR, $MB_OK), "导出失败", "无法写入：" & @CRLF & $sPath)
    EndIf
EndFunc   ;==>_OnDump

Func _OnMinimize()
    GUISetState(@SW_HIDE, $g_hGui)
    TrayTip("磁盘参数与健康检测", "窗口已最小化到托盘，双击托盘图标可恢复。", 3)
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

Func _OnQuit()
    Exit
EndFunc   ;==>_OnQuit

Func _WriteUtf8($sPath, $sText)
    Local $hFile = FileOpen($sPath, $FO_OVERWRITE + $FO_CREATEPATH + $FO_UTF8)
    If $hFile = -1 Then Return False
    FileWrite($hFile, $sText)
    FileClose($hFile)
    Return True
EndFunc   ;==>_WriteUtf8

; -------------------------------------------------------------- 命令行实现
; 0=成功，3=没取到磁盘数据，1=写文件失败
; $bHistory=True 时额外留一份带时间戳的副本（人工导出用；自检不留，避免 out 目录堆积）
Func _RunReport($bDemo = False, $bHistory = True)
    If $bDemo Then
        _Disk_InjectDemoData()
    Else
        _Disk_CollectAll()
    EndIf
    Local $sReport = _Disk_BuildReport()

    Local $sOutDir = @ScriptDir & "\..\out"
    If Not FileExists($sOutDir) Then DirCreate($sOutDir)

    Local $sName = "diskinfo.txt"
    If $bDemo Then $sName = "diskinfo-demo.txt"

    If Not _WriteUtf8($sOutDir & "\" & $sName, $sReport) Then Return 1
    If $bHistory Then
        _WriteUtf8($sOutDir & "\diskinfo_" & @YEAR & @MON & @MDAY & "_" & @HOUR & @MIN & @SEC & ".txt", $sReport)
    EndIf
    ConsoleWrite($sReport & @CRLF)

    If UBound($g_aDisks, 1) = 0 Then Return 3
    Return 0
EndFunc   ;==>_RunReport

Func _RunDump()
    _Disk_CollectAll()
    Local $sOutDir = @ScriptDir & "\..\out"
    If Not FileExists($sOutDir) Then DirCreate($sOutDir)
    If _Disk_DumpAll($sOutDir & "\diskinfo-dump.txt") Then Return 0
    Return 1
EndFunc   ;==>_RunDump

; 自检：逻辑断言 + 合成数据 + 真实采集的优雅降级
Func _RunSelfTest()
    _SelfLog("=== DiskInfo 自检 ===")

    _AssertTest("容量格式化 0", _Disk_FmtSize(0) = "—")
    _AssertTest("容量格式化 1KB", _Disk_FmtSize(1024) = "1 KB")
    _AssertTest("容量格式化 500MB", _Disk_FmtSize(524288000) = "500 MB")
    _AssertTest("容量格式化 1GB", _Disk_FmtSize(1073741824) = "1 GB")
    _AssertTest("容量格式化 1.5GB", _Disk_FmtSize(1610612736) = "1.5 GB")
    _AssertTest("容量格式化 2TB", _Disk_FmtSize(2199023255552) = "2 TB")
    _AssertTest("介质类型 SSD", _Disk_MediaName(4) = "固态硬盘 SSD")
    _AssertTest("介质类型 HDD", _Disk_MediaName(3) = "机械硬盘 HDD")
    _AssertTest("总线 NVMe", _Disk_BusName(17) = "NVMe")
    _AssertTest("总线 SATA", _Disk_BusName(11) = "SATA")
    _AssertTest("健康状态 Healthy", _Disk_HealthName(0) = "Healthy")
    _AssertTest("运行状态 OK", _Disk_OpStatusOne(2) = "OK")
    _AssertTest("转速 7200", _Disk_SpeedText("7200") = "7200 转/分")
    _AssertTest("通电时间 0", _Disk_FmtHours(0) = "—")
    _AssertTest("通电时间 24", _Disk_FmtHours(24) = "24 小时 / 1 天")
    _AssertTest("SMART 属性名 5", _Disk_SmartAttrName(5) = "重映射扇区计数")
    _AssertTest("SMART 关键属性 197", _Disk_SmartIsCritical(197))
    _AssertTest("SMART 非关键属性 194", Not _Disk_SmartIsCritical(194))

    _AssertTest("全部正常 -> 正常", _Disk_Verdict(_MakeTestDisks("Healthy", "", "", ""), 0) = "正常")
    _AssertTest("温度 65 度 -> 注意", _Disk_Verdict(_MakeTestDisks("Healthy", "65", "", ""), 0) = "注意")
    _AssertTest("温度 75 度 -> 警告", _Disk_Verdict(_MakeTestDisks("Healthy", "75", "", ""), 0) = "警告")
    _AssertTest("磨损 85% -> 注意", _Disk_Verdict(_MakeTestDisks("Healthy", "", "85", ""), 0) = "注意")
    _AssertTest("磨损 95% -> 警告", _Disk_Verdict(_MakeTestDisks("Healthy", "", "95", ""), 0) = "警告")
    _AssertTest("SMART 预测故障 -> 严重", _Disk_Verdict(_MakeTestDisks("Healthy", "", "", "预测故障"), 0) = "严重")
    _AssertTest("健康状态 Unhealthy -> 严重", _Disk_Verdict(_MakeTestDisks("Unhealthy", "", "", ""), 0) = "严重")
    _AssertTest("不可纠正错误 -> 警告", _Disk_Verdict(_MakeTestDisks("Healthy", "", "", "", "3"), 0) = "警告")

    ; ---- 真实采集：权限不足也必须优雅降级 ----
    Local $iDisks = _Disk_CollectAll()
    _SelfLog("真实采集：磁盘 " & $iDisks & " 块，分区 " & UBound($g_aParts, 1) & " 个，卷 " & UBound($g_aVols, 1) & " 个，SMART 属性 " & UBound($g_aSmart, 1) & " 条")

    Local $sReport = _Disk_BuildReport()
    _AssertTest("报告包含标题", StringInStr($sReport, "磁盘参数与健康报告") > 0)
    _AssertTest("报告包含数据源状态段", StringInStr($sReport, "【数据源状态】") > 0)
    _AssertTest("报告包含总体结论段", StringInStr($sReport, "【总体结论】") > 0)
    _AssertTest("报告包含分区段", StringInStr($sReport, "【分区】") > 0)
    _AssertTest("报告已记录数据源条目", UBound($g_aSources, 1) > 0)

    Local $bStateOk = True
    For $i = 0 To UBound($g_aSources, 1) - 1
        If $g_aSources[$i][$S_STATE] = "不可用" And StringStripWS($g_aSources[$i][$S_DETAIL], 3) = "" Then $bStateOk = False
    Next
    _AssertTest("不可用的数据源都写明了原因", $bStateOk)

    If $iDisks = 0 Then
        _SelfLog("[info] 本次没有取到磁盘数据（权限受限时会这样），已确认报告给出明确说明。")
        _AssertTest("无数据时报告给出说明", StringInStr($sReport, "无法读取磁盘数据") > 0 Or StringInStr($sReport, "未能获取磁盘信息") > 0)
    Else
        Local $bSane = True
        For $i = 0 To $iDisks - 1
            If StringStripWS($g_aDisks[$i][$D_ID], 3) = "" Then $bSane = False
            If _Disk_Num($g_aDisks[$i][$D_SIZE]) <= 0 Then $bSane = False
            If StringStripWS($g_aDisks[$i][$D_VERDICT], 3) = "" Then $bSane = False
        Next
        _AssertTest("每块磁盘都有序号/容量/结论", $bSane)
    EndIf

    _AssertTest("报告文件写出成功(0 或 3)", _RunReport(False, False) = 0 Or _RunReport(False, False) = 3)

    Local $sDumpPath = @ScriptDir & "\..\out\diskinfo-dump.txt"
    FileDelete($sDumpPath)
    _AssertTest("诊断转储写出成功", _RunDump() = 0)
    _AssertTest("诊断转储文件存在", FileExists($sDumpPath))
    Local $sDump = ""
    If FileExists($sDumpPath) Then $sDump = FileRead($sDumpPath)
    _AssertTest("诊断含命名空间标题", StringInStr($sDump, "命名空间") > 0)
    _AssertTest("诊断含原始设备探测", StringInStr($sDump, "原始磁盘设备访问探测") > 0)

    ; ---- 合成数据：把“真的有磁盘”的整条路径也测掉 ----
    Local $iDemo = _Disk_InjectDemoData()
    _AssertTest("演示数据 3 块磁盘", $iDemo = 3)
    _AssertTest("演示数据 5 个分区", UBound($g_aParts, 1) = 5)
    _AssertTest("演示数据 3 个卷", UBound($g_aVols, 1) = 3)
    _AssertTest("演示数据 16 条 SMART 属性", UBound($g_aSmart, 1) = 16)
    _AssertTest("演示磁盘0 结论=正常", $g_aDisks[0][$D_VERDICT] = "正常")
    _AssertTest("演示磁盘1 结论=警告(写入不可纠正+属性198)", $g_aDisks[1][$D_VERDICT] = "警告")
    _AssertTest("演示磁盘2 结论=严重(SMART 预测故障)", $g_aDisks[2][$D_VERDICT] = "严重")
    _AssertTest("演示卷已对应物理磁盘", $g_aVols[0][$V_DISK] = "磁盘 0")

    Local $sDemoReport = _Disk_BuildReport()
    _AssertTest("演示报告含磁盘型号", StringInStr($sDemoReport, "Samsung SSD 990 PRO 1TB") > 0)
    _AssertTest("演示报告含 SMART 属性表", StringInStr($sDemoReport, "[SMART 属性]") > 0)
    _AssertTest("演示报告含重映射扇区计数", StringInStr($sDemoReport, "重映射扇区计数") > 0)
    _AssertTest("演示报告含健康结论", StringInStr($sDemoReport, "综合结论") > 0 And StringInStr($sDemoReport, "严重") > 0)
    _AssertTest("演示报告提示需要关注", StringInStr($sDemoReport, "需要关注") > 0)
    _AssertTest("演示报告含分区行", StringInStr($sDemoReport, "C:") > 0 And StringInStr($sDemoReport, "NTFS") > 0)
    _AssertTest("演示报告标明是演示数据", StringInStr($sDemoReport, "演示") > 0)
    _AssertTest("演示报告文件写出成功", _RunReport(True, False) = 0)
    _AssertTest("演示报告单独成文件", FileExists(@ScriptDir & "\..\out\diskinfo-demo.txt"))

    _SelfLog("")
    If $g_iSelftestFail = 0 Then
        _SelfLog("自检结果：全部通过")
    Else
        _SelfLog("自检结果：失败 " & $g_iSelftestFail & " 项")
    EndIf
    Return $g_iSelftestFail
EndFunc   ;==>_RunSelfTest

; 造一行二维测试数据（AutoIt 不能用 $a[$i] 取二维数组的一行）
Func _MakeTestDisks($sHealth, $sTemp, $sWear, $sSmart, $sReadErr = "")
    Local $aDisks[1][$D_COLS]
    $aDisks[0][$D_HEALTH] = $sHealth
    $aDisks[0][$D_TEMP] = $sTemp
    $aDisks[0][$D_WEAR] = $sWear
    $aDisks[0][$D_SMART] = $sSmart
    $aDisks[0][$D_READERR] = $sReadErr
    Return $aDisks
EndFunc   ;==>_MakeTestDisks

Func _AssertTest($sName, $bOk)
    If $bOk Then
        _SelfLog("[ ok ] " & $sName)
    Else
        _SelfLog("[FAIL] " & $sName)
        $g_iSelftestFail += 1
    EndIf
EndFunc   ;==>_AssertTest

Func _SelfLog($sText)
    ConsoleWrite($sText & @CRLF)
    Local $sDir = @ScriptDir & "\..\out"
    If Not FileExists($sDir) Then DirCreate($sDir)
    Local $hFile = FileOpen($sDir & "\diskinfo-selftest.log", $FO_APPEND + $FO_CREATEPATH + $FO_UTF8)
    If $hFile <> -1 Then
        FileWrite($hFile, $sText & @CRLF)
        FileClose($hFile)
    EndIf
EndFunc   ;==>_SelfLog
