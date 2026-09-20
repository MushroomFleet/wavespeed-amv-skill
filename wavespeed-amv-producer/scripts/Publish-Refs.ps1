<#
.SYNOPSIS
    Mirror local reference assets to a public Cloudflare R2 bucket and rewrite clips.json with
    the resulting URLs.

.DESCRIPTION
    WaveSpeed's reference_images / reference_audios take public HTTPS URLs and the service has no
    upload endpoint of its own - /api/v3/<anything> routes as a model path, so what looks like an
    upload endpoint returning 400 is really "Model not found". Every seed frame and audio segment
    therefore has to be publicly hosted before a render can use it.

    R2 suits this better than a general object store: the free tier covers a normal project, and
    there is no egress charge, which matters because the API refetches every reference on every
    render and every re-roll.

    Emits one object per asset to the pipeline; progress goes to the host.

.PARAMETER Teardown
    Disable the bucket's public URL and exit. Objects are retained; re-running without -Teardown
    re-enables. Use this when a render queue is finished.

.EXAMPLE
    pwsh -File Publish-Refs.ps1 -Bucket my-amv-refs
    pwsh -File Publish-Refs.ps1 -Bucket my-amv-refs -Teardown
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Bucket,
    [string] $ClipsFile   = 'clips.json',
    [string] $ProjectRoot = '.',
    [string] $Prefix      = '',
    [switch] $Teardown,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_Common.ps1')

$script:Mime = @{
    '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.webp' = 'image/webp'
    '.wav' = 'audio/wav'; '.mp3' = 'audio/mpeg';  '.m4a' = 'audio/mp4';  '.mp4'  = 'video/mp4'
}

function Assert-Wrangler {
    if (-not (Get-Command wrangler -ErrorAction SilentlyContinue)) {
        throw "wrangler not found. Install it, then run 'wrangler login'."
    }
    $who = Invoke-Tool -Exe 'wrangler' -Arguments @('whoami') -TimeoutSec 120
    if (-not $who.Succeeded) { throw "wrangler is not authenticated. Run 'wrangler login'." }
}

function Disable-PublicUrl {
    param([string] $Name)
    $r = Invoke-Tool -Exe 'wrangler' -TimeoutSec 120 `
             -Arguments @('r2', 'bucket', 'dev-url', 'disable', $Name, '--force')
    if (-not $r.Succeeded) { throw $r.StdErr.Trim() }
    [pscustomobject]@{ Bucket = $Name; PublicUrl = $null; Status = 'disabled' }
}

function Initialize-PublicBucket {
    <#  Create the bucket if needed, enable its public dev URL, and return the base URL. #>
    param([string] $Name)
    $info = Invoke-Tool -Exe 'wrangler' -Arguments @('r2', 'bucket', 'info', $Name) -TimeoutSec 120
    if (-not $info.Succeeded) {
        Write-Human "creating bucket '$Name'..."
        $c = Invoke-Tool -Exe 'wrangler' -Arguments @('r2', 'bucket', 'create', $Name) -TimeoutSec 300
        if (-not $c.Succeeded) { throw "could not create bucket: $($c.StdErr.Trim())" }
    }
    $dev = Invoke-Tool -Exe 'wrangler' -TimeoutSec 300 `
               -Arguments @('r2', 'bucket', 'dev-url', 'enable', $Name, '--force')
    $m = [regex]::Match(($dev.StdOut + $dev.StdErr), 'https://pub-[0-9a-f]+\.r2\.dev')
    if (-not $m.Success) { throw "could not determine the public URL: $($dev.StdOut) $($dev.StdErr)" }
    return $m.Value
}

function Get-LocalAssets {
    <#  Every local (non-URL) file the queue references, in first-seen order. #>
    param([psobject[]] $Clips)
    $seen = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $Clips) {
        foreach ($f in @($c.image, $c.audio)) {
            if ($f -and $f -notmatch '^https?://' -and -not $seen.Contains($f)) { $seen.Add($f) }
        }
    }
    return $seen
}

function Test-AlreadyPublished {
    param([string] $Url, [string] $LocalPath)
    try {
        $h = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 30
        return ([int]$h.Headers['Content-Length'] -eq (Get-Item $LocalPath).Length)
    } catch { return $false }
}

function Publish-Asset {
    param([string] $Path, [string] $BucketName, [string] $Key, [string] $BaseUrl, [switch] $ForceUpload)
    if (-not (Test-Path $Path)) { throw "asset referenced by the queue is missing: $Path" }
    $url = "$BaseUrl/$Key"
    $ct  = $script:Mime[[IO.Path]::GetExtension($Path).ToLower()]
    if (-not $ct) { $ct = 'application/octet-stream' }

    if (-not $ForceUpload -and (Test-AlreadyPublished -Url $url -LocalPath $Path)) {
        Write-Human "  ok   $Path"
        return [pscustomobject]@{ Path = $Path; Url = $url; ContentType = $ct; Action = 'skipped' }
    }
    $r = Invoke-Tool -Exe 'wrangler' -TimeoutSec 900 -Arguments @(
        'r2', 'object', 'put', "$BucketName/$Key", '--file', $Path, '--content-type', $ct, '--remote')
    if (-not $r.Succeeded) { throw "upload failed for $Path : $($r.StdErr.Trim())" }
    Write-Human "  up   $Path"
    [pscustomobject]@{ Path = $Path; Url = $url; ContentType = $ct; Action = 'uploaded' }
}

function Assert-Reachable {
    <#  An upload that reports success but does not serve is worse than a failed one, because the
        render fails later and costs money to discover. #>
    param([psobject[]] $Published)
    $bad = foreach ($p in $Published) {
        try {
            $h = Invoke-WebRequest -Uri $p.Url -Method Head -UseBasicParsing -TimeoutSec 30
            if ($h.StatusCode -ne 200) { $p.Path }
        } catch { $p.Path }
    }
    if ($bad) { throw "these assets are not publicly reachable after upload:`n  " + ($bad -join "`n  ") }
}

function Update-Queue {
    param([string] $Path, [psobject[]] $Clips, [hashtable] $Map)
    foreach ($c in $Clips) {
        if ($c.image -and $Map.ContainsKey($c.image)) { $c.image = $Map[$c.image] }
        if ($c.audio -and $Map.ContainsKey($c.audio)) { $c.audio = $Map[$c.audio] }
        foreach ($p in 'Dest', 'Delivered') {
            if ($c.PSObject.Properties.Name -contains $p) { $c.PSObject.Properties.Remove($p) }
        }
    }
    $Clips | ConvertTo-Json -Depth 8 | Set-Content $Path -Encoding UTF8
}

function Invoke-Main {
    Set-Location $ProjectRoot
    Assert-Wrangler
    if ($Teardown) {
        $r = Disable-PublicUrl -Name $Bucket
        Write-Human "public URL disabled for '$Bucket'. Objects are retained."
        return $r
    }

    $base = Initialize-PublicBucket -Name $Bucket
    Write-Human "bucket : $Bucket"
    Write-Human "public : $base"
    Write-Human "  NOTE: this bucket is PUBLIC and unauthenticated. Anyone holding a URL can fetch"
    Write-Human "        the assets. Run with -Teardown when the render queue is finished."
    Write-Human ''

    if (-not (Test-Path $ClipsFile)) { throw "$ClipsFile not found - run build_clips.py first." }
    $clips  = Get-Content $ClipsFile -Raw | ConvertFrom-Json
    $assets = Get-LocalAssets -Clips $clips
    if (-not $assets.Count) {
        Write-Human 'Nothing local left to publish - every reference is already a URL.'
        return @()
    }

    $published = foreach ($a in $assets) {
        $key = if ($Prefix) { "$Prefix/$($a -replace '\\','/')" } else { ($a -replace '\\', '/') }
        Publish-Asset -Path $a -BucketName $Bucket -Key $key -BaseUrl $base -ForceUpload:$Force
    }
    Assert-Reachable -Published $published

    $map = @{}
    foreach ($p in $published) { $map[$p.Path] = $p.Url }
    Update-Queue -Path $ClipsFile -Clips $clips -Map $map
    $map | ConvertTo-Json -Depth 3 | Set-Content 'refs-r2.json' -Encoding UTF8

    $up   = @($published | Where-Object Action -eq 'uploaded').Count
    $skip = @($published | Where-Object Action -eq 'skipped').Count
    Write-Human ''
    Write-Human "uploaded $up, already present $skip, all $($published.Count) URLs verified 200"
    Write-Human "$ClipsFile rewritten with public URLs; map saved to refs-r2.json"
    return $published
}

Invoke-Main
