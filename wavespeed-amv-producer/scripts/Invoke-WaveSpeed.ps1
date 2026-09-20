<#
.SYNOPSIS
    Render the clip queue on WaveSpeed's MiniMax H3 reference-to-video API.

.DESCRIPTION
    Reads clips.json, submits one prediction per clip with its prompt, reference image and audio
    URL, polls until terminal, downloads the result, and saves it under the sequence-ordered
    filename the queue assigned so finished clips sort into timeline order on disk.

    Emits one result object per clip to the pipeline; progress goes to the host. A caller can do
    `$r = ./Invoke-WaveSpeed.ps1` and get data back rather than a transcript.

    THESE ARE PAID, NON-REFUNDABLE JOBS. Every guard here exists because of a specific way money
    gets wasted:

      - Submission is never retried. A retry re-charges for an identical job. Only the poll is
        allowed to be patient.
      - The prediction id is logged BEFORE polling starts, so a crash or a dropped connection
        after submission still leaves a record of what was bought and where to collect it.
      - A clip whose output already exists is skipped, which makes an interrupted run resumable
        by simply running it again.
      - -MaxCost refuses to start above a spend ceiling.

    Render ONE clip first and look at it before queueing a batch.

.PARAMETER Only
    Clip ids or sequence numbers, e.g. -Only 1 or -Only C01,C03. Omit to run everything.

.PARAMETER CostPerClip
    Drives the estimate and the -MaxCost guard. Check the current rate rather than trusting it.

.EXAMPLE
    pwsh -File Invoke-WaveSpeed.ps1 -Only 1 -DryRun
    $results = ./Invoke-WaveSpeed.ps1 -Only 1
#>
[CmdletBinding()]
param(
    [string[]] $Only,
    [string]   $ClipsFile   = 'clips.json',
    [string]   $ProjectRoot = '.',
    [string]   $OutDir      = 'video/raw',
    [string]   $KeyFile     = '.wavespeed_key',
    [double]   $CostPerClip = 0.84,
    [double]   $MaxCost     = 20.00,
    [int]      $TimeoutMin  = 20,
    [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_Common.ps1')

$script:Endpoint   = 'https://api.wavespeed.ai/api/v3/minimax/h3/reference-to-video'
$script:ResultBase = 'https://api.wavespeed.ai/api/v3/predictions'
$script:LogFile    = 'wavespeed-log.jsonl'

function Get-Queue {
    param([string] $Path, [string[]] $Filter, [string] $OutputDir)
    if (-not (Test-Path $Path)) { throw "$Path not found - run build_clips.py first." }
    $clips = Get-Content $Path -Raw | ConvertFrom-Json
    if ($Filter) {
        $want = (Split-ListArgument $Filter) | ForEach-Object { $_.ToUpper() }
        $clips = $clips | Where-Object { $_.id.ToUpper() -in $want -or "$($_.seq)" -in $want }
    }
    if (-not $clips) { throw "no clips matched -Only $($Filter -join ',')" }
    foreach ($c in $clips) {
        Add-Member -InputObject $c -NotePropertyName Dest `
                   -NotePropertyValue (Join-Path $OutputDir $c.out) -Force
        Add-Member -InputObject $c -NotePropertyName Delivered `
                   -NotePropertyValue (Test-Path (Join-Path $OutputDir $c.out)) -Force
    }
    return $clips
}

function New-RequestBody {
    param([psobject] $Clip)
    $b = [ordered]@{
        prompt           = $Clip.prompt
        aspect_ratio     = $(if ($Clip.aspect_ratio) { $Clip.aspect_ratio } else { '16:9' })
        resolution       = $(if ($Clip.resolution)   { $Clip.resolution }   else { '2k' })
        duration         = [int]$(if ($Clip.duration) { $Clip.duration } else { 6 })
        reference_images = @($Clip.image)
    }
    if ($Clip.audio) { $b.reference_audios = @($Clip.audio) }
    return $b
}

function Submit-Prediction {
    <#  Submits exactly once and returns the prediction id. Deliberately has no retry: a retry
        here bills a second time for the same job. #>
    param([hashtable] $Headers, [string] $Json)
    $sub  = Invoke-RestMethod -Uri $script:Endpoint -Method Post -Headers $Headers `
                -ContentType 'application/json' -Body $Json -TimeoutSec 120
    $task = if ($sub.PSObject.Properties.Name -contains 'data') { $sub.data } else { $sub }
    if (-not $task.id) { throw 'submission returned no prediction id' }
    return $task.id
}

function Write-SpendLog {
    param([psobject] $Clip, [string] $PredictionId, [double] $Cost)
    ([ordered]@{
        ts = (Get-Date).ToString('o'); clip = $Clip.id; seq = $Clip.seq
        prediction = $PredictionId; out = $Clip.out; cost = $Cost
    } | ConvertTo-Json -Compress) | Add-Content $script:LogFile -Encoding UTF8
}

function Wait-Prediction {
    param([hashtable] $Headers, [string] $PredictionId, [int] $TimeoutMinutes)
    $url      = "$script:ResultBase/$PredictionId/result"
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $wait     = 2
    do {
        Start-Sleep -Seconds $wait
        if ($wait -lt 10) { $wait++ }          # back off, as the API docs advise
        $res = Invoke-RestMethod -Uri $url -Headers $Headers -TimeoutSec 60
        $r   = if ($res.PSObject.Properties.Name -contains 'data') { $res.data } else { $res }
    } while ($r.status -in 'created', 'queued', 'processing', 'pending' -and (Get-Date) -lt $deadline)
    return $r
}

function Get-OutputUrl {
    param([psobject] $Result)
    $u = @($Result.outputs)[0]
    if ($u -isnot [string]) { $u = $u.url }
    if (-not $u) { throw "prediction completed with no output url" }
    return $u
}

function Invoke-Clip {
    param([psobject] $Clip, [hashtable] $Headers, [double] $Cost, [int] $TimeoutMinutes)
    $started = Get-Date
    try {
        $json = (New-RequestBody -Clip $Clip) | ConvertTo-Json -Depth 5 -Compress
        $id   = Submit-Prediction -Headers $Headers -Json $json
        Write-SpendLog -Clip $Clip -PredictionId $id -Cost $Cost   # before the wait, always

        $r = Wait-Prediction -Headers $Headers -PredictionId $id -TimeoutMinutes $TimeoutMinutes
        if ($r.status -ne 'completed') { throw "prediction $id ended '$($r.status)' $($r.error)" }

        Invoke-WebRequest -Uri (Get-OutputUrl -Result $r) -OutFile $Clip.Dest -UseBasicParsing -TimeoutSec 900
        $mb = [math]::Round((Get-Item $Clip.Dest).Length / 1MB, 1)
        Write-Human "  $($Clip.id) -> $($Clip.out)  (${mb} MB)"
        [pscustomobject]@{
            Id = $Clip.id; Seq = $Clip.seq; Status = 'delivered'; Prediction = $id
            Path = $Clip.Dest; SizeMB = $mb; Cost = $Cost
            DurationSec = [math]::Round(((Get-Date) - $started).TotalSeconds, 1); Error = $null
        }
    }
    catch {
        # Fail soft: one bad clip must not abandon the rest of a queue that is already paid for.
        Write-Human "  $($Clip.id) FAILED: $($_.Exception.Message)"
        [pscustomobject]@{
            Id = $Clip.id; Seq = $Clip.seq; Status = 'failed'; Prediction = $null
            Path = $null; SizeMB = 0; Cost = 0
            DurationSec = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
            Error = $_.Exception.Message
        }
    }
}

function Invoke-Main {
    Set-Location $ProjectRoot
    $auth = Resolve-ApiKey -KeyFile $KeyFile
    $headers = @{ Authorization = "Bearer $($auth.Key)" }
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

    $clips = Get-Queue -Path $ClipsFile -Filter $Only -OutputDir $OutDir
    $local = @($clips | Where-Object { $_.image -and $_.image -notmatch '^https?://' })
    if ($local -and -not $DryRun) {
        throw "these clips still reference local files, which the API cannot fetch: $($local.id -join ', '). Run Publish-Refs.ps1 first."
    }

    $todo = @($clips | Where-Object { -not $_.Delivered })
    $done = @($clips | Where-Object { $_.Delivered })
    $cost = $todo.Count * $CostPerClip

    Write-Human "model  : minimax/h3/reference-to-video"
    Write-Human "auth   : $($auth.Source)"
    Write-Human "queue  : $($clips.Count) selected, $($done.Count) already delivered, $($todo.Count) to submit"
    Write-Human "cost   : $($todo.Count) x $CostPerClip = $([math]::Round($cost,2))"
    Write-Human "output : $OutDir"
    Write-Human ''
    foreach ($d in $done) { Write-Human "  skip  $($d.id)  $($d.out)" }

    if (-not $todo) { Write-Human 'Nothing to do.'; return @() }
    if ($cost -gt $MaxCost -and -not $DryRun) {
        throw "this run would cost $([math]::Round($cost,2)), over the -MaxCost guard of $MaxCost. Raise it deliberately if that is intended."
    }

    if ($DryRun) {
        $plan = foreach ($c in $todo) {
            $b = New-RequestBody -Clip $c
            Write-Human "DRYRUN $($c.id) -> $($c.out)"
            Write-Human "    image: $($c.image)"
            Write-Human "    audio: $(if ($c.audio) { $c.audio } else { '(none)' })"
            Write-Human "    $($b.resolution) $($b.aspect_ratio) $($b.duration)s, prompt $($c.prompt.Length) chars"
            [pscustomobject]@{ Id = $c.id; Seq = $c.seq; Status = 'dryrun'
                               Image = $c.image; Audio = $c.audio; Cost = $CostPerClip }
        }
        Write-Human ''
        Write-Human "DRYRUN - $($todo.Count) clip(s) would be submitted, $([math]::Round($cost,2)) total."
        return $plan
    }

    $results = foreach ($c in $todo) {
        Invoke-Clip -Clip $c -Headers $headers -Cost $CostPerClip -TimeoutMinutes $TimeoutMin
    }

    $ok     = @($results | Where-Object Status -eq 'delivered')
    $failed = @($results | Where-Object Status -eq 'failed')
    Write-Human ''
    Write-Human "delivered $($ok.Count) clip(s), spent ~$([math]::Round(($ok.Count * $CostPerClip), 2)) this run"
    if ($failed) {
        Write-Human "failed: $($failed.Id -join ', ')"
        Write-Human "re-run to retry only those - delivered clips are skipped. Prediction ids are in $script:LogFile."
    }
    return $results
}

Invoke-Main
