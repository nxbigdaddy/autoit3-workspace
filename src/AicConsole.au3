; AicConsole.au3 - aic（本机多 Agent 编码调度器）的 AutoIt 控制台
;
;   运行     : au3 src\AicConsole.au3
;   自检     : au3 src\AicConsole.au3 /selftest
;   演示环境 : au3 src\AicConsole.au3 /demo      （造一份假的 ~/.aic 并输出摘要）
;   演示界面 : au3 src\AicConsole.au3 /demogui   （用假环境开界面，用于回归测试）
;   指定目录 : au3 src\AicConsole.au3 /home D:\tmp\aic-home /repo <workspace>\AI-C
;   编译     : au3build src\AicConsole.au3
;
; 界面结构：
;   顶部  : aic 目录 / 仓库路径 + 刷新 / 自动刷新 / 新建配置 / 保存配置 + 状态汇总
;   左    : 运行列表（读取 ~/.aic/runs/*/state.json）
;   中    : 任务板（编号/标题/种类/状态/agent/依赖）
;   右页签: 任务详情（含原始 JSON 字段）、日志（跟随文件尾部）
;   下页签: 模型与 Agent 配置、控制（插话/取消）、数据源与诊断
;
; 写文件的边界：只写 ~/.aic/agents.yaml、~/.aic/config.yaml、<repo>/.aic/project.yaml
; 与 ~/.aic/runs/<id>/control.json；不碰仓库业务代码，也不碰 aic 的其它文件。

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
#include <ComboConstants.au3>
#include <GuiEdit.au3>
#include <GuiListView.au3>
#include <GuiComboBox.au3>
#include <Array.au3>
#include "lib\MiniYaml.au3"
#include "lib\MiniJson.au3"
#include "lib\AicConfig.au3"
#include "lib\AicRuns.au3"

Opt("GUIOnEventMode", 1)
Opt("TrayMenuMode", 3)
Opt("TrayOnEventMode", 1)
Opt("MustDeclareVars", 1)

; ------------------------------------------------------------------ 全局状态
; 所有 Global 必须在命令行分支之前（AutoIt 的全局是“执行到那里”才存在的）
Global $g_iFail = 0
Global $g_bDemo = False
Global $g_bAutoRefresh = True
Global $g_iTickCount = 0
Global $g_sLastStateTime = ""
Global $g_bLoading = False

Global $g_hGui, $g_idHome, $g_idRepo, $g_idBrowseHome, $g_idBrowseRepo, $g_idRefresh, $g_idAuto
Global $g_idSummary, $g_idMessage
Global $g_idRunList, $g_idTaskList
Global $g_idRightTabs, $g_idDetail, $g_idLogList, $g_idLogCombo, $g_idLogEdit, $g_idFollow
Global $g_idBottomTabs
Global $g_idStall, $g_idHostCmd, $g_idAgentList, $g_idEditName, $g_idEditModel, $g_idEditCmd, $g_idCmdPreview
Global $g_idFitPlan, $g_idFitWrite, $g_idFitReview, $g_idFitIntegrate, $g_idEditProjFit
Global $g_idAgentAdd, $g_idAgentDel, $g_idAgentApply, $g_idSaveAgents, $g_idSaveGlobal, $g_idSaveProject, $g_idSeed
Global $g_idCtrlTaskLabel, $g_idCancelReason, $g_idCancelTask, $g_idCancelRun
Global $g_idQuestion, $g_idAnswer, $g_idAnswerSend, $g_idCtrlLog
Global $g_idDiag, $g_idTrayShow, $g_idTrayExit
Global $g_iEditingAgent = -1
Global $g_sActiveTaskId = ""

; ------------------------------------------------------- 命令行（无界面）模式
If $CmdLine[0] > 0 Then
    Local $i = 1
    While $i <= $CmdLine[0]
        Switch StringLower(StringStripWS($CmdLine[$i], 3))
            Case "/selftest"
                Exit _SelfTest()
            Case "/demo"
                Exit _RunDemo()
            Case "/demogui"
                $g_bDemo = True
            Case "/home"
                If $i < $CmdLine[0] Then
                    $i += 1
                    _Aic_SetHome($CmdLine[$i])
                EndIf
            Case "/repo"
                If $i < $CmdLine[0] Then
                    $i += 1
                    _Aic_SetRepo($CmdLine[$i])
                EndIf
        EndSwitch
        $i += 1
    WEnd
EndIf

; -------------------------------------------------------------------- 创建界面
$g_hGui = GUICreate("aic 控制台 - 多 Agent 编码调度器", 1240, 880, -1, -1, BitOR($WS_OVERLAPPEDWINDOW, $WS_CLIPCHILDREN))
GUISetFont(10, 400, 0, "Microsoft YaHei UI")
GUISetOnEvent($GUI_EVENT_CLOSE, "_OnQuit")
GUISetOnEvent($GUI_EVENT_MINIMIZE, "_OnMinimize")

Local $idTitle = GUICtrlCreateLabel("aic 控制台", 15, 12, 200, 26)
GUICtrlSetFont($idTitle, 13, 700)

GUICtrlCreateLabel("aic 目录", 15, 48, 60, 20)
$g_idHome = GUICtrlCreateInput("", 78, 46, 330, 24)
$g_idBrowseHome = GUICtrlCreateButton("浏览", 412, 45, 60, 26)

GUICtrlCreateLabel("仓库", 484, 48, 40, 20)
$g_idRepo = GUICtrlCreateInput("", 526, 46, 390, 24)
$g_idBrowseRepo = GUICtrlCreateButton("浏览", 920, 45, 60, 26)

$g_idRefresh = GUICtrlCreateButton("刷新", 988, 45, 74, 26)
$g_idAuto = GUICtrlCreateCheckbox("自动刷新(2s)", 1070, 47, 130, 22)
GUICtrlSetState($g_idAuto, $GUI_CHECKED)

$g_idSummary = GUICtrlCreateLabel("准备中……", 15, 78, 1210, 22)

; ---- 左：运行列表 ----
Local $idLblRuns = GUICtrlCreateLabel("运行列表（~/.aic/runs）", 15, 104, 340, 18)
GUICtrlSetColor($idLblRuns, 0x555555)
$g_idRunList = GUICtrlCreateListView("运行 ID|状态|任务|更新时间", 15, 124, 340, 376)
_GUICtrlListView_SetColumnWidth($g_idRunList, 0, 130)
_GUICtrlListView_SetColumnWidth($g_idRunList, 1, 54)
_GUICtrlListView_SetColumnWidth($g_idRunList, 2, 46)
_GUICtrlListView_SetColumnWidth($g_idRunList, 3, 72)
_GUICtrlListView_SetExtendedListViewStyle($g_idRunList, BitOR($LVS_EX_FULLROWSELECT, $LVS_EX_GRIDLINES))

; ---- 中：任务板 ----
Local $idLblTasks = GUICtrlCreateLabel("任务板（state.json）", 365, 104, 390, 18)
GUICtrlSetColor($idLblTasks, 0x555555)
$g_idTaskList = GUICtrlCreateListView("编号|标题|种类|状态|agent|依赖", 365, 124, 390, 376)
_GUICtrlListView_SetColumnWidth($g_idTaskList, 0, 42)
_GUICtrlListView_SetColumnWidth($g_idTaskList, 1, 108)
_GUICtrlListView_SetColumnWidth($g_idTaskList, 2, 46)
_GUICtrlListView_SetColumnWidth($g_idTaskList, 3, 54)
_GUICtrlListView_SetColumnWidth($g_idTaskList, 4, 56)
_GUICtrlListView_SetColumnWidth($g_idTaskList, 5, 64)
_GUICtrlListView_SetExtendedListViewStyle($g_idTaskList, BitOR($LVS_EX_FULLROWSELECT, $LVS_EX_GRIDLINES))

; ---- 右：选中任务的详情（常显，不放在页签里） ----
Local $idLblDetail = GUICtrlCreateLabel("选中任务的详情（含 state.json 原始字段）", 765, 104, 460, 18)
GUICtrlSetColor($idLblDetail, 0x555555)
$g_idDetail = GUICtrlCreateEdit("", 765, 124, 460, 376, BitOR($ES_MULTILINE, $ES_READONLY, $WS_VSCROLL, $ES_AUTOVSCROLL))

; ---- 下：唯一的一个页签控件（日志 / 配置 / 控制 / 诊断） ----
; 注意：一个窗口里只用这一个 Tab 控件。AutoIt 的 GUICtrlCreateTabItem 只会挂到
; 最后创建的 Tab 上，同一窗口放两个 Tab 会出现“标签全挤到一行、另一个页签空着”。
$g_idBottomTabs = GUICtrlCreateTab(15, 510, 1210, 320)

; ===== 日志 =====
GUICtrlCreateTabItem("日志")
GUICtrlCreateLabel("日志文件", 30, 540, 70, 20)
$g_idLogCombo = GUICtrlCreateCombo("", 104, 538, 300, 200, BitOR($CBS_DROPDOWNLIST, $WS_VSCROLL))
$g_idFollow = GUICtrlCreateCheckbox("跟随选中任务的日志", 418, 540, 180, 22)
GUICtrlSetState($g_idFollow, $GUI_CHECKED)
GUICtrlCreateLabel("（只读文件末尾 64 KiB，自动刷新时同步更新）", 610, 542, 420, 20)
GUICtrlSetColor(-1, 0x777777)
$g_idLogEdit = GUICtrlCreateEdit("", 30, 566, 1180, 256, BitOR($ES_MULTILINE, $ES_READONLY, $WS_VSCROLL, $ES_AUTOVSCROLL, $ES_AUTOHSCROLL))

; ===== 模型与 Agent 配置 =====
GUICtrlCreateTabItem("模型与 Agent 配置")
GUICtrlCreateLabel("stall_timeout", 30, 542, 110, 20)
$g_idStall = GUICtrlCreateInput("10m", 145, 540, 110, 24)
GUICtrlCreateLabel("判卡住时长，例 10m / 30s", 262, 544, 200, 20)
GUICtrlSetColor(-1, 0x777777)

GUICtrlCreateLabel("host 命令（每行一个 token）", 30, 572, 300, 20)
$g_idHostCmd = GUICtrlCreateEdit("", 30, 594, 380, 108, BitOR($ES_MULTILINE, $WS_VSCROLL, $ES_AUTOVSCROLL))

GUICtrlCreateLabel("Agent 列表（选中即在右侧编辑）", 430, 542, 340, 20)
$g_idAgentList = GUICtrlCreateListView("名称|模型|fit", 430, 564, 340, 138)
_GUICtrlListView_SetColumnWidth($g_idAgentList, 0, 84)
_GUICtrlListView_SetColumnWidth($g_idAgentList, 1, 100)
_GUICtrlListView_SetColumnWidth($g_idAgentList, 2, 150)
_GUICtrlListView_SetExtendedListViewStyle($g_idAgentList, BitOR($LVS_EX_FULLROWSELECT, $LVS_EX_GRIDLINES))

GUICtrlCreateLabel("最终命令", 430, 712, 80, 20)
Local $idCmdPreview = GUICtrlCreateLabel("", 430, 732, 340, 66)
GUICtrlSetColor($idCmdPreview, 0x006000)
$g_idCmdPreview = $idCmdPreview

GUICtrlCreateLabel("名称", 790, 542, 44, 20)
$g_idEditName = GUICtrlCreateInput("", 836, 540, 130, 24)
$g_idAgentAdd = GUICtrlCreateButton("新增", 974, 539, 74, 26)
$g_idAgentDel = GUICtrlCreateButton("删除", 1054, 539, 74, 26)

GUICtrlCreateLabel("模型", 790, 572, 44, 20)
$g_idEditModel = GUICtrlCreateInput("", 836, 570, 292, 24)

GUICtrlCreateLabel("命令 token（每行一个，首行是可执行文件）", 790, 600, 380, 20)
$g_idEditCmd = GUICtrlCreateEdit("", 790, 622, 420, 82, BitOR($ES_MULTILINE, $WS_VSCROLL, $ES_AUTOVSCROLL))

GUICtrlCreateLabel("fit", 790, 712, 26, 20)
$g_idFitPlan = GUICtrlCreateCheckbox("plan 规划", 822, 710, 86, 22)
$g_idFitWrite = GUICtrlCreateCheckbox("write 实现", 912, 710, 90, 22)
$g_idFitReview = GUICtrlCreateCheckbox("review 审查", 1006, 710, 94, 22)
$g_idFitIntegrate = GUICtrlCreateCheckbox("integrate 集成", 1104, 710, 116, 22)
$g_idAgentApply = GUICtrlCreateButton("应用到列表", 1054, 738, 156, 26)

GUICtrlCreateLabel("项目级覆盖（写 <仓库>\.aic\project.yaml）", 30, 712, 380, 20)
$g_idEditProjFit = GUICtrlCreateInput("", 30, 734, 380, 24)
GUICtrlCreateLabel("留空 = 该项目不覆盖该 agent", 30, 762, 380, 20)
GUICtrlSetColor(-1, 0x777777)

$g_idSaveAgents = GUICtrlCreateButton("保存 agents.yaml", 30, 790, 160, 28)
$g_idSaveGlobal = GUICtrlCreateButton("保存 config.yaml", 198, 790, 160, 28)
$g_idSaveProject = GUICtrlCreateButton("保存 project.yaml", 366, 790, 160, 28)
$g_idSeed = GUICtrlCreateButton("从模板新建配置", 534, 790, 180, 28)
Local $idSaveHint = GUICtrlCreateLabel("保存只覆盖 command / fit / model / stall_timeout，其它键与类型原样保留", 726, 796, 480, 20)
GUICtrlSetColor($idSaveHint, 0x777777)

; ===== 控制 =====
GUICtrlCreateTabItem("控制（插话 / 取消）")
GUICtrlCreateLabel("选中任务", 30, 542, 70, 20)
$g_idCtrlTaskLabel = GUICtrlCreateLabel("（在任务板里选一行）", 104, 542, 700, 20)

GUICtrlCreateLabel("取消原因", 30, 574, 70, 20)
$g_idCancelReason = GUICtrlCreateInput("人从控制台取消", 104, 572, 500, 24)
$g_idCancelTask = GUICtrlCreateButton("取消该任务", 614, 571, 120, 26)
$g_idCancelRun = GUICtrlCreateButton("取消整次运行", 742, 571, 130, 26)

GUICtrlCreateLabel("ask_human 问题", 30, 608, 120, 20)
$g_idQuestion = GUICtrlCreateEdit("", 154, 606, 820, 54, BitOR($ES_MULTILINE, $ES_READONLY, $WS_VSCROLL))

GUICtrlCreateLabel("回答", 30, 670, 40, 20)
$g_idAnswer = GUICtrlCreateInput("", 74, 668, 760, 24)
$g_idAnswerSend = GUICtrlCreateButton("提交回答", 842, 667, 130, 26)

GUICtrlCreateLabel("已写入 control.json 的内容（调度程序处理后会自动消失）", 30, 702, 500, 20)
$g_idCtrlLog = GUICtrlCreateEdit("", 30, 724, 940, 98, BitOR($ES_MULTILINE, $ES_READONLY, $WS_VSCROLL))
Local $idCtrlHint = GUICtrlCreateLabel("控制通道契约：" & @CRLF & "control.json 里两个数组" & @CRLF & _
        "answers[] / cancels[]" & @CRLF & "每条形如 {task_id, text|reason, at}" & @CRLF & _
        "task_id = * 表示整次运行", 986, 726, 220, 96)
GUICtrlSetColor($idCtrlHint, 0x777777)

; ===== 诊断 =====
GUICtrlCreateTabItem("数据源与诊断")
$g_idDiag = GUICtrlCreateEdit("", 30, 540, 1180, 282, BitOR($ES_MULTILINE, $ES_READONLY, $WS_VSCROLL, $ES_AUTOVSCROLL))

GUICtrlCreateTabItem("")

; 底部消息
$g_idMessage = GUICtrlCreateLabel("", 15, 840, 1210, 22)

; 托盘
$g_idTrayShow = TrayCreateItem("显示 / 隐藏窗口")
TrayItemSetOnEvent($g_idTrayShow, "_OnTrayToggle")
TrayCreateItem("")
$g_idTrayExit = TrayCreateItem("退出")
TrayItemSetOnEvent($g_idTrayExit, "_OnQuit")
TraySetOnEvent($TRAY_EVENT_PRIMARYDOUBLE, "_OnTrayToggle")
TraySetToolTip("aic 控制台")

GUICtrlSetOnEvent($g_idBrowseHome, "_OnBrowseHome")
GUICtrlSetOnEvent($g_idBrowseRepo, "_OnBrowseRepo")
GUICtrlSetOnEvent($g_idRefresh, "_OnManualRefresh")
GUICtrlSetOnEvent($g_idAuto, "_OnToggleAuto")
GUICtrlSetOnEvent($g_idAgentAdd, "_OnAgentAdd")
GUICtrlSetOnEvent($g_idAgentDel, "_OnAgentDelete")
GUICtrlSetOnEvent($g_idAgentApply, "_OnAgentApply")
GUICtrlSetOnEvent($g_idSaveAgents, "_OnSaveAgents")
GUICtrlSetOnEvent($g_idSaveGlobal, "_OnSaveGlobal")
GUICtrlSetOnEvent($g_idSaveProject, "_OnSaveProject")
GUICtrlSetOnEvent($g_idSeed, "_OnSeedDefaults")
GUICtrlSetOnEvent($g_idCancelTask, "_OnCancelTask")
GUICtrlSetOnEvent($g_idCancelRun, "_OnCancelRun")
GUICtrlSetOnEvent($g_idAnswerSend, "_OnSendAnswer")
GUICtrlSetOnEvent($g_idLogCombo, "_OnLogChange")
GUIRegisterMsg($WM_NOTIFY, "_WM_NOTIFY")

; 初始目录
If $g_sAicHome = "" Then
    If $g_bDemo Then
        _Aic_SetHome(_DemoHome())
    Else
        _Aic_SetHome(_Aic_DefaultHome())
    EndIf
EndIf
If $g_sAicRepo = "" And Not $g_bDemo Then _Aic_SetRepo("")

GUICtrlSetData($g_idHome, $g_sAicHome)
GUICtrlSetData($g_idRepo, $g_sAicRepo)

GUISetState(@SW_SHOW, $g_hGui)
_RefreshAll()
AdlibRegister("_Tick", 2000)

While 1
    Sleep(50)
WEnd

; ------------------------------------------------------------------ 演示目录
; 工作区根目录：脚本在 src\ 下、或编译产物在 build\ 下，都取上一级，
; 避免界面上出现 "<workspace>\AUTOit3\build\..\out\..." 这种难看的路径。
Func _WorkspaceRoot()
    Local $sDir = @ScriptDir
    Local $iPos = StringInStr($sDir, "\", 0, -1)
    If $iPos > 0 Then
        Local $sBase = StringLower(StringMid($sDir, $iPos + 1))
        If $sBase = "src" Or $sBase = "build" Then Return StringLeft($sDir, $iPos - 1)
    EndIf
    Return $sDir
EndFunc   ;==>_WorkspaceRoot

Func _DemoHome()
    Return _WorkspaceRoot() & "\out\aic-demo-home"
EndFunc   ;==>_DemoHome

Func _DemoRepo()
    Return _WorkspaceRoot() & "\out\aic-demo-repo"
EndFunc   ;==>_DemoRepo

; ------------------------------------------------------------------ 刷新
Func _OnManualRefresh()
    _RefreshAll()
EndFunc   ;==>_OnManualRefresh

Func _OnToggleAuto()
    $g_bAutoRefresh = (GUICtrlRead($g_idAuto) = $GUI_CHECKED)
EndFunc   ;==>_OnToggleAuto

Func _RefreshAll()
    If $g_bLoading Then Return
    $g_bLoading = True

    _Aic_SetHome(StringStripWS(GUICtrlRead($g_idHome), 3))
    _Aic_SetRepo(StringStripWS(GUICtrlRead($g_idRepo), 3))

    Local $iAgents = _Aic_LoadAll()
    Local $aErrors = _Aic_Validate()

    _FillAgentList()
    _FillConfigFields()
    GUICtrlSetData($g_idStall, $g_sStallTimeout)
    GUICtrlSetData($g_idHostCmd, _Aic_JoinLines($g_aHostCmd))

    _LoadRunList()
    _FillDiag($iAgents, $aErrors)

    ; 汇总
    Local $aRuns = $g_aRuns
    Local $sText = "配置：" & $iAgents & " 个 agent"
    If $g_sAicError <> "" Then
        $sText &= "    " & $g_sAicError
    ElseIf UBound($aErrors) > 0 Then
        $sText &= "    校验：" & $aErrors[0]
    Else
        $sText &= "    校验通过"
    EndIf
    $sText &= "    ·    运行 " & UBound($aRuns) & " 个"
    If $g_sRunId <> "" Then
        $sText &= "    ·    当前：" & $g_sRunId & "（任务 " & UBound($g_aTasks, 1) & "，运行中 " & _Run_CountByStatus("running") & "）"
    EndIf
    $sText &= "    ·    " & @HOUR & ":" & @MIN & ":" & @SEC
    GUICtrlSetData($g_idSummary, $sText)

    If $g_sAicError <> "" Or UBound($aErrors) > 0 Then
        GUICtrlSetColor($g_idSummary, 0xC06000)
    Else
        GUICtrlSetColor($g_idSummary, 0x007000)
    EndIf

    $g_bLoading = False
EndFunc   ;==>_RefreshAll

; 自动刷新：只在 state.json 变化时重读，日志按需跟随
Func _Tick()
    If Not $g_bAutoRefresh Then Return
    If $g_bLoading Then Return
    $g_iTickCount += 1

    If $g_sRunId <> "" Then
        Local $sState = _Run_StateFile($g_sAicHome, $g_sRunId)
        If FileExists($sState) Then
            Local $sTime = FileGetTime($sState, 0, 1)
            If $sTime <> $g_sLastStateTime Then
                $g_sLastStateTime = $sTime
                _ReloadCurrentRun()
            EndIf
        EndIf
        If GUICtrlRead($g_idFollow) = $GUI_CHECKED Then _ReloadLog()
    EndIf

    ; 每 5 个 tick 刷一次运行列表（发现新运行）
    If Mod($g_iTickCount, 5) = 0 Then
        _LoadRunList()
    EndIf
EndFunc   ;==>_Tick

Func _OnBrowseHome()
    Local $s = FileSelectFolder("选择 aic 目录（含 agents.yaml 与 runs）", "", 1, GUICtrlRead($g_idHome))
    If @error Or $s = "" Then Return
    GUICtrlSetData($g_idHome, $s)
    _RefreshAll()
EndFunc   ;==>_OnBrowseHome

Func _OnBrowseRepo()
    Local $s = FileSelectFolder("选择仓库（用于 .aic\project.yaml）", "", 1, GUICtrlRead($g_idRepo))
    If @error Or $s = "" Then Return
    GUICtrlSetData($g_idRepo, $s)
    _RefreshAll()
EndFunc   ;==>_OnBrowseRepo

; ------------------------------------------------------------------ 运行/任务
Func _LoadRunList()
    Local $aRuns = _Run_ListRuns($g_sAicHome)
    _GUICtrlListView_DeleteAllItems($g_idRunList)

    Local $iKeep = -1
    For $i = 0 To UBound($aRuns) - 1
        Local $sRunId = $aRuns[$i]
        Local $sState = _Run_StateFile($g_sAicHome, $sRunId)
        Local $sStatus = "?"
        Local $iTasks = 0
        If FileExists($sState) Then
            _Json_Reset()
            If _Json_ParseFile($sState) Then
                $sStatus = _Run_Pick("", "status,state", "?")
                $iTasks = _Json_ArrayCount("tasks")
            Else
                $sStatus = "(坏)"
            EndIf
        EndIf
        Local $sTime = ""
        If FileExists($sState) Then
            Local $t = FileGetTime($sState, 0, 0)
            If IsArray($t) Then $sTime = $t[1] & "-" & $t[2] & " " & $t[3] & ":" & $t[4]
        EndIf
        GUICtrlCreateListViewItem($sRunId & "|" & $sStatus & "|" & $iTasks & "|" & $sTime, $g_idRunList)
        If $sRunId = $g_sRunId Then $iKeep = $i
    Next

    ; 选中：保持当前，否则选第一条
    If UBound($aRuns) > 0 Then
        If $iKeep < 0 Then $iKeep = 0
        _GUICtrlListView_SetItemSelected($g_idRunList, $iKeep, True, True)
        _SelectRun($iKeep)
    Else
        Local $aEmpty[0][$TK_COLS]
        $g_aTasks = $aEmpty
        _GUICtrlListView_DeleteAllItems($g_idTaskList)
        $g_sRunId = ""
        GUICtrlSetData($g_idDetail, "还没有运行记录。aic run 启动后会在 ~/.aic/runs/<run-id>/ 下写 state.json。")
        GUICtrlSetData($g_idLogEdit, "")
        GUICtrlSetData($g_idCtrlTaskLabel, "（没有运行）")
    EndIf
EndFunc   ;==>_LoadRunList

Func _SelectRun($iIndex)
    If $iIndex < 0 Or $iIndex >= UBound($g_aRuns) Then Return
    Local $sRunId = $g_aRuns[$iIndex]
    If $sRunId = $g_sRunId Then Return
    _Run_LoadState($g_sAicHome, $sRunId)
    $g_sLastStateTime = FileGetTime(_Run_StateFile($g_sAicHome, $sRunId), 0, 1)
    _FillTaskList()
    _FillLogList()
    _FillControlPanel()
EndFunc   ;==>_SelectRun

Func _ReloadCurrentRun()
    If $g_sRunId = "" Then Return
    _Run_LoadState($g_sAicHome, $g_sRunId)
    _FillTaskList()
EndFunc   ;==>_ReloadCurrentRun

Func _FillTaskList()
    _GUICtrlListView_DeleteAllItems($g_idTaskList)
    For $i = 0 To UBound($g_aTasks, 1) - 1
        GUICtrlCreateListViewItem($g_aTasks[$i][$TK_ID] & "|" & _Cell($g_aTasks[$i][$TK_TITLE]) & "|" & _
                $g_aTasks[$i][$TK_KIND] & "|" & $g_aTasks[$i][$TK_STATUS] & "|" & $g_aTasks[$i][$TK_AGENT] & "|" & _
                _Cell($g_aTasks[$i][$TK_DEPENDS]), $g_idTaskList)
    Next
    If UBound($g_aTasks, 1) > 0 Then
        _GUICtrlListView_SetItemSelected($g_idTaskList, 0, True, True)
        _ShowTask(0)
    Else
        GUICtrlSetData($g_idDetail, "该运行的任务板是空的。")
    EndIf
EndFunc   ;==>_FillTaskList

Func _ShowTask($iIndex)
    If $iIndex < 0 Or $iIndex >= UBound($g_aTasks, 1) Then Return
    $g_sActiveTaskId = $g_aTasks[$iIndex][$TK_ID]

    Local $s = "===== 任务 " & $g_aTasks[$iIndex][$TK_ID] & " =====" & @CRLF & @CRLF
    $s &= "标题      : " & _Val($g_aTasks[$iIndex][$TK_TITLE]) & @CRLF
    $s &= "种类      : " & _Val($g_aTasks[$iIndex][$TK_KIND]) & @CRLF
    $s &= "状态      : " & _Val($g_aTasks[$iIndex][$TK_STATUS]) & @CRLF
    $s &= "agent     : " & _Val($g_aTasks[$iIndex][$TK_AGENT]) & @CRLF
    $s &= "路径      : " & _Val($g_aTasks[$iIndex][$TK_PATHS]) & @CRLF
    $s &= "依赖      : " & _Val($g_aTasks[$iIndex][$TK_DEPENDS]) & @CRLF
    $s &= "阻塞原因  : " & _Val($g_aTasks[$iIndex][$TK_BLOCKED]) & @CRLF
    $s &= @CRLF & "摘要：" & @CRLF & _Val($g_aTasks[$iIndex][$TK_SUMMARY]) & @CRLF
    $s &= @CRLF & "----- state.json 里的原始字段 -----" & @CRLF
    Local $aRaw = _Run_TaskRawFields($iIndex)
    For $i = 0 To UBound($aRaw) - 1
        $s &= "  " & $aRaw[$i] & @CRLF
    Next
    If UBound($aRaw) = 0 Then $s &= "  （没有可显示的字段）" & @CRLF

    GUICtrlSetData($g_idDetail, $s)
    GUICtrlSetData($g_idCtrlTaskLabel, $g_aTasks[$iIndex][$TK_ID] & "  " & $g_aTasks[$iIndex][$TK_TITLE] & _
            "  [" & $g_aTasks[$iIndex][$TK_STATUS] & "]")

    If GUICtrlRead($g_idFollow) = $GUI_CHECKED Then
        Local $sLog = _Run_GuessLog($g_sAicHome, $g_sRunId, $g_sActiveTaskId)
        If $sLog <> "" Then GUICtrlSetData($g_idLogEdit, _Run_TailFile($sLog, 64))
    EndIf
EndFunc   ;==>_ShowTask

Func _FillLogList()
    Local $aLogs = _Run_ListLogs($g_sAicHome, $g_sRunId)
    Local $sList = ""
    For $i = 0 To UBound($aLogs) - 1
        If $i > 0 Then $sList &= "|"
        $sList &= $aLogs[$i]
    Next
    GUICtrlSetData($g_idLogCombo, $sList)
    If UBound($aLogs) > 0 Then
        _GUICtrlComboBox_SetCurSel($g_idLogCombo, 0)
        _ReloadLog()
    Else
        GUICtrlSetData($g_idLogEdit, "该运行还没有 logs 目录下的日志。")
    EndIf
EndFunc   ;==>_FillLogList

Func _OnLogChange()
    _ReloadLog()
EndFunc   ;==>_OnLogChange

Func _ReloadLog()
    Local $sName = GUICtrlRead($g_idLogCombo)
    If $sName = "" Then Return
    Local $sFile = _Run_LogsDir($g_sAicHome, $g_sRunId) & "\" & $sName
    If Not FileExists($sFile) Then Return
    GUICtrlSetData($g_idLogEdit, _Run_TailFile($sFile, 64))
EndFunc   ;==>_ReloadLog

; ------------------------------------------------------------------ 配置界面
Func _FillConfigFields()
    GUICtrlSetData($g_idStall, $g_sStallTimeout)
    GUICtrlSetData($g_idHostCmd, _Aic_JoinLines($g_aHostCmd))
EndFunc   ;==>_FillConfigFields

Func _FillAgentList()
    _GUICtrlListView_DeleteAllItems($g_idAgentList)
    For $i = 0 To UBound($g_aAgents, 1) - 1
        Local $sModel = _Aic_ModelForRow($i)
        Local $sFit = $g_aAgents[$i][$AG_FIT]
        If $g_aAgents[$i][$AG_PROJFIT] <> "" Then $sFit &= "  ← 项目覆盖: " & $g_aAgents[$i][$AG_PROJFIT]
        GUICtrlCreateListViewItem($g_aAgents[$i][$AG_NAME] & "|" & $sModel & "|" & $sFit, $g_idAgentList)
    Next
    ; 列表重建后选中第一行，命令预览也跟着刷新
    If UBound($g_aAgents, 1) > 0 Then
        _GUICtrlListView_SetItemSelected($g_idAgentList, 0, True, True)
        GUICtrlSetData($g_idCmdPreview, _Aic_CommandPreview(0))
    Else
        GUICtrlSetData($g_idCmdPreview, "（还没有 agent）")
    EndIf
EndFunc   ;==>_FillAgentList

Func _OnAgentSelect()
    Local $iSel = _GUICtrlListView_GetNextItem($g_idAgentList, -1, $LVNI_SELECTED)
    If $iSel < 0 Then Return
    If $iSel >= UBound($g_aAgents, 1) Then Return
    $g_iEditingAgent = $iSel

    GUICtrlSetData($g_idEditName, $g_aAgents[$iSel][$AG_NAME])
    GUICtrlSetData($g_idEditCmd, $g_aAgents[$iSel][$AG_CMD])

    GUICtrlSetData($g_idEditModel, _Aic_ModelForRow($iSel))
    GUICtrlSetData($g_idCmdPreview, _Aic_CommandPreview($iSel))

    Local $aFit = _Yaml_MakeList($g_aAgents[$iSel][$AG_FIT])
    GUICtrlSetState($g_idFitPlan, $GUI_UNCHECKED)
    GUICtrlSetState($g_idFitWrite, $GUI_UNCHECKED)
    GUICtrlSetState($g_idFitReview, $GUI_UNCHECKED)
    GUICtrlSetState($g_idFitIntegrate, $GUI_UNCHECKED)
    For $i = 0 To UBound($aFit) - 1
        Switch $aFit[$i]
            Case "plan"
                GUICtrlSetState($g_idFitPlan, $GUI_CHECKED)
            Case "write"
                GUICtrlSetState($g_idFitWrite, $GUI_CHECKED)
            Case "review"
                GUICtrlSetState($g_idFitReview, $GUI_CHECKED)
            Case "integrate"
                GUICtrlSetState($g_idFitIntegrate, $GUI_CHECKED)
        EndSwitch
    Next

    GUICtrlSetData($g_idEditProjFit, $g_aAgents[$iSel][$AG_PROJFIT])
EndFunc   ;==>_OnAgentSelect

Func _OnAgentApply()
    If $g_iEditingAgent < 0 Or $g_iEditingAgent >= UBound($g_aAgents, 1) Then
        _Msg("请先在 Agent 列表里选中一行", 0xC06000)
        Return
    EndIf

    Local $sName = StringStripWS(GUICtrlRead($g_idEditName), 3)
    If $sName = "" Then
        _Msg("agent 名称不能为空", 0xB00000)
        Return
    EndIf
    ; 改名冲突检查
    For $i = 0 To UBound($g_aAgents, 1) - 1
        If $i <> $g_iEditingAgent And $g_aAgents[$i][$AG_NAME] = $sName Then
            _Msg("已存在同名 agent：" & $sName, 0xB00000)
            Return
        EndIf
    Next

    Local $aCmd = _Yaml_MakeList(StringReplace(GUICtrlRead($g_idEditCmd), @LF, ","))
    Local $sModel = StringStripWS(GUICtrlRead($g_idEditModel), 3)
    ; 按该 agent 原本的写法更新模型（独立 model 键 或 command 里的 --model）
    $aCmd = _Aic_ApplyModel($g_iEditingAgent, $aCmd, $sModel)

    Local $sFit = ""
    If GUICtrlRead($g_idFitPlan) = $GUI_CHECKED Then $sFit = _AddCsv($sFit, "plan")
    If GUICtrlRead($g_idFitWrite) = $GUI_CHECKED Then $sFit = _AddCsv($sFit, "write")
    If GUICtrlRead($g_idFitReview) = $GUI_CHECKED Then $sFit = _AddCsv($sFit, "review")
    If GUICtrlRead($g_idFitIntegrate) = $GUI_CHECKED Then $sFit = _AddCsv($sFit, "integrate")

    $g_aAgents[$g_iEditingAgent][$AG_NAME] = $sName
    $g_aAgents[$g_iEditingAgent][$AG_CMD] = _Aic_JoinLines($aCmd)
    $g_aAgents[$g_iEditingAgent][$AG_FIT] = $sFit
    $g_aAgents[$g_iEditingAgent][$AG_PROJFIT] = StringStripWS(GUICtrlRead($g_idEditProjFit), 3)

    _FillAgentList()
    _GUICtrlListView_SetItemSelected($g_idAgentList, $g_iEditingAgent, True, True)
    _Msg("已应用到列表：" & $sName & "   命令：" & _Aic_CommandPreview($g_iEditingAgent) & "    别忘了保存", 0x007000)
EndFunc   ;==>_OnAgentApply

Func _AddCsv($sCsv, $sItem)
    If $sCsv = "" Then Return $sItem
    Return $sCsv & "," & $sItem
EndFunc   ;==>_AddCsv

Func _OnAgentAdd()
    Local $sName = StringStripWS(InputBox("新增 agent", "给这个 agent 起个名字（如 gemini、aider）：", ""), 3)
    If @error Or $sName = "" Then Return
    If _Aic_AddAgent($sName) < 0 Then
        _Msg("新增失败：名字为空或已存在", 0xB00000)
        Return
    EndIf
    _FillAgentList()
    $g_iEditingAgent = UBound($g_aAgents, 1) - 1
    _GUICtrlListView_SetItemSelected($g_idAgentList, $g_iEditingAgent, True, True)
    _OnAgentSelect()
    _Msg("已新增 agent：" & $sName & "（填好命令后点“应用到列表”，再保存）", 0x007000)
EndFunc   ;==>_OnAgentAdd

Func _OnAgentDelete()
    If $g_iEditingAgent < 0 Or $g_iEditingAgent >= UBound($g_aAgents, 1) Then
        _Msg("请先选中一个 agent", 0xC06000)
        Return
    EndIf
    Local $sName = $g_aAgents[$g_iEditingAgent][$AG_NAME]
    Local $iAnswer = MsgBox(BitOR($MB_ICONQUESTION, $MB_YESNO, $MB_DEFBUTTON2), "确认删除", _
            "从配置里删除 agent “" & $sName & "”？" & @CRLF & @CRLF & "（要写入文件才真正生效）")
    If $iAnswer <> $IDYES Then Return
    _Aic_RemoveAgent($sName)
    $g_iEditingAgent = -1
    _FillAgentList()
    _Msg("已从列表删除：" & $sName, 0x007000)
EndFunc   ;==>_OnAgentDelete

Func _OnSaveAgents()
    ; 先把界面上的 host / stall 同步进模型
    $g_aHostCmd = _Yaml_MakeList(StringReplace(GUICtrlRead($g_idHostCmd), @LF, ","))
    $g_sStallTimeout = StringStripWS(GUICtrlRead($g_idStall), 3)

    Local $aErrors = _Aic_Validate()
    If UBound($aErrors) > 0 Then
        _Msg("校验未通过，未保存：" & $aErrors[0], 0xB00000)
        Return
    EndIf

    Local $sErr = _Aic_SaveAgents()
    If $sErr <> "" Then
        _Msg("保存 agents.yaml 失败：" & $sErr, 0xB00000)
        Return
    EndIf
    _Msg("已保存：" & _Aic_AgentsFile(), 0x007000)
    _RefreshAll()
EndFunc   ;==>_OnSaveAgents

Func _OnSaveGlobal()
    $g_sStallTimeout = StringStripWS(GUICtrlRead($g_idStall), 3)
    If _Aic_ParseDuration($g_sStallTimeout) <= 0 Then
        _Msg("stall_timeout 格式不对，未保存：" & $g_sStallTimeout, 0xB00000)
        Return
    EndIf
    Local $sErr = _Aic_SaveGlobal()
    If $sErr <> "" Then
        _Msg("保存 config.yaml 失败：" & $sErr, 0xB00000)
        Return
    EndIf
    _Msg("已保存：" & _Aic_ConfigFile(), 0x007000)
EndFunc   ;==>_OnSaveGlobal

Func _OnSaveProject()
    If $g_sAicRepo = "" Then
        _Msg("请先填仓库路径（project.yaml 写在 <仓库>\.aic\ 下）", 0xC06000)
        Return
    EndIf
    If $g_iEditingAgent >= 0 And $g_iEditingAgent < UBound($g_aAgents, 1) Then
        $g_aAgents[$g_iEditingAgent][$AG_PROJFIT] = StringStripWS(GUICtrlRead($g_idEditProjFit), 3)
    EndIf
    Local $sErr = _Aic_SaveProject()
    If $sErr <> "" Then
        _Msg("保存 project.yaml 失败：" & $sErr, 0xB00000)
        Return
    EndIf
    _Msg("已保存：" & _Aic_ProjectFile(), 0x007000)
    _RefreshAll()
EndFunc   ;==>_OnSaveProject

Func _OnSeedDefaults()
    Local $iAnswer = MsgBox(BitOR($MB_ICONQUESTION, $MB_YESNO, $MB_DEFBUTTON2), "从模板新建配置", _
            "会用五家常客的命令（codex / opencode / kimi / dsh / pi）覆盖当前的 agent 列表，" & @CRLF & _
            "并写入：" & @CRLF & _Aic_AgentsFile() & @CRLF & _Aic_ConfigFile() & @CRLF & @CRLF & _
            "已有文件里的其它键会保留。继续吗？")
    If $iAnswer <> $IDYES Then Return

    _Aic_CreateDefaultAgents()
    Local $aErrors = _Aic_Validate()
    If UBound($aErrors) > 0 Then
        _Msg("模板校验失败（不应该发生）：" & $aErrors[0], 0xB00000)
        Return
    EndIf
    Local $sErr = _Aic_SaveAgents()
    If $sErr <> "" Then
        _Msg("保存 agents.yaml 失败：" & $sErr, 0xB00000)
        Return
    EndIf
    Local $sErr2 = _Aic_SaveGlobal()
    If $sErr2 <> "" Then
        _Msg("保存 config.yaml 失败：" & $sErr2, 0xB00000)
        Return
    EndIf
    _RefreshAll()
    _Msg("已按模板生成配置，请按需修改命令与模型", 0x007000)
EndFunc   ;==>_OnSeedDefaults

Func _OnCreateConfig()
    Return
EndFunc   ;==>_OnCreateConfig

; ------------------------------------------------------------------ 控制界面
Func _FillControlPanel()
    Local $aCtrl = _Run_ReadControl($g_sAicHome, $g_sRunId)
    Local $s = ""
    If $aCtrl[0] <> "" Then $s &= "取消命令待处理：" & @CRLF & $aCtrl[0] & @CRLF & @CRLF
    If $aCtrl[1] <> "" Then $s &= "回答待处理：" & @CRLF & $aCtrl[1] & @CRLF
    If $s = "" Then $s = "（control.json 里还没有待处理命令）"
    GUICtrlSetData($g_idCtrlLog, $s)

    Local $sQ = _Run_PendingQuestion()
    Local $sTask = _Run_PendingQuestionTask()
    If $sQ <> "" Then
        GUICtrlSetData($g_idQuestion, $sQ & @CRLF & "（关联任务：" & $sTask & "）")
        GUICtrlSetData($g_idAnswer, "")
    Else
        GUICtrlSetData($g_idQuestion, "（当前没有 ask_human 待回答的问题）")
    EndIf
EndFunc   ;==>_FillControlPanel

Func _OnCancelTask()
    If $g_sRunId = "" Or $g_sActiveTaskId = "" Then
        _Msg("请先在任务板里选中一条任务", 0xC06000)
        Return
    EndIf
    Local $sReason = StringStripWS(GUICtrlRead($g_idCancelReason), 3)
    Local $sErr = _Run_AppendCancel($g_sAicHome, $g_sRunId, $g_sActiveTaskId, $sReason)
    If $sErr <> "" Then
        _Msg("写入 control.json 失败：" & $sErr, 0xB00000)
        Return
    EndIf
    _FillControlPanel()
    _Msg("已写入取消命令：" & $g_sActiveTaskId & "（调度程序处理后会从数组里移除）", 0x007000)
EndFunc   ;==>_OnCancelTask

Func _OnCancelRun()
    If $g_sRunId = "" Then
        _Msg("还没有选中运行", 0xC06000)
        Return
    EndIf
    Local $iAnswer = MsgBox(BitOR($MB_ICONQUESTION, $MB_YESNO, $MB_DEFBUTTON2), "确认", _
            "取消整次运行 " & $g_sRunId & "？" & @CRLF & @CRLF & "（会停掉所有工人进程树，已有分支保留）")
    If $iAnswer <> $IDYES Then Return
    Local $sReason = StringStripWS(GUICtrlRead($g_idCancelReason), 3)
    Local $sErr = _Run_AppendCancel($g_sAicHome, $g_sRunId, "*", $sReason)
    If $sErr <> "" Then
        _Msg("写入 control.json 失败：" & $sErr, 0xB00000)
        Return
    EndIf
    _FillControlPanel()
    _Msg("已写入取消整次运行的命令（task_id = *）", 0x007000)
EndFunc   ;==>_OnCancelRun

Func _OnSendAnswer()
    If $g_sRunId = "" Then
        _Msg("还没有选中运行", 0xC06000)
        Return
    EndIf
    Local $sText = StringStripWS(GUICtrlRead($g_idAnswer), 3)
    If $sText = "" Then
        _Msg("回答内容不能为空", 0xC06000)
        Return
    EndIf
    Local $sTask = _Run_PendingQuestionTask()
    If $sTask = "" Then $sTask = $g_sActiveTaskId
    Local $sErr = _Run_AppendAnswer($g_sAicHome, $g_sRunId, $sTask, $sText)
    If $sErr <> "" Then
        _Msg("写入 control.json 失败：" & $sErr, 0xB00000)
        Return
    EndIf
    GUICtrlSetData($g_idAnswer, "")
    _FillControlPanel()
    _Msg("已提交回答（关联任务 " & $sTask & "）", 0x007000)
EndFunc   ;==>_OnSendAnswer

; ------------------------------------------------------------------ 诊断页
Func _FillDiag($iAgents, $aErrors)
    Local $s = "===== 路径与文件 =====" & @CRLF
    $s &= "aic 目录      : " & $g_sAicHome & _ExistsMark($g_sAicHome) & @CRLF
    $s &= "  agents.yaml : " & _Aic_AgentsFile() & _ExistsMark(_Aic_AgentsFile()) & @CRLF
    $s &= "  config.yaml : " & _Aic_ConfigFile() & _ExistsMark(_Aic_ConfigFile()) & @CRLF
    $s &= "  runs/       : " & $g_sAicHome & "\runs" & _ExistsMark($g_sAicHome & "\runs") & @CRLF
    $s &= "仓库          : " & _Val2($g_sAicRepo, "(未设置)") & @CRLF
    $s &= "  project.yaml: " & _Val2(_Aic_ProjectFile(), "(未设置)") & _ExistsMark(_Aic_ProjectFile()) & @CRLF
    $s &= @CRLF & "===== 解析结果 =====" & @CRLF
    $s &= "读到的 agent 数 : " & $iAgents & @CRLF
    $s &= "stall_timeout   : " & $g_sStallTimeout & "（解析为 " & _Aic_ParseDuration($g_sStallTimeout) & " 秒）" & @CRLF
    $s &= "host 命令       : " & _Aic_JoinCsv($g_aHostCmd) & @CRLF
    If $g_sAicError <> "" Then $s &= "读取错误        : " & $g_sAicError & @CRLF
    $s &= @CRLF & "===== 配置校验 =====" & @CRLF
    If UBound($aErrors) = 0 Then
        $s &= "通过。" & @CRLF
    Else
        For $i = 0 To UBound($aErrors) - 1
            $s &= "  · " & $aErrors[$i] & @CRLF
        Next
    EndIf
    $s &= @CRLF & "===== 按角色看 agent（fit）=====" & @CRLF
    Local $aRoles[4] = ["plan", "write", "review", "integrate"]
    For $i = 0 To UBound($aRoles) - 1
        Local $aWho = _Aic_FindAgentsByFit($aRoles[$i])
        $s &= "  " & $aRoles[$i] & " : " & _Aic_JoinCsv($aWho) & @CRLF
    Next
    $s &= @CRLF & "===== 控制通道契约（本项目定义，供调度程序实现）=====" & @CRLF
    $s &= "  ~/.aic/runs/<run-id>/control.json" & @CRLF
    $s &= '  {"answers":[{"task_id":"T2","text":"...","at":"..."}],' & @CRLF
    $s &= '   "cancels":[{"task_id":"T3","reason":"...","at":"..."}]}' & @CRLF
    $s &= "  task_id 为 * 表示取消整次运行；调度程序处理完一条应把它从数组里移除。" & @CRLF

    GUICtrlSetData($g_idDiag, $s)
EndFunc   ;==>_FillDiag

Func _ExistsMark($sPath)
    If $sPath = "" Then Return ""
    If FileExists($sPath) Then Return "   [存在]"
    Return "   [不存在]"
EndFunc   ;==>_ExistsMark

; ------------------------------------------------------------------ 小工具
Func _Cell($sText)
    Return StringReplace($sText, "|", "/")
EndFunc   ;==>_Cell

Func _Val($sText)
    If StringStripWS($sText, 3) = "" Then Return "—"
    Return $sText
EndFunc   ;==>_Val

Func _Val2($sText, $sDefault)
    If StringStripWS($sText, 3) = "" Then Return $sDefault
    Return $sText
EndFunc   ;==>_Val2

Func _Msg($sText, $iColor = 0x000000)
    GUICtrlSetData($g_idMessage, "[" & @HOUR & ":" & @MIN & ":" & @SEC & "] " & $sText)
    GUICtrlSetColor($g_idMessage, $iColor)
EndFunc   ;==>_Msg

Func _WM_NOTIFY($hWnd, $iMsg, $wParam, $lParam)
    Local $tNMHDR = DllStructCreate($tagNMHDR, $lParam)
    Local $hFrom = HWnd(DllStructGetData($tNMHDR, "hWndFrom"))
    Local $iCode = DllStructGetData($tNMHDR, "Code")

    If $iCode = $LVN_ITEMCHANGED Then
        If $hFrom = $g_idRunList Then
            Local $iSel = _GUICtrlListView_GetNextItem($g_idRunList, -1, $LVNI_SELECTED)
            If $iSel >= 0 Then _SelectRun($iSel)
        ElseIf $hFrom = $g_idTaskList Then
            Local $iSel2 = _GUICtrlListView_GetNextItem($g_idTaskList, -1, $LVNI_SELECTED)
            If $iSel2 >= 0 Then _ShowTask($iSel2)
        ElseIf $hFrom = $g_idAgentList Then
            _OnAgentSelect()
        EndIf
    EndIf

    Return $GUI_RUNDEFMSG
EndFunc   ;==>_WM_NOTIFY

Func _OnMinimize()
    GUISetState(@SW_HIDE, $g_hGui)
    TrayTip("aic 控制台", "窗口已最小化到托盘，双击托盘图标可恢复。", 3)
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

; -------------------------------------------------------------- 命令行实现
Func _Log($sText)
    ConsoleWrite($sText & @CRLF)
    Local $sDir = @ScriptDir & "\..\out"
    If Not FileExists($sDir) Then DirCreate($sDir)
    Local $hFile = FileOpen($sDir & "\aic-console.log", $FO_APPEND + $FO_CREATEPATH + $FO_UTF8)
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

; 造演示环境：假的 aic 目录 + 假的仓库（含 project.yaml）
Func _BuildDemo()
    Local $sHome = _DemoHome()
    Local $sRepo = _DemoRepo()

    _Run_BuildDemoHome($sHome)

    ; 用夹具里的 agents.yaml 当用户配置，project.yaml 放仓库里
    FileCopy(@ScriptDir & "\..\tests\fixtures\agents-sample.yaml", $sHome & "\agents.yaml", 1)
    FileCopy(@ScriptDir & "\..\tests\fixtures\config-sample.yaml", $sHome & "\config.yaml", 1)
    If Not FileExists($sRepo & "\.aic") Then DirCreate($sRepo & "\.aic")
    FileCopy(@ScriptDir & "\..\tests\fixtures\project-sample.yaml", $sRepo & "\.aic\project.yaml", 1)
    Return True
EndFunc   ;==>_BuildDemo

Func _RunDemo()
    _BuildDemo()
    _Aic_SetHome(_DemoHome())
    _Aic_SetRepo(_DemoRepo())

    Local $iAgents = _Aic_LoadAll()
    Local $s = "=== aic 控制台演示环境 ===" & @CRLF
    $s &= "aic 目录 : " & _DemoHome() & @CRLF
    $s &= "仓库     : " & _DemoRepo() & @CRLF
    $s &= "agent 数 : " & $iAgents & @CRLF
    $s &= "stall    : " & $g_sStallTimeout & @CRLF & @CRLF

    For $i = 0 To UBound($g_aAgents, 1) - 1
        Local $aCmd = _Yaml_MakeList(StringReplace($g_aAgents[$i][$AG_CMD], @LF, ","))
        Local $aFound = _Aic_ExtractModel($aCmd)
        $s &= "  " & $g_aAgents[$i][$AG_NAME] & "  模型=" & _Val2($aFound[0], "(未设置)") & "  fit=" & $g_aAgents[$i][$AG_FIT] & "  覆盖=" & _Val2($g_aAgents[$i][$AG_PROJFIT], "-") & @CRLF
    Next

    Local $aRuns = _Run_ListRuns(_DemoHome())
    $s &= @CRLF & "运行 " & UBound($aRuns) & " 个：" & @CRLF
    For $i = 0 To UBound($aRuns) - 1
        Local $iTasks = _Run_LoadState(_DemoHome(), $aRuns[$i])
        $s &= "  " & $aRuns[$i] & "  任务 " & $iTasks & "  状态 " & _Run_Field("status") & @CRLF
        For $k = 0 To UBound($g_aTasks, 1) - 1
            $s &= "      " & $g_aTasks[$k][$TK_ID] & "  " & $g_aTasks[$k][$TK_TITLE] & "  [" & $g_aTasks[$k][$TK_KIND] & "/" & $g_aTasks[$k][$TK_STATUS] & "]  " & $g_aTasks[$k][$TK_AGENT] & @CRLF
        Next
    Next

    Local $sOut = @ScriptDir & "\..\out\aic-demo-report.txt"
    Local $hFile = FileOpen($sOut, $FO_OVERWRITE + $FO_CREATEPATH + $FO_UTF8)
    If $hFile <> -1 Then
        FileWrite($hFile, $s)
        FileClose($hFile)
    EndIf
    ConsoleWrite($s & @CRLF)
    Return 0
EndFunc   ;==>_RunDemo

Func _SelfTest()
    _Log("=== AIC 控制台自检 ===")
    FileDelete(@ScriptDir & "\..\out\aic-console.log")

    ; ---- 演示环境 ----
    _BuildDemo()
    _Aic_SetHome(_DemoHome())
    _Aic_SetRepo(_DemoRepo())
    _Check("演示目录建立", FileExists(_DemoHome() & "\agents.yaml"))

    ; ---- 配置读取 ----
    Local $iAgents = _Aic_LoadAll()
    _Check("读到 3 个 agent", $iAgents = 3, String($iAgents))
    _Check("stall_timeout = 10m", $g_sStallTimeout = "10m", $g_sStallTimeout)
    _Check("host 命令 3 个 token", UBound($g_aHostCmd) = 3, String(UBound($g_aHostCmd)))

    Local $iCodex = _Aic_AgentIndex("codex")
    _Check("找得到 codex", $iCodex >= 0)
    Local $aCodexCmd = _Yaml_MakeList(StringReplace($g_aAgents[$iCodex][$AG_CMD], @LF, ","))
    _Check("codex 命令解析为 3 项", UBound($aCodexCmd) = 3, String(UBound($aCodexCmd)))
    _Check("codex fit 含 write", StringInStr($g_aAgents[$iCodex][$AG_FIT], "write") > 0, $g_aAgents[$iCodex][$AG_FIT])

    ; 模型两种写法：codex 用独立 model 键，kimi 用命令 token（这里都没有）
    _Check("识别独立 model 键写法", _Aic_ModelForRow($iCodex) = "gpt-5-codex", _Aic_ModelForRow($iCodex))
    _Check("codex 用的是独立键", $g_aAgents[$iCodex][$AG_MODELKEY] = "1", $g_aAgents[$iCodex][$AG_MODELKEY])
    Local $iKimi = _Aic_AgentIndex("kimi")
    _Check("kimi 没有模型", _Aic_ModelForRow($iKimi) = "", _Aic_ModelForRow($iKimi))
    _Check("kimi 用的是 token 写法", $g_aAgents[$iKimi][$AG_MODELKEY] = "", $g_aAgents[$iKimi][$AG_MODELKEY])

    ; 项目级覆盖生效（project-sample.yaml 把 codex.fit 改成 review）
    _Check("项目级覆盖生效", StringInStr($g_aAgents[$iCodex][$AG_PROJFIT], "review") > 0, $g_aAgents[$iCodex][$AG_PROJFIT])
    Local $aReview = _Aic_FindAgentsByFit("review")
    _Check("按 review 角色能找到 agent", UBound($aReview) > 0, _Aic_JoinCsv($aReview))

    ; ---- 校验 ----
    _Check("当前配置校验通过", UBound(_Aic_Validate()) = 0, _Aic_JoinCsv(_Aic_Validate()))

    ; ---- 模型写入 token ----
    Local $aTokens[4] = ["opencode", "run", "--format", "json"]
    Local $aNew = _Aic_SetModelTokens($aTokens, "claude-4")
    _Check("追加模型参数后 6 个 token", UBound($aNew) = 6, String(UBound($aNew)))
    _Check("追加的是 --model", $aNew[4] = "--model" And $aNew[5] = "claude-4", _Aic_JoinCsv($aNew))
    Local $aBack = _Aic_ExtractModel($aNew)
    _Check("回读模型参数", $aBack[0] = "claude-4", $aBack[0])
    Local $aChanged = _Aic_SetModelTokens($aNew, "gpt-5")
    Local $aBack2 = _Aic_ExtractModel($aChanged)
    _Check("改模型不重复追加", UBound($aChanged) = 6 And $aBack2[0] = "gpt-5", _Aic_JoinCsv($aChanged))
    Local $aRemoved = _Aic_SetModelTokens($aNew, "")
    Local $aRemovedCheck = _Aic_ExtractModel($aRemoved)
    _Check("清空模型会移除参数", UBound($aRemoved) = 4 And $aRemovedCheck[0] = "", _Aic_JoinCsv($aRemoved))

    ; ---- 保存 / 重新读取 ----
    $g_aAgents[$iCodex][$AG_FIT] = "write,review,integrate"
    $g_sStallTimeout = "5m"
    Local $sErr = _Aic_SaveAgents()
    _Check("保存 agents.yaml 成功", $sErr = "", $sErr)
    Local $sErr2 = _Aic_SaveGlobal()
    _Check("保存 config.yaml 成功", $sErr2 = "", $sErr2)

    _Aic_SetHome(_DemoHome())
    Local $iAgain = _Aic_LoadAll()
    _Check("重新读取仍是 3 个 agent", $iAgain = 3, String($iAgain))
    _Check("stall_timeout 改成了 5m", $g_sStallTimeout = "5m", $g_sStallTimeout)
    _Check("fit 修改已保存", $g_aAgents[_Aic_AgentIndex("codex")][$AG_FIT] = "write,review,integrate", $g_aAgents[_Aic_AgentIndex("codex")][$AG_FIT])
    _Check("模型值重新读取正确", _Aic_ModelForRow(_Aic_AgentIndex("codex")) = "gpt-5-codex", _Aic_ModelForRow(_Aic_AgentIndex("codex")))
    ; 直接重新解析文件确认 model 键还在（不依赖当前内存里的文档）
    _Yaml_ParseFile(_Aic_AgentsFile())
    _Check("独立 model 键写回文件后仍在", _Yaml_Get("agents.codex.model") = "gpt-5-codex", _Yaml_Get("agents.codex.model"))
    _Check("kimi 的 note 键仍在", StringInStr(_Yaml_Get("agents.kimi.note"), "#") > 0, _Yaml_Get("agents.kimi.note"))
    _Check("kimi 的 fit 仍在", UBound(_Yaml_GetList("agents.kimi.fit")) = 2, String(UBound(_Yaml_GetList("agents.kimi.fit"))))
    _Check("未改动的 host 段仍在", UBound(_Yaml_GetList("host.command")) = 3, String(UBound(_Yaml_GetList("host.command"))))
    _Check("其它 agent 的未知键保留", StringInStr($g_aAgents[_Aic_AgentIndex("kimi")][$AG_EXTRAS], "note=") > 0, $g_aAgents[_Aic_AgentIndex("kimi")][$AG_EXTRAS])

    ; ---- 校验失败路径 ----
    Local $aBad[0]
    $g_aHostCmd = $aBad
    _Check("host 为空时报错", UBound(_Aic_Validate()) > 0)
    Local $aHostBack[3] = ["dsh", "--profile", "headless"]
    $g_aHostCmd = $aHostBack
    Local $iCmdx = _Aic_AgentIndex("codex")
    $g_aAgents[$iCmdx][$AG_FIT] = "写代码"
    _Check("非法 fit 值报错", UBound(_Aic_Validate()) > 0)
    $g_aAgents[$iCmdx][$AG_FIT] = "write,review"
    Local $sStallBack = $g_sStallTimeout
    $g_sStallTimeout = "十秒"
    _Check("非法 stall_timeout 报错", UBound(_Aic_Validate()) > 0)
    $g_sStallTimeout = $sStallBack

    ; ---- 运行 / 任务板 ----
    Local $aRuns = _Run_ListRuns(_DemoHome())
    _Check("列出 2 个运行", UBound($aRuns) = 2, String(UBound($aRuns)))
    Local $iTasks = _Run_LoadState(_DemoHome(), "20260922-1601-abcd1234")
    _Check("第一个运行有 2 条任务", $iTasks = 2, String($iTasks))
    _Check("任务 T1 的 agent = codex", $g_aTasks[0][$TK_AGENT] = "codex", $g_aTasks[0][$TK_AGENT])
    _Check("任务 T1 的路径有 2 条", StringInStr($g_aTasks[0][$TK_PATHS], "export.ts") > 0, $g_aTasks[0][$TK_PATHS])
    _Check("任务 T2 依赖 T1", $g_aTasks[1][$TK_DEPENDS] = "T1", $g_aTasks[1][$TK_DEPENDS])
    _Check("任务 T2 的阻塞原因读到", $g_aTasks[1][$TK_BLOCKED] <> "", $g_aTasks[1][$TK_BLOCKED])
    _Check("按状态统计 running = 1", _Run_CountByStatus("running") = 1, String(_Run_CountByStatus("running")))
    _Check("ask_human 问题读到", StringInStr(_Run_PendingQuestion(), "CSV") > 0, _Run_PendingQuestion())
    _Check("ask_human 关联任务 = T2", _Run_PendingQuestionTask() = "T2", _Run_PendingQuestionTask())
    Local $aRawFields = _Run_TaskRawFields(0)
    _Check("任务原始字段 >= 10 个", UBound($aRawFields) >= 10, String(UBound($aRawFields)))

    ; 第二个运行（宽容映射：不同键名/状态）
    _Run_LoadState(_DemoHome(), "20260922-1530-9f8e7d6c")
    _Check("第二个运行读到 1 条任务", UBound($g_aTasks, 1) = 1, String(UBound($g_aTasks, 1)))
    _Check("宽容映射读到标题", $g_aTasks[0][$TK_TITLE] = "修 setTimeout", $g_aTasks[0][$TK_TITLE])

    ; ---- 日志 ----
    Local $aLogs = _Run_ListLogs(_DemoHome(), "20260922-1601-abcd1234")
    _Check("日志列表有 1 个文件", UBound($aLogs) = 1, String(UBound($aLogs)))
    Local $sGuessed = _Run_GuessLog(_DemoHome(), "20260922-1601-abcd1234", "T1")
    _Check("按任务号猜到日志文件", StringInStr($sGuessed, "T1.log") > 0, $sGuessed)
    Local $sTail = _Run_TailFile($sGuessed, 64)
    _Check("日志尾部读到了内容", StringInStr($sTail, "12 passed") > 0, $sTail)

    ; ---- 控制通道 ----
    Local $sErr3 = _Run_AppendCancel(_DemoHome(), "20260922-1601-abcd1234", "T2", "人取消")
    _Check("写入取消命令成功", $sErr3 = "", $sErr3)
    Local $sErr4 = _Run_AppendAnswer(_DemoHome(), "20260922-1601-abcd1234", "T2", "用 XLSX")
    _Check("写入回答成功", $sErr4 = "", $sErr4)
    Local $aCtrl = _Run_ReadControl(_DemoHome(), "20260922-1601-abcd1234")
    _Check("回读取消命令", StringInStr($aCtrl[0], "T2") > 0 And StringInStr($aCtrl[0], "人取消") > 0, $aCtrl[0])
    _Check("回读回答", StringInStr($aCtrl[1], "用 XLSX") > 0, $aCtrl[1])

    ; 追加第二条：不应覆盖第一条
    _Run_AppendCancel(_DemoHome(), "20260922-1601-abcd1234", "T1", "第二条")
    Local $aCtrl2 = _Run_ReadControl(_DemoHome(), "20260922-1601-abcd1234")
    _Check("追加不覆盖已有条目", StringInStr($aCtrl2[0], "T2") > 0 And StringInStr($aCtrl2[0], "T1") > 0, $aCtrl2[0])

    ; control.json 必须是合法 JSON（用 Python 再验一次，见 tests\test-aic.ps1）
    Local $sCtrlFile = _Run_ControlFile(_DemoHome(), "20260922-1601-abcd1234")
    _Check("control.json 已生成", FileExists($sCtrlFile), $sCtrlFile)

    _Log("")
    If $g_iFail = 0 Then
        _Log("AIC 控制台自检：全部通过")
    Else
        _Log("AIC 控制台自检：失败 " & $g_iFail & " 项")
    EndIf
    Return $g_iFail
EndFunc   ;==>_SelfTest
