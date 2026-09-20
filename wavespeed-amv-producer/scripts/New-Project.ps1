<#
.SYNOPSIS
    Scaffold a new music video project - folders, PROJECT.md, and a .gitignore that keeps your
    key and your bucket URL out of version control.

.DESCRIPTION
    Run this first. Everything downstream expects this layout.

    The .gitignore it writes is not optional housekeeping. Publish-Refs.ps1 writes your live R2
    public URL into clips.json and refs-r2.json, and those files live in YOUR project, not in the
    skill. Commit them and your bucket address is published - anyone who reads the repo can fetch
    every seed frame and audio segment you uploaded. This file is what stops that.

.PARAMETER Name
    Project folder to create, relative to -Path.

.PARAMETER Path
    Where to create it. Defaults to the current directory.

.EXAMPLE
    pwsh -File New-Project.ps1 -Name my-track
    pwsh -File New-Project.ps1 -Name my-track -Path D:\videos
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Name,
    [string] $Path = '.',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

function New-ProjectTree {
    param([string] $Root)
    foreach ($d in 'audio', 'renders', 'prompts/stills', 'video/raw', 'video/cut') {
        New-Item -ItemType Directory -Path (Join-Path $Root $d) -Force | Out-Null
    }
}

function Write-ProjectGitignore {
    param([string] $Root)
    @'
# ---------------------------------------------------------------------------
# SECRETS - never commit
# ---------------------------------------------------------------------------
.wavespeed_key
*.wavespeed_key*
.env

# ---------------------------------------------------------------------------
# YOUR PUBLIC BUCKET URL - never commit
#
# Publish-Refs.ps1 rewrites clips.json with the public R2 URLs of every seed
# frame and audio segment, and saves the same map to refs-r2.json. Committing
# either one publishes your bucket address, and that bucket is public and
# unauthenticated while a run is live. Anyone reading the repo could fetch
# every reference you uploaded.
# ---------------------------------------------------------------------------
clips.json
refs-r2.json

# Generated state - reproducible, no reason to track
tempo.json
segments.json
wavespeed-log.jsonl

# Media - large, and regenerable from the prompts plus references
audio/
renders/
video/

# Python
__pycache__/
*.pyc
'@ | Set-Content (Join-Path $Root '.gitignore') -Encoding UTF8
}

function Write-ProjectDoc {
    param([string] $Root, [string] $ProjectName)
    @"
# $ProjectName

## Track

| | |
|---|---|
| File | |
| Length | |
| BPM | *measured by analyze_tempo.py, not guessed* |
| Bar | |
| Start point | *the drop or downbeat the sequence cuts from* |
| Grid confidence | *sigma from analyze_tempo - below 3, do not trust it* |

## Shape

| | |
|---|---|
| Bars per clip | |
| Clip length | |
| Render length | |
| Clip count | |
| Est. cost | clips x your per-clip rate |

## Look

What this video is. Locations, subjects, palette, time of day, camera language - enough that
every clip belongs to the same film.

## Steps

- [ ] tempo measured, start point confirmed with a human
- [ ] audio split, segments contiguous
- [ ] prompts written, one per clip, in sequence order
- [ ] seed frames present for every clip
- [ ] queue built, pairing table checked by eye
- [ ] references published to R2
- [ ] ONE clip rendered and verified before the batch
- [ ] batch rendered
- [ ] trimmed frame-locked
- [ ] assembled
"@ | Set-Content (Join-Path $Root 'PROJECT.md') -Encoding UTF8
}

function Invoke-Main {
    $root = Join-Path $Path $Name
    if ((Test-Path $root) -and -not $Force) {
        throw "$root already exists. Use -Force to scaffold into it anyway (existing files are not overwritten except PROJECT.md and .gitignore)."
    }
    New-ProjectTree     -Root $root
    Write-ProjectGitignore -Root $root
    Write-ProjectDoc    -Root $root -ProjectName $Name

    Write-Host ""
    Write-Host "created $root"
    Write-Host "  audio/  renders/  prompts/stills/  video/raw/  video/cut/"
    Write-Host "  PROJECT.md    fill this in as you go"
    Write-Host "  .gitignore    keeps your key AND your bucket URL out of git"
    Write-Host ""
    Write-Host "next:"
    Write-Host "  1. put your track in $Name/"
    Write-Host "  2. set `$env:WAVESPEED_API_KEY"
    Write-Host "  3. python <skill>/scripts/analyze_tempo.py <track> --find-drop"
    Write-Host ""

    [pscustomobject]@{
        Name = $Name; Root = (Resolve-Path $root).Path
        Folders = @('audio', 'renders', 'prompts/stills', 'video/raw', 'video/cut')
        Files = @('PROJECT.md', '.gitignore')
    }
}

Invoke-Main
