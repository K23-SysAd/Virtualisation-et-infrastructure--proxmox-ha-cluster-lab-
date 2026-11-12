#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Émet un certificat serveur TLS signé par « Helios Root CA ».

.DESCRIPTION
    Deux modes :

    - Mode CSR (recommandé) : la clé privée est générée sur le serveur
      applicatif (openssl sous Linux), seul le CSR est copié sur INFRA.
          .\03-emettre-certificat.ps1 -Csr C:\Helios-PKI\demandes\odoo.csr

    - Mode PFX : la clé est générée sur INFRA puis exportée dans un .pfx
      protégé par mot de passe (pratique pour Windows ou un test rapide).
          .\03-emettre-certificat.ps1 -Nom odoo.helios.intern -NomsAlternatifs erp.helios.intern

    Une CA autonome met les demandes « en attente » : le script les approuve
    automatiquement, puis récupère le certificat.

    Fichiers produits dans C:\Helios-PKI\certificats\<nom>\ :
        <nom>.crt            certificat (PEM)
        <nom>-fullchain.crt  certificat + racine (PEM), pour Nginx, Apache, etc.
        <nom>.pfx            certificat + clé (mode PFX uniquement)
#>
[CmdletBinding(DefaultParameterSetName = 'Pfx')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Pfx')]
    [string]  $Nom,

    [Parameter(ParameterSetName = 'Pfx')]
    [string[]]$NomsAlternatifs = @(),

    [Parameter(Mandatory, ParameterSetName = 'Csr')]
    [string]  $Csr,

    [string]  $Sortie     = 'C:\Helios-PKI\certificats',
    [string]  $RacinePem  = 'C:\Helios-PKI\helios-root-ca.crt'
)

$ErrorActionPreference = 'Stop'

# Constantes de l'API ICertRequest
$CR_IN_BASE64HEADER  = 0x0
$CR_IN_PKCS10        = 0x100
$CR_OUT_BASE64HEADER = 0x0
$DISP_ISSUED         = 3
$DISP_UNDER_SUBMIT   = 5

# Configuration de la CA locale : « SERVEUR\Nom de la CA »
$caName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration').Active
if (-not $caName) { throw 'Aucune CA configurée sur ce serveur. Lancer d''abord 02-installer-ca.ps1.' }
$caConfig = "$env:COMPUTERNAME\$caName"

$work = Join-Path $env:TEMP ("helios-cert-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

try {
    # --- 1. Obtenir le CSR -------------------------------------------------
    if ($PSCmdlet.ParameterSetName -eq 'Pfx') {
        $sans = @($Nom) + $NomsAlternatifs | Select-Object -Unique
        $sanLines = ($sans | ForEach-Object { "_continue_ = ""dns=$_&""" }) -join "`r`n"
        $inf = @"
[Version]
Signature="`$Windows NT`$"

[NewRequest]
Subject = "CN=$Nom, O=Helios, C=FR"
KeyAlgorithm = RSA
KeyLength = 2048
HashAlgorithm = SHA256
MachineKeySet = TRUE
Exportable = TRUE
RequestType = PKCS10
KeyUsage = 0xa0
ProviderName = "Microsoft Software Key Storage Provider"

[EnhancedKeyUsageExtension]
OID = 1.3.6.1.5.5.7.3.1

[Extensions]
2.5.29.17 = "{text}"
$sanLines
"@
        $infFile = Join-Path $work 'demande.inf'
        $csrFile = Join-Path $work 'demande.csr'
        $inf | Out-File -FilePath $infFile -Encoding ascii
        certreq -new -q -machine $infFile $csrFile | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "certreq -new a échoué (code $LASTEXITCODE)." }
        $label = $Nom
    } else {
        $csrFile = (Resolve-Path $Csr).Path
        $label = [IO.Path]::GetFileNameWithoutExtension($csrFile)
    }

    # --- 2. Soumettre, approuver, récupérer --------------------------------
    $csrText = Get-Content -Path $csrFile -Raw
    $req   = New-Object -ComObject CertificateAuthority.Request
    $admin = New-Object -ComObject CertificateAuthority.Admin

    $disp = $req.Submit($CR_IN_BASE64HEADER -bor $CR_IN_PKCS10, $csrText, '', $caConfig)
    $id   = $req.GetRequestId()
    Write-Host "==> Demande n° $id soumise à « $caConfig »" -ForegroundColor Cyan

    if ($disp -eq $DISP_UNDER_SUBMIT) {
        Write-Host '    Demande en attente : approbation...'
        $admin.ResubmitRequest($caConfig, $id) | Out-Null
        $disp = $req.RetrievePending($id, $caConfig)
    }
    if ($disp -ne $DISP_ISSUED) {
        throw "Certificat non délivré (disposition $disp) : $($req.GetDispositionMessage())"
    }
    $certPem = $req.GetCertificate($CR_OUT_BASE64HEADER)

    # --- 3. Écrire les fichiers --------------------------------------------
    $dest = Join-Path $Sortie $label
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $crt       = Join-Path $dest "$label.crt"
    $fullchain = Join-Path $dest "$label-fullchain.crt"

    $certPem | Out-File -FilePath $crt -Encoding ascii
    $chain = $certPem.TrimEnd() + "`r`n"
    if (Test-Path $RacinePem) { $chain += (Get-Content $RacinePem -Raw) }
    $chain | Out-File -FilePath $fullchain -Encoding ascii

    $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $crt
    $sanExt = $x509.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }

    # --- 4. Mode PFX : associer la clé et exporter -------------------------
    if ($PSCmdlet.ParameterSetName -eq 'Pfx') {
        certreq -accept -q -machine $crt | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "certreq -accept a échoué (code $LASTEXITCODE)." }

        $installed = Get-Item "Cert:\LocalMachine\My\$($x509.Thumbprint)"
        $pfx = Join-Path $dest "$label.pfx"
        $pfxPassword = Read-Host "Mot de passe du fichier $label.pfx" -AsSecureString
        Export-PfxCertificate -Cert $installed -FilePath $pfx -Password $pfxPassword -ChainOption BuildChain | Out-Null

        # La clé n'a rien à faire dans le magasin de la CA : on la supprime.
        Remove-Item -Path $installed.PSPath -DeleteKey
        Write-Host "    PFX : $pfx" -ForegroundColor Green
    }

    Write-Host ''
    Write-Host "Certificat délivré pour : $($x509.Subject)" -ForegroundColor Green
    if ($sanExt) { Write-Host "    SAN       : $($sanExt.Format($false))" }
    Write-Host "    Valide    : $($x509.NotBefore.ToString('d')) -> $($x509.NotAfter.ToString('d'))"
    Write-Host "    Dossier   : $dest"
    if (-not $sanExt) {
        Write-Warning 'Aucun SAN dans le certificat : les navigateurs le refuseront. Ajouter subjectAltName au CSR.'
    }
}
finally {
    Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
}
