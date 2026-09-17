param(
  [string]$InstallDir = $PSScriptRoot
)

# ── Instance unique ───────────────────────────────────────────────────────
# Empêche deux icônes Suite Vigie de tourner en même temps (ex. relancée par
# plusieurs installateurs d'affilée, ou lancée deux fois par erreur) — si une
# autre instance tourne déjà, celle-ci se ferme immédiatement sans rien faire.
$MyProcessId = $PID
$AlreadyRunning = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  $_.ProcessId -ne $MyProcessId -and $_.Name -eq 'powershell.exe' -and
  $_.CommandLine -like '*tray.ps1*' -and $_.CommandLine -like '*Suite Vigie*'
}
if ($AlreadyRunning) { exit }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Icônes (couleur = tout fonctionne, gris = au moins un arrêté) ────────────
# Chargées via un MemoryStream (et non le chemin de fichier directement) pour
# ne PAS garder le fichier verrouillé pendant toute la durée de vie du script.
$IconPath = Join-Path $InstallDir "brand\favicon-32.png"
$iconBytes = [System.IO.File]::ReadAllBytes($IconPath)
$bmpColor = New-Object System.Drawing.Bitmap((New-Object System.IO.MemoryStream(,$iconBytes)))

$bmpGrey = New-Object System.Drawing.Bitmap($bmpColor.Width, $bmpColor.Height)
$g = [System.Drawing.Graphics]::FromImage($bmpGrey)
$matrix = New-Object System.Drawing.Imaging.ColorMatrix (,@(
  @(0.3,0.3,0.3,0,0), @(0.59,0.59,0.59,0,0), @(0.11,0.11,0.11,0,0), @(0,0,0,1,0), @(0,0,0,0,1)
))
$attrs = New-Object System.Drawing.Imaging.ImageAttributes
$attrs.SetColorMatrix($matrix)
$g.DrawImage($bmpColor, (New-Object System.Drawing.Rectangle(0,0,$bmpColor.Width,$bmpColor.Height)), 0, 0, $bmpColor.Width, $bmpColor.Height, [System.Drawing.GraphicsUnit]::Pixel, $attrs)
$g.Dispose()

$iconColor = [System.Drawing.Icon]::FromHandle($bmpColor.GetHicon())
$iconGrey  = [System.Drawing.Icon]::FromHandle($bmpGrey.GetHicon())

# ── Applications de la suite — seules celles réellement installées (service
# Windows présent sur ce poste) apparaissent dans le menu ───────────────────
$AllApps = @(
  @{ Name = "Vigie Billets";    Service = "VigieBillets";    Url = "http://localhost:3500" },
  @{ Name = "Vigie Parc";       Service = "VigieParc";       Url = "http://localhost:3501" },
  @{ Name = "Vigie Inventory";  Service = "VigieInventory";  Url = "http://localhost:3502" },
  @{ Name = "Vigie Simulation"; Service = "VigieSimulation"; Url = "http://localhost:3503" }
)
$Apps = $AllApps | Where-Object { Get-Service -Name $_.Service -ErrorAction SilentlyContinue }

if (-not $Apps -or $Apps.Count -eq 0) {
  [System.Windows.Forms.MessageBox]::Show(
    "Aucun programme de la Suite Vigie (Billets / Parc / Inventory / Simulation) n'a été détecté sur ce poste.",
    "Suite Vigie", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
  exit
}

# ── Icône système ─────────────────────────────────────────────────────────────
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $iconColor
$notifyIcon.Visible = $true
$notifyIcon.Text = "Suite Vigie"

function Get-AppRunning($app) {
  $svc = Get-Service -Name $app.Service -ErrorAction SilentlyContinue
  return ($svc -and $svc.Status -eq 'Running')
}

function Update-Status {
  $allRunning = $true
  $lines = @("Suite Vigie")
  foreach ($app in $Apps) {
    $running = Get-AppRunning $app
    if (-not $running) { $allRunning = $false }
    $lines += "  $($app.Name) : $(if ($running) { 'en cours' } else { 'arrêté' })"
  }
  $notifyIcon.Icon = $(if ($allRunning) { $iconColor } else { $iconGrey })
  # NotifyIcon.Text est limité à 63 caractères sous Windows — on garde court.
  $notifyIcon.Text = $(if ($allRunning) { "Suite Vigie — tout fonctionne" } else { "Suite Vigie — attention requise" })
}

# ── Menu contextuel (clic droit) : un sous-menu par application détectée ────
$menu = New-Object System.Windows.Forms.ContextMenuStrip

foreach ($app in $Apps) {
  $appName = $app.Name
  $svcName = $app.Service
  $appUrl  = $app.Url

  $sub = New-Object System.Windows.Forms.ToolStripMenuItem($appName)

  $openItem = $sub.DropDownItems.Add("Ouvrir")
  $openItem.Add_Click({ Start-Process $appUrl }.GetNewClosure())

  $sub.DropDownItems.Add("-") | Out-Null

  $restartItem = $sub.DropDownItems.Add("Redémarrer le serveur")
  $restartItem.Add_Click({
    Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -Command Restart-Service -Name '$svcName' -Force" -Verb RunAs
    Start-Sleep -Seconds 2
    Update-Status
    $notifyIcon.ShowBalloonTip(3000, $appName, "Le serveur redémarre...", [System.Windows.Forms.ToolTipIcon]::Info)
  }.GetNewClosure())

  $stopItem = $sub.DropDownItems.Add("Fermer le serveur")
  $stopItem.Add_Click({
    Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -Command Stop-Service -Name '$svcName' -Force" -Verb RunAs
    Start-Sleep -Seconds 2
    Update-Status
    $notifyIcon.ShowBalloonTip(3000, $appName, "Le serveur a été arrêté.", [System.Windows.Forms.ToolTipIcon]::Warning)
  }.GetNewClosure())

  $startItem = $sub.DropDownItems.Add("Démarrer le serveur")
  $startItem.Add_Click({
    Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -Command Start-Service -Name '$svcName'" -Verb RunAs
    Start-Sleep -Seconds 2
    Update-Status
    $notifyIcon.ShowBalloonTip(3000, $appName, "Le serveur démarre...", [System.Windows.Forms.ToolTipIcon]::Info)
  }.GetNewClosure())

  $menu.Items.Add($sub) | Out-Null
}

$menu.Items.Add("-") | Out-Null

$quitAllItem = $menu.Items.Add("Tout arrêter et quitter")
$quitAllItem.Add_Click({
  $svcNamesQuoted = ($Apps | ForEach-Object { "'$($_.Service)'" }) -join ','
  Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -Command Stop-Service -Name $svcNamesQuoted -Force -ErrorAction SilentlyContinue" -Verb RunAs -Wait
  $notifyIcon.Visible = $false
  [System.Windows.Forms.Application]::Exit()
})

$quitIconOnlyItem = $menu.Items.Add("Quitter l'icône seulement (les serveurs continuent)")
$quitIconOnlyItem.Add_Click({
  $notifyIcon.Visible = $false
  [System.Windows.Forms.Application]::Exit()
})

$notifyIcon.ContextMenuStrip = $menu
$notifyIcon.Add_MouseDoubleClick({
  # Double-clic : ouvre la première application détectée
  Start-Process $Apps[0].Url
})

# ── Vérification périodique du statut (toutes les 5 secondes) ────────────────
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Update-Status })
$timer.Start()

Update-Status
[System.Windows.Forms.Application]::Run()
