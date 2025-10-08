; AutoHotkey v2 script
; Caps Lock: Tap for Escape, Hold for Shift
; Then map Caps Lock to Escape

#Requires AutoHotkey v2.0

; Disable the default Caps Lock functionality
SetCapsLockState "AlwaysOff"

; Variables to track the state
capsPressed := false
startTime := 0
holdThreshold := 150  ; milliseconds - adjust as needed

; When Caps Lock is pressed down
CapsLock::
{
    global capsPressed, startTime
    capsPressed := true
    startTime := A_TickCount
    
    ; Send Shift down for hold functionality
    Send "{LShift down}"
}

; When Caps Lock is released
CapsLock up::
{
    global capsPressed, startTime, holdThreshold
    
    if (capsPressed) {
        ; Send Shift up to release the hold
        Send "{LShift up}"
        
        ; Calculate how long it was held
        duration := A_TickCount - startTime
        
        ; If it was a quick tap (less than threshold), send Escape
        if (duration < holdThreshold) {
            Send "{Escape}"
        }
        
        capsPressed := false
    }
}

; Additional mapping: Map Caps Lock to Escape (this will override the above when uncommented)
; If you want a simple Caps Lock -> Escape mapping instead, uncomment the line below:
; CapsLock::Escape

; --- Additional Shortcuts ---

; Super (Windows) + Q closes current window
#q::Send "!{F4}"
