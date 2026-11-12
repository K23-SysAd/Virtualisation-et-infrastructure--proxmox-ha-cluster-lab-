#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installe le rôle DNS sur INFRA et crée les zones helios.intern
    (directe) et 1.16.172.in-addr.arpa (inverse).

.DESCRIPTION
    Script idempotent : il peut être relancé sans risque, par exemple
    après l'ajout d'une ligne dans enregistrements-dns.csv. Les
    enregistrements déjà présents ne sont pas modifiés.

.EXAMPLE
    .\01-installer-dns.ps1
#>
param(
    [string]  $Zone        = 'helios.intern',
    [string]  $ServerIP    = '172.16.1.50',
    [string]  $NetworkId   = '172.16.1.0/24',
    [string[]]$Forwarders  = @('1.1.1.1', '8.8.8.8'),
    [string]  $RecordsFile = (Join-Path $PSScriptRoot 'enregistrements-dns.csv')
)

$ErrorActionPreference = 'Stop'

# --- 1. Rôle DNS -----------------------------------------------------------
Write-Host '==> Rôle DNS Server' -ForegroundColor Cyan
Install-WindowsFeature -Name DNS -IncludeManagementTools | Out-Null
Import-Module DnsServer

# --- 2. Paramètres du serveur ----------------------------------------------
Write-Host "==> Écoute uniquement sur $ServerIP" -ForegroundColor Cyan
$settings = Get-DnsServerSetting -All
$settings.ListeningIPAddress = @($ServerIP)
Set-DnsServerSetting -InputObject $settings

Write-Host "==> Redirecteurs : $($Forwarders -join ', ')" -ForegroundColor Cyan
Set-DnsServerForwarder -IPAddress $Forwarders -UseRootHint $true

# --- 3. Zones --------------------------------------------------------------
if (-not (Get-DnsServerZone -Name $Zone -ErrorAction SilentlyContinue)) {
    Write-Host "==> Création de la zone $Zone" -ForegroundColor Cyan
    Add-DnsServerPrimaryZone -Name $Zone -ZoneFile "$Zone.dns" -DynamicUpdate None
}

# Nom de la zone inverse pour un réseau /24 : 172.16.1.0/24 -> 1.16.172.in-addr.arpa
$octets      = ($NetworkId -split '/')[0] -split '\.'
$reverseZone = '{0}.{1}.{2}.in-addr.arpa' -f $octets[2], $octets[1], $octets[0]
if (-not (Get-DnsServerZone -Name $reverseZone -ErrorAction SilentlyContinue)) {
    Write-Host "==> Création de la zone inverse $reverseZone" -ForegroundColor Cyan
    Add-DnsServerPrimaryZone -NetworkId $NetworkId -ZoneFile "$reverseZone.dns" -DynamicUpdate None
}

# Aucun transfert de zone (pas de serveur secondaire)
foreach ($z in @($Zone, $reverseZone)) {
    Set-DnsServerPrimaryZone -Name $z -SecureSecondaries NoTransfer -Notify NoNotify
}

# --- 4. Enregistrements ----------------------------------------------------
Write-Host "==> Enregistrements depuis $(Split-Path $RecordsFile -Leaf)" -ForegroundColor Cyan
$records = Get-Content -Path $RecordsFile -Encoding UTF8 |
    Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } |
    ConvertFrom-Csv

function ConvertTo-Fqdn([string]$Name) {
    if ($Name.Contains('.')) { return $Name.TrimEnd('.') + '.' }
    return "$Name.$Zone."
}

foreach ($r in $records) {
    $name = $r.Nom.Trim()
    $type = $r.Type.Trim().ToUpper()

    $existing = Get-DnsServerResourceRecord -ZoneName $Zone -Name $name -RRType $type -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "    = $name $type existe déjà"
        continue
    }

    if ($type -notin @('A', 'CNAME', 'MX')) {
        Write-Warning "Type non géré : $type ($name)"
        continue
    }

    # Windows DNS désigne la racine de la zone par « . » à la création
    $addName = if ($name -eq '@') { '.' } else { $name }

    switch ($type) {
        'A' {
            $ptr = ($r.PTR -eq 'oui')
            Add-DnsServerResourceRecordA -ZoneName $Zone -Name $addName `
                -IPv4Address $r.Valeur.Trim() -CreatePtr:$ptr
        }
        'CNAME' {
            Add-DnsServerResourceRecordCName -ZoneName $Zone -Name $addName `
                -HostNameAlias (ConvertTo-Fqdn $r.Valeur.Trim())
        }
        'MX' {
            Add-DnsServerResourceRecordMX -ZoneName $Zone -Name $addName `
                -MailExchange (ConvertTo-Fqdn $r.Valeur.Trim()) -Preference ([int]$r.Priorite)
        }
    }
    Write-Host "    + $name $type $($r.Valeur)" -ForegroundColor Green
}

# --- 5. Le serveur utilise son propre DNS ----------------------------------
Write-Host "==> Le serveur utilise désormais $ServerIP comme DNS" -ForegroundColor Cyan
$nic = Get-NetIPAddress -IPAddress $ServerIP -ErrorAction SilentlyContinue
if ($nic) {
    Set-DnsClientServerAddress -InterfaceIndex $nic.InterfaceIndex -ServerAddresses $ServerIP
} else {
    Write-Warning "L'IP $ServerIP n'est pas configurée sur ce serveur : DNS client non modifié."
}
Clear-DnsClientCache

# --- 6. Tests --------------------------------------------------------------
Write-Host '==> Tests' -ForegroundColor Cyan
$tests = @(
    @{ Name = "infra.$Zone"; Type = 'A' },
    @{ Name = "ca.$Zone";    Type = 'A' },
    @{ Name = $ServerIP;     Type = 'PTR' },
    @{ Name = 'microsoft.com'; Type = 'A' }
)
foreach ($t in $tests) {
    try {
        $res = Resolve-DnsName -Name $t.Name -Type $t.Type -Server $ServerIP -DnsOnly -ErrorAction Stop |
            Where-Object { $_.Type -eq $t.Type } | Select-Object -First 1
        $val = if ($res.IPAddress) { $res.IPAddress } else { $res.NameHost }
        Write-Host ("    OK   {0,-22} {1,-4} -> {2}" -f $t.Name, $t.Type, $val) -ForegroundColor Green
    } catch {
        Write-Host ("    ÉCHEC {0,-21} {1,-4}" -f $t.Name, $t.Type) -ForegroundColor Red
    }
}
Write-Host 'DNS prêt.' -ForegroundColor Green
