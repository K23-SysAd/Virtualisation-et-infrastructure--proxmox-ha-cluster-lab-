# Procédure — DNS et CA interne sur Windows Server 2019

**Objectif :** un serveur Windows unique, `INFRA`, qui fait autorité pour la zone
`helios.intern` et héberge une autorité de certification racine autonome
(« Helios Root CA »), sans Active Directory.

| Élément        | Valeur                                              |
|----------------|-----------------------------------------------------|
| VM Proxmox     | `infra-helios` — Windows Server 2019 Standard (Desktop Experience) |
| Nom d'hôte     | `INFRA` → FQDN `infra.helios.intern`                |
| IP             | 172.16.1.50/24, passerelle 172.16.1.1               |
| Alias          | `ca.helios.intern` → 172.16.1.50 (publication de la CRL et de la racine) |
| Rôles          | DNS Server, AD CS (Standalone Root CA), IIS         |

## 0. Création de la VM dans Proxmox

| Onglet | Valeur |
|---|---|
| General | Name `infra-helios`, Start at boot ✅, Start order `1` |
| OS | ISO Windows Server 2019 ; Guest OS `Microsoft Windows 10/2016/2019` ; 2ᵉ lecteur CD : ISO **virtio-win** |
| System | Machine `q35`, BIOS `OVMF (UEFI)` + EFI disk, SCSI `VirtIO SCSI single`, Qemu Agent ✅ |
| Disks | SCSI, 60 Go, Discard ✅, IO thread ✅, SSD emulation ✅ |
| CPU | 2 cœurs, type `host` (`x86-64-v2-AES` dans un cluster) |
| Memory | 4096 Mo, ballooning désactivé |
| Network | `vmbr0`, VirtIO |

Pendant l'installation :
- choisir **Windows Server 2019 Standard (Desktop Experience)** ;
- quand aucun disque n'apparaît : **Load driver** › ISO virtio-win › `vioscsi\2k19\amd64`.

Après l'installation :
1. lancer `virtio-win-guest-tools.exe` depuis l'ISO virtio-win (réseau, QEMU Guest Agent) ;
2. installer toutes les mises à jour Windows Update ;
3. retirer les ISO dans Proxmox, puis faire un **snapshot `os-propre`**.

## 1. Récupérer les scripts sur le serveur

Copier le dossier `DNS et CA interne` sur le serveur, par exemple dans
`C:\Helios\`, puis ouvrir **PowerShell en tant qu'administrateur** :

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
Get-ChildItem C:\Helios -Recurse -Filter *.ps1 | Unblock-File
cd C:\Helios
```

## 2. Préparer le serveur (IP, nom, suffixe DNS)

```powershell
.\serveur\00-preparer-serveur.ps1
```

Le script fixe l'IP 172.16.1.50/24, la passerelle 172.16.1.1 et le suffixe DNS
`helios.intern`, renomme la machine en `INFRA`, puis **redémarre**.
Les valeurs se changent en paramètres : `-IPAddress`, `-Gateway`, `-ComputerName`.

## 3. Installer le DNS

```powershell
.\dns\01-installer-dns.ps1
```

Le script :
- installe le rôle DNS Server, n'écoute que sur 172.16.1.50 ;
- crée la zone `helios.intern` et la zone inverse `1.16.172.in-addr.arpa` (sans mise à jour dynamique ni transfert de zone) ;
- définit les redirecteurs 1.1.1.1 et 8.8.8.8 pour les noms Internet ;
- crée les enregistrements listés dans [`dns/enregistrements-dns.csv`](../dns/enregistrements-dns.csv) ;
- configure le serveur pour qu'il utilise son propre DNS, puis lance des tests.

**Ajouter une application :** ajouter une ligne au CSV, par exemple
`odoo,A,172.16.1.60,oui,`, puis relancer le script. Pour modifier un
enregistrement existant, le supprimer d'abord dans la console DNS
(`dnsmgmt.msc`) : le script ne remplace jamais ce qui existe.

## 4. Installer la CA

```powershell
.\ca\02-installer-ca.ps1
```

Le script :
- écrit `C:\Windows\CAPolicy.inf` (clé de renouvellement 4096 bits, CRL hebdomadaire, pas de delta CRL) ;
- installe AD CS en **Standalone Root CA** : « Helios Root CA », RSA 4096, SHA-256, valable 10 ans ;
- fixe la durée des certificats émis à 2 ans ;
- remplace les points de publication LDAP (inutiles sans AD) par
  `http://ca.helios.intern/CertEnroll/` (CRL et certificat racine), servis par IIS ;
- exporte la racine dans `C:\Helios-PKI\helios-root-ca.crt` (PEM) et `.cer` (DER).

Faire ensuite un **snapshot `ca-installee`** dans Proxmox.

## 5. Distribuer le certificat racine

Copier `C:\Helios-PKI\helios-root-ca.crt` sur chaque machine, ou le télécharger
depuis `http://ca.helios.intern/CertEnroll/`.

| Système | Commande |
|---|---|
| Windows | `Import-Certificate -FilePath .\helios-root-ca.crt -CertStoreLocation Cert:\LocalMachine\Root` |
| Ubuntu / Debian | `sudo cp helios-root-ca.crt /usr/local/share/ca-certificates/` puis `sudo update-ca-certificates` |
| CentOS / RHEL | `sudo cp helios-root-ca.crt /etc/pki/ca-trust/source/anchors/` puis `sudo update-ca-trust` |
| Firefox | Paramètres › Vie privée et sécurité › Certificats › Importer (ou `security.enterprise_roots.enabled = true` sous Windows) |

Les clients doivent aussi utiliser **172.16.1.50 comme DNS**, avec le suffixe de
recherche `helios.intern`.

## 6. Émettre un certificat pour une application

### Méthode recommandée : CSR généré sur le serveur applicatif

Sur le serveur Linux (la clé privée ne quitte jamais ce serveur) :

```bash
openssl req -new -newkey rsa:2048 -nodes \
  -keyout odoo.helios.intern.key -out odoo.helios.intern.csr \
  -subj "/CN=odoo.helios.intern/O=Helios/C=FR" \
  -addext "subjectAltName=DNS:odoo.helios.intern,DNS:erp.helios.intern"
```

Copier le `.csr` sur INFRA, puis :

```powershell
.\ca\03-emettre-certificat.ps1 -Csr C:\Helios-PKI\demandes\odoo.helios.intern.csr
```

Récupérer `odoo.helios.intern-fullchain.crt` dans
`C:\Helios-PKI\certificats\odoo.helios.intern\` et le configurer dans Nginx ou
Apache avec la clé `.key` restée sur le serveur.

### Méthode rapide : clé générée sur INFRA (export PFX)

```powershell
.\ca\03-emettre-certificat.ps1 -Nom odoo.helios.intern -NomsAlternatifs erp.helios.intern
```

Le script demande un mot de passe et produit un `.pfx` (certificat + clé + racine).
Sous Linux, pour l'extraire :

```bash
openssl pkcs12 -in odoo.helios.intern.pfx -nocerts -nodes -out odoo.helios.intern.key
openssl pkcs12 -in odoo.helios.intern.pfx -clcerts -nokeys -out odoo.helios.intern.crt
```

> Avec une CA autonome, chaque demande arrive « en attente ». Le script
> l'approuve automatiquement. Dans la console (`certsrv.msc`), on retrouve
> l'historique dans *Issued Certificates*.

### Révoquer un certificat

```powershell
certutil -revoke <NuméroDeSérie> 4    # 4 = Superseded ; 1 = Key Compromise
certutil -crl                          # publie immédiatement la nouvelle CRL
```

## 7. Sauvegarde de la CA (indispensable)

Perdre la clé de la CA, c'est devoir réémettre et redistribuer tous les
certificats. Sauvegarder après l'installation, puis régulièrement :

```powershell
$pw = Read-Host 'Mot de passe de la sauvegarde' -AsSecureString
Backup-CARoleService -Path C:\Helios-PKI\sauvegarde -Password $pw
reg export HKLM\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration C:\Helios-PKI\sauvegarde\ca-config.reg
```

Copier `C:\Helios-PKI\sauvegarde` **hors de la VM**, et inclure la VM dans un job de
sauvegarde Proxmox (Datacenter › Backup).

> **Renouvellement de la CRL :** elle est valable une semaine et la CA la
> republie automatiquement tant que le service tourne. Si le serveur reste
> éteint plus d'une semaine, lancer `certutil -crl` au redémarrage.

## Vérification

Depuis un poste client qui utilise 172.16.1.50 comme DNS :

```powershell
Resolve-DnsName infra.helios.intern          # 172.16.1.50
Resolve-DnsName ca.helios.intern             # 172.16.1.50
Resolve-DnsName 172.16.1.50                  # infra.helios.intern
Resolve-DnsName microsoft.com                # IP publique (redirecteurs OK)
Invoke-WebRequest http://ca.helios.intern/CertEnroll/ -UseBasicParsing   # 200
```

Sous Linux :

```bash
dig +short infra.helios.intern
openssl s_client -connect odoo.helios.intern:443 -servername odoo.helios.intern </dev/null | grep "Verify return code"
# attendu : Verify return code: 0 (ok)
```

Sur INFRA :

```powershell
certutil -cainfo                  # état de la CA
# Vérifie la chaîne et télécharge réellement la CRL et la racine via HTTP :
certutil -verify -urlfetch C:\Helios-PKI\certificats\odoo.helios.intern\odoo.helios.intern.crt
```

- ☐ Les zones directe et inverse répondent ; les noms Internet sont résolus.
- ☐ La CA « Helios Root CA » est démarrée (`certsrv.msc`).
- ☐ La CRL et la racine sont téléchargeables en HTTP.
- ☐ La racine est installée sur les clients.
- ☐ Un site interne en HTTPS s'ouvre **sans alerte** dans le navigateur.
- ☐ La sauvegarde de la CA est copiée hors de la VM.
