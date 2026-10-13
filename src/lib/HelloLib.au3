; HelloLib.au3 - tiny project-local UDF library used by the smoke test.
; Demonstrates that relative includes next to the script work, and that the
; AutoIt install Include folder can be mixed in freely.

#include-once
#include <FileConstants.au3>
#include <StringConstants.au3>

; Writes a message to the console and appends it to a log file.
; Returns 1 on success, 0 when the log file could not be opened.
Func _Hello_Log($sMessage, $sLogFile = "")
    ConsoleWrite($sMessage & @CRLF)
    If $sLogFile = "" Then Return 1

    Local $hFile = FileOpen($sLogFile, $FO_APPEND + $FO_CREATEPATH + $FO_UTF8)
    If $hFile = -1 Then Return 0

    FileWrite($hFile, $sMessage & @CRLF)
    FileClose($hFile)
    Return 1
EndFunc   ;==>_Hello_Log

; Returns a greeting; an empty or whitespace-only name becomes "world".
Func _Hello_Greet($sName)
    If StringStripWS($sName, $STR_STRIPALL) = "" Then $sName = "world"
    Return "Hello, " & $sName & "!"
EndFunc   ;==>_Hello_Greet
