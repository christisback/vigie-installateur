param(
  [Parameter(Mandatory=$true)][string]$InstallDir,
  [string]$ServiceName = "VigieInventory"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Icônes (couleur = en cours, gris = arrêté) ───────────────────────────────
# Chargées via un MemoryStream (et non le chemin de fichier directement) pour
# ne PAS garder le fichier verrouillé pendant toute la durée de vie du script.
$IconPath = Join-Path $InstallDir "public\brand\favicon-32.png"
$iconBytes = [System.IO.File]::ReadAllBytes($IconPath)
$bmpColor = New-Object System.Drawing.Bitmap((New-Object System.IO.MemoryStream(,$iconBytes)))

# Version grise (désaturée) pour l'état "arrêté"
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

# ── Icône système ─────────────────────────────────────────────────────────────
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $iconColor
$notifyIcon.Visible = $true
$notifyIcon.Text = "Vigie Inventory"

function Get-ServerRunning {
  $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
  return ($svc -and $svc.Status -eq 'Running')
}

function Update-Status {
  if (Get-ServerRunning) {
    $notifyIcon.Icon = $iconColor
    $notifyIcon.Text = "Vigie Inventory — en cours"
  } else {
    $notifyIcon.Icon = $iconGrey
    $notifyIcon.Text = "Vigie Inventory — arrêté"
  }
}

# ── Menu contextuel (clic droit) ──────────────────────────────────────────────
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$openItem = $menu.Items.Add("Ouvrir Vigie Inventory")
$openItem.Add_Click({ Start-Process "http://localhost:3502" })

$menu.Items.Add("-") | Out-Null

$restartItem = $menu.Items.Add("Redémarrer le serveur")
$restartItem.Add_Click({
  Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -Command Restart-Service -Name '$ServiceName' -Force" -Verb RunAs
  Start-Sleep -Seconds 2
  Update-Status
  $notifyIcon.ShowBalloonTip(3000, "Vigie Inventory", "Le serveur redémarre...", [System.Windows.Forms.ToolTipIcon]::Info)
})

$stopItem = $menu.Items.Add("Fermer le serveur")
$stopItem.Add_Click({
  Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -Command Stop-Service -Name '$ServiceName' -Force" -Verb RunAs
  Start-Sleep -Seconds 2
  Update-Status
  $notifyIcon.ShowBalloonTip(3000, "Vigie Inventory", "Le serveur a été arrêté.", [System.Windows.Forms.ToolTipIcon]::Warning)
})

$startItem = $menu.Items.Add("Démarrer le serveur")
$startItem.Add_Click({
  Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -Command Start-Service -Name '$ServiceName'" -Verb RunAs
  Start-Sleep -Seconds 2
  Update-Status
  $notifyIcon.ShowBalloonTip(3000, "Vigie Inventory", "Le serveur démarre...", [System.Windows.Forms.ToolTipIcon]::Info)
})

$menu.Items.Add("-") | Out-Null

$quitItem = $menu.Items.Add("Quitter et fermer le serveur")
$quitItem.Add_Click({
  $confirm = [System.Windows.Forms.MessageBox]::Show(
    "Le serveur va être arrêté — les utilisateurs connectés seront déconnectés.`n`nQuitter quand même ?",
    "Vigie Inventory", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
  if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  try {
    Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -Command Stop-Service -Name '$ServiceName' -Force -ErrorAction SilentlyContinue" -Verb RunAs -Wait -ErrorAction Stop
  } catch {
    # Autorisation administrateur refusée : le serveur tourne toujours, on garde l'icône.
    $notifyIcon.ShowBalloonTip(3000, "Vigie Inventory", "Le serveur n'a pas été arrêté (autorisation refusée).", [System.Windows.Forms.ToolTipIcon]::Warning)
    return
  }
  $notifyIcon.Visible = $false
  [System.Windows.Forms.Application]::Exit()
})

$notifyIcon.ContextMenuStrip = $menu
$notifyIcon.Add_MouseDoubleClick({ Start-Process "http://localhost:3502" })

# ── Vérification périodique du statut (toutes les 5 secondes) ────────────────
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Update-Status })
$timer.Start()

Update-Status
[System.Windows.Forms.Application]::Run()
