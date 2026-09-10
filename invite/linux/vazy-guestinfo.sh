#!/bin/sh
# vazy-guestinfo : applique au démarrage la configuration déposée par vazy dans
# la variable guestinfo.vazy_config (JSON encodé en base64), lue avec les outils
# invité. vazy n'entre jamais dans la VM : il dépose de l'extérieur, avant le
# démarrage, et ce script lit.
#
# Clés appliquées : hostname, ip, masque (longueur de préfixe), passerelle, dns
# (séparés par des virgules), cle_ssh. Plus « mode: pool », qui met le script en
# attente au lieu de fixer l'identité (voir README, réserve de VM chaudes).
# Toute clé inconnue est ignorée, pour rester compatible avec les versions
# futures.
# Idempotent : ne fait rien si tout est déjà en place. Variable absente ou
# vide : ne fait rien. Lancé par l'unité systemd vazy-guestinfo.service, avant
# le réseau, en root.
set -u
ETAT=/var/lib/vazy
FICHIER_UUID=$ETAT/identite.uuid

lire_variable() {
    if command -v vmtoolsd >/dev/null 2>&1; then
        vmtoolsd --cmd "info-get guestinfo.vazy_config" 2>/dev/null && return 0
    fi
    if command -v vmware-rpctool >/dev/null 2>&1; then
        vmware-rpctool "info-get guestinfo.vazy_config" 2>/dev/null && return 0
    fi
    return 1
}

# Repose une variable que l'hôte pourra lire (vmrun readVariable ... guestVar).
# Sert à la poignée de main du pool : « je suis prêt à être figé ».
poser_variable() {
    _cle=$1; _valeur=$2
    if command -v vmtoolsd >/dev/null 2>&1; then
        vmtoolsd --cmd "info-set guestinfo.$_cle $_valeur" >/dev/null 2>&1 && return 0
    fi
    if command -v vmware-rpctool >/dev/null 2>&1; then
        vmware-rpctool "info-set guestinfo.$_cle $_valeur" >/dev/null 2>&1 && return 0
    fi
    return 1
}

# Valeur simple d'une clé du JSON, sans jq ni python.
valeur_json() {
    printf '%s' "$2" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

# --- 1. Identité de la machine ------------------------------------------------
# L'UUID du BIOS change à chaque clone. Si les clés d'identité du serveur SSH
# ont été générées sur une autre machine (le modèle), on les régénère : sinon
# tous les clones partagent la même empreinte et le client SSH crie à
# l'attaque. Même traitement pour /etc/machine-id (sinon deux clones se
# présentent au DHCP avec le même identifiant et reçoivent la même adresse).
UUID=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || true)
if [ -n "$UUID" ]; then
    mkdir -p "$ETAT"
    if [ ! -f "$FICHIER_UUID" ] || [ "$(cat "$FICHIER_UUID")" != "$UUID" ]; then
        rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
        if command -v ssh-keygen >/dev/null 2>&1; then ssh-keygen -A >/dev/null 2>&1 || true; fi
        if [ -f /etc/machine-id ]; then
            : > /etc/machine-id
            if command -v systemd-machine-id-setup >/dev/null 2>&1; then systemd-machine-id-setup >/dev/null 2>&1 || true; fi
            if [ ! -L /var/lib/dbus/machine-id ]; then
                rm -f /var/lib/dbus/machine-id
                ln -s /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
            fi
        fi
        printf '%s\n' "$UUID" > "$FICHIER_UUID"
    fi
fi

# --- 2. Application du nom d'hôte ---------------------------------------------
appliquer_nom_hote() {
    _nom=$1
    case "$_nom" in
        ""|*[!A-Za-z0-9-]*|-*|*-) return 0 ;;   # lettres, chiffres, tirets, ni au début ni à la fin
    esac
    [ ${#_nom} -le 63 ] || return 0
    _actuel=$(cat /etc/hostname 2>/dev/null || hostname)
    if [ "$_actuel" = "$_nom" ] && [ "$(hostname)" = "$_nom" ]; then return 0 ; fi
    # hostnamectl a besoin de D-Bus, souvent absent si tôt dans le démarrage :
    # à défaut on écrit directement, ce qui revient au même.
    if command -v hostnamectl >/dev/null 2>&1 && hostnamectl set-hostname "$_nom" 2>/dev/null; then
        :
    else
        printf '%s\n' "$_nom" > /etc/hostname
        hostname "$_nom" 2>/dev/null || true
    fi
    if grep -q '^127\.0\.1\.1' /etc/hosts 2>/dev/null; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$_nom/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$_nom" >> /etc/hosts
    fi
    return 0
}

# Première interface réseau réelle (pas la boucle locale).
interface_principale() {
    for _i in /sys/class/net/*; do
        _n=$(basename "$_i")
        [ "$_n" = "lo" ] && continue
        case "$_n" in vir*|docker*|br-*|veth*) continue ;; esac
        printf '%s' "$_n"
        return 0
    done
    return 1
}

# --- Adressage statique --------------------------------------------------------
# Écrit une configuration réseau et l'applique. Idempotent : si le fichier est
# déjà exactement celui-là, on ne touche à rien et on ne redémarre rien.
# Deux gestionnaires couverts : netplan (Ubuntu récent) et systemd-networkd.
appliquer_reseau() {
    _ip=$1; _masque=$2; _passerelle=$3; _dns=$4
    [ -n "$_ip" ] || return 0
    [ -n "$_masque" ] || return 0
    _if=$(interface_principale) || return 0

    _dns_liste=""
    if [ -n "$_dns" ]; then
        _dns_liste=$(printf '%s' "$_dns" | tr ',' ' ')
    fi

    if [ -d /etc/netplan ] && command -v netplan >/dev/null 2>&1; then
        _cible=/etc/netplan/99-vazy.yaml
        {
            printf 'network:\n  version: 2\n  ethernets:\n    %s:\n' "$_if"
            printf '      dhcp4: false\n'
            printf '      addresses: [%s/%s]\n' "$_ip" "$_masque"
            if [ -n "$_passerelle" ]; then
                printf '      routes:\n        - to: default\n          via: %s\n' "$_passerelle"
            fi
            if [ -n "$_dns_liste" ]; then
                printf '      nameservers:\n        addresses: ['
                _premier=1
                for _s in $_dns_liste; do
                    [ $_premier -eq 1 ] || printf ', '
                    printf '%s' "$_s"
                    _premier=0
                done
                printf ']\n'
            fi
        } > "$_cible.tmp"
        if [ -f "$_cible" ] && cmp -s "$_cible" "$_cible.tmp"; then
            rm -f "$_cible.tmp"
            return 0
        fi
        mv "$_cible.tmp" "$_cible"
        chmod 600 "$_cible" 2>/dev/null || true
        netplan apply >/dev/null 2>&1 || true
        return 0
    fi

    if [ -d /etc/systemd/network ]; then
        _cible=/etc/systemd/network/99-vazy.network
        {
            printf '[Match]\nName=%s\n\n[Network]\n' "$_if"
            printf 'Address=%s/%s\n' "$_ip" "$_masque"
            [ -n "$_passerelle" ] && printf 'Gateway=%s\n' "$_passerelle"
            for _s in $_dns_liste; do printf 'DNS=%s\n' "$_s"; done
        } > "$_cible.tmp"
        if [ -f "$_cible" ] && cmp -s "$_cible" "$_cible.tmp"; then
            rm -f "$_cible.tmp"
            return 0
        fi
        mv "$_cible.tmp" "$_cible"
        if command -v networkctl >/dev/null 2>&1; then networkctl reload >/dev/null 2>&1 || true; fi
        return 0
    fi
    return 0
}

# --- Clé SSH de l'utilisateur ---------------------------------------------------
# Déposée pour le premier compte humain trouvé, à défaut pour root. Idempotent :
# une clé déjà présente n'est pas ajoutée deux fois.
appliquer_cle_ssh() {
    _cle=$1
    [ -n "$_cle" ] || return 0
    _foyer=""
    _utilisateur=""
    for _d in /home/*; do
        [ -d "$_d" ] || continue
        _foyer=$_d
        _utilisateur=$(basename "$_d")
        break
    done
    if [ -z "$_foyer" ]; then _foyer=/root; _utilisateur=root; fi
    mkdir -p "$_foyer/.ssh" 2>/dev/null || return 0
    _fichier=$_foyer/.ssh/authorized_keys
    touch "$_fichier" 2>/dev/null || return 0
    if ! grep -qF "$_cle" "$_fichier" 2>/dev/null; then
        printf '%s\n' "$_cle" >> "$_fichier"
    fi
    chmod 700 "$_foyer/.ssh" 2>/dev/null || true
    chmod 600 "$_fichier" 2>/dev/null || true
    chown -R "$_utilisateur" "$_foyer/.ssh" 2>/dev/null || true
    return 0
}

# Applique tout ce que la configuration demande, hors mode réserve.
appliquer_configuration() {
    _json=$1
    appliquer_nom_hote "$(valeur_json hostname "$_json")"
    appliquer_reseau "$(valeur_json ip "$_json")" "$(valeur_json masque "$_json")" \
                     "$(valeur_json passerelle "$_json")" "$(valeur_json dns "$_json")"
    appliquer_cle_ssh "$(valeur_json cle_ssh "$_json")"
    return 0
}

# Après un réveil de réserve, la machine n'a PAS redémarré : son bail DHCP est
# celui qu'elle avait avant d'être figée, et il est partagé avec ses sœurs.
# On le relâche et on en redemande un.
rafraichir_reseau() {
    if command -v dhclient >/dev/null 2>&1; then
        dhclient -r >/dev/null 2>&1 || true
        dhclient    >/dev/null 2>&1 || true
        return 0
    fi
    if command -v networkctl >/dev/null 2>&1; then
        networkctl renew >/dev/null 2>&1 && return 0
    fi
    if command -v nmcli >/dev/null 2>&1; then
        for _c in $(nmcli -t -f NAME connection show --active 2>/dev/null); do
            nmcli connection down "$_c" >/dev/null 2>&1 || true
            nmcli connection up   "$_c" >/dev/null 2>&1 || true
        done
    fi
    return 0
}

# --- 3. Configuration déposée par vazy -----------------------------------------
BRUT=$(lire_variable) || BRUT=""
case "$BRUT" in ""|"No value found"*) exit 0 ;; esac
JSON=$(printf '%s' "$BRUT" | base64 -d 2>/dev/null) || exit 0
[ -n "$JSON" ] || exit 0

MODE=$(valeur_json mode "$JSON")

# --- 4. Mode réserve chaude ----------------------------------------------------
# vazy veut figer cette machine pour la réveiller plus tard avec une autre
# identité. On ne fixe donc RIEN maintenant : on annonce qu'on est prêt, puis on
# attend en tâche de fond que la vraie configuration arrive. La suspension gèle
# cette attente ; le réveil la reprend exactement où elle en était, et c'est ce
# qui permet d'appliquer une identité sans redémarrage.
attendre_configuration() {
    _ecoule=0
    while [ "$_ecoule" -lt 3600 ]; do
        _brut=$(lire_variable) || _brut=""
        case "$_brut" in
            ""|"No value found"*) : ;;
            *)
                _json=$(printf '%s' "$_brut" | base64 -d 2>/dev/null) || _json=""
                if [ -n "$_json" ]; then
                    _mode=$(valeur_json mode "$_json")
                    if [ "$_mode" != "pool" ]; then
                        appliquer_configuration "$_json"
                        # Sans adresse fixe demandée, le bail DHCP hérité de
                        # l'état figé est encore celui d'avant : on en redemande un.
                        if [ -z "$(valeur_json ip "$_json")" ]; then rafraichir_reseau ; fi
                        poser_variable vazy_pool_pret 0
                        return 0
                    fi
                fi
                ;;
        esac
        sleep 2
        _ecoule=$((_ecoule + 2))
    done
    return 0
}

if [ "$MODE" = "pool" ]; then
    poser_variable vazy_pool_pret 1
    # L'unité systemd doit porter KillMode=process, sans quoi systemd tuerait
    # cette attente en même temps que le script principal.
    attendre_configuration &
    exit 0
fi

appliquer_configuration "$JSON"
exit 0
