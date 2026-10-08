#!/bin/bash

# Configuration Zabbix
ZABBIX_SERVER="<URL_OR_IP_ZABBIX"
ZABBIX_HOST="<HOSTNAME_CLIENT>"

# --- Températures CPU par core ---
CORES=("Core 0" "Core 1" "Core 2" "Core 3")

index=1
for CORE in "${CORES[@]}"; do
    temp=$(sensors | grep -E "$CORE" | awk '{print $3}' | tr -d '+°C')
    if [[ "$temp" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "Température ${CORE}: $temp°C"
        zabbix_sender -z "$ZABBIX_SERVER" -s "$ZABBIX_HOST" -k "cpu.temperature.package$index" -o "$temp"
    else
        echo "Erreur : température invalide ou non trouvée pour $CORE -> \"$temp\""
        exit 1
    fi
    ((index++))
done

# --- Vitesse du ventilateur fan1 ---
fan1_speed=$(sensors | grep -i "^fan1:" | awk '{print $2}')
if [[ "$fan1_speed" =~ ^[0-9]+$ ]]; then
    echo "Vitesse fan1 : $fan1_speed RPM"
    zabbix_sender -z "$ZABBIX_SERVER" -s "$ZABBIX_HOST" -k "fan.speed.fan1" -o "$fan1_speed"
else
    echo "Erreur : vitesse du ventilateur fan1 invalide -> \"$fan1_speed\""
    exit 1
fi

# --- Température de la carte mère ---
board_temp=$(sensors | grep -i "Board Temp" | awk '{print $3}' | tr -d '+°C')
if [[ "$board_temp" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Température carte mère : $board_temp°C"
    zabbix_sender -z "$ZABBIX_SERVER" -s "$ZABBIX_HOST" -k "board.temperature" -o "$board_temp"
else
    echo "Erreur : température carte mère invalide -> \"$board_temp\""
    exit 1
fi
