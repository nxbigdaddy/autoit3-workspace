; broken-sample.au3 - intentionally invalid, used as a fixture to verify that
; Au3Check reports errors and that the VS Code problem matcher picks them up.
; Expected: Au3Check exits 2 and reports 1 error on line 7.

Global $x = 1

If $x = 1 Then
    ConsoleWrite("missing EndIf"
