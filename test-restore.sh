#!/bin/bash

set -u
set -o pipefail

# ============================================================
# TEST AUTOMATISE DES RESTAURATIONS PBS
# ============================================================

# ============================================================
# Configuration
# ============================================================

PBS_STORAGE="<NOM_STORAGE_SOURCE>"
TARGET_STORAGE="<NOM_STORAGE_DESTINATION"

# VM utilisée comme VM temporaire de restauration
TEST_VMID="<VMID>"

# Configuration réseau de test
TEST_MAC="<MAC_VM>" # Adresse mac à renseigner sous le format 1A:2B:3C:4D:5E:6F
TEST_VLAN="<VLAN_ID>"
TEST_IP="<IP_VM>"
TEST_GATEWAY="<GATEWAY>"
TEST_DNS="<IP_DNS>"
TEST_SEARCHDOMAIN="<DOMAINE>"

# Nom donné à la VM restaurée
TEST_VM_NAME="VM-BACKUP-TEST-01"

# Logs
LOG_FILE="/var/log/pbs-restore-test.log"
LOCK_FILE="/run/lock/pbs-restore-test.lock"

# ------------------------------------------------------------
# Mode d'exécution
# ------------------------------------------------------------
# 1 = dry-run : aucune restauration
# 0 = exécution réelle

DRY_RUN=0

# ------------------------------------------------------------
# VMID à exclure
# ------------------------------------------------------------

EXCLUDE_VMIDS=(
#liste d'exclusion, une ligne par VM
)

# ------------------------------------------------------------
# Gotify
# ------------------------------------------------------------

GOTIFY_URL="<URL_GOTIFY>"
GOTIFY_TOKEN="<TOKEN_GOTIFY"

# ============================================================
# Variables internes
# ============================================================

FAILED_VMIDS=()
TESTED_VMIDS=()

CURRENT_SOURCE_VMID=""
CURRENT_BACKUP=""

# ============================================================
# Logging
# ============================================================

log()
{
    local msg="$1"

    printf '[%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$msg" |
        tee -a "$LOG_FILE"
}

# ============================================================
# Vérification exclusion
# ============================================================

is_excluded()
{
    local vmid="$1"
    local excluded

    for excluded in "${EXCLUDE_VMIDS[@]}"; do
        if [[ "$vmid" == "$excluded" ]]; then
            return 0
        fi
    done

    return 1
}

# ============================================================
# Notification Gotify
# ============================================================

send_gotify()
{
    local message="$1"

    if [[ -z "$GOTIFY_TOKEN" || "$GOTIFY_TOKEN" == "<token>" ]]; then
        log "Gotify non configuré : notification ignorée"
        return 0
    fi

    if ! curl -fsS \
        --max-time 15 \
        -X POST \
        "${GOTIFY_URL}/message?token=${GOTIFY_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg message "$message" \
            '{message:$message}')" \
        >/dev/null 2>&1; then

        log "ERREUR : impossible d'envoyer la notification Gotify"
        return 1
    fi

    log "Notification Gotify envoyée"
    return 0
}

# ============================================================
# Vérification existence VM
# ============================================================

vm_exists()
{
    qm status "$TEST_VMID" >/dev/null 2>&1
}

# ============================================================
# Nettoyage VM de test
# ============================================================

cleanup_vm()
{
    if ! vm_exists; then
        return 0
    fi

    log "Nettoyage de la VM de test ${TEST_VMID}..."

    local status

    # qm status est volontairement utilisé en format texte :
    # le format JSON n'est pas fiable/disponible selon la version de qm.
    status="$(qm status "$TEST_VMID" 2>&1 | awk '{print $2}')"

    if [[ -z "$status" ]]; then
        log "ATTENTION : impossible de déterminer l'état de ${TEST_VMID}"
        log "Tentative d'arrêt forcé par sécurité..."
        qm stop "$TEST_VMID" --skiplock 1 --timeout 30 >>"$LOG_FILE" 2>&1 || true
        sleep 2
    elif [[ "$status" == "running" ]]; then
        log "Arrêt forcé de la VM ${TEST_VMID}..."

        if qm stop "$TEST_VMID" --skiplock 1 --timeout 30 >>"$LOG_FILE" 2>&1; then
            log "VM ${TEST_VMID} arrêtée"
        else
            log "ATTENTION : qm stop a échoué pour ${TEST_VMID}"
        fi

        sleep 2
    else
        log "VM ${TEST_VMID} déjà arrêtée"
    fi

    # Supprime un éventuel verrou Proxmox avant destruction.
    qm unlock "$TEST_VMID" >/dev/null 2>&1 || true

    log "Suppression de la VM ${TEST_VMID}..."

    local destroy_output

    if destroy_output="$(qm destroy "$TEST_VMID" \
        --purge 1 \
        --destroy-unreferenced-disks 1 2>&1)"; then

        log "VM ${TEST_VMID} supprimée"
        return 0
    fi

    log "Première tentative de suppression échouée :"
    log "$destroy_output"

    log "Nouvelle tentative après déverrouillage..."
    qm unlock "$TEST_VMID" >/dev/null 2>&1 || true

    if destroy_output="$(qm destroy "$TEST_VMID" \
        --purge 1 \
        --destroy-unreferenced-disks 1 2>&1)"; then

        log "VM ${TEST_VMID} supprimée"
        return 0
    fi

    log "ERREUR : impossible de supprimer ${TEST_VMID}"
    log "$destroy_output"
    return 1
}

# ============================================================
# Nettoyage de sécurité à la sortie
# ============================================================

cleanup_on_exit()
{
    if [[ "$DRY_RUN" == "0" ]]; then
        if vm_exists; then
            log "Nettoyage de sécurité à la sortie du script..."
            cleanup_vm
        fi
    fi
}

trap cleanup_on_exit EXIT

# ============================================================
# Attente QEMU Guest Agent
# ============================================================

wait_for_qga()
{
    local timeout=120
    local elapsed=0

    log "Attente du QEMU Guest Agent (${timeout}s max)..."

    while (( elapsed < timeout )); do

        if qm guest cmd "$TEST_VMID" ping >/dev/null 2>&1; then
            log "QEMU Guest Agent : OK"
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    log "ERREUR : QEMU Guest Agent indisponible après ${timeout}s"

    return 1
}

# ============================================================
# Exécution d'une commande dans la VM
#
# Retourne :
#   0 = commande guest réussie
#   1 = commande guest échouée
#
# La sortie stdout du guest est renvoyée sur stdout.
# ============================================================

run_guest()
{
    local result
    local exitcode

    result="$(
        qm guest exec "$TEST_VMID" -- "$@" 2>/dev/null
    )" || {
        return 1
    }

    exitcode="$(
        printf '%s\n' "$result" |
        jq -r '.exitcode // 1'
    )"

    printf '%s\n' "$result" |
        jq -r '."out-data" // ""'

    [[ "$exitcode" == "0" ]]
}

# ============================================================
# Test d'une VM
# ============================================================

test_vm()
{
    local vmid="$1"
    local backup="$2"

    CURRENT_SOURCE_VMID="$vmid"
    CURRENT_BACKUP="$backup"

    log "============================================================"
    log "TEST VM ${vmid}"
    log "Backup : ${backup}"
    log "============================================================"

    # --------------------------------------------------------
    # Restauration
    # --------------------------------------------------------

    log "Restauration de VM ${vmid} vers VMID ${TEST_VMID}..."

    if ! qmrestore \
        "$backup" \
        "$TEST_VMID" \
        --storage "$TARGET_STORAGE" \
        --unique 1 \
        >>"$LOG_FILE" 2>&1; then

        log "ERREUR : restauration de VM ${vmid} échouée"

        return 1
    fi

    log "Restauration : OK"

    # --------------------------------------------------------
    # Configuration de la VM de test
    # --------------------------------------------------------

    log "Application de la configuration de test..."

    if ! qm set "$TEST_VMID" \
        --name "$TEST_VM_NAME" \
        --agent 1 \
        --net0 "virtio=${TEST_MAC},bridge=vmbr0,tag=${TEST_VLAN}" \
        --ipconfig0 "ip=${TEST_IP},gw=${TEST_GATEWAY}" \
        --nameserver "$TEST_DNS" \
        --searchdomain "$TEST_SEARCHDOMAIN" \
        --onboot 0 \
        >>"$LOG_FILE" 2>&1; then

        log "ERREUR : impossible de configurer la VM"

        return 1
    fi

    log "Configuration de test : OK"

    # --------------------------------------------------------
    # Démarrage
    # --------------------------------------------------------

    log "Démarrage de la VM ${TEST_VMID}..."

    if ! qm start "$TEST_VMID" >>"$LOG_FILE" 2>&1; then
        log "ERREUR : impossible de démarrer la VM"

        return 1
    fi

    log "VM démarrée"

    # --------------------------------------------------------
    # QEMU Guest Agent
    # --------------------------------------------------------

    if ! wait_for_qga; then
        return 1
    fi

    # --------------------------------------------------------
    # Adresse IP
    # --------------------------------------------------------

    log "Vérification de l'adresse IP..."

    local addresses

    addresses="$(
        run_guest ip -br addr
    )" || {
        log "ERREUR : impossible de récupérer les interfaces réseau"
        return 1
    }

    log "Interfaces détectées :"
    log "$addresses"

    if ! echo "$addresses" |
        grep -q "172.16.11.20/24"; then

        log "ERREUR : adresse ${TEST_IP} absente"

        return 1
    fi

    log "Adresse IP : OK"

    # --------------------------------------------------------
    # Route par défaut
    # --------------------------------------------------------

    log "Vérification de la route par défaut..."

    if ! run_guest sh -c \
        "ip route | grep -q '^default via ${TEST_GATEWAY} '"; then

        log "ERREUR : route par défaut absente"

        return 1
    fi

    log "Route par défaut : OK"

    # --------------------------------------------------------
    # Gateway
    # --------------------------------------------------------

    log "Test de la gateway ${TEST_GATEWAY}..."

    local ping_result

    ping_result="$(
        run_guest ping -c 3 -W 2 "$TEST_GATEWAY"
    )" || {
        log "ERREUR : ping de la gateway impossible"
        return 1
    }

    log "$ping_result"

    log "Gateway : OK"

    # --------------------------------------------------------
    # DNS
    # --------------------------------------------------------

    log "Test DNS..."

    local dns_result

    dns_result="$(
        run_guest getent hosts google.com
    )" || {
        log "ERREUR : résolution DNS impossible"
        return 1
    }

    log "Résolution DNS : $dns_result"
    log "DNS : OK"

    # --------------------------------------------------------
    # Services systemd en échec
    # --------------------------------------------------------

    log "Vérification des services systemd en échec..."

    local failed_services

    failed_services="$(
        run_guest systemctl --failed --no-legend --no-pager 2>/dev/null
    )" || {
        log "ERREUR : impossible d'interroger systemd"
        return 1
    }

    if [[ -n "$(printf '%s' "$failed_services" | tr -d '[:space:]')" ]]; then
        log "ERREUR : au moins une unité systemd est en échec"
        log "$failed_services"
        return 1
    fi

    log "Services systemd : aucun échec"

    # --------------------------------------------------------
    # Succès
    # --------------------------------------------------------

    log "VM ${vmid} : TEST OK"

    return 0
}

# ============================================================
# Récupération du dernier backup d'une VM
# ============================================================

get_latest_backup()
{
    local vmid="$1"

    pvesm list "$PBS_STORAGE" 2>/dev/null |
        awk -v vmid="$vmid" '
            $2 == "pbs-vm" &&
            $3 == "backup" &&
            $5 == vmid {
                print $1
            }
        ' |
        sort -t/ -k4,4 |
        tail -n 1
}

# ============================================================
# Initialisation
# ============================================================

mkdir -p "$(dirname "$LOG_FILE")"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    log "Une autre instance du script est déjà en cours."
    exit 1
fi

log ""
log "############################################################"
log "# TEST AUTOMATISE DES RESTAURATIONS PBS"
log "############################################################"
log "PBS       : ${PBS_STORAGE}"
log "Stockage  : ${TARGET_STORAGE}"
log "VM test   : ${TEST_VMID}"
log "Dry-run   : ${DRY_RUN}"
log "############################################################"

# ============================================================
# Vérification des dépendances
# ============================================================

for command in qm qmrestore pvesm jq curl flock; do

    if ! command -v "$command" >/dev/null 2>&1; then
        log "ERREUR : commande requise absente : ${command}"
        exit 1
    fi

done

# ============================================================
# Vérification PBS
# ============================================================

if ! pvesm status 2>/dev/null |
    awk -v storage="$PBS_STORAGE" '
        $1 == storage &&
        $2 == "pbs" &&
        $3 == "active" {
            found=1
        }

        END {
            exit !found
        }
    '; then

    log "ERREUR : datastore ${PBS_STORAGE} indisponible"
    exit 1
fi

log "Datastore ${PBS_STORAGE} : OK"

# ============================================================
# Vérification stockage cible
# ============================================================

if ! pvesm status 2>/dev/null |
    awk -v storage="$TARGET_STORAGE" '
        $1 == storage &&
        $3 == "active" {
            found=1
        }

        END {
            exit !found
        }
    '; then

    log "ERREUR : stockage ${TARGET_STORAGE} indisponible"
    exit 1
fi

log "Stockage ${TARGET_STORAGE} : OK"

# ============================================================
# Récupération des VM ayant un backup
# ============================================================

mapfile -t VMIDS < <(
    pvesm list "$PBS_STORAGE" 2>/dev/null |
    awk '
        $2 == "pbs-vm" &&
        $3 == "backup" {
            print $5
        }
    ' |
    sort -n -u
)

if [[ "${#VMIDS[@]}" -eq 0 ]]; then
    log "ERREUR : aucune VM trouvée dans ${PBS_STORAGE}"
    exit 1
fi

log "VM trouvées dans PBS : ${#VMIDS[@]}"

# ============================================================
# DRY-RUN
# ============================================================

if [[ "$DRY_RUN" == "1" ]]; then

    log "MODE DRY-RUN : aucune restauration ne sera effectuée."

    for vmid in "${VMIDS[@]}"; do

        if is_excluded "$vmid"; then
            log "VM ${vmid} : EXCLUE"
            continue
        fi

        backup="$(get_latest_backup "$vmid")"

        if [[ -z "$backup" ]]; then
            log "VM ${vmid} : aucun backup trouvé"
            continue
        fi

        log "VM ${vmid} : TEST → ${backup}"
    done

    log "Dry-run terminé."

    exit 0
fi

# ============================================================
# Sécurité : VM de test déjà présente
# ============================================================

if vm_exists; then

    log "ERREUR : la VM ${TEST_VMID} existe déjà."

    log "Pour éviter toute destruction accidentelle,"
    log "le script ne supprimera pas automatiquement une VM"
    log "existante au démarrage."

    log "Supprime-la manuellement si elle correspond bien"
    log "à la VM de test :"

    log "    qm stop ${TEST_VMID}"
    log "    qm destroy ${TEST_VMID} --purge 1"

    exit 1
fi

# ============================================================
# Tests
# ============================================================

for vmid in "${VMIDS[@]}"; do

    if is_excluded "$vmid"; then
        log "VM ${vmid} : EXCLUE"
        continue
    fi

    backup="$(get_latest_backup "$vmid")"

    if [[ -z "$backup" ]]; then

        log "VM ${vmid} : aucun backup trouvé → ECHEC"

        FAILED_VMIDS+=("$vmid")

        continue
    fi

    TESTED_VMIDS+=("$vmid")

    if test_vm "$vmid" "$backup"; then

        :

    else

        log "VM ${vmid} : TEST EN ECHEC"

        FAILED_VMIDS+=("$vmid")
    fi

    # Toujours supprimer la VM avant de passer à la suivante.
    # Si le nettoyage échoue, on arrête immédiatement afin de ne pas
    # risquer de restaurer la VM suivante par-dessus un VMID encore présent.
    if ! cleanup_vm; then
        log "ERREUR : nettoyage de la VM de test impossible."
        log "Arrêt du script pour éviter une restauration sur ${TEST_VMID} existante."

        FAILED_LIST="$(IFS=', '; echo "${FAILED_VMIDS[*]}")"
        if [[ -z "$FAILED_LIST" ]]; then
            FAILED_LIST="$vmid"
        fi

        send_gotify             "⛔ Test des saves — Erreur sur ${FAILED_LIST}"

        exit 1
    fi

    log ""
done

# ============================================================
# Résumé
# ============================================================

log "############################################################"
log "# FIN DES TESTS"
log "############################################################"

log "VM testées : ${#TESTED_VMIDS[@]}"
log "VM en erreur : ${#FAILED_VMIDS[@]}"

# ============================================================
# Résultat OK
# ============================================================

if [[ "${#FAILED_VMIDS[@]}" -eq 0 ]]; then

    log "RESULTAT GLOBAL : RAS"

    send_gotify \
        "##### ✅ Test des saves — RAS"

    exit 0
fi

# ============================================================
# Résultat KO
# ============================================================

FAILED_LIST="$(IFS=', '; echo "${FAILED_VMIDS[*]}")"

log "VM en erreur : ${FAILED_LIST}"

send_gotify \
    "⛔ Test des saves — Erreur sur ${FAILED_LIST}"

exit 1
