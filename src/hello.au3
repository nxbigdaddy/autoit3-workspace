; hello.au3 - environment smoke test for this AutoIt3 workspace.
;
;   syntax check : .\tools\au3-check.ps1 src\hello.au3
;   run          : .\tools\au3-run.ps1   src\hello.au3
;   build        : .\tools\au3-build.ps1 src\hello.au3
;
; It exercises: core macros, a UDF from the AutoIt install Include folder,
; a project-local relative include, the regex engine and file access.

#include <Array.au3>
#include <FileConstants.au3>
#include "lib\HelloLib.au3"

Opt("MustDeclareVars", 1)

Global $sLogFile = @ScriptDir & "\..\out\hello.log"
If $CmdLine[0] >= 1 Then $sLogFile = $CmdLine[1]
Global $iFailures = 0

_Hello_Log("=== AutoIt3 workspace smoke test ===", $sLogFile)
_Hello_Log("", $sLogFile)
_Hello_Log("AutoIt version  : " & @AutoItVersion, $sLogFile)
_Hello_Log("Interpreter x64 : " & @AutoItX64 & "    OS: " & @OSArch & " / " & @CPUArch, $sLogFile)
_Hello_Log("Windows         : " & @OSVersion & " (build " & @OSBuild & ")", $sLogFile)
_Hello_Log("Computer / user : " & @ComputerName & " / " & @UserName, $sLogFile)
_Hello_Log("Script folder   : " & @ScriptDir, $sLogFile)
_Hello_Log("Working folder  : " & @WorkingDir, $sLogFile)
_Hello_Log("Log file        : " & $sLogFile, $sLogFile)
_Hello_Log("", $sLogFile)

; 1) core language
If @AutoItVersion = "" Then
    _Hello_Log("[FAIL] @AutoItVersion is empty", $sLogFile)
    $iFailures += 1
Else
    _Hello_Log("[ ok ] core macros readable", $sLogFile)
EndIf

; 2) UDF shipped with AutoIt (install Include folder)
Local $aDemo[3] = ["alpha", "beta", "gamma"]
Local $sJoined = _ArrayToString($aDemo, "|")
If $sJoined = "alpha|beta|gamma" Then
    _Hello_Log("[ ok ] install UDF <Array.au3> -> " & $sJoined, $sLogFile)
Else
    _Hello_Log("[FAIL] _ArrayToString returned: " & $sJoined, $sLogFile)
    $iFailures += 1
EndIf

; 3) project-local relative include
_Hello_Log("[ ok ] local include lib\HelloLib.au3 -> " & _Hello_Greet("AutoIt"), $sLogFile)

; 4) regex engine
If StringRegExp("abc123", "\d+") Then
    _Hello_Log("[ ok ] StringRegExp works", $sLogFile)
Else
    _Hello_Log("[FAIL] StringRegExp did not match", $sLogFile)
    $iFailures += 1
EndIf

; 5) file access to the workspace out\ folder
Local $sProbe = @ScriptDir & "\..\out\write-probe.txt"
Local $hProbe = FileOpen($sProbe, $FO_OVERWRITE + $FO_CREATEPATH + $FO_UTF8)
If $hProbe <> -1 Then
    FileWrite($hProbe, "probe " & @YEAR & "-" & @MON & "-" & @MDAY & " " & @HOUR & ":" & @MIN & ":" & @SEC)
    FileClose($hProbe)
    _Hello_Log("[ ok ] file write -> " & $sProbe, $sLogFile)
Else
    _Hello_Log("[FAIL] cannot write " & $sProbe, $sLogFile)
    $iFailures += 1
EndIf

; 6) registry: user include folder (informational)
Local $sUserInc = RegRead("HKEY_CURRENT_USER\Software\AutoIt v3\AutoIt", "Include")
If @error Then
    _Hello_Log("[info] user include folder is not registered yet", $sLogFile)
ElseIf FileExists($sUserInc) Then
    _Hello_Log("[ ok ] user include folder -> " & $sUserInc, $sLogFile)
Else
    _Hello_Log("[info] registered user include folder is missing on disk -> " & $sUserInc, $sLogFile)
EndIf

_Hello_Log("", $sLogFile)
If $iFailures = 0 Then
    _Hello_Log("SMOKE TEST: PASS", $sLogFile)
Else
    _Hello_Log("SMOKE TEST: FAIL (" & $iFailures & " check(s))", $sLogFile)
EndIf

Exit $iFailures
