# build-acceptance.ps1 — generate the acceptance criteria file from the flow.json acceptance declaration
#
# Why generate it: the paths in the acceptance criteria (Results / export directories / calendar) are
# derived from flow variables anyway. Hand-writing two copies is bound to drift: change ResultsDir and the
# acceptance check still looks at the old directory, giving "run succeeded but acceptance failed".
#
# Rules:
#   {{variables.X}}  → the value of variable X (a deployKey variable outputs {{KEY}}, everything else uses default)
#   %X%              → same as above; both forms are supported so this reads like the .robin
#   resolved recursively until the text stops changing (e.g. %PadRoot%\Results)
#
# Usage:
#   .\build-acceptance.ps1 -FlowFile business\flows\sample-report.json -OutFile <target path>
#   .\build-acceptance.ps1 -FlowFile business\flows\sample-report.json -Check   # validate and print only
#
# Exit codes: 0 success / 1 the declaration is broken

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$FlowFile,
    [string]$OutFile,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

# The criterion types PadAcceptance understands; anything else in the declaration is rejected outright, so we never generate a criterion that can never run
$KNOWN_TYPES = @('fileExists', 'globNewerThan', 'pair', 'json', 'jsonl', 'logState')

function Resolve-FlowExpr([string]$Text, [hashtable]$Map) {
    $cur = [string]$Text
    for ($i = 0; $i -lt 8; $i++) {
        $before = $cur
        foreach ($k in $Map.Keys) {
            $v = [string]$Map[$k]
            $cur = $cur.Replace("{{variables.$k}}", $v)
            $cur = $cur.Replace("{{$k}}", $v)
            $cur = $cur.Replace("%$k%", $v)
        }
        if ($cur -eq $before) { break }
    }
    return $cur
}

# Recursive resolution: substitute in strings, walk arrays element by element, walk objects property by property
function Resolve-Node($Node, [hashtable]$Map) {
    if ($null -eq $Node) { return $null }
    if ($Node -is [string]) { return Resolve-FlowExpr $Node $Map }
    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        return @($Node | ForEach-Object { Resolve-Node $_ $Map })
    }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $o = [ordered]@{}
        foreach ($p in $Node.PSObject.Properties) { $o[$p.Name] = Resolve-Node $p.Value $Map }
        return [pscustomobject]$o
    }
    return $Node
}

try {
    $flow = [IO.File]::ReadAllText($FlowFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
} catch {
    Write-Error "failed to read flow.json: $($_.Exception.Message)"
    exit 1
}

if (-not $flow.acceptance -or -not $flow.acceptance.checks) {
    Write-Error "flow.json has no acceptance.checks; cannot build acceptance criteria"
    exit 1
}

# Variable name → value: deployment parameters use {{KEY}}, derived paths use default
$vars = @{}
foreach ($v in @($flow.variables)) {
    $name = [string]$v.name
    if (-not $name) { continue }
    if ($v.deployKey) { $vars[$name] = "{{$($v.deployKey)}}" }
    elseif ($null -ne $v.default) { $vars[$name] = [string]$v.default }
}

$checks = @()
$errs = @()
foreach ($c in @($flow.acceptance.checks)) {
    $resolved = Resolve-Node $c $vars
    $type = [string]$resolved.type
    if (-not $resolved.name) { $errs += "one criterion is missing name" }
    if ($KNOWN_TYPES -notcontains $type) {
        $errs += "criterion '$($resolved.name)' has an unsupported type $type (supported: $($KNOWN_TYPES -join ' / '))"
    }
    foreach ($s in @($resolved.path, $resolved.dir) + @($resolved.paths)) {
        # Only deployment placeholders such as {{PAD_ROOT}} may remain (the config substitutes them at acceptance time)
        if ($s -and ($s -match '\{\{variables\.' -or $s -match '%[A-Za-z_]\w*%')) {
            $errs += "criterion '$($resolved.name)' has an unresolved reference: $s"
        }
    }
    $checks += $resolved
}

if ($errs.Count -gt 0) {
    foreach ($e in $errs) { Write-Host "[build-acceptance] error: $e" }
    exit 1
}

$spec = [ordered]@{
    version     = 1
    description = if ($flow.acceptance.description) { [string]$flow.acceptance.description } else { [string]$flow.name }
    checks      = $checks
}
$json = $spec | ConvertTo-Json -Depth 12

if ($Check) {
    Write-Host "[build-acceptance] $($checks.Count) criteria passed validation (no file written)"
    Write-Output $json
    exit 0
}

if (-not $OutFile) {
    Write-Error "-OutFile is missing (or use -Check to validate only)"
    exit 1
}
$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[IO.File]::WriteAllText($OutFile, $json, (New-Object Text.UTF8Encoding($false)))
Write-Host "[build-acceptance] generated $OutFile ($($checks.Count) criteria)"
exit 0
