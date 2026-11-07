on dumpEl(e, depth, maxDepth)
  set out to ""
  tell application "System Events"
    set r to "" 
    try
      set r to role of e
    end try
    set d to ""
    try
      set d to description of e
    end try
    set n to ""
    try
      set n to name of e
      if n is missing value then set n to ""
    end try
    set v to ""
    try
      set v to value of e as text
      if (count of v) > 60 then set v to text 1 thru 60 of v
    end try
    set h to ""
    try
      set h to value of attribute "AXHelp" of e
      if h is missing value then set h to ""
    end try
    set t to ""
    try
      set t to value of attribute "AXTitle" of e
      if t is missing value then set t to ""
    end try
    set pos to ""
    try
      set {x, y} to position of e
      set {wd, ht} to size of e
      set pos to (x as text) & "," & (y as text) & " " & (wd as text) & "x" & (ht as text)
    end try
    set pad to ""
    repeat depth times
      set pad to pad & "  "
    end repeat
    set out to pad & r & " [" & d & "] '" & n & "' t=" & t & " h=" & h & " =" & v & " @" & pos & linefeed
    if depth < maxDepth then
      try
        repeat with c in (UI elements of e)
          set out to out & my dumpEl(c, depth + 1, maxDepth)
        end repeat
      end try
    end if
  end tell
  return out
end dumpEl
on run argv
  set pid to (item 1 of argv) as integer
  set maxDepth to (item 2 of argv) as integer
  tell application "System Events"
    set p to first process whose unix id is pid
    set w to window 1 of p
  end tell
  return dumpEl(w, 0, maxDepth)
end run
