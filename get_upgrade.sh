#!/bin/bash

# Zabbix serveur et hôte
ZABBIX_SERVER="URL_OR_IP_ZABBIX"
ZABBIX_HOST="HOSTNAME_CLIENT"

# Liste des mises à jour en attente (on filtre les lignes après "Listing..." et on récupère les paquets)
upgrades=$(apt list --upgradable 2>/dev/null | grep -v "^Listing" | awk '{print $1}')

# Vérifie si des mises à jour sont disponibles
if [[ -n "$upgrades" ]]; then
    echo "$upgrades"
    zabbix_sender -z "$ZABBIX_SERVER" -s "$ZABBIX_HOST" -k "system.upgrades.list" -o "$upgrades"
else
    echo "Aucune mise à jour en attente"
    zabbix_sender -z "$ZABBIX_SERVER" -s "$ZABBIX_HOST" -k "system.upgrades.list" -o "Aucune mise à jour en attente"
fi
updates_count=$(apt list --upgradable 2>/dev/null | wc -l)

zabbix_sender -z "$ZABBIX_SERVER" -s "$ZABBIX_HOST" -k "system.upgrades.count" -o "$updates_count"
