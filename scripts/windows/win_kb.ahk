; AutoHotkey v2 script
; Caps Lock: Acts as Shift when used with another key, otherwise Escape
; Left Shift acts as Ctrl
; Super (Windows) + Q closes current window

#Requires AutoHotkey v2.0
SetCapsLockState "AlwaysOff"

capsUsed := false  ; tracks if any other key was pressed while CapsLock held

; --- CapsLock behavior ---
*CapsLock::
{
    global capsUsed
    capsUsed := false
    Send "{Shift down}"

    ih := InputHook("V") ; watch for any key press
    ih.KeyOpt("{All}", "E") ; mark all keys as end keys
    ih.Start()
    ih.Wait()  ; waits until a key is pressed or CapsLock released

    if (ih.EndKey != "CapsLock") {
        capsUsed := true
    }
}

*CapsLock up::
{
    global capsUsed
    Send "{Shift up}"
    if !capsUsed {
        Send "{Escape}"
    }
}

; --- Left Shift acts as Ctrl ---
LShift::
{
    Send "{LCtrl down}"
}
LShift up::
{
    Send "{LCtrl up}"
}

; --- Super (Windows) + Q closes current window ---
#q::Send "!{F4}"