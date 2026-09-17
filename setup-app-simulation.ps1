param(
  [Parameter(Mandatory=$true)][string]$InstallDir
)

$ErrorActionPreference = 'Stop'
$LogFile = Join-Path $InstallDir "install-log.txt"
function Log($msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
  Write-Host $line
  Add-Content -Path $LogFile -Value $line
}

function Update-PathFromMachine {
  $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
}

function Invoke-Nssm {
  param([string[]]$NssmArgs)
  try {
    & $script:NssmExe @NssmArgs 2>&1 | ForEach-Object { Log "  nssm> $_" }
  } catch {
    Log "  (nssm $($NssmArgs -join ' ') a signalé: $($_.Exception.Message))"
  }
}

try {

$SetupDir = Join-Path $InstallDir "_setup"
$NodeMsi  = Join-Path $SetupDir "node-v24.19.0-x64.msi"
$NssmExe  = Join-Path $SetupDir "nssm.exe"

Log "=== Installation Vigie Simulation — démarrage ==="

# ── 1) Node.js (aucune base de données requise pour cette application) ──────
Update-PathFromMachine
$nodeOk = $false
try { $v = & node --version 2>$null; if ($v) { $nodeOk = $true; Log "Node.js déjà présent ($v)" } } catch {}
if (-not $nodeOk) {
  Log "Installation de Node.js LTS..."
  $p = Start-Process msiexec.exe -ArgumentList "/i `"$NodeMsi`" /qn /norestart" -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "Échec installation Node.js (code $($p.ExitCode))" }
  Update-PathFromMachine
  Log "Node.js installé."
}

# ── 2) Service Windows (via NSSM) ────────────────────────────────────────
Update-PathFromMachine
$NodeExePath = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $NodeExePath) { $NodeExePath = "C:\Program Files\nodejs\node.exe" }

$ServiceName = "VigieSimulation"
Log "Configuration du service Windows '$ServiceName'..."
Invoke-Nssm @('stop', $ServiceName)
Invoke-Nssm @('remove', $ServiceName, 'confirm')
Invoke-Nssm @('install', $ServiceName, $NodeExePath)
Invoke-Nssm @('set', $ServiceName, 'AppDirectory', $InstallDir)
Invoke-Nssm @('set', $ServiceName, 'AppParameters', 'server.js')
Invoke-Nssm @('set', $ServiceName, 'AppEnvironmentExtra', "NODE_ENV=production", "PORT=3503")
Invoke-Nssm @('set', $ServiceName, 'Start', 'SERVICE_AUTO_START')
Invoke-Nssm @('set', $ServiceName, 'AppStdout', (Join-Path $InstallDir "service-out.log"))
Invoke-Nssm @('set', $ServiceName, 'AppStderr', (Join-Path $InstallDir "service-err.log"))
Invoke-Nssm @('start', $ServiceName)
Start-Sleep -Seconds 2

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
  Log "Service démarré avec succès."
} else {
  Log "⚠️ Le service ne semble pas démarré (statut: $($svc.Status)). Vérifiez service-err.log."
}

# ── 3) Pare-feu — accès depuis le réseau local ──────────────────────────
try {
  Get-NetFirewallRule -DisplayName "Vigie Simulation (port 3503)" -ErrorAction Stop | Out-Null
  Log "Règle de pare-feu déjà présente."
} catch {
  try {
    New-NetFirewallRule -DisplayName "Vigie Simulation (port 3503)" -Direction Inbound -Protocol TCP -LocalPort 3503 -Action Allow -Profile Any | Out-Null
    Log "Règle de pare-feu ajoutée (port 3503 ouvert pour le réseau local)."
  } catch {
    Log "⚠️ Impossible d'ajouter la règle de pare-feu automatiquement: $($_.Exception.Message)"
  }
}

# ── 4) Raccourci bureau ───────────────────────────────────────────────────
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("$env:PUBLIC\Desktop\Vigie Simulation.lnk")
$Shortcut.TargetPath = "http://localhost:3503"
$Shortcut.IconLocation = Join-Path $InstallDir "public\brand\vigie-simulation.ico"
$Shortcut.Save()

# ── 5) Fichier de récapitulatif ──────────────────────────────────────────
$LanIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
  $_.IPAddress -notmatch '^169\.254\.' -and $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown'
} | Select-Object -First 1 -ExpandProperty IPAddress)

$infoPath = Join-Path $InstallDir "IMPORTANT - Installation.txt"
@"
Vigie Simulation — Installation terminée
=========================================
Adresse sur ce poste       : http://localhost:3503
Adresse depuis le réseau local : http://$LanIp`:3503

Aucun compte, aucune base de données — l'outil charge directement ses 100 scénarios.
Le serveur tourne en service Windows ($ServiceName) — démarre automatiquement avec Windows.
"@ | Out-File -FilePath $infoPath -Encoding UTF8

Log "=== Installation terminée avec succès ==="

} catch {
  Log "❌ ERREUR FATALE: $($_.Exception.Message)"
  Log ($_.ScriptStackTrace -replace "`n", " | ")
  exit 1
}
