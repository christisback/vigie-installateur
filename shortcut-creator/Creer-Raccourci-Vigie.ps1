<#
  Créateur de raccourcis Vigie
  ----------------------------
  À exécuter sur N'IMPORTE QUEL poste du réseau (pas besoin d'avoir l'application
  installée dessus) pour créer un raccourci bureau vers une appli Vigie qui tourne
  sur un autre poste (le serveur), avec le vrai logo de l'appli - téléchargé
  directement depuis le serveur au moment de créer le raccourci.
#>

$Apps = [ordered]@{
  '1' = @{ Nom = 'Vigie Billets';    Port = 3500; Icone = 'vigie-billets.ico' }
  '2' = @{ Nom = 'Vigie Parc';       Port = 3501; Icone = 'vigie-parc.ico' }
  '3' = @{ Nom = 'Vigie Inventory';  Port = 3502; Icone = 'vigie-inventory.ico' }
  '4' = @{ Nom = 'Vigie Simulation'; Port = 3503; Icone = 'vigie-simulation.ico' }
}

Write-Host ''
Write-Host '=== Createur de raccourcis Vigie ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Quelle application ?'
foreach ($k in $Apps.Keys) { Write-Host "  $k) $($Apps[$k].Nom)" }
Write-Host ''
$choix = Read-Host 'Votre choix (1-4)'

if (-not $Apps.Contains($choix)) {
  Write-Host "Choix invalide." -ForegroundColor Red
  Read-Host 'Appuyez sur Entree pour fermer'
  exit 1
}
$App = $Apps[$choix]

Write-Host ''
$ServerIP = Read-Host "Adresse IP du serveur (ex: 192.168.1.50) qui fait tourner $($App.Nom)"
if ([string]::IsNullOrWhiteSpace($ServerIP)) {
  Write-Host "Adresse IP requise." -ForegroundColor Red
  Read-Host 'Appuyez sur Entree pour fermer'
  exit 1
}
$ServerIP = $ServerIP.Trim()

$Url = "http://${ServerIP}:$($App.Port)"
$IconUrl = "$Url/brand/$($App.Icone)"

Write-Host ''
Write-Host "Verification de la connexion a $Url ..."
try {
  $resp = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
} catch {
  Write-Host ''
  Write-Host "ATTENTION : impossible de joindre $Url pour le moment." -ForegroundColor Yellow
  Write-Host "Le raccourci sera quand meme cree (le serveur est peut-etre juste eteint la), mais verifiez l'adresse IP et le port si ca ne fonctionne pas une fois double-clique." -ForegroundColor Yellow
}

# Icone : telechargee depuis le serveur si possible, sinon raccourci sans icone personnalisee
$IconDir = Join-Path $env:LOCALAPPDATA 'VigieRaccourcis'
New-Item -ItemType Directory -Path $IconDir -Force | Out-Null
$IconPath = Join-Path $IconDir $App.Icone
$IconOk = $false
try {
  Invoke-WebRequest -Uri $IconUrl -OutFile $IconPath -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
  $IconOk = $true
  Write-Host "Logo telecharge."
} catch {
  Write-Host "Logo non recupere (serveur injoignable) - le raccourci utilisera l'icone par defaut du navigateur." -ForegroundColor Yellow
}

$WshShell = New-Object -ComObject WScript.Shell
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "$($App.Nom).lnk"
$Shortcut = $WshShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = $Url
if ($IconOk) { $Shortcut.IconLocation = $IconPath }
$Shortcut.Save()

Write-Host ''
Write-Host "Raccourci cree sur le Bureau : $($App.Nom) -> $Url" -ForegroundColor Green
Write-Host ''
Read-Host 'Appuyez sur Entree pour fermer'
