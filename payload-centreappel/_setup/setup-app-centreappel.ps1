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

# Lit PGPASSWORD et JWT_SECRET depuis la configuration NSSM du service Vigie Billets déjà installé.
# Le JWT_SECRET doit être EXACTEMENT le même que celui de Billets (pas un secret propre comme Vigie Parc) :
# c'est ce qui permet à un jeton de connexion émis par Billets d'être accepté directement ici, sans
# système de compte séparé. Jamais deviné ni codé en dur (un mauvais mot de passe ferait planter le
# reste en silence, et un secret en clair dans le script serait visible dans le dépôt public).
function Read-BilletsSecrets {
  $billetsDir = $null
  try {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{8F3C1A2B-6D4E-4A7F-9B12-3E5C7D9A1F00}_is1'
    $billetsDir = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallLocation
  } catch {}
  if (-not $billetsDir) { return $null }
  $billetsNssm = Join-Path $billetsDir "_setup\nssm.exe"
  if (-not (Test-Path $billetsNssm)) { return $null }
  $envLines = & $billetsNssm get VigieBillets AppEnvironmentExtra 2>$null
  $r = @{ PGPASSWORD = $null; JWT_SECRET = $null }
  foreach ($line in $envLines) {
    $s = "$line".Trim()
    if ($s -like 'PGPASSWORD=*')  { $r.PGPASSWORD  = $s.Substring(11) }
    elseif ($s -like 'JWT_SECRET=*') { $r.JWT_SECRET = $s.Substring(11) }
  }
  if (-not $r.PGPASSWORD -or -not $r.JWT_SECRET) { return $null }
  return $r
}

try {

$SetupDir = Join-Path $InstallDir "_setup"
$NssmExe  = Join-Path $SetupDir "nssm.exe"

Log "=== Installation Vigie Centre d'Appel - démarrage ==="

# ── 1) Vérifier que Vigie Billets (Node.js + PostgreSQL + tickets_db + JWT_SECRET) est déjà là ──
Update-PathFromMachine
$nodeOk = $false
try { $v = & node --version 2>$null; if ($v) { $nodeOk = $true; Log "Node.js présent ($v)" } } catch {}
if (-not $nodeOk) {
  throw "Node.js n'a pas été trouvé sur ce poste. Vigie Centre d'Appel nécessite que Vigie Billets soit déjà installé (il réutilise son Node.js, sa base de données et son secret de connexion) - installez Vigie Billets d'abord."
}

$PgBin = "C:\Program Files\PostgreSQL\18\bin"
$psql  = Join-Path $PgBin "psql.exe"
if (-not (Test-Path $psql)) {
  throw "PostgreSQL n'a pas été trouvé sur ce poste. Vigie Centre d'Appel nécessite que Vigie Billets soit déjà installé - installez Vigie Billets d'abord."
}

$Secrets = Read-BilletsSecrets
if (-not $Secrets) {
  throw "Impossible de lire le mot de passe PostgreSQL et le secret de connexion depuis le service Vigie Billets déjà installé. Vigie Centre d'Appel nécessite que Vigie Billets soit installé et fonctionnel sur ce poste."
}
$PgPassword = $Secrets.PGPASSWORD
$JwtSecret  = $Secrets.JWT_SECRET
$env:PGPASSWORD = $PgPassword
$dbExists = (& $psql -U postgres -h localhost -tAc "SELECT 1 FROM pg_database WHERE datname='tickets_db'") -join ''
if ($dbExists -ne '1') {
  throw "La base de données tickets_db est introuvable. Vigie Centre d'Appel nécessite que Vigie Billets soit déjà installé - installez Vigie Billets d'abord."
}
Log "Base tickets_db et secret de connexion trouvés (partagés avec Vigie Billets)."

# ── 2) Service Windows (via NSSM) ────────────────────────────────────────
Update-PathFromMachine
$NodeExePath = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $NodeExePath) { $NodeExePath = "C:\Program Files\nodejs\node.exe" }

$ServiceName = "VigieCentreAppel"
Log "Configuration du service Windows '$ServiceName'..."
Invoke-Nssm @('stop', $ServiceName)
Invoke-Nssm @('remove', $ServiceName, 'confirm')
Invoke-Nssm @('install', $ServiceName, $NodeExePath)
Invoke-Nssm @('set', $ServiceName, 'AppDirectory', $InstallDir)
Invoke-Nssm @('set', $ServiceName, 'AppParameters', 'server.js')
Invoke-Nssm @('set', $ServiceName, 'AppEnvironmentExtra', "JWT_SECRET=$JwtSecret", "PGPASSWORD=$PgPassword", "NODE_ENV=production", "PORT=3504")
Invoke-Nssm @('set', $ServiceName, 'Start', 'SERVICE_AUTO_START')
Invoke-Nssm @('set', $ServiceName, 'AppStdout', (Join-Path $InstallDir "service-out.log"))
Invoke-Nssm @('set', $ServiceName, 'AppStderr', (Join-Path $InstallDir "service-err.log"))
Invoke-Nssm @('start', $ServiceName)
Start-Sleep -Seconds 3

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
  Log "Service démarré avec succès."
} else {
  Log "⚠️ Le service ne semble pas démarré (statut: $($svc.Status)). Vérifiez service-err.log."
}

# ── 3) Pare-feu - accès depuis le réseau local (HTTP 3504 et HTTPS 3505) ──
foreach ($fw in @(@{Name="Vigie Centre d'Appel (port 3504)"; Port=3504}, @{Name="Vigie Centre d'Appel HTTPS (port 3505)"; Port=3505})) {
  try {
    Get-NetFirewallRule -DisplayName $fw.Name -ErrorAction Stop | Out-Null
    Log "Règle de pare-feu '$($fw.Name)' déjà présente."
  } catch {
    try {
      New-NetFirewallRule -DisplayName $fw.Name -Direction Inbound -Protocol TCP -LocalPort $fw.Port -Action Allow -Profile Any | Out-Null
      Log "Règle de pare-feu ajoutée : $($fw.Name)."
    } catch {
      Log "⚠️ Impossible d'ajouter la règle de pare-feu '$($fw.Name)' automatiquement: $($_.Exception.Message)"
    }
  }
}

# ── 4) Certificat HTTPS interne (nécessaire pour le micro) ──────────────
# Génère automatiquement à l'installation - évite d'avoir à lancer generer-certificat-https.ps1 à la
# main plus tard (ce script hérite du -ExecutionPolicy Bypass de ce process-ci).
try {
  $certScript = Join-Path $InstallDir "generer-certificat-https.ps1"
  $pfxPath    = Join-Path $InstallDir "certs\vigie.pfx"
  if ((Test-Path $certScript) -and -not (Test-Path $pfxPath)) {
    Log "Génération du certificat HTTPS interne..."
    & $certScript *>&1 | ForEach-Object { Log "  cert> $_" }
    if (Test-Path $pfxPath) {
      Log "Certificat HTTPS créé. Redémarrage du service pour l'activer..."
      Invoke-Nssm @('restart', $ServiceName)
      Start-Sleep -Seconds 3
    } else {
      Log "⚠️ Le certificat HTTPS n'a pas pu être créé automatiquement (voir ci-dessus). Le centre d'appel fonctionne quand même en HTTP sur ce poste ; le micro restera indisponible depuis un autre poste tant que le certificat n'est pas en place."
    }
  } elseif (Test-Path $pfxPath) {
    Log "Certificat HTTPS déjà présent."
  }
} catch {
  Log "⚠️ Génération du certificat HTTPS interne ignorée: $($_.Exception.Message)"
}

# ── 5) Raccourci bureau ───────────────────────────────────────────────────
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("$env:PUBLIC\Desktop\Vigie Centre d'Appel.lnk")
$Shortcut.TargetPath = "https://localhost:3505"
$Shortcut.Save()

# ── 6) Fichier de récapitulatif ──────────────────────────────────────────
$LanIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
  $_.IPAddress -notmatch '^169\.254\.' -and $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' -and
  $_.InterfaceAlias -match '^(Wi-?Fi|Ethernet)'
} | Select-Object -First 1 -ExpandProperty IPAddress)
if (-not $LanIp) {
  $LanIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.IPAddress -notmatch '^169\.254\.' -and $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown'
  } | Select-Object -First 1 -ExpandProperty IPAddress)
}

$infoPath = Join-Path $InstallDir "IMPORTANT - Installation.txt"
@"
Vigie Centre d'Appel - Installation terminée
=============================================
Adresse sur ce poste (HTTP, sans micro)      : http://localhost:3504
Adresse sur ce poste (HTTPS, avec micro)     : https://localhost:3505
Adresse depuis le réseau local (HTTPS)       : https://$LanIp`:3505
  (l'adresse réseau peut changer si le routeur la réattribue - réservez
   cette IP pour ce poste dans les paramètres du routeur pour l'éviter)

Le micro (pour les appels) exige une connexion HTTPS : utilisez toujours
l'adresse https://. Sur un poste qui n'a jamais vu ce certificat, le
navigateur affiche un avertissement de sécurité - installez le certificat
avec installer-certificat-client.ps1 (fichier vigie-certificat.cer dans
le dossier certs\ de ce poste) pour le faire disparaître.

Connectez-vous avec votre compte Vigie Billets habituel (même numéro
d'employé, même mot de passe) : Centre d'Appel n'a pas ses propres comptes.

Le serveur tourne en service Windows (VigieCentreAppel) - démarre
automatiquement avec Windows.
"@ | Out-File -FilePath $infoPath -Encoding UTF8
Copy-Item -Path $infoPath -Destination "$env:PUBLIC\Desktop\IMPORTANT - Centre d'Appel.txt" -Force

Log "=== Installation terminée avec succès ==="

} catch {
  Log "❌ ERREUR FATALE: $($_.Exception.Message)"
  Log ($_.ScriptStackTrace -replace "`n", " | ")
  try { $prev = Get-Service -Name 'VigieCentreAppel' -ErrorAction SilentlyContinue; if ($prev -and $prev.Status -ne 'Running') { Start-Service -Name $prev.Name; Log "Ancien service redémarré : la mise à jour a échoué." } } catch {}
  exit 1
}
