<#
  Vigie Centre d'Appel : crée le certificat HTTPS interne du serveur (à lancer UNE fois, sur le serveur).

  Pourquoi : les navigateurs n'autorisent le micro (appels) que sur une page en HTTPS ou sur localhost.
  Ce script crée un certificat auto-signé valable pour le nom du serveur et ses adresses réseau, le range dans le dossier certs\
  et ouvre le port HTTPS (3505) dans le pare-feu Windows. Le serveur écoute alors en HTTPS EN PLUS du HTTP habituel.

  Usage (PowerShell en administrateur, depuis le dossier de Vigie Centre d'Appel) :
    powershell -ExecutionPolicy Bypass -File .\generer-certificat-https.ps1
  Puis redémarrer le service (ou relancer node server.js).

  Options :
    -NomsSupplementaires "centreappel.mondomaine.local","10.0.0.5"   noms ou adresses en plus de ceux détectés
    -Port 3505            port HTTPS
    -Annees 5             durée de validité
    -SansPareFeu          ne touche pas au pare-feu
    -Forcer               remplace un certificat existant (les postes devront installer le nouveau)
    -Dossier <chemin>     dossier de destination (par défaut : certs à côté du script)
#>
param(
  [string]$Dossier = (Join-Path $PSScriptRoot 'certs'),
  [int]$Port = 3505,
  [string[]]$NomsSupplementaires = @(),
  [int]$Annees = 5,
  [switch]$SansPareFeu,
  [switch]$Forcer
)
$ErrorActionPreference = 'Stop'

$pfx  = Join-Path $Dossier 'vigie.pfx'
$cer  = Join-Path $Dossier 'vigie-certificat.cer'
$pass = Join-Path $Dossier 'pfx-pass.txt'
if ((Test-Path $pfx) -and -not $Forcer) {
  Write-Host "Un certificat existe déjà : $pfx" -ForegroundColor Yellow
  Write-Host "Les postes lui font déjà confiance. Utilisez -Forcer seulement si vous voulez le remplacer (chaque poste devra alors installer le nouveau)."
  exit 0
}

# Noms et adresses que les navigateurs utiliseront pour joindre le serveur
$dns = New-Object System.Collections.Generic.List[string]
$ips = New-Object System.Collections.Generic.List[string]
$dns.Add('localhost'); $dns.Add($env:COMPUTERNAME)
try { $fqdn = [System.Net.Dns]::GetHostEntry('').HostName; if ($fqdn -and $fqdn -ne $env:COMPUTERNAME) { $dns.Add($fqdn) } } catch {}
$ips.Add('127.0.0.1')
try {
  Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } | ForEach-Object { $ips.Add($_.IPAddress) }
} catch {}
foreach ($n in $NomsSupplementaires) { if ($n -match '^\d{1,3}(\.\d{1,3}){3}$') { $ips.Add($n) } elseif ($n) { $dns.Add($n) } }
$dns = @($dns | Select-Object -Unique); $ips = @($ips | Select-Object -Unique)
$san = '2.5.29.17={text}' + ((@($dns | ForEach-Object { "DNS=$_" }) + @($ips | ForEach-Object { "IPAddress=$_" })) -join '&')

New-Item -ItemType Directory -Force $Dossier | Out-Null
# Le certificat est créé dans le magasin de l'utilisateur courant (aucun droit spécial), exporté, puis retiré du magasin
$cert = New-SelfSignedCertificate -Subject "CN=Vigie Centre d'Appel ($env:COMPUTERNAME)" -TextExtension @($san, '2.5.29.37={text}1.3.6.1.5.5.7.3.1') `
  -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeyUsage DigitalSignature, KeyEncipherment `
  -NotAfter (Get-Date).AddYears($Annees) -KeyExportPolicy Exportable -CertStoreLocation 'Cert:\CurrentUser\My'
try {
  $bytes = New-Object byte[] 24
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $secret = [Convert]::ToBase64String($bytes)
  Export-PfxCertificate -Cert $cert -FilePath $pfx -Password (ConvertTo-SecureString $secret -AsPlainText -Force) -Force | Out-Null
  Export-Certificate -Cert $cert -FilePath $cer -Force | Out-Null
  Set-Content -Path $pass -Value $secret -Encoding ASCII -NoNewline
} finally {
  Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force -ErrorAction SilentlyContinue
}

# Droits : la clé privée n'est lisible que par le système, les administrateurs et le compte qui a lancé le script
# (identifiants de sécurité universels : cela fonctionne quelle que soit la langue de Windows)
$moi = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
& icacls.exe $Dossier /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*${moi}:(OI)(CI)F" | Out-Null
# Le certificat PUBLIC (.cer) peut être lu par tous les comptes du poste (il contient seulement la partie publique)
& icacls.exe $cer /grant "*S-1-5-32-545:R" | Out-Null

$firewall = 'non modifié'
if (-not $SansPareFeu) {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($isAdmin) {
    $name = "Vigie Centre d'Appel HTTPS (port $Port)"
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any | Out-Null
    $firewall = "port $Port ouvert (tous types de réseau, comme le port 3504)"
  } else {
    $firewall = "NON ouvert : relancez ce script en administrateur, ou ouvrez le port TCP $Port dans le pare-feu"
  }
}

Write-Host ''
Write-Host 'Certificat créé.' -ForegroundColor Green
Write-Host "  Dossier      : $Dossier"
Write-Host "  Noms         : $($dns -join ', ')"
Write-Host "  Adresses     : $($ips -join ', ')"
Write-Host "  Empreinte    : $($cert.Thumbprint)   (à comparer sur les postes)"
Write-Host "  Valable      : jusqu'au $($cert.NotAfter.ToString('yyyy-MM-dd'))"
Write-Host "  Pare-feu     : $firewall"
Write-Host ''
Write-Host 'Étapes suivantes :'
Write-Host '  1. Redémarrer Vigie Centre d Appel'
Write-Host "  2. Sur chaque poste, installer le certificat : copiez $cer puis lancez installer-certificat-client.ps1"
Write-Host "  3. Les employés ouvrent Centre d'Appel à l'adresse https://<serveur>:$Port/"
