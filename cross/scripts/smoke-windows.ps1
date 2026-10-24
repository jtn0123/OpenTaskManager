<#
.SYNOPSIS
  Drives the Windows build through UI Automation (the accessibility tree Slint
  exposes), so it never moves the mouse or takes the keyboard: sorting by
  clicking headers, the order the rows then come in, search, End Task and
  Force Quit on a throwaway ping process it starts and always cleans up, one
  running copy, Start at sign-in, and settings kept across a relaunch. It
  runs its own instance (--instance smoke-PID), so the user's settings and
  sign-in entry are never touched, and removes what that instance wrote.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File cross\scripts\smoke-windows.ps1 -Exe target\release\opentaskmanager.exe
#>
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    # A safety net only: the test quits the app with --quit when it's done.
    [int]$TimeoutSeconds = 150
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$Type = [System.Windows.Automation.ControlType]

$failures = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Output "ok: $what" } else { Write-Output "FAIL: $what"; $script:failures++ }
}

# A copy of its own, so the user's settings and sign-in entry are never touched.
$Instance = "smoke-$PID"
$Settings = Join-Path $env:APPDATA "OpenTaskManager\settings-$Instance.conf"
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValue = "OpenTaskManager ($Instance)"
function Clean {
    Remove-Item -LiteralPath $Settings -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue
}
function Launch([string[]]$More = @()) {
    Start-Process -FilePath $Exe -ArgumentList (@('--instance', $Instance) + $More) -PassThru
}
function WindowOf($process) {
    $byProcess = New-Object System.Windows.Automation.PropertyCondition($A::ProcessIdProperty, $process.Id)
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        $found = $A::RootElement.FindFirst($Scope::Children, $byProcess)
        if ($found) { return $found }
    }
    throw 'The window never appeared.'
}
# Asks the running copy to quit, as a second launch with --quit does.
function Quit($process) {
    $asker = Launch @('--quit')
    $asked = $asker.WaitForExit(10000)
    $asked -and $process.WaitForExit(10000)
}

Clean
# The app also quits by itself (and removes its tray icon) once the test is surely over.
$app = Launch @('--exit-after', $TimeoutSeconds)
$again = $null
try {
    $window = WindowOf $app
    Check ($window.Current.Name -eq 'OpenTaskManager') "window titled OpenTaskManager"

    function Elements($controlType) {
        $condition = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $controlType)
        @($window.FindAll($Scope::Descendants, $condition) | ForEach-Object { $_ })
    }
    function Header([string]$title) {
        Elements $Type::Button | Where-Object { $_.Current.Name -like "$title*" } | Select-Object -First 1
    }
    function Button([string]$name) {
        Elements $Type::Button | Where-Object { $_.Current.Name -eq $name } | Select-Object -First 1
    }
    function Press([string]$name) {
        $button = Button $name
        if (-not $button) { throw "No button named $name." }
        # A button just shown can be found a moment before it can be pressed: if pressing it fails
        # and it's still there, press it again; if it's gone, its own click closed its bar.
        for ($try = 0; $try -lt 5 -and $button; $try++) {
            try {
                $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                break
            } catch {
                if ($_.FullyQualifiedErrorId -notmatch 'ElementNotAvailable') { throw }
                Start-Sleep -Milliseconds 300
                $button = Button $name
            }
        }
        Start-Sleep -Milliseconds 500
    }
    function Texts([string]$pattern) {
        @(Elements $Type::Text | ForEach-Object { $_.Current.Name } | Where-Object { $_ -match $pattern })
    }
    function Click([string]$title) {
        $header = Header $title
        if (-not $header) { throw "No header named $title." }
        $header.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Start-Sleep -Milliseconds 700
    }
    # Rows read "name, PID n, CPU x, memory y".
    function Rows {
        Elements $Type::ListItem | ForEach-Object { $_.Current.Name } | Where-Object { $_ -match ', PID \d+' }
    }
    function Bytes([string]$row) {
        if ($row -notmatch 'memory ([\d.]+) (B|KB|MB|GB|TB)$') { return $null }
        $power = @{ B = 0; KB = 1; MB = 2; GB = 3; TB = 4 }[$Matches[2]]
        [double]$Matches[1] * [math]::Pow(1024, $power)
    }
    function Ordered($values, [bool]$descending) {
        for ($i = 1; $i -lt $values.Count; $i++) {
            if ($descending -and $values[$i] -gt $values[$i - 1]) { return $false }
            if (-not $descending -and $values[$i] -lt $values[$i - 1]) { return $false }
        }
        $true
    }

    # Processes appear on the second sample after the window opens.
    for ($i = 0; $i -lt 20 -and (Rows).Count -eq 0; $i++) { Start-Sleep -Milliseconds 500 }
    $rows = @(Rows)
    Check ($rows.Count -ge 5) "the table lists processes ($($rows.Count) rows in view)"
    Check ((Header 'CPU').Current.Name -eq 'CPU, sorted highest first') "starts sorted by CPU, highest first"

    Click 'Memory'
    Check ((Header 'Memory').Current.Name -eq 'Memory, sorted highest first') "clicking Memory sorts by it, highest first"
    Check ((Header 'CPU').Current.Name -eq 'CPU') "CPU is no longer marked sorted"
    $memory = @(Rows | ForEach-Object { Bytes $_ })
    Check (Ordered $memory $true) "rows come in falling memory order"

    Click 'Memory'
    Check ((Header 'Memory').Current.Name -eq 'Memory, sorted lowest first') "a second click turns it to lowest first"
    $memory = @(Rows | ForEach-Object { Bytes $_ })
    Check (Ordered $memory $false) "rows come in rising memory order"

    Click 'Name'
    $names = @(Rows | ForEach-Object { ($_ -split ', PID ')[0].ToLowerInvariant() })
    # The app compares lowercased names character by character, so compare ordinally, not by culture.
    $sorted = [string[]]$names.Clone()
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    Check ((Header 'Name').Current.Name -eq 'Name, sorted lowest first') "clicking Name sorts A to Z"
    Check (($names -join '|') -eq ($sorted -join '|')) "rows come in name order"

    $search = Elements $Type::Edit | Select-Object -First 1
    if ($search -and $search.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$null)) {
        $query = 'svchost'
        $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($query)
        Start-Sleep -Milliseconds 900
        $found = @(Rows)
        Check ($found.Count -gt 0 -and @($found | Where-Object { $_ -notmatch $query }).Count -eq 0) "searching '$query' leaves only matching rows ($($found.Count))"

        # Windows won't let an ordinary account open csrss: its figures are unknown, shown as a dash, never 0.
        $dash = [char]0x2014
        $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('csrss')
        Start-Sleep -Milliseconds 900
        $protected = @(Rows)
        Check ($protected.Count -gt 0 -and @($protected | Where-Object { $_ -notmatch "memory $dash$" }).Count -eq 0) "a protected process (csrss) shows its memory as a dash"
        Check (@($protected | Where-Object { $_ -match 'memory 0 B$' }).Count -eq 0) "no protected process shows 0 bytes"

        # End Task and Force Quit on a process started for the purpose: ping, with no window of its own.
        $forceQuitAsk = 'Force Quit' + [char]0x2026
        Check (-not (Button 'End Task').Current.IsEnabled) "End Task is off until a process is selected"
        $start = New-Object System.Diagnostics.ProcessStartInfo 'ping', '-n 120 127.0.0.1'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $target = [System.Diagnostics.Process]::Start($start)
        try {
            $id = $target.Id
            $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue("$id")
            $row = $null
            for ($i = 0; $i -lt 10 -and -not $row; $i++) {
                Start-Sleep -Milliseconds 500
                $row = Elements $Type::ListItem | Where-Object { $_.Current.Name -match ", PID $id," } | Select-Object -First 1
            }
            if (-not $row) { throw "The ping process (PID $id) never appeared in the table." }
            # Rows are selectable list items: UI Automation selects one as a click would.
            $item = [System.Windows.Automation.SelectionItemPattern]::Pattern
            $row.GetCurrentPattern($item).Select()
            Start-Sleep -Milliseconds 500
            Check ($row.GetCurrentPattern($item).Current.IsSelected) "the row reports itself selected"
            Check (Button 'End Task').Current.IsEnabled "selecting a row turns End Task on"

            Press 'End Task'
            Check ((Texts "\(PID $id\) has no window to close\. Force Quit ends it\.").Count -eq 1) "End Task on a process without windows says Force Quit is needed"
            Check (-not $target.HasExited) "and leaves it running"

            Press $forceQuitAsk
            Check ((Texts "^Force quit .+ \(PID $id\)\? It stops at once").Count -eq 1) "Force Quit asks first, naming the process and PID"
            Press 'Cancel'
            Check ((Texts '^Force quit ').Count -eq 0 -and -not $target.HasExited) "Cancel closes the question and ends nothing"

            Press $forceQuitAsk
            Press 'Force Quit'
            Check ($target.WaitForExit(5000)) "confirming Force Quit ends the process"
            Check ((Texts "^Ended .+ \(PID $id\) at once\.$").Count -eq 1) "and says so"
            Press 'Dismiss'
            Check ((Texts "\(PID $id\)").Count -eq 0) "Dismiss clears the notice"
        } finally {
            if (-not $target.HasExited) { $target.Kill() }
        }

        # Groups. Opening one the user already has ends nothing: expand the first header in view.
        $value = [System.Windows.Automation.ValuePattern]::Pattern
        $search.GetCurrentPattern($value).SetValue('')
        Start-Sleep -Milliseconds 900
        # Rows are slots the list refills as processes come and go, so find a header and open it in one go.
        $expandPattern = [System.Windows.Automation.ExpandCollapsePattern]::Pattern
        $opened = $null
        for ($i = 0; $i -lt 5 -and -not $opened; $i++) {
            $header = Elements $Type::ListItem | Where-Object { $_.Current.Name -match ', group of \d+ processes, top PID \d+,' } | Select-Object -First 1
            $pattern = $null
            if ($header -and $header.TryGetCurrentPattern($expandPattern, [ref]$pattern) -and $header.Current.Name -match ', top PID (\d+),') {
                $top = $Matches[1]
                $before = @(Rows).Count
                try { $pattern.Expand(); $opened = $top } catch {
                    Write-Output ("  (retrying: {0}, state {1}, search '{2}')" -f $header.Current.Name, $pattern.Current.ExpandCollapseState, $search.GetCurrentPattern($value).Current.Value)
                    Start-Sleep -Milliseconds 300
                }
            } else {
                Start-Sleep -Milliseconds 300
            }
        }
        if ($opened) {
            Start-Sleep -Milliseconds 700
            $header = Elements $Type::ListItem | Where-Object { $_.Current.Name -match ", top PID $opened," } | Select-Object -First 1
            Check ($header -and $header.GetCurrentPattern($expandPattern).Current.ExpandCollapseState -eq 'Expanded') "a group header opens"
            Check (@(Rows).Count -gt $before) "and lists its processes under it"
        } else {
            Check $false "a group header in view that opens"
        }

        # A group of its own to end: cmd.exe running ping, started through a cmd that exits at once,
        # so the group has no parent and can never take in this test or the user's apps.
        $count = Get-Random -Minimum 130 -Maximum 199
        $start = New-Object System.Diagnostics.ProcessStartInfo 'cmd.exe', "/c start `"`" /b cmd.exe /c ping -n $count 127.0.0.1"
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $outer = [System.Diagnostics.Process]::Start($start)
        [void]$outer.WaitForExit(5000)
        $ping = $null
        for ($i = 0; $i -lt 20 -and -not $ping; $i++) {
            Start-Sleep -Milliseconds 250
            $ping = Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE' AND CommandLine LIKE '%-n $count %'" | Select-Object -First 1
        }
        if (-not $ping) { throw 'The test group (cmd running ping) never started.' }
        $pingId = [int]$ping.ProcessId
        $cmdId = [int]$ping.ParentProcessId
        try {
            # The details panel names what started a process.
            $search.GetCurrentPattern($value).SetValue("$pingId")
            $row = $null
            for ($i = 0; $i -lt 10 -and -not $row; $i++) {
                Start-Sleep -Milliseconds 500
                $row = Elements $Type::ListItem | Where-Object { $_.Current.Name -match ", PID $pingId," } | Select-Object -First 1
            }
            if (-not $row) { throw "The test ping (PID $pingId) never appeared in the table." }
            Check ((Elements $Type::ListItem | Where-Object { $_.Current.Name -match "^cmd\.exe, group of 2 processes, top PID $cmdId," }).Count -eq 1) "a search opens the group a match is in (cmd.exe, 2 processes)"
            $row.GetCurrentPattern($item).Select()
            Start-Sleep -Milliseconds 800
            Check ((Texts "^PING\.EXE . PID $pingId$").Count -eq 1) "selecting a process shows its details"
            Check ((Texts "^cmd\.exe \(PID $cmdId\)$").Count -eq 1) "which name what started it"
            Check ((Texts '\\PING\.EXE$').Count -ge 1) "and its program file"

            # End the whole group, chosen by its header with this test's cmd at the top.
            $search.GetCurrentPattern($value).SetValue("$cmdId")
            $group = $null
            for ($i = 0; $i -lt 10 -and -not $group; $i++) {
                Start-Sleep -Milliseconds 500
                $group = Elements $Type::ListItem | Where-Object { $_.Current.Name -match "^cmd\.exe, group of 2 processes, top PID $cmdId," } | Select-Object -First 1
            }
            if (-not $group) { throw "The test group (top PID $cmdId) never appeared." }
            $group.GetCurrentPattern($item).Select()
            Start-Sleep -Milliseconds 800
            Check ((Texts '^cmd\.exe . group of 2 processes$').Count -eq 1) "selecting a header shows the group's details"
            Press 'End Task'
            Check ((Texts "^None of cmd\.exe's 2 processes has a window to close\. Force Quit ends them\.$").Count -eq 1) "End Task on a group without windows says Force Quit is needed"
            Press $forceQuitAsk
            Check ((Texts "^Force quit cmd\.exe's group, 2 processes\? They stop at once").Count -eq 1) "Force Quit on a group asks first, with how many"
            Press 'Force Quit'
            $pingProcess = Get-Process -Id $pingId -ErrorAction SilentlyContinue
            $cmdProcess = Get-Process -Id $cmdId -ErrorAction SilentlyContinue
            Check ((-not $pingProcess -or $pingProcess.WaitForExit(5000)) -and (-not $cmdProcess -or $cmdProcess.WaitForExit(5000))) "confirming ends both processes"
            $said = Texts "cmd\.exe"
            Check ((Texts "^Ended cmd\.exe's group \(2 processes\) at once\.$").Count -eq 1) "and says so ($($said -join ' | '))"
            Press 'Dismiss'
        } finally {
            foreach ($id in @($pingId, $cmdId)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        }

        # Flat, then grouped again.
        $search.GetCurrentPattern($value).SetValue('')
        $grouping = Elements $Type::CheckBox | Where-Object { $_.Current.Name -eq 'Group by app' } | Select-Object -First 1
        $switch = $grouping.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        $switch.Toggle()
        Start-Sleep -Milliseconds 900
        Check (@(Elements $Type::ListItem | Where-Object { $_.Current.Name -match ', group of \d+ processes' }).Count -eq 0) "turning Group by app off lists every process flat"
        $switch.Toggle()
        Start-Sleep -Milliseconds 900
        Check (@(Elements $Type::ListItem | Where-Object { $_.Current.Name -match ', group of \d+ processes' }).Count -gt 0) "and on again groups them"
    } else {
        Write-Output "skipped: the search field offers no value pattern to type into"
    }

    # One copy: a second launch hands over to the first and exits.
    $second = Launch
    Check ($second.WaitForExit(10000) -and $second.ExitCode -eq 0) "a second launch hands over and exits"
    Check (-not $app.HasExited) "and the first copy keeps running"

    # Start at sign-in writes and removes this instance's Run value.
    $signIn = Elements $Type::CheckBox | Where-Object { $_.Current.Name -eq 'Start at sign-in' } | Select-Object -First 1
    if ($signIn) {
        $toggle = $signIn.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        Check ($toggle.Current.ToggleState -eq 'Off') "Start at sign-in starts off"
        $toggle.Toggle()
        Start-Sleep -Milliseconds 600
        $command = (Get-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue).$RunValue
        $expected = '"' + (Resolve-Path $Exe).Path + '" --hidden --instance ' + $Instance
        Check ($command -eq $expected) "turning it on writes the Run value ($command)"
        $toggle.Toggle()
        Start-Sleep -Milliseconds 600
        Check ($null -eq (Get-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue)) "turning it off removes it"
    } else {
        Check $false "a Start at sign-in check box"
    }

    # Settings outlive the copy: the size the window was given and the sort (Name, A to Z, from above).
    $transform = $null
    if ($window.TryGetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern, [ref]$transform) -and $transform.Current.CanResize) {
        $transform.Resize(1000, 700)
        Start-Sleep -Milliseconds 800
    }
    $size = $window.Current.BoundingRectangle
    Check (Quit $app) "--quit closes the running copy"
    Check ((Test-Path $Settings) -and (Get-Content $Settings -Raw) -match 'sort-column = name') "the settings file keeps the sort"
    $again = Launch @('--exit-after', $TimeoutSeconds)
    $window = WindowOf $again
    for ($i = 0; $i -lt 20 -and (Rows).Count -eq 0; $i++) { Start-Sleep -Milliseconds 500 }
    Check ((Header 'Name').Current.Name -eq 'Name, sorted lowest first') "reopened, it still sorts by name"
    $reopened = $window.Current.BoundingRectangle
    Check ([math]::Abs($reopened.Width - $size.Width) -le 2 -and [math]::Abs($reopened.Height - $size.Height) -le 2) "and opens at the size it closed at ($($reopened.Width)x$($reopened.Height))"
    Check (Quit $again) "--quit closes it again"
} finally {
    foreach ($copy in @($app, $again)) {
        if ($copy -and -not $copy.WaitForExit(($TimeoutSeconds + 15) * 1000)) {
            Stop-Process -Id $copy.Id -Force
            Write-Output "FAIL: the app didn't quit"
            $failures++
        }
    }
    Clean
}

if ($failures -gt 0) { Write-Output "$failures check(s) failed"; exit 1 }
Write-Output 'All smoke checks passed.'
