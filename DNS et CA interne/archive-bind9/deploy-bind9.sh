#!/usr/bin/env bash
# Déploie BIND9 sur infra.helios.intern (Ubuntu Server 22.04 / 24.04),
# VM Linux qui héberge aussi la CA interne.
# Usage : sudo ./deploy-bind9.sh   (depuis le dossier dns/)
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BIND_DIR=/etc/bind
ZONE_DIR=$BIND_DIR/zones

if [[ $EUID -ne 0 ]]; then
    echo "Ce script doit être lancé avec sudo." >&2
    exit 1
fi

echo "==> Installation de BIND9"
apt-get update -qq
apt-get install -y bind9 bind9-utils bind9-dnsutils

echo "==> Sauvegarde de la configuration existante"
BACKUP="/root/bind-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
tar czf "$BACKUP" -C /etc bind
echo "    Sauvegarde : $BACKUP"

echo "==> Copie des fichiers de configuration"
install -m 644 -o root -g bind "$SRC_DIR/named.conf.options" "$BIND_DIR/named.conf.options"
install -m 644 -o root -g bind "$SRC_DIR/named.conf.local"   "$BIND_DIR/named.conf.local"
install -d -m 755 -o root -g bind "$ZONE_DIR"
install -m 644 -o root -g bind "$SRC_DIR/zones/db.helios.intern" "$ZONE_DIR/db.helios.intern"
install -m 644 -o root -g bind "$SRC_DIR/zones/db.192.168.100"   "$ZONE_DIR/db.192.168.100"

echo "==> Répertoire des journaux"
install -d -m 750 -o bind -g bind /var/log/named

echo "==> Vérification de la syntaxe"
named-checkconf
named-checkzone helios.intern            "$ZONE_DIR/db.helios.intern"
named-checkzone 100.168.192.in-addr.arpa "$ZONE_DIR/db.192.168.100"

echo "==> Redémarrage de BIND9"
systemctl enable named
systemctl restart named
systemctl --no-pager --lines=0 status named

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    echo "==> Ouverture du port 53 (UFW)"
    ufw allow from 192.168.100.0/24 to any port 53 proto udp
    ufw allow from 192.168.100.0/24 to any port 53 proto tcp
fi

echo "==> Tests rapides"
dig +short @127.0.0.1 ns1.helios.intern A
dig +short @127.0.0.1 helios.intern MX
dig +short @127.0.0.1 -x 192.168.100.20
dig +short @127.0.0.1 ubuntu.com A | head -n1

echo "Déploiement terminé."
