#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installe la CA racine autonome « Helios Root CA » (AD CS, Standalone Root CA)
    et publie la racine et la CRL en HTTP sur http://ca.helios.intern/CertEnroll/.

.DESCRIPTION
    À lancer APRÈS 01-installer-dns.ps1 : l'enregistrement ca.helios.intern doit
    exister, car il est inscrit dans tous les certificats émis (CDP et AIA).

    Le script :
      1. écrit C:\Windows\CAPolicy.inf (doit exister avant la configuration de la CA) ;
      2. installe les rôles AD CS et IIS ;
      3. configure la CA : RSA 4096, SHA-256, validité 10 ans ;
      4. remplace les points LDAP/file inutiles (pas d'AD) par des URL HTTP ;
      5. publie la CRL et exporte la racine dans C:\Helios-PKI.

.EXAMPLE
    .\02-installer-ca.ps1
#>
param(
    [string]$CACommonName      = 'Helios Root CA',
    [string]$CASubjectSuffix   = 'O=Helios,C=FR',
    [string]$PublicationHost   = 'ca.helios.intern',
    [int]   $CAValidityYears   = 10,
    [int]   $CertValidityYears = 2,
    [string]$ExportDir         = 'C:\Helios-PKI'
)

$ErrorActionPreference = 'Stop'
$certEnroll = Join-Path $env:SystemRoot 'System32\CertSrv\CertEnroll'

# --- 0. Prérequis : le nom de publication doit se résoudre -----------------
try {
    Resolve-DnsName -Name $PublicationHost -Type A -DnsOnly -ErrorAction Stop | Out-Null
} catch {
    throw "$PublicationHost ne se résout pas. Lancer d'abord dns\01-installer-dns.ps1."
}

# --- 1. CAPolicy.inf -------------------------------------------------------
Write-Host '==> CAPolicy.inf' -ForegroundColor Cyan
$capolicy = @'
[Version]
Signature="$Windows NT$"

[Certsrv_Server]
RenewalKeyLength=4096
RenewalValidityPeriod=Years
RenewalValidityPeriodUnits={VALIDITY}
CRLPeriod=Weeks
CRLPeriodUnits=1
CRLDeltaPeriodUnits=0
AlternateSignatureAlgorithm=0

[BasicConstraintsExtension]
Critical=Yes
'@
$capolicy.Replace('{VALIDITY}', "$CAValidityYears") |
    Out-File -FilePath (Join-Path $env:SystemRoot 'CAPolicy.inf') -Encoding ascii -Force

# --- 2. Rôles ---------------------------------------------------------------
Write-Host '==> Rôles AD CS (Certification Authority) et IIS' -ForegroundColor Cyan
Install-WindowsFeature -Name ADCS-Cert-Authority, Web-Server -IncludeManagementTools | Out-Null

# --- 3. Configuration de la CA ---------------------------------------------
$caConfigured = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\*'
if ($caConfigured) {
    Write-Host '    CA déjà configurée : étape ignorée.' -ForegroundColor Yellow
} else {
    Write-Host "==> Création de la CA racine autonome « $CACommonName »" -ForegroundColor Cyan
    Install-AdcsCertificationAuthority `
        -CAType StandaloneRootCA `
        -CACommonName $CACommonName `
        -CADistinguishedNameSuffix $CASubjectSuffix `
        -CryptoProviderName 'RSA#Microsoft Software Key Storage Provider' `
        -KeyLength 4096 `
        -HashAlgorithmName SHA256 `
        -ValidityPeriod Years `
        -ValidityPeriodUnits $CAValidityYears `
        -Force | Out-Null
}

# Durée de validité des certificats émis
certutil -setreg CA\ValidityPeriod 'Years' | Out-Null
certutil -setreg CA\ValidityPeriodUnits $CertValidityYears | Out-Null

# --- 4. Points de publication CRL (CDP) et AIA -----------------------------
Write-Host "==> CDP et AIA en HTTP sur http://$PublicationHost/CertEnroll/" -ForegroundColor Cyan
# Sans AD, les URL ldap:// et file:// ne servent à rien : on les retire.
# L'entrée locale (C:\Windows\System32\CertSrv\...) est conservée : c'est elle
# qui écrit les fichiers dans le dossier publié par IIS.
Get-CACrlDistributionPoint |
    Where-Object { $_.Uri -match '^(ldap|http|file)' } |
    Remove-CACrlDistributionPoint -Force | Out-Null
Add-CACrlDistributionPoint -Uri "http://$PublicationHost/CertEnroll/<CaName><CRLNameSuffix><DeltaCRLAllowed>.crl" `
    -AddToCertificateCdp -AddToFreshestCrl -Force | Out-Null

Get-CAAuthorityInformationAccess |
    Where-Object { $_.Uri -match '^(ldap|http|file)' } |
    Remove-CAAuthorityInformationAccess -Force | Out-Null
Add-CAAuthorityInformationAccess -Uri "http://$PublicationHost/CertEnroll/<ServerDNSName>_<CaName><CertificateName>.crt" `
    -AddToCertificateAia -Force | Out-Null

Restart-Service -Name certsvc
Start-Sleep -Seconds 5
certutil -crl | Out-Null

# --- 5. Publication HTTP via IIS -------------------------------------------
Write-Host '==> Répertoire virtuel IIS /CertEnroll' -ForegroundColor Cyan
Import-Module WebAdministration
if (-not (Get-WebVirtualDirectory -Site 'Default Web Site' -Name 'CertEnroll')) {
    New-WebVirtualDirectory -Site 'Default Web Site' -Name 'CertEnroll' -PhysicalPath $certEnroll | Out-Null
}
Set-WebConfigurationProperty -PSPath 'IIS:\Sites\Default Web Site\CertEnroll' `
    -Filter 'system.webServer/directoryBrowse' -Name enabled -Value $true

# --- 6. Export du certificat racine ----------------------------------------
Write-Host "==> Export de la racine dans $ExportDir" -ForegroundColor Cyan
New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null
$der = Join-Path $ExportDir 'helios-root-ca.cer'
$pem = Join-Path $ExportDir 'helios-root-ca.crt'
Remove-Item $der, $pem -ErrorAction SilentlyContinue
certutil -ca.cert $der | Out-Null
certutil -encode $der $pem | Out-Null

# --- 7. Vérifications ------------------------------------------------------
Write-Host '==> Vérifications' -ForegroundColor Cyan
$caInfo = certutil -cainfo name
Write-Host "    $($caInfo | Select-String 'CA name|Nom de l')"
$root = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $der
Write-Host "    Sujet      : $($root.Subject)"
Write-Host "    Validité   : $($root.NotBefore.ToString('d')) -> $($root.NotAfter.ToString('d'))"
Write-Host "    Empreinte  : $($root.Thumbprint)"
try {
    $r = Invoke-WebRequest -Uri "http://$PublicationHost/CertEnroll/" -UseBasicParsing
    Write-Host "    HTTP CertEnroll : $($r.StatusCode)" -ForegroundColor Green
} catch {
    Write-Warning "http://$PublicationHost/CertEnroll/ ne répond pas : $($_.Exception.Message)"
}

Write-Host ''
Write-Host "CA prête. Certificat racine à distribuer : $pem (PEM) / $der (DER)" -ForegroundColor Green
Write-Host 'Pensez à sauvegarder la CA : Backup-CARoleService (voir la procédure).' -ForegroundColor Yellow
