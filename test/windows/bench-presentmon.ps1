# PresentMon ETW adapter for cross-terminal comparability.
#
# The benchmark suite's own cold-start and idle metrics read noctty's internal
# instrumentation: `cold_start_app_ms` comes from the render trace field
# `process_start_to_first_swap_ms`, and `idle_swap_count_delta` counts swap
# atomics inside the process. No competing terminal exposes an equivalent
# counter, so those metrics stay `not-supported` for every other target.
#
# This file adds a second, instrument-symmetric layer: the same external
# observer measures every target the same way. PresentMon reports presents
# through ETW with QueryPerformanceCounter timestamps, which satisfies the
# comparability requirement stated in `New-BenchAdapterRequiredMetric` -
# measurement ends at presentation evidence rather than producer-only timing.
#
# Elevation is required: PresentMon opens an ETW trace session. Callers must
# check `Test-BenchPresentMonReady` and degrade to a status other than `pass`
# when it returns a reason.

$script:BenchPresentMonSessionPrefix = 'noctty-bench'

function Get-BenchPresentMonPath {
    $command = Get-Command presentmon -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    return $null
}

function Test-BenchProcessElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Returns $null when PresentMon can be used, otherwise a human-readable reason.
function Test-BenchPresentMonReady {
    if (-not [Diagnostics.Stopwatch]::IsHighResolution) {
        return 'QueryPerformanceCounter is unavailable, so PresentMon QPC timestamps cannot be correlated with launch time'
    }
    if ($null -eq (Get-BenchPresentMonPath)) {
        return 'presentmon.exe was not found on PATH; install Intel.PresentMon.Console'
    }
    if (-not (Test-BenchProcessElevated)) {
        return 'PresentMon opens an ETW trace session and requires an elevated shell'
    }
    return $null
}

function Get-BenchPresentMonVersion {
    $path = Get-BenchPresentMonPath
    if ($null -eq $path) { return $null }
    $version = (Get-Item -LiteralPath $path).VersionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($version)) { return $null }
    return $version.Trim()
}

# PresentMon attributes rows to a process id, so a second instance of the same
# executable does not corrupt a measurement by itself. It does break one thing:
# a terminal that folds a new window into an already running process leaves the
# launched process id with no presents at all, which would silently read as a
# failed capture. noctty is launched with `--single-instance=false` and always
# gets its own process, so callers skip this check for it.
function Wait-BenchNoForeignTargetProcess {
    param(
        [Parameter(Mandatory)] [string] $ProcessName,
        [ValidateRange(0, 120)] [int] $TimeoutSeconds = 20
    )

    $bareName = [IO.Path]::GetFileNameWithoutExtension($ProcessName)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $existing = @(Get-Process -Name $bareName -ErrorAction SilentlyContinue)
        if ($existing.Count -eq 0) { return }
        if ([DateTime]::UtcNow -ge $deadline) {
            $ids = ($existing | ForEach-Object { $_.Id }) -join ', '
            throw "$ProcessName is still running (pid $ids) after ${TimeoutSeconds}s; a leftover window absorbs the next launch and leaves it with no presents"
        }
        # A previous run's window can take a moment to go away, so wait for it
        # instead of failing the whole measurement on the first check.
        Start-Sleep -Milliseconds 250
    }
}

function Start-BenchPresentMonCapture {
    param(
        [Parameter(Mandatory)] [string] $ProcessName,
        [Parameter(Mandatory)] [string] $CsvPath,
        [switch] $ExcludeDropped
    )

    $reason = Test-BenchPresentMonReady
    if ($null -ne $reason) { throw $reason }

    Remove-Item -LiteralPath $CsvPath -ErrorAction SilentlyContinue
    $sessionName = '{0}-{1}' -f $script:BenchPresentMonSessionPrefix, [Guid]::NewGuid().ToString('N').Substring(0, 8)

    $arguments = @(
        '--process_name', $ProcessName,
        '--output_file', $CsvPath,
        '--qpc_time',
        '--no_console_stats',
        '--session_name', $sessionName,
        '--stop_existing_session'
    )
    if ($ExcludeDropped) { $arguments += '--exclude_dropped' }

    $process = Start-Process -FilePath (Get-BenchPresentMonPath) -ArgumentList $arguments -PassThru -WindowStyle Hidden
    return [pscustomobject]@{
        Process = $process
        CsvPath = $CsvPath
        SessionName = $sessionName
        ProcessName = $ProcessName
    }
}

function Stop-BenchPresentMonCapture {
    param(
        [Parameter(Mandatory)] [object] $Capture,
        [ValidateRange(1, 120)] [int] $TimeoutSeconds = 20
    )

    if ($null -ne $Capture.Process -and -not $Capture.Process.HasExited) {
        # PresentMon flushes the CSV on a clean shutdown. Killing it can leave a
        # truncated final row, so ask the session to stop first and only fall
        # back to a kill if it refuses.
        & (Get-BenchPresentMonPath) --session_name $Capture.SessionName --terminate_existing_session 2>&1 | Out-Null
        if (-not $Capture.Process.WaitForExit($TimeoutSeconds * 1000)) {
            $Capture.Process.Kill()
            $Capture.Process.WaitForExit(5000) | Out-Null
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Capture.CsvPath -PathType Leaf) {
            try {
                $stream = [IO.File]::Open($Capture.CsvPath, 'Open', 'Read', 'None')
                $stream.Dispose()
                return
            }
            catch { }
        }
        Start-Sleep -Milliseconds 50
    }
    throw "PresentMon did not produce a readable CSV at $($Capture.CsvPath)"
}

function Get-BenchPresentMonRows {
    param(
        [Parameter(Mandatory)] [string] $CsvPath,
        [int] $ProcessId
    )

    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) { return @() }
    $rows = @(Import-Csv -LiteralPath $CsvPath)
    if ($PSBoundParameters.ContainsKey('ProcessId')) {
        $rows = @($rows | Where-Object { [int] $_.ProcessID -eq $ProcessId })
    }
    # PresentMon writes rows in capture order, but a kill during a flush can
    # leave the last row short. Drop anything without a usable timestamp.
    return @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.TimeInQPC) })
}

function Get-BenchFirstPresentQpc {
    param(
        [Parameter(Mandatory)] [object[]] $Rows
    )

    $timestamps = @($Rows | ForEach-Object {
        $value = 0L
        if ([long]::TryParse($_.TimeInQPC, [ref] $value)) { $value }
    })
    if ($timestamps.Count -eq 0) { return $null }
    return ($timestamps | Measure-Object -Minimum).Minimum
}

function Get-BenchQpcDeltaMilliseconds {
    param(
        [Parameter(Mandatory)] [long] $StartQpc,
        [Parameter(Mandatory)] [long] $EndQpc
    )

    if ($EndQpc -le $StartQpc) { return $null }
    return [Math]::Round((($EndQpc - $StartQpc) / [double] [Diagnostics.Stopwatch]::Frequency) * 1000.0, 6)
}
