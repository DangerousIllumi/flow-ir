# trigger-file.Tests.ps1 — file (file-arrival) trigger branch tests (Pester 3.4)
#
# Covers: literal path rejected, read-only config-key resolution, 0/1/2+ candidates, the poll_sec lower bound,
#         max_wait_sec timeout exiting 0, ledger de-duplication of the same file, -Test/Register -DryRun writing nothing.
# Everything runs in temp directories, never touching real business paths, registering no scheduled task and starting no daemon.

Import-Module (Join-Path $PSScriptRoot '..\tools\pad-sync\TriggerRegistry.psm1') -Force
$script:FileModule = Get-Module TriggerRegistry
$script:FileCli = Join-Path $PSScriptRoot '..\tools\pad-sync\pad-trigger.ps1'

# Smallest possible file trigger flow; dir always comes from a config reference
function New-FileFlow {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Name,
        [string]$FileDir = '{{config.INBOX_PATH}}',
        [string]$Pattern = '*.csv',
        [int]$PollSec = 60,
        [int]$SettleSec = 60,
        [int]$MaxWaitSec = 7200,
        [bool]$OncePerFile = $true
    )
    $trigger = [ordered]@{
        kind = 'file'; time = '09:00'; gate = 'none'
        file = [ordered]@{
            dir = $FileDir; pattern = $Pattern
            poll_sec = $PollSec; settle_sec = $SettleSec
            max_wait_sec = $MaxWaitSec; once_per_file = $OncePerFile
        }
    }
    $path = Join-Path $Dir ($Name + '.json')
    $obj = [ordered]@{
        name = 'PESTER_FILE_TRIGGER'
        trigger = $trigger
        nodes = @([ordered]@{ id = '1'; pad_hint = 'Comment.Comment'; run_mode = 'auto' })
    }
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 8),
        (New-Object Text.UTF8Encoding($false)))
    return $path
}

function New-FileConfig {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$InboxPath)
    $path = Join-Path $Dir 'flow-config.json'
    # Deliberately uses a key outside the fixed PadConfig key set, to prove read-only resolution does not depend on those 6 keys
    $obj = [ordered]@{ INBOX_PATH = $InboxPath; ANY_OTHER_KEY = 'demo' }
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json),
        (New-Object Text.UTF8Encoding($false)))
    return $path
}

function New-FileRuntime {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$StateDir)
    $path = Join-Path $Dir 'runtime.json'
    $obj = [ordered]@{
        PadSyncPath   = 'C:\tmp\pad-sync.ps1'
        PythonExe     = 'python'
        CalendarPath  = 'C:\tmp\workday-calendar.xlsx'
        WorkdayScript = 'C:\tmp\workday.py'
        RunTimeoutSec = 4200
        TriggerStateDir = $StateDir
    }
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json),
        (New-Object Text.UTF8Encoding($false)))
    return $path
}

# Directory snapshot: directory mtime plus a name/size/last-write listing, used to prove -Test writes no file
function Get-DirSnapshot([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'MISSING' }
    $dir = Get-Item -LiteralPath $Path
    $items = @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object { '{0}|{1}|{2}' -f $_.Name, $_.Length, $_.LastWriteTimeUtc.ToString('o') })
    return ('DIR=' + $dir.LastWriteTimeUtc.ToString('o') + "`n" + ($items -join "`n"))
}

function Get-FileErrorCode {
    param([scriptblock]$Action)
    try {
        & $Action | Out-Null
        return 'NO_ERROR'
    } catch {
        if ($_.Exception.Data.Contains('code')) { return [string]$_.Exception.Data['code'] }
        return 'UNKNOWN'
    }
}

Describe 'file declaration and config resolution' {

    It 'file.dir as a literal path → TRIGGER_PATH_LITERAL' {
        $f = New-FileFlow -Dir $TestDrive -Name 'literal' -FileDir 'C:\inbox'
        (Get-FileErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'TRIGGER_PATH_LITERAL'
    }

    It 'Read-only config resolution: keys outside the PadConfig fixed key set resolve' {
        $listen = Join-Path $TestDrive 'listen-a'
        New-Item -ItemType Directory -Path $listen -Force | Out-Null
        $cfg = New-FileConfig -Dir $TestDrive -InboxPath $listen
        $got = & $script:FileModule {
            param($Token, $ConfigFile)
            Resolve-TriggerConfigRef -Token $Token -ConfigFile $ConfigFile
        } '{{config.INBOX_PATH}}' $cfg
        $got | Should Be $listen
    }

    It 'Key missing from the config → TRIGGER_CONFIG_UNRESOLVED' {
        $cfg = New-FileConfig -Dir $TestDrive -InboxPath (Join-Path $TestDrive 'x')
        (Get-FileErrorCode {
            & $script:FileModule {
                param($Token, $ConfigFile)
                Resolve-TriggerConfigRef -Token $Token -ConfigFile $ConfigFile
            } '{{config.NO_SUCH_KEY}}' $cfg
        }) | Should Be 'TRIGGER_CONFIG_UNRESOLVED'
    }

    It 'poll_sec below 15 → TRIGGER_INVALID' {
        $f = New-FileFlow -Dir $TestDrive -Name 'poll-14' -PollSec 14
        (Get-FileErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'TRIGGER_INVALID'
    }
}

Describe 'file -Test read-only validation' {

    It 'Zero candidates: the directory is readable and the status is ready' {
        $listen = Join-Path $TestDrive 'listen-zero'
        New-Item -ItemType Directory -Path $listen -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $listen 'note.txt') -Value 'x'
        $state = Join-Path $TestDrive 'state-zero'
        New-Item -ItemType Directory -Path $state -Force | Out-Null
        $f = New-FileFlow -Dir $TestDrive -Name 'zero'
        $cfg = New-FileConfig -Dir $TestDrive -InboxPath $listen
        $rt = New-FileRuntime -Dir $TestDrive -StateDir $state
        $r = Test-Trigger -FlowFile $f -ConfigFile $cfg -RuntimeConfigPath $rt
        $r.ok | Should Be $true
        $r.status | Should Be 'ready'
        @($r.candidates).Count | Should Be 0
    }

    It 'One candidate: ready, with no extra selection' {
        $listen = Join-Path $TestDrive 'listen-one'
        New-Item -ItemType Directory -Path $listen -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $listen 'report.csv') -Value 'a,b'
        $state = Join-Path $TestDrive 'state-one'
        New-Item -ItemType Directory -Path $state -Force | Out-Null
        $f = New-FileFlow -Dir $TestDrive -Name 'one'
        $cfg = New-FileConfig -Dir $TestDrive -InboxPath $listen
        $rt = New-FileRuntime -Dir $TestDrive -StateDir $state
        $r = Test-Trigger -FlowFile $f -ConfigFile $cfg -RuntimeConfigPath $rt
        $r.ok | Should Be $true
        $r.status | Should Be 'ready'
        @($r.candidates).Count | Should Be 1
        @($r.candidates)[0] | Should Be 'report.csv'
    }

    It 'Two or more candidates: TRIGGER_FILE_AMBIGUOUS, never the newest' {
        $listen = Join-Path $TestDrive 'listen-many'
        New-Item -ItemType Directory -Path $listen -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $listen 'a.csv') -Value '1'
        Set-Content -LiteralPath (Join-Path $listen 'b.csv') -Value '2'
        $state = Join-Path $TestDrive 'state-many'
        New-Item -ItemType Directory -Path $state -Force | Out-Null
        $f = New-FileFlow -Dir $TestDrive -Name 'many'
        $cfg = New-FileConfig -Dir $TestDrive -InboxPath $listen
        $rt = New-FileRuntime -Dir $TestDrive -StateDir $state
        $r = Test-Trigger -FlowFile $f -ConfigFile $cfg -RuntimeConfigPath $rt
        $r.ok | Should Be $false
        $r.code | Should Be 'TRIGGER_FILE_AMBIGUOUS'
        $r.status | Should Be 'ambiguous'
        @($r.candidates).Count | Should Be 2
    }

    It '-Test writes no files: the watched directory and state directory keep identical mtimes and file listings before and after' {
        $listen = Join-Path $TestDrive 'listen-nowrite'
        New-Item -ItemType Directory -Path $listen -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $listen 'only.csv') -Value 'abc'
        $state = Join-Path $TestDrive 'state-nowrite'
        New-Item -ItemType Directory -Path $state -Force | Out-Null
        $f = New-FileFlow -Dir $TestDrive -Name 'nowrite'
        $cfg = New-FileConfig -Dir $TestDrive -InboxPath $listen
        $rt = New-FileRuntime -Dir $TestDrive -StateDir $state
        $beforeListen = Get-DirSnapshot $listen
        $beforeState = Get-DirSnapshot $state
        Test-Trigger -FlowFile $f -ConfigFile $cfg -RuntimeConfigPath $rt | Out-Null
        (Get-DirSnapshot $listen) | Should Be $beforeListen
        (Get-DirSnapshot $state) | Should Be $beforeState
    }

    It 'Register -DryRun only returns planned, creating no state directory and registering no task' {
        $listen = Join-Path $TestDrive 'listen-dry'
        New-Item -ItemType Directory -Path $listen -Force | Out-Null
        $state = Join-Path $TestDrive 'state-dry-not-created'
        $f = New-FileFlow -Dir $TestDrive -Name 'dry'
        $cfg = New-FileConfig -Dir $TestDrive -InboxPath $listen
        $rt = New-FileRuntime -Dir $TestDrive -StateDir $state
        $r = Register-Trigger -FlowFile $f -ConfigFile $cfg -RuntimeConfigPath $rt -DryRun
        $r.ok | Should Be $true
        $r.changed | Should Be 'planned'
        $r.args | Should Match 'pad-trigger\.ps1'
        $r.args | Should Match '-Watch'
        (Test-Path -LiteralPath $state) | Should Be $false
        (@(Get-ScheduledTask -TaskName $r.taskName -ErrorAction SilentlyContinue).Count) | Should Be 0
    }
}

Describe 'file watch and ledger' {

    It 'max_wait_sec expiry exits quietly with 0 (empty directory, no waiting for a file)' {
        $listen = Join-Path $TestDrive 'listen-timeout'
        New-Item -ItemType Directory -Path $listen -Force | Out-Null
        $state = Join-Path $TestDrive 'state-timeout'
        New-Item -ItemType Directory -Path $state -Force | Out-Null
        $f = New-FileFlow -Dir $TestDrive -Name 'timeout' -PollSec 15 -SettleSec 1 -MaxWaitSec 1
        $cfg = New-FileConfig -Dir $TestDrive -InboxPath $listen
        $rt = New-FileRuntime -Dir $TestDrive -StateDir $state
        $r = Invoke-TriggerWatch -FlowFile $f -ConfigFile $cfg -RuntimeConfigPath $rt
        $r.ok | Should Be $true
        $r.status | Should Be 'timeout'
        ($null -eq $r.triggeredFileName) | Should Be $true
    }

    It 'The ledger key is fileName|size|lastWriteUtc, and the same file returns false the second time' {
        $listen = Join-Path $TestDrive 'listen-ledger'
        New-Item -ItemType Directory -Path $listen -Force | Out-Null
        $file = Join-Path $listen 'report.csv'
        Set-Content -LiteralPath $file -Value 'abc'
        $state = Join-Path $TestDrive 'state-ledger'
        New-Item -ItemType Directory -Path $state -Force | Out-Null
        $ledger = Join-Path $state 'flow-ir-PESTER_FILE_TRIGGER.json'
        $info = Get-Item -LiteralPath $file
        $key = & $script:FileModule { param($F) Get-TriggerFileKey $F } $info
        $parts = $key -split '\|'
        $parts.Count | Should Be 3
        $parts[0] | Should Be 'report.csv'
        $parts[1] | Should Be ([string]$info.Length)
        $first = & $script:FileModule { param($P, $K) Add-TriggerLedgerKey -Path $P -Key $K } $ledger $key
        $first | Should Be $true
        $second = & $script:FileModule { param($P, $K) Add-TriggerLedgerKey -Path $P -Key $K } $ledger $key
        $second | Should Be $false
        (Test-Path -LiteralPath $ledger) | Should Be $true
        $json = [IO.File]::ReadAllText($ledger, [Text.Encoding]::UTF8) | ConvertFrom-Json
        (@($json.keys) -contains $key) | Should Be $true
    }

    It 'CLI -Watch timeout: exit code 0 with a final status=timeout line' {
        $listen = Join-Path $TestDrive 'listen-cli-timeout'
        New-Item -ItemType Directory -Path $listen -Force | Out-Null
        $state = Join-Path $TestDrive 'state-cli-timeout'
        New-Item -ItemType Directory -Path $state -Force | Out-Null
        $f = New-FileFlow -Dir $TestDrive -Name 'cli-timeout' -PollSec 15 -SettleSec 1 -MaxWaitSec 1
        $cfg = New-FileConfig -Dir $TestDrive -InboxPath $listen
        $rt = New-FileRuntime -Dir $TestDrive -StateDir $state
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:FileCli `
            -FlowFile $f -ConfigFile $cfg -RuntimeConfigPath $rt -Watch 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0
        $r = [regex]::Match($out, 'PAD_TRIGGER_RESULT=(\{.*\})').Groups[1].Value | ConvertFrom-Json
        $r.status | Should Be 'timeout'
    }
}
