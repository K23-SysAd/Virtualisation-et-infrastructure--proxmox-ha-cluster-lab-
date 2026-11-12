#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prépare le serveur INFRA (Windows Server 2019) : IP statique, nom d'hôte,
    suffixe DNS principal helios.intern.

.DESCRIPTION
    À lancer une seule fois, juste après l'installation de Windows et des
    pilotes VirtIO. Le serveur redémarre à la fin.

.EXAMPLE
    .\00-preparer-serveur.ps1
    .\00-preparer-serveur.ps1 -IPAddress 172.16.1.50 -Gateway 172.16.1.1
#>
param(
    [string]$ComputerName = 'INFRA',
    [string]$DnsSuffix    = 'helios.intern',
    [string]$IPAddress    = '172.16.1.50',
    [int]   $PrefixLength = 24,
    [string]$Gateway      = '172.16.1.1',
    # DNS temporaires : le serveur pointera sur lui-même après 01-installer-dns.ps1
    [string[]]$TempDns    = @('1.1.1.1', '8.8.8.8')
)

$ErrorActionPreference = 'Stop'

Write-Host '==> Carte réseau' -ForegroundColor Cyan
$nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
if (-not $nic) { throw 'Aucune carte réseau active. Les pilotes VirtIO (NetKVM) sont-ils installés ?' }
Write-Host "    Carte utilisée : $($nic.Name) ($($nic.InterfaceDescription))"

Write-Host "==> IP statique $IPAddress/$PrefixLength, passerelle $Gateway" -ForegroundColor Cyan
Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Disabled
Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false
Get-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false
New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $IPAddress `
    -PrefixLength $PrefixLength -DefaultGateway $Gateway | Out-Null
Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $TempDns

Write-Host "==> Suffixe DNS principal : $DnsSuffix" -ForegroundColor Cyan
# Sans domaine AD, le suffixe principal se règle dans le registre (« NV Domain »).
$tcpip = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
Set-ItemProperty -Path $tcpip -Name 'NV Domain' -Value $DnsSuffix
Set-DnsClientGlobalSetting -SuffixSearchList @($DnsSuffix)
Set-DnsClient -InterfaceIndex $nic.ifIndex -ConnectionSpecificSuffix $DnsSuffix

Write-Host '==> Pare-feu : autoriser le ping (ICMPv4)' -ForegroundColor Cyan
Enable-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In' -ErrorAction SilentlyContinue

if ($env:COMPUTERNAME -ne $ComputerName) {
    Write-Host "==> Renommage en $ComputerName puis redémarrage" -ForegroundColor Cyan
    Rename-Computer -NewName $ComputerName -Force
    Restart-Computer -Force
} else {
    Write-Host "Nom d'hôte déjà correct. Redémarrer pour appliquer le suffixe DNS." -ForegroundColor Yellow
}
