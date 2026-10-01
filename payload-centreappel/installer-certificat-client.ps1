<#
  Vigie Centre d'Appel : fait confiance au certificat HTTPS interne sur CE poste (à lancer sur chaque poste employé).

  Après cela, le navigateur (Edge, Chrome) n'affiche plus d'avertissement sur https://<serveur>:3505/ et autorise le micro
  pour les appels. Firefox utilise son propre magasin : activez "security.enterprise_roots.enabled" ou importez le fichier.

  Usage : powershell -ExecutionPolicy Bypass -File .\installer-certificat-client.ps1 -Fichier .\vigie-certificat.cer
    (en administrateur : installé pour tous les comptes du poste ; sinon pour le compte courant, Windows demande une confirmation)
  Vérifiez que l'empreinte affichée est bien celle annoncée par generer-certificat-https.ps1 sur le serveur.
#>
param(
  [string]$Fichier = (Join-Path $PSScriptRoot 'vigie-certificat.cer'),
  [string]$EmpreinteAttendue = ''
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Fichier)) {
  Write-Host "Fichier introuvable : $Fichier" -ForegroundColor Red
  Write-Host "Copiez vigie-certificat.cer depuis le dossier certs\ du serveur."
  exit 1
}
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (Resolve-Path $Fichier).Path
Write-Host "Certificat : $($cert.Subject)"
Write-Host "Empreinte  : $($cert.Thumbprint)"
Write-Host "Valable    : du $($cert.NotBefore.ToString('yyyy-MM-dd')) au $($cert.NotAfter.ToString('yyyy-MM-dd'))"
if ($EmpreinteAttendue -and ($cert.Thumbprint -ne ($EmpreinteAttendue -replace '\s', '').ToUpper())) {
  Write-Host 'ATTENTION : cette empreinte ne correspond pas à celle attendue. Installation annulée.' -ForegroundColor Red
  exit 2
}
if ($cert.NotAfter -lt (Get-Date)) { Write-Host 'Ce certificat est expiré. Installation annulée.' -ForegroundColor Red; exit 3 }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$store = if ($isAdmin) { 'Cert:\LocalMachine\Root' } else { 'Cert:\CurrentUser\Root' }
Import-Certificate -FilePath $Fichier -CertStoreLocation $store | Out-Null
Write-Host "Certificat installé dans $store." -ForegroundColor Green
Write-Host 'Fermez et rouvrez le navigateur, puis ouvrez Centre d''Appel à l''adresse https://<serveur>:3505/'
