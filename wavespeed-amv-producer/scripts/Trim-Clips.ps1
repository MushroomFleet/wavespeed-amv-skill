<#
.SYNOPSIS
    Cut each delivered clip to its planned timeline length, frame-locked, leaving originals intact.

.DESCRIPTION
    Models return a little more than the requested duration, and a music cut needs exact lengths.
    This trims each clip's TAIL, keeping the head, writing copies to -OutDir under the SAME
    filename so the originals stay available for an editor who prefers a clip's later seconds.

    FRAME-LOCKED, NOT DURATION-LOCKED, and the difference is not cosmetic. A bar is rarely a whole
    number of frames - at 125 BPM and 24fps, 3 bars is 138.43 frames. Rounding each clip's LENGTH
    gives a flat 138 and loses 0.018s per clip, drifting a third of a second ahead of the track
    over twenty clips. Rounding each timeline BOUNDARY instead - round(out*fps) - round(in*fps) -
    gives an alternating 138/139 and holds total error under half a frame. Same operation, applied
    one level up.

    Stream copy is attempted first but verified, never trusted: `ffmpeg -c copy -t` routinely
    returns a frame or two long, so a trim that believes the flag produces silently wrong lengths.
    On any mismatch the clip is re-encoded to an exact frame count.

    Emits one object per clip to the pipeline; progress goes to the host.

.PARAMETER Skip
    Clip ids to leave alone - typically any clip that will be retimed rather than trimmed.

.EXAMPLE
    pwsh -File Trim-Clips.ps1 -DryRun
    $cuts = ./Trim-Clips.ps1 -Fps 24
#>
[CmdletBinding()]
param(
    [string]   $ClipsFile   = 'clips.json',
    [string]   $ProjectRoot = '.',
    [string]   $InDir       = 'video/raw',
    [string]   $OutDir      = 'video/cut',
    [int]      $Fps         = 24,
    [string[]] $Skip,
    [int]      $Crf         = 16,
    [string]   $FfmpegPath  = '',
    [switch]   $Reencode,
    [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_Common.ps1')

function Get-TrimPlan {
    <#  Frame count per clip, derived from the TIMELINE BOUNDARIES rather than the durations, so
        the half-frame each clip is off never accumulates. #>
    param([psobject[]] $Clips, [int] $Rate, [string] $In, [string] $Out, [string[]] $SkipIds)
    $skip = (Split-ListArgument $SkipIds) | ForEach-Object { $_.ToUpper() }
    foreach ($c in $Clips) {
        $frames = [int][math]::Round($c.timeline_out * $Rate) - [int][math]::Round($c.timeline_in * $Rate)
        $src = Join-Path $In $c.out
        $dst = Join-Path $Out $c.out
        [pscustomobject]@{
            Id = $c.id; Seq = $c.seq; Name = $c.out
            Source = $src; Dest = $dst
            Frames = $frames; Seconds = [math]::Round($frames / $Rate, 4)
            Delivered = (Test-Path $src); AlreadyCut = (Test-Path $dst)
            Excluded = ($c.id.ToUpper() -in $skip)
        }
    }
}

function Invoke-StreamCopy {
    <#  Lossless and instant when it lands, but the frame count is VERIFIED because -c copy cuts
        on packet boundaries and routinely overshoots. Returns the frame count, or -1. #>
    param([psobject] $Item, [int] $Rate, [string] $Ffmpeg)
    $dur = ($Item.Frames / $Rate).ToString([cultureinfo]::InvariantCulture)
    $r = Invoke-Tool -Exe $Ffmpeg -TimeoutSec 900 -Arguments @(
        '-hide_banner', '-loglevel', 'error', '-i', $Item.Source,
        '-t', $dur, '-c', 'copy', '-avoid_negative_ts', 'make_zero', $Item.Dest, '-y')
    if (-not $r.Succeeded) { return -1 }
    $got = Get-VideoFrameCount -Path $Item.Dest -Ffmpeg $Ffmpeg
    if ($got -ne $Item.Frames) {
        Remove-Item $Item.Dest -Force -ErrorAction SilentlyContinue
        return -1
    }
    return $got
}

function Invoke-ExactEncode {
    param([psobject] $Item, [string] $Ffmpeg, [int] $Quality)
    $r = Invoke-Tool -Exe $Ffmpeg -TimeoutSec 3600 -Arguments @(
        '-hide_banner', '-loglevel', 'error', '-i', $Item.Source,
        '-frames:v', "$($Item.Frames)",
        '-c:v', 'libx264', '-crf', "$Quality", '-preset', 'slow', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-b:a', '192k', $Item.Dest, '-y')
    if (-not $r.Succeeded) { throw $r.StdErr.Trim() }
    $got = Get-VideoFrameCount -Path $Item.Dest -Ffmpeg $Ffmpeg
    if ($got -ne $Item.Frames) { throw "got $got frames, wanted $($Item.Frames)" }
    return $got
}

function Invoke-TrimOne {
    param([psobject] $Item, [int] $Rate, [string] $Ffmpeg, [int] $Quality, [switch] $ForceEncode)
    try {
        $method = 'copy'
        $got = if ($ForceEncode) { -1 } else { Invoke-StreamCopy -Item $Item -Rate $Rate -Ffmpeg $Ffmpeg }
        if ($got -lt 0) {
            $method = 'encode'
            $got = Invoke-ExactEncode -Item $Item -Ffmpeg $Ffmpeg -Quality $Quality
        }
        Write-Human ("  {0} {1,-6} {2}  {3} frames ({4}s)" -f $Item.Id, $method, $Item.Name, $got, $Item.Seconds)
        [pscustomobject]@{ Id = $Item.Id; Seq = $Item.Seq; Status = 'cut'; Method = $method
                           Path = $Item.Dest; Frames = $got; Seconds = $Item.Seconds; Error = $null }
    }
    catch {
        Write-Human "  $($Item.Id) FAILED: $($_.Exception.Message)"
        [pscustomobject]@{ Id = $Item.Id; Seq = $Item.Seq; Status = 'failed'; Method = $null
                           Path = $null; Frames = 0; Seconds = 0; Error = $_.Exception.Message }
    }
}

function Invoke-Main {
    Set-Location $ProjectRoot
    $ffmpeg = Resolve-Ffmpeg -Explicit $FfmpegPath
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    if (-not (Test-Path $ClipsFile)) { throw "$ClipsFile not found - run build_clips.py first." }

    $clips = Get-Content $ClipsFile -Raw | ConvertFrom-Json
    $plan  = @(Get-TrimPlan -Clips $clips -Rate $Fps -In $InDir -Out $OutDir -SkipIds $Skip)

    Write-Human "ffmpeg : $ffmpeg"
    Write-Human "in     : $InDir   out: $OutDir   (originals are never modified)"
    Write-Human "rate   : $Fps fps, frame-locked to the timeline"
    Write-Human ''
    foreach ($p in $plan) {
        $why = if (-not $p.Delivered) { 'MISSING - not delivered' }
               elseif ($p.AlreadyCut) { 'skip - already cut' }
               elseif ($p.Excluded)   { 'skip - excluded by -Skip' }
               else                    { '' }
        Write-Human ("{0,-6} {1,-42} {2,5}f {3,9:N4}s  {4}" -f $p.Id, $p.Name, $p.Frames, $p.Seconds, $why)
    }
    Write-Human ''

    $todo = @($plan | Where-Object { $_.Delivered -and -not $_.AlreadyCut -and -not $_.Excluded })
    if (-not $todo) { Write-Human 'Nothing to cut.'; return $plan }
    if ($DryRun)    { Write-Human "DRYRUN - $($todo.Count) clip(s) would be cut."; return $plan }

    $results = foreach ($it in $todo) {
        Invoke-TrimOne -Item $it -Rate $Fps -Ffmpeg $ffmpeg -Quality $Crf -ForceEncode:$Reencode
    }

    $total  = ($plan | Where-Object { Test-Path $_.Dest } | Measure-Object -Property Frames -Sum).Sum
    $failed = @($results | Where-Object Status -eq 'failed')
    Write-Human ''
    Write-Human "cut clips total $total frames = $([math]::Round($total / $Fps, 4))s"
    Write-Human "originals untouched in $InDir"
    if ($failed) { Write-Human "failed: $($failed.Id -join ', ')" }
    return $results
}

Invoke-Main
