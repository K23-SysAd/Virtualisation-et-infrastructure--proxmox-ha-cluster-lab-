# DNS et CA interne — domaine `helios.intern`

Ce dossier regroupe tout ce qui concerne le DNS interne et l'autorité de
certification (CA) interne. Objectif : accéder aux applications internes via des
noms en `*.helios.intern`, avec des certificats TLS reconnus par les postes.

## Architecture

Un seul serveur **Windows Server 2019**, sans Active Directory, sous forme de VM Proxmox :

| VM / hôte                     | IP              | Rôles                                                       |
|-------------------------------|-----------------|-------------------------------------------------------------|
| `INFRA` (`infra.helios.intern`) | 172.16.1.50/24 | DNS Server · AD CS **Standalone Root CA** · IIS (publication CRL/racine) |

- Passerelle : 172.16.1.1. Redirecteurs DNS : 1.1.1.1, 8.8.8.8.
- `ca.helios.intern` est un alias de 172.16.1.50, inscrit dans tous les
  certificats (CDP/AIA) : `http://ca.helios.intern/CertEnroll/`.
- CA « Helios Root CA » : RSA 4096, SHA-256, valable 10 ans. Certificats émis valables 2 ans.

> Remarque : `.intern` n'est pas un suffixe réservé. L'ICANN a réservé
> `.internal` (2024) pour l'usage privé. `helios.intern` fonctionne en interne,
> mais `helios.internal` éliminerait tout risque de collision future.

## Organisation du dossier

```
DNS et CA interne/
├── README.md
├── serveur/
│   └── 00-preparer-serveur.ps1     # IP statique, nom INFRA, suffixe helios.intern
├── dns/
│   ├── 01-installer-dns.ps1        # rôle DNS, zones, redirecteurs, enregistrements
│   └── enregistrements-dns.csv     # liste des enregistrements de la zone
├── ca/
│   ├── 02-installer-ca.ps1         # CA racine autonome + publication HTTP
│   └── 03-emettre-certificat.ps1   # émission d'un certificat (CSR ou PFX)
├── docs/
│   └── procedure-windows-server.md # procédure complète et vérifications
└── archive-bind9/                  # ancienne piste Linux/BIND9 (non utilisée)
```

## Ordre de déploiement

1. Créer la VM et installer Windows Server 2019 ([procédure § 0](docs/procedure-windows-server.md#0-création-de-la-vm-dans-proxmox)).
2. `serveur\00-preparer-serveur.ps1` (redémarrage).
3. `dns\01-installer-dns.ps1`.
4. `ca\02-installer-ca.ps1`.
5. Distribuer `helios-root-ca.crt` sur les postes et serveurs.
6. `ca\03-emettre-certificat.ps1` pour chaque application.
7. Sauvegarder la CA hors de la VM.
