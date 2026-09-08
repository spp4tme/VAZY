#!/bin/sh
# Installe vazy-guestinfo dans un modèle Linux (systemd). À lancer en root dans
# la VM modèle, AVANT de l'éteindre et de prendre l'instantané :
#     sudo sh installer.sh
# Ce fichier se suffit à lui-même : il contient le script et l'unité systemd
# (copies de vazy-guestinfo.sh et vazy-guestinfo.service).
set -e
if [ "$(id -u)" -ne 0 ]; then echo "Lancez ce script en root : sudo sh $0" >&2; exit 1; fi
if ! command -v systemctl >/dev/null 2>&1; then echo "systemd est requis (systemctl introuvable)." >&2; exit 1; fi
if ! command -v vmtoolsd >/dev/null 2>&1 && ! command -v vmware-rpctool >/dev/null 2>&1; then
    echo "Les outils invité manquent : installez-les d'abord (Debian/Ubuntu : apt install open-vm-tools)." >&2; exit 1
fi

cat > /usr/local/sbin/vazy-guestinfo <<'FIN_SCRIPT'
#!/bin/sh
# vazy-guestinfo : applique au démarrage la configuration déposée par vazy dans
# la variable guestinfo.vazy_config (JSON encodé en base64), lue avec les outils
# invité. vazy n'entre jamais dans la VM : il dépose de l'extérieur, avant le
# démarrage, et ce script lit.
#
# Clés appliquées : hostname. Toute clé inconnue est ignorée, pour rester
# compatible avec les versions futures (ip, masque, passerelle, dns, cle_ssh).
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

# --- 2. Configuration déposée par vazy -----------------------------------------
BRUT=$(lire_variable) || BRUT=""
case "$BRUT" in ""|"No value found"*) exit 0 ;; esac
JSON=$(printf '%s' "$BRUT" | base64 -d 2>/dev/null) || exit 0
[ -n "$JSON" ] || exit 0

# Extraction sans dépendance (ni jq ni python) : valeur simple de la clé "hostname".
NOM=$(printf '%s' "$JSON" | sed -n 's/.*"hostname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
case "$NOM" in
    ""|*[!A-Za-z0-9-]*|-*|*-) NOM="" ;;   # lettres, chiffres, tirets, ni au début ni à la fin
esac
if [ -n "$NOM" ] && [ ${#NOM} -le 63 ]; then
    ACTUEL=$(cat /etc/hostname 2>/dev/null || hostname)
    if [ "$ACTUEL" != "$NOM" ] || [ "$(hostname)" != "$NOM" ]; then
        # hostnamectl a besoin de D-Bus, souvent absent si tôt dans le démarrage :
        # à défaut on écrit directement, ce qui revient au même.
        if command -v hostnamectl >/dev/null 2>&1 && hostnamectl set-hostname "$NOM" 2>/dev/null; then
            :
        else
            printf '%s\n' "$NOM" > /etc/hostname
            hostname "$NOM" 2>/dev/null || true
        fi
        if grep -q '^127\.0\.1\.1' /etc/hosts 2>/dev/null; then
            sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NOM/" /etc/hosts
        else
            printf '127.0.1.1\t%s\n' "$NOM" >> /etc/hosts
        fi
    fi
fi
exit 0
FIN_SCRIPT
chmod 755 /usr/local/sbin/vazy-guestinfo

cat > /etc/systemd/system/vazy-guestinfo.service <<'FIN_UNITE'
[Unit]
Description=vazy : configuration de l'invite depuis guestinfo (nom d'hote, identite SSH)
Documentation=https://github.com/spp4tme/VAZY
DefaultDependencies=no
ConditionVirtualization=vmware
After=local-fs.target
Before=network-pre.target sysinit.target shutdown.target
Wants=network-pre.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/vazy-guestinfo

[Install]
WantedBy=sysinit.target
FIN_UNITE

systemctl daemon-reload
systemctl enable vazy-guestinfo.service >/dev/null 2>&1

# Première exécution dans le modèle : enregistre l'identité du modèle (ses clés
# SSH sont régénérées une fois) ; aucune variable déposée, donc rien d'autre.
/usr/local/sbin/vazy-guestinfo || true

echo "vazy-guestinfo installé et activé au démarrage."
echo "Suite : vider la configuration réseau mémorisée (README, « Préparer un modèle »),"
echo "éteindre la VM, prendre l'instantané, puis sur l'hôte : vazy template mark <alias> --guestinfo"
