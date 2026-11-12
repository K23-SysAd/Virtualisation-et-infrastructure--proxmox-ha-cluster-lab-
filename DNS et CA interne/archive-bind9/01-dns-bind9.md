# 01 — DNS interne BIND9 sur la VM `infra.helios.intern`

**Objectif :** déployer un serveur DNS qui fait autorité pour `helios.intern` (zone
directe et inverse) et qui résout les noms Internet pour tout le lab. La même VM
Linux hébergera ensuite la CA interne (`step-ca`, étape 02).

| Élément    | Valeur                                  |
|------------|-----------------------------------------|
| VM         | `infra` — Ubuntu Server 22.04 ou 24.04 (DNS + CA) |
| Noms       | `infra`, `ns1` et `ca` → 192.168.100.11  |
| Ressources | 2 vCPU, 2 Go RAM, 20 Go disque          |
| IP         | 192.168.100.11/24, passerelle 192.168.100.2 |
| Fichiers   | [`dns/`](../dns/)                        |

## 1. Créer la VM

Installer Ubuntu Server (OpenSSH coché), nom d'hôte `infra`, utilisateur `admin-lab`.

## 2. IP statique et nom d'hôte

`/etc/netplan/50-cloud-init.yaml` (adapter `ens33` au nom réel vu dans `ip a`) :

```yaml
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: false
      addresses: [192.168.100.11/24]
      routes:
        - to: default
          via: 192.168.100.2
      nameservers:
        search: [helios.intern]
        addresses: [127.0.0.1]
```

```bash
sudo netplan apply
sudo hostnamectl set-hostname infra.helios.intern
```

`/etc/hosts` :

```
127.0.0.1       localhost
192.168.100.11  infra.helios.intern  infra
```

> Ici `systemd-resolved` reste actif : il écoute sur `127.0.0.53`, BIND sur
> `127.0.0.1` et `192.168.100.11`, il n'y a donc pas de conflit sur le port 53.

## 3. Déployer BIND9

Copier le dossier `dns/` sur la VM (par `git clone` ou `scp`), puis :

```bash
cd "DNS et CA interne/dns"
chmod +x deploy-bind9.sh
sudo ./deploy-bind9.sh
```

Le script installe BIND9, sauvegarde `/etc/bind`, copie la configuration, vérifie
la syntaxe (`named-checkconf`, `named-checkzone`), redémarre le service puis
lance des tests.

## 4. Basculer les autres machines sur le nouveau DNS

| Machine            | Méthode                                                   |
|--------------------|-----------------------------------------------------------|
| Ubuntu (netplan)   | `nameservers: { search: [helios.intern], addresses: [192.168.100.11] }` puis `sudo netplan apply` |
| CentOS (nmcli)     | `sudo nmcli con mod ens160 ipv4.dns 192.168.100.11 ipv4.dns-search helios.intern ipv4.ignore-auto-dns yes && sudo nmcli con up ens160` |
| Ubuntu Desktop     | Paramètres › Réseau › IPv4 › DNS `192.168.100.11`          |
| Hôte Windows (optionnel) | DNS de la carte VMnet8 : `192.168.100.11`           |

> **VM1 (Zimbra) :** son dnsmasq sert encore `lab.local`. On le laisse en place
> tant que Zimbra n'a pas été migré vers `helios.intern` ; le jour de la
> bascule, on pointe VM1 vers `192.168.100.11` et on arrête dnsmasq.

## 5. Ajouter un enregistrement

1. Éditer `dns/zones/db.helios.intern` (et `db.192.168.100` pour le PTR).
2. **Incrémenter le serial** (`2026111201` → `2026111202`).
3. Relancer `sudo ./deploy-bind9.sh`, ou bien copier la zone puis lancer `sudo rndc reload`.

## Vérification

Depuis le poste client (VM3) :

```bash
dig ns1.helios.intern +short          # 192.168.100.11
dig odoo.helios.intern +short         # 192.168.100.20
dig erp.helios.intern +short          # odoo.helios.intern. puis 192.168.100.20
dig helios.intern MX +short           # 10 mail.helios.intern.
dig ca.helios.intern +short           # 192.168.100.11
dig -x 192.168.100.11 +short          # infra.helios.intern.
dig ubuntu.com +short                 # une IP publique (récursion OK)
dig @192.168.100.11 helios.intern AXFR   # doit être REFUSÉ (transfert interdit)
```

Sur `infra` :

```bash
sudo named-checkconf && echo OK
sudo rndc status
sudo tail -f /var/log/named/queries.log
```

- ☐ Les enregistrements A, CNAME, MX et PTR répondent.
- ☐ Les noms Internet sont résolus depuis le client.
- ☐ Le transfert de zone (AXFR) est refusé.
- ☐ Les requêtes apparaissent dans `queries.log`.

## Références

- Documentation BIND 9 : https://bind9.readthedocs.io/
- Ubuntu Server — Service DNS : https://documentation.ubuntu.com/server/how-to/networking/install-dns/
