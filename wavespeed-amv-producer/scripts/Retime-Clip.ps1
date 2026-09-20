<#
.SYNOPSIS
    Stretch or compress one clip to a target length, optionally replacing its audio.

.DESCRIPTION
    For the clip that has to COVER a span rather than be trimmed to one - an outro held under a
    fade, a slow push that needs to last, a beat the edit wants to linger on.

    Two things worth knowing before using it.

    Frame duplication versus interpolation. A plain setpts stretch holds each source frame for
    several output frames, which judders badly past about 1.5x. -Interpolate synthesises the
    in-between frames instead, which is far smoother and suits slow continuous motion (drifting
    smoke, settling cloth, a sinking flame). It is slower to encode and can tear on fast motion,
    so it is opt-in.

    A short result is often correct. minterpolate cannot extrapolate past the last source frame,
    so a heavy stretch usually lands a few frames under the target. That shortfall is normally the
    fade handle - the clip has already come to rest, and the editor cross-fades across those
    static tail frames. Only a large miss means something actually broke, so this warns rather
    than fails. Do not "fix" a small shortfall by distorting the retime factor; that changes the
    motion to satisfy a number nobody watches.

.PARAMETER Seconds
    Target length. Either this or -Frames.

.PARAMETER Audio
    Audio file to mux in, replacing the clip's own. Use this when the clip was rendered without an
    audio reference - anything it invented will sound wrong slowed down.

.EXAMPLE
    pwsh -File Retime-Clip.ps1 -Source video/raw/020-outro.mp4 -Dest video/cut/020-outro.mp4 -Seconds 17.4167 -Audio audio/outro.wav -Interpolate
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Source,
    [Parameter(Mandatory = $true)][string] $Dest,
    [double] $Seconds     = 0,
    [int]    $Frames      = 0,
    [string] $Audio       = '',
    [int]    $Fps         = 24,
    [int]    $Crf         = 16,
    [string] $ProjectRoot = '.',
    [string] $FfmpegPath  = '',
    [switch] $Interpolate,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_Common.ps1')

function Get-RetimeFilter {
    <#  tpad clones the final frame to fill any shortfall; without it the clip silently comes out
        under length, because minterpolate stops at the last real frame. #>
    param([double] $Factor, [int] $Rate, [switch] $Smooth)
    $f = $Factor.ToString([cultureinfo]::InvariantCulture)
    if ($Smooth) {
        return "setpts=$f*PTS,minterpolate=fps=${Rate}:mi_mode=mci:mc_mode=aobmc:vsbmc=1,tpad=stop_mode=clone:stop_duration=2"
    }
    return "setpts=$f*PTS,fps=$Rate,tpad=stop_mode=clone:stop_duration=2"
}

function New-RetimeArguments {
    param([string] $Src, [string] $Dst, [string] $AudioPath, [string] $Filter, [int] $Target, [int] $Quality)
    $a = @('-hide_banner', '-loglevel', 'error', '-i', $Src)
    if ($AudioPath) { $a += @('-i', $AudioPath) }
    $a += @('-filter:v', $Filter, '-frames:v', "$Target")
    if ($AudioPath) { $a += @('-map', '0:v:0', '-map', '1:a:0') } else { $a += @('-map', '0:v:0') }
    $a += @('-c:v', 'libx264', '-crf', "$Quality", '-preset', 'slow', '-pix_fmt', 'yuv420p')
    if ($AudioPath) { $a += @('-c:a', 'aac', '-b:a', '192k') }
    $a += @($Dst, '-y')
    return $a
}

function Invoke-Main {
Set-Location $ProjectRoot
$ffmpeg = Resolve-Ffmpeg -Explicit $FfmpegPath
if (-not (Test-Path $Source)) { throw "source not found: $Source" }
if ($Seconds -le 0 -and $Frames -le 0) { throw 'give either -Seconds or -Frames.' }

$srcF = Get-VideoFrameCount -Path $Source -Ffmpeg $ffmpeg
if ($srcF -lt 1) { throw "could not read a frame count from $Source" }
$dstF = if ($Frames -gt 0) { $Frames } else { [int][math]::Round($Seconds * $Fps) }
$factor = $dstF / $srcF

$vf = Get-RetimeFilter -Factor $factor -Rate $Fps -Smooth:$Interpolate

Write-Human "source  : $Source  ($srcF frames, $([math]::Round($srcF / $Fps, 3))s)"
Write-Human "target  : $dstF frames ($([math]::Round($dstF / $Fps, 4))s) = $([math]::Round($factor, 4))x"
Write-Human "mode    : $(if ($Interpolate) { 'motion interpolation' } else { 'frame duplication' })"
if ($Audio) { Write-Human "audio   : $Audio (replacing the clip's own)" }
Write-Human "out     : $Dest"
Write-Human ''
if ($DryRun) { Write-Human 'DRYRUN - nothing encoded.'; return [pscustomobject]@{ Status='dryrun'; Source=$Source; Dest=$Dest; SourceFrames=$srcF; TargetFrames=$dstF; Factor=[math]::Round($factor,4) } }
if ($factor -gt 4) { Write-Human "  note: $([math]::Round($factor,2))x is a heavy stretch; expect visible softness even interpolated." }

$dir = Split-Path $Dest -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$vfArgs = New-RetimeArguments -Src $Source -Dst $Dest -AudioPath $Audio -Filter $vf -Target $dstF -Quality $Crf
$r = Invoke-Tool -Exe $ffmpeg -Arguments $vfArgs -TimeoutSec 7200
if (-not $r.Succeeded) { throw "retime failed: $($r.StdErr.Trim())" }

$got = Get-VideoFrameCount -Path $Dest -Ffmpeg $ffmpeg
if ($got -lt 1) { throw 'retime produced no frames' }
$short = $dstF - $got
$mb = [math]::Round((Get-Item $Dest).Length / 1MB, 1)
Write-Human "$(Split-Path $Dest -Leaf)  $got frames ($([math]::Round($got / $Fps, 4))s, ${mb} MB)"
if ($short -gt $Fps) {
    throw "short by $short frames (over a second) - something went wrong, not just the tail."
} elseif ($short -gt 0) {
    Write-Human "  $short frame(s) under target - expected on a stretch, and normally the fade handle."
}
Write-Human "original untouched at $Source"
[pscustomobject]@{
    Status = 'retimed'; Source = $Source; Dest = $Dest
    SourceFrames = $srcF; TargetFrames = $dstF; ActualFrames = $got; ShortBy = $short
    Factor = [math]::Round($factor, 4); Seconds = [math]::Round($got / $Fps, 4); SizeMB = $mb
    Audio = $(if ($Audio) { $Audio } else { $null })
}
}

Invoke-Main
