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

try {

Log "=== Installation Suite Vigie - démarrage ==="

$StartupFolder = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"

# ── Retrait des anciennes icônes individuelles (une par application) ────────
# Vigie Billets / Vigie Parc / Vigie Inventory installaient chacun leur propre
# icône dans la barre système avant la Suite - on les retire pour éviter les
# doublons. Les serveurs eux-mêmes (services Windows) ne sont PAS touchés,
# seules les icônes de la barre système le sont.
$OldTrayShortcuts = @(
  "Vigie Billets (icône).lnk",
  "Vigie Parc (icone).lnk",
  "Vigie Inventory (icone).lnk",
  "Vigie Simulation (icône).lnk"
)
foreach ($name in $OldTrayShortcuts) {
  $p = Join-Path $StartupFolder $name
  if (Test-Path $p) {
    Remove-Item -Path $p -Force
    Log "Ancien raccourci retiré : $name"
  }
}
try {
  Get-CimInstance Win32_Process | Where-Object {
    ($_.CommandLine -like '*tray.ps1*' -or $_.CommandLine -like '*tray-simulation.ps1*') -and
    $_.CommandLine -notlike '*Suite Vigie*'
  } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Log "Anciennes icônes individuelles fermées."
} catch {
  Log "(fermeture des anciennes icônes : $($_.Exception.Message))"
}

# ── Icône unifiée dans la barre système (démarre avec Windows) ──────────────
Log "Configuration de l'icône Suite Vigie..."
$WshShell = New-Object -ComObject WScript.Shell
$TrayShortcut = $WshShell.CreateShortcut((Join-Path $StartupFolder "Suite Vigie (icone).lnk"))
$TrayShortcut.TargetPath = "powershell.exe"
$TrayShortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstallDir\tray.ps1`" -InstallDir `"$InstallDir`""
$TrayShortcut.WorkingDirectory = $InstallDir
$TrayShortcut.WindowStyle = 7
$TrayShortcut.Save()
try {
  $trayProc = Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstallDir\tray.ps1`" -InstallDir `"$InstallDir`"" -PassThru
  $trayProc.Id | Out-File -FilePath (Join-Path $InstallDir "tray.pid") -Encoding ASCII
  Log "Icône Suite Vigie démarrée (PID $($trayProc.Id))."
} catch {
  Log "⚠️ Icône Suite Vigie non démarrée: $($_.Exception.Message)"
}

Log "=== Installation terminée avec succès ==="

} catch {
  Log "❌ ERREUR FATALE: $($_.Exception.Message)"
  Log ($_.ScriptStackTrace -replace "`n", " | ")
  exit 1
}
