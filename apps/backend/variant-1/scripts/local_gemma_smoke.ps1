[CmdletBinding()]
param(
  [int]$Port = 4311
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$smokeDir = Join-Path $rootDir ".zig-cache\smoke"
$zigWrapper = Join-Path $scriptDir "zigw.ps1"
$exePath = Join-Path $rootDir "zig-out\bin\VAR1.exe"
$frontendClientDir = Join-Path (Split-Path -Parent (Split-Path -Parent $rootDir)) "frontend\var1-client"
$bridgeOut = Join-Path $smokeDir "bridge-out.txt"
$bridgeErr = Join-Path $smokeDir "bridge-err.txt"
$sanityPrompt = "Count the lowercase letter r in this exact character sequence: s t r a w b e r r y. Return only the number."
$promptFile = $null
$bridgeProcess = $null

function Read-EnvMap {
  param([string]$EnvPath)

  $values = @{}
  foreach ($line in Get-Content -LiteralPath $EnvPath) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) {
      continue
    }

    $parts = $line.Split("=", 2)
    if ($parts.Count -eq 2) {
      $values[$parts[0]] = $parts[1]
    }
  }

  return $values
}

function Get-PortOwnerProcess {
  param([int]$TargetPort)

  if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    $connection = Get-NetTCPConnection -LocalPort $TargetPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($connection) {
      return Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
    }
  }

  $netstatLine = netstat -ano -p tcp | Select-String -Pattern "LISTENING\s+(\S+:)?$TargetPort\s+.*\s+(\d+)$" | Select-Object -First 1
  if (-not $netstatLine) {
    return $null
  }

  $segments = ($netstatLine.Line -split '\s+') | Where-Object { $_ -ne "" }
  if ($segments.Count -lt 5) {
    return $null
  }

  return Get-Process -Id ([int]$segments[-1]) -ErrorAction SilentlyContinue
}

function Get-ProviderModelsUrl {
  param([string]$BaseUrl)

  $trimmed = $BaseUrl.TrimEnd("/")
  if ($trimmed -match "/v\d+$") {
    return "$trimmed/models"
  }

  return "$trimmed/v1/models"
}

function Assert-ProviderReady {
  param(
    [string]$BaseUrl,
    [string]$ApiKey,
    [string]$Model
  )

  $modelsUrl = Get-ProviderModelsUrl -BaseUrl $BaseUrl
  $headers = @{}
  if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
    $headers["Authorization"] = "Bearer $ApiKey"
  }

  try {
    $response = Invoke-RestMethod -Uri $modelsUrl -Headers $headers -Method Get -TimeoutSec 15
  } catch {
    throw "GEMMA_LOCAL expected reachable provider at ${modelsUrl}: $($_.Exception.Message)"
  }

  $availableModels = @($response.data | ForEach-Object { $_.id })
  if ($availableModels -notcontains $Model) {
    $available = if ($availableModels.Count -gt 0) { $availableModels -join ", " } else { "<none>" }
    throw "GEMMA_LOCAL expected model $Model to be served at $modelsUrl. Available models: $available"
  }
}

function Clear-BridgePort {
  param([int]$TargetPort)

  $owner = Get-PortOwnerProcess -TargetPort $TargetPort
  if (-not $owner) {
    return
  }

  if ($owner.ProcessName -ne "VAR1") {
    throw "smoke port $TargetPort is already owned by non-VAR1 process $($owner.ProcessName) (PID $($owner.Id))"
  }

  Stop-Process -Id $owner.Id -Force
}

function Invoke-Variant1 {
  param([string[]]$CommandArgs)

  $output = & $exePath @CommandArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "VAR1.exe failed for args [$($CommandArgs -join ' ')]`n$($output | Out-String)"
  }

  return ($output | Out-String).Trim()
}

function Test-ReportsThree {
  param([string]$Text)

  return $Text -match '\b3\b'
}

function Wait-ForBridgeHealth {
  param([int]$TargetPort)

  for ($attempt = 0; $attempt -lt 40; $attempt += 1) {
    try {
      return Invoke-RestMethod -Uri "http://127.0.0.1:$TargetPort/api/health"
    } catch {
      Start-Sleep -Seconds 1
    }
  }

  throw "bridge health check did not respond on port $TargetPort"
}

try {
  New-Item -ItemType Directory -Force -Path $smokeDir | Out-Null

  $envValues = Read-EnvMap -EnvPath (Join-Path $rootDir ".env")
  if ($envValues["OPENAI_BASE_URL"] -ne "http://127.0.0.1:1234") {
    throw "GEMMA_LOCAL expected OPENAI_BASE_URL=http://127.0.0.1:1234 in .env"
  }
  if ($envValues["OPENAI_MODEL"] -ne "gemma-4-26b-a4b-it-apex") {
    throw "GEMMA_LOCAL expected OPENAI_MODEL=gemma-4-26b-a4b-it-apex in .env"
  }
  Assert-ProviderReady -BaseUrl $envValues["OPENAI_BASE_URL"] -ApiKey $envValues["OPENAI_API_KEY"] -Model $envValues["OPENAI_MODEL"]

  Write-Host "GEMMA_LOCAL suite"
  & $zigWrapper build test --summary all
  if ($LASTEXITCODE -ne 0) {
    throw "zig test suite failed"
  }

  Write-Host "GEMMA_LOCAL windows build"
  & $zigWrapper build -Dtarget=x86_64-windows-gnu --summary all
  if ($LASTEXITCODE -ne 0) {
    throw "windows build failed"
  }

  Write-Host "GEMMA_LOCAL direct run"
  $directRunOutput = Invoke-Variant1 -CommandArgs @("run", "--prompt", $sanityPrompt)
  if (-not (Test-ReportsThree -Text $directRunOutput)) {
    throw "GEMMA_LOCAL direct run did not clearly report 3: $directRunOutput"
  }
  Write-Host $directRunOutput

  $promptFile = Join-Path $smokeDir "VAR1-gemma-delegated-prompt-$([guid]::NewGuid().ToString('N')).txt"
  @'
Launch a child agent named berry-child.
Child prompt: Count the lowercase letter r in this exact character sequence: s t r a w b e r r y. Return only the number.
Use agent_status as the primary supervision surface.
Use wait_agent only when you are ready to collect a current or terminal snapshot.
Return only the child's final answer and nothing else.
'@ | Set-Content -LiteralPath $promptFile -NoNewline

  Write-Host "GEMMA_LOCAL delegated"
  $delegatedOutput = Invoke-Variant1 -CommandArgs @("run", "--prompt-file", $promptFile)
  if (-not (Test-ReportsThree -Text $delegatedOutput)) {
    throw "GEMMA_LOCAL delegated run did not clearly report 3: $delegatedOutput"
  }
  Write-Host $delegatedOutput

  Clear-BridgePort -TargetPort $Port
  Remove-Item -LiteralPath $bridgeOut, $bridgeErr -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $rootDir "bridge-out.txt"), (Join-Path $rootDir "bridge-err.txt") -Force -ErrorAction SilentlyContinue

  Write-Host "GEMMA_LOCAL bridge"
  $bridgeProcess = Start-Process -FilePath $exePath -ArgumentList @("serve", "--host", "127.0.0.1", "--port", $Port.ToString()) -RedirectStandardOutput $bridgeOut -RedirectStandardError $bridgeErr -PassThru -WindowStyle Hidden

  $health = Wait-ForBridgeHealth -TargetPort $Port
  if ($health.model -ne "gemma-4-26b-a4b-it-apex") {
    throw "GEMMA_LOCAL bridge health reported unexpected model: $($health.model)"
  }

  if (-not (Test-Path -LiteralPath (Join-Path $frontendClientDir "index.html"))) {
    throw "GEMMA_LOCAL expected external browser client at $frontendClientDir"
  }

  $bridgeHome = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/" -Method Get
  if ($bridgeHome -notmatch "VAR1 HTTP bridge ready") {
    throw "GEMMA_LOCAL bridge root did not return bridge-only text"
  }
  if ($bridgeHome -notmatch "apps/frontend/var1-client") {
    throw "GEMMA_LOCAL bridge root did not point operators to apps/frontend/var1-client"
  }

  $created = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/tasks" -Method Post -ContentType "application/json" -Body (@{ prompt = $sanityPrompt } | ConvertTo-Json -Compress)
  $taskId = $created.task.id
  if ([string]::IsNullOrWhiteSpace($taskId)) {
    throw "GEMMA_LOCAL bridge compatibility create route did not return a task id"
  }

  $taskList = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/tasks" -Method Get
  if (-not ($taskList.tasks | Where-Object { $_.id -eq $taskId })) {
    throw "GEMMA_LOCAL bridge compatibility list route did not expose the created task"
  }

  $detail = $null
  for ($attempt = 0; $attempt -lt 40; $attempt += 1) {
    $detail = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/tasks/$taskId" -Method Get
    $detailAnswer = if ($null -ne $detail.task.answer) { [string]$detail.task.answer } else { "" }
    if ($detail.task.status -eq "completed" -and (Test-ReportsThree -Text $detailAnswer)) {
      break
    }
    Start-Sleep -Seconds 1
  }

  $detailAnswer = if ($null -ne $detail.task.answer) { [string]$detail.task.answer } else { "" }
  if ($detail.task.status -ne "completed" -or -not (Test-ReportsThree -Text $detailAnswer)) {
    throw "GEMMA_LOCAL bridge compatibility task did not complete with the expected answer"
  }

  $journal = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/tasks/$taskId/journal" -Method Get
  $journalEventTypes = @($journal.events | ForEach-Object { $_.event_type })
  if ($journalEventTypes -notcontains "assistant_response") {
    throw "GEMMA_LOCAL bridge compatibility journal did not expose assistant_response"
  }

  $summary = [ordered]@{
    model = $health.model
    workspace_root = $health.workspace_root
    task_id = $taskId
    status = $detail.task.status
    answer = $detail.task.answer
    journal_events = ($journalEventTypes -join ",")
  } | ConvertTo-Json -Compress

  Write-Host $summary
  Write-Host "GEMMA_LOCAL bridge ok"
} finally {
  if ($promptFile -and (Test-Path -LiteralPath $promptFile)) {
    Remove-Item -LiteralPath $promptFile -Force
  }

  if ($bridgeProcess -and -not $bridgeProcess.HasExited) {
    Stop-Process -Id $bridgeProcess.Id -Force
  } else {
    Clear-BridgePort -TargetPort $Port
  }
}
