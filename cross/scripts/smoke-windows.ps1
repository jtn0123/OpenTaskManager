<#
.SYNOPSIS
  Drives the Windows build through UI Automation (the accessibility tree Slint
  exposes), so it never moves the mouse or takes the keyboard: sorting by
  clicking headers, the order the rows then come in, and search.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File cross\scripts\smoke-windows.ps1 -Exe target\release\opentaskmanager.exe
#>
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [int]$TimeoutSeconds = 45
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

# The app quits by itself (and removes its tray icon) once the test is surely over.
$app = Start-Process -FilePath $Exe -ArgumentList '--exit-after', $TimeoutSeconds -PassThru
try {
    $byProcess = New-Object System.Windows.Automation.PropertyCondition($A::ProcessIdProperty, $app.Id)
    $window = $null
    for ($i = 0; $i -lt 60 -and -not $window; $i++) {
        Start-Sleep -Milliseconds 500
        $window = $A::RootElement.FindFirst($Scope::Children, $byProcess)
    }
    if (-not $window) { throw 'The window never appeared.' }
    Check ($window.Current.Name -eq 'OpenTaskManager') "window titled OpenTaskManager"

    function Elements($controlType) {
        $condition = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $controlType)
        @($window.FindAll($Scope::Descendants, $condition) | ForEach-Object { $_ })
    }
    function Header([string]$title) {
        Elements $Type::Button | Where-Object { $_.Current.Name -like "$title*" } | Select-Object -First 1
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
    } else {
        Write-Output "skipped: the search field offers no value pattern to type into"
    }
} finally {
    if (-not $app.WaitForExit(($TimeoutSeconds + 15) * 1000)) {
        Stop-Process -Id $app.Id -Force
        Write-Output "FAIL: the app didn't quit by itself"
        $failures++
    }
}

if ($failures -gt 0) { Write-Output "$failures check(s) failed"; exit 1 }
Write-Output 'All smoke checks passed.'
