<#
    Shared helpers for the wavespeed-amv-producer scripts.

    Dot-source it:  . (Join-Path $PSScriptRoot '_Common.ps1')

    Two conventions every script here follows, both from TINA's grounding:

      Logic lives in functions.  The top level of each script is a thin call into Invoke-Main,
      so the pieces can be dot-sourced and tested without running the whole thing.

      Human text goes to the HOST; the pipeline carries OBJECTS.  Write-Human writes to the
      information stream, so a caller doing `$r = ./Trim-Clips.ps1` gets a result object rather
      than a mixture of progress lines and data. This matters the moment anything orchestrates
      these scripts rather than a person reading them.
#>

function Write-Human {
    <#  Progress and summaries for a person. Never enters the pipeline. #>
    param([Parameter(ValueFromPipeline)][string] $Message = '')
    process { Write-Information $Message -InformationAction Continue }
}

function Resolve-Tool {
    <#  Locate an executable, with optional fallbacks for tools that are commonly not on PATH. #>
    param(
        [Parameter(Mandatory)][string] $Name,
        [string[]] $Fallbacks = @(),
        [switch] $Required
    )
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($f in $Fallbacks) {
        $p = [Environment]::ExpandEnvironmentVariables($f)
        if (Test-Path $p) { return $p }
    }
    if ($Required) { throw "$Name not found on PATH. Install it, or pass an explicit path." }
    return $null
}

function Resolve-Ffmpeg {
    param([string] $Explicit)
    if ($Explicit) {
        if (-not (Test-Path $Explicit)) { throw "ffmpeg not found at $Explicit" }
        return $Explicit
    }
    $p = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($p) { return $p.Source }
    throw @"
ffmpeg not found on PATH.
  Install it from https://ffmpeg.org/download.html, or pass -FfmpegPath <path>.

  A copy bundled inside another tool's directory will usually work if you point at it
  explicitly, but do not rely on one as a default - those paths are machine-specific and
  temp extractions get cleaned up without warning.
"@
}

function Invoke-Tool {
    <#  Run an external CLI and return a structured result. Uses TINA when it is loaded, so runs
        are captured in its log; falls back to a direct invocation when it is not, which keeps
        this skill usable on a machine without TINA. #>
    param(
        [Parameter(Mandatory)][string] $Exe,
        [Parameter(Mandatory)][string[]] $Arguments,
        [int] $TimeoutSec = 600,
        [int[]] $SuccessExitCodes = @(0)
    )
    if (Get-Command Invoke-TINAProcess -ErrorAction SilentlyContinue) {
        return Invoke-TINAProcess $Exe $Arguments -TimeoutSeconds $TimeoutSec -SuccessExitCodes $SuccessExitCodes
    }
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -NoNewWindow -Wait -PassThru `
                 -RedirectStandardOutput $o -RedirectStandardError $e
        [pscustomobject]@{
            Succeeded = ($SuccessExitCodes -contains $p.ExitCode)
            ExitCode  = $p.ExitCode
            StdOut    = (Get-Content $o -Raw)
            StdErr    = (Get-Content $e -Raw)
        }
    } finally { Remove-Item $o, $e -Force -ErrorAction SilentlyContinue }
}

function Get-VideoFrameCount {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Ffmpeg)
    $r = Invoke-Tool -Exe $Ffmpeg -TimeoutSec 600 -SuccessExitCodes 0, 1 -Arguments @(
        '-hide_banner', '-i', $Path, '-map', '0:v:0', '-c', 'copy', '-f', 'null', '-')
    $m = [regex]::Matches(($r.StdErr + $r.StdOut), 'frame=\s*(\d+)')
    if (-not $m.Count) { return -1 }
    return [int]$m[$m.Count - 1].Groups[1].Value
}

function Resolve-ApiKey {
    <#  Find the WaveSpeed key WITHOUT inventing a credential store.

        TINA's grounding is explicit that per-script credential patterns are not to be invented,
        and that an auth requirement should be surfaced to the user rather than silently handled.
        So the order here is deliberate:

          1. WAVESPEED_API_KEY  - the environment variable WaveSpeed's own documentation uses.
                                  Following the vendor's convention is not inventing one.
          2. a key file         - a convenience for an interactive project, opt-in by existing.
          3. neither            - stop and TELL the user exactly what to set, rather than guessing.

        The value is returned for immediate use in an Authorization header and is never written
        to disk, logged, or echoed. #>
    param([string] $KeyFile = '.wavespeed_key')

    if ($env:WAVESPEED_API_KEY) {
        return [pscustomobject]@{ Key = $env:WAVESPEED_API_KEY.Trim(); Source = 'WAVESPEED_API_KEY' }
    }
    if ($KeyFile -and (Test-Path $KeyFile)) {
        $k = (Get-Content $KeyFile -Raw).Trim()
        if (-not $k -or $k -match 'REPLACE|your-api-key') {
            throw "$KeyFile still holds the placeholder text. Put your real key in it, or set `$env:WAVESPEED_API_KEY."
        }
        return [pscustomobject]@{ Key = $k; Source = $KeyFile }
    }
    throw @"
No WaveSpeed API key found. This skill does not store credentials for you - set one of:

  `$env:WAVESPEED_API_KEY = '<your key>'      (preferred; WaveSpeed's own documented variable)
  or place the key in $KeyFile               (copy assets/wavespeed_key.template)

If you use the file, add it to .gitignore before pasting the key in.
"@
}

function Split-ListArgument {
    <#  pwsh -File passes "A,B" as a single string rather than an array, so every list parameter
        has to be split again on the inside or it silently matches nothing. #>
    param([string[]] $Value)
    return @($Value | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.Trim() })
}
