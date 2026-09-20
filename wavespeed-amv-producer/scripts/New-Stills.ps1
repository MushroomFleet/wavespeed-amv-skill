<#
.SYNOPSIS
    Generate seed frames on Higgsfield from a directory of prompt files. Optional - only needed
    when the user does not already have reference images.

.DESCRIPTION
    One .txt per still in -PromptDir, generated in sorted order and saved to -OutDir under the
    same basename. Submission is never retried, because a retry spends credits again; a still that
    already exists is skipped, so a partial run resumes by re-running.

    Emits one object per still to the pipeline; progress goes to the host.

    TWO TRAPS THIS ENCODES, both of which produce silently wrong output rather than an error:

    1. The CLI splits an argument on NEWLINES. A multi-paragraph prompt loses everything after the
       first blank line AND pushes the later flags out of position, so the job runs at the default
       aspect ratio from a truncated prompt with no error anywhere. Prompts are collapsed to one
       line before submission; the .txt files stay readable.

    2. A SPACE in a file path breaks the CLI's signed upload - it computes the S3 signature from
       the path and the request then fails with SignatureDoesNotMatch. Reference images are staged
       through a space-free temp path and pre-uploaded as media ids.

.PARAMETER ReferenceImage
    Up to 10 donor images. Pass a character sheet when a subject must stay consistent across
    shots. Leave it off for landscapes: the model follows references strongly and a shared donor
    pulls otherwise distinct compositions toward each other.

.EXAMPLE
    pwsh -File New-Stills.ps1 -PromptDir prompts/stills -OutDir renders -DryRun
    $stills = ./New-Stills.ps1 -PromptDir prompts/stills -OutDir renders -ReferenceImage keyart/sheet.png
#>
[CmdletBinding()]
param(
    [string]   $PromptDir   = 'prompts/stills',
    [string]   $OutDir      = 'renders',
    [string]   $ProjectRoot = '.',
    [string[]] $Only,
    [string[]] $ReferenceImage,
    [string]   $Model       = 'seedream_v5_pro',
    [string]   $Resolution  = '2k',
    [string]   $AspectRatio = '16:9',
    [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_Common.ps1')

function Assert-Higgsfield {
    if (-not (Get-Command higgsfield -ErrorAction SilentlyContinue)) {
        throw "higgsfield CLI not found. Install it, then run 'higgsfield auth login'."
    }
    $acct = (Invoke-Tool -Exe 'higgsfield' -Arguments @('account', 'status') -TimeoutSec 120).StdOut
    if ($acct -match 'expired|not authenticated') {
        throw "higgsfield is not authenticated. Run 'higgsfield auth login'."
    }
    return $acct.Trim()
}

function Publish-Donor {
    <#  Stage through a space-free path and pre-upload, returning a media id. See trap 2. #>
    param([string] $Path)
    if (-not (Test-Path $Path)) { throw "reference image not found: $Path" }
    $stage = Join-Path ([IO.Path]::GetTempPath()) 'hf-refs'
    if (-not (Test-Path $stage)) { New-Item -ItemType Directory -Path $stage | Out-Null }
    $tmp = Join-Path $stage ([IO.Path]::GetFileName($Path) -replace '\s', '_')
    Copy-Item $Path $tmp -Force
    $u = Invoke-Tool -Exe 'higgsfield' -Arguments @('upload', 'create', $tmp, '--json') -TimeoutSec 600
    if (-not $u.Succeeded) { throw "reference upload failed for $Path : $($u.StdErr.Trim())" }
    $id = ([regex]::Match($u.StdOut, '"id"\s*:\s*"([0-9a-f-]{36})"')).Groups[1].Value
    if (-not $id) { throw "no media id returned for $Path" }
    Write-Human "  donor $(Split-Path $Path -Leaf) -> $id"
    return $id
}

function Get-OneLinePrompt {
    <#  One line, always. See trap 1. #>
    param([string] $Path)
    return ((Get-Content $Path -Raw) -replace '\s+', ' ').Trim()
}

function Assert-ParametersLanded {
    <#  Read the submitted job back before waiting on it. A coerced aspect ratio or a truncated
        prompt still renders and still bills, and the wait is where the time goes. #>
    param([string] $JobId, [string] $Prompt, [string] $Aspect)
    $chk = (Invoke-Tool -Exe 'higgsfield' -Arguments @('generate', 'get', $JobId, '--json') -TimeoutSec 120).StdOut | ConvertFrom-Json
    if ($chk.params.aspect_ratio -ne $Aspect) {
        throw "aspect_ratio came back '$($chk.params.aspect_ratio)' not $Aspect - argument passing is broken (job $JobId)"
    }
    if ($chk.params.prompt.Length -lt ($Prompt.Length - 5)) {
        throw "prompt truncated to $($chk.params.prompt.Length) of $($Prompt.Length) chars (job $JobId)"
    }
    return $chk
}

function Wait-Still {
    param([string] $JobId, [int] $TimeoutMinutes = 15)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 5
        $j = (Invoke-Tool -Exe 'higgsfield' -Arguments @('generate', 'get', $JobId, '--json') -TimeoutSec 120).StdOut | ConvertFrom-Json
    } while ($j.status -in 'queued', 'in_progress', 'pending' -and (Get-Date) -lt $deadline)
    return $j
}

function Invoke-Still {
    param([System.IO.FileInfo] $File, [string] $Dest, [string[]] $DonorIds)
    try {
        $prompt = Get-OneLinePrompt -Path $File.FullName
        $args = @('generate', 'create', $Model, '--prompt', $prompt,
                  '--aspect_ratio', $AspectRatio, '--resolution', $Resolution)
        foreach ($id in $DonorIds) { $args += @('--image-references', $id) }

        $r = Invoke-Tool -Exe 'higgsfield' -Arguments $args -TimeoutSec 300
        if (-not $r.Succeeded) { throw "submit failed: $($r.StdErr.Trim())" }
        $jobId = ([regex]::Match($r.StdOut, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')).Value
        if (-not $jobId) { throw "no job id in submit output: $($r.StdOut.Trim())" }

        $chk = Assert-ParametersLanded -JobId $jobId -Prompt $prompt -Aspect $AspectRatio
        $j = Wait-Still -JobId $jobId
        if ($j.status -ne 'completed') { throw "job $jobId ended '$($j.status)'" }
        if (-not $j.result_url) { throw "job $jobId completed with no result_url" }

        Invoke-WebRequest -Uri $j.result_url -OutFile $Dest -UseBasicParsing -TimeoutSec 600
        $kb = [math]::Round((Get-Item $Dest).Length / 1KB)
        Write-Human "  $($File.BaseName) -> $(Split-Path $Dest -Leaf)  (${kb} KB, $($chk.params.width)x$($chk.params.height))"
        [pscustomobject]@{ Name = $File.BaseName; Status = 'rendered'; Job = $jobId; Path = $Dest
                           Width = $chk.params.width; Height = $chk.params.height; SizeKB = $kb; Error = $null }
    }
    catch {
        Write-Human "  $($File.BaseName) FAILED: $($_.Exception.Message)"
        [pscustomobject]@{ Name = $File.BaseName; Status = 'failed'; Job = $null; Path = $null
                           Width = 0; Height = 0; SizeKB = 0; Error = $_.Exception.Message }
    }
}

function Invoke-Main {
    Set-Location $ProjectRoot
    $acct = Assert-Higgsfield
    Write-Human "account : $acct"
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

    $refPaths = Split-ListArgument $ReferenceImage
    if ($refPaths.Count -gt 10) { throw "at most 10 reference images, got $($refPaths.Count)" }
    $donorIds = @()
    if ($refPaths -and -not $DryRun) { $donorIds = @($refPaths | ForEach-Object { Publish-Donor -Path $_ }) }

    $files = Get-ChildItem $PromptDir -Filter '*.txt' | Sort-Object Name
    if ($Only) {
        $want = (Split-ListArgument $Only) | ForEach-Object { $_.ToLower() }
        $files = $files | Where-Object { $n = $_.BaseName.ToLower(); ($want -contains $n) -or ($want | Where-Object { $n.StartsWith($_) }) }
    }
    if (-not $files) { throw "no prompt files matched in $PromptDir" }

    Write-Human "model   : $Model ($Resolution, $AspectRatio)"
    Write-Human "stills  : $($files.Count)"
    Write-Human ''

    $results = foreach ($f in $files) {
        $dest = Join-Path $OutDir "$($f.BaseName).png"
        if (Test-Path $dest) {
            Write-Human "  skip  $($f.BaseName) - already rendered"
            [pscustomobject]@{ Name = $f.BaseName; Status = 'skipped'; Job = $null; Path = $dest
                               Width = 0; Height = 0; SizeKB = 0; Error = $null }
            continue
        }
        if ($DryRun) {
            $p = Get-OneLinePrompt -Path $f.FullName
            Write-Human "  DRYRUN $($f.BaseName)  ($($p.Length) chars, $($refPaths.Count) donors)"
            [pscustomobject]@{ Name = $f.BaseName; Status = 'dryrun'; Job = $null; Path = $dest
                               Width = 0; Height = 0; SizeKB = 0; Error = $null }
            continue
        }
        Invoke-Still -File $f -Dest $dest -DonorIds $donorIds
    }

    $ok     = @($results | Where-Object Status -eq 'rendered')
    $failed = @($results | Where-Object Status -eq 'failed')
    Write-Human ''
    if (-not $DryRun) { Write-Human "rendered $($ok.Count) still(s)" }
    if ($failed) { Write-Human "failed: $($failed.Name -join ', ')" }
    return $results
}

Invoke-Main
