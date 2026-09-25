#!/usr/bin/env bash
# Ajoute un pair WireGuard : attribue la prochaine IP libre, met à jour
# group_vars/all/wireguard.yml et affiche la configuration à donner au client.
#
#   ./scripts/wg-add-peer.sh
#   ./scripts/wg-add-peer.sh leo-laptop 'cleDuClientEnBase64='
#
# La clé PRIVÉE du client n'est jamais manipulée ici : elle reste sur sa machine.

set -euo pipefail

PROJET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAIRS="$PROJET/group_vars/all/wireguard.yml"
RESEAU="10.99.0"
PREMIERE_IP=2
DERNIERE_IP=50

# Informations publiques du serveur, affichées dans la configuration client.
SERVEUR_PUBKEY="$(sudo wg show wg0 public-key 2>/dev/null || echo '<clé publique de rasb>')"
SERVEUR_ENDPOINT="${WG_ENDPOINT:-<ip-publique>:51820}"
SERVEUR_ALLOWED="10.99.0.0/24, 192.168.1.0/24"

err() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
ok()  { printf '\033[32m%s\033[0m\n' "$*"; }

[[ -f "$PAIRS" ]] || err "Fichier introuvable : $PAIRS"

# --- Saisie -----------------------------------------------------------------
nom="${1:-}"
cle="${2:-}"

if [[ -z "$nom" ]]; then
  read -rp "Nom du pair (ex. leo-laptop) : " nom
fi
if [[ -z "$cle" ]]; then
  echo "Clé PUBLIQUE affichée par le client WireGuard (jamais la privée) :"
  read -rp "  > " cle
fi

# --- Validations ------------------------------------------------------------
[[ "$nom" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
  || err "Nom invalide : minuscules, chiffres et tirets uniquement."

[[ "$cle" =~ ^[A-Za-z0-9+/]{42}[A-Za-z0-9+/=]{2}$ ]] \
  || err "Clé publique invalide : 44 caractères en base64 attendus."

grep -q "name: $nom$" "$PAIRS" \
  && err "Le pair « $nom » existe déjà dans $PAIRS."

grep -q "$cle" "$PAIRS" \
  && err "Cette clé publique est déjà déclarée."

# --- Attribution de la prochaine IP libre -----------------------------------
utilisees="$(grep -oE "ip: $RESEAU\.[0-9]+" "$PAIRS" | grep -oE '[0-9]+$' || true)"
ip_libre=""
for n in $(seq "$PREMIERE_IP" "$DERNIERE_IP"); do
  if ! grep -qx "$n" <<< "$utilisees"; then ip_libre="$n"; break; fi
done
[[ -n "$ip_libre" ]] || err "Plus d'adresse libre entre .$PREMIERE_IP et .$DERNIERE_IP."
ip="$RESEAU.$ip_libre"

# --- Écriture ---------------------------------------------------------------
cat >> "$PAIRS" <<EOF
  - name: $nom
    public_key: "$cle"
    ip: $ip
EOF

ok "Pair « $nom » ajouté avec l'adresse $ip."

# --- Configuration à transmettre au client ----------------------------------
conf="$PROJET/wg-$nom.conf.example"
cat > "$conf" <<EOF
# Configuration WireGuard — $nom
# À importer dans le client, puis remplacer la ligne PrivateKey par celle
# que le client a générée lui-même. Ne jamais transmettre de clé privée.

[Interface]
PrivateKey = <clé privée générée par TON client, à ne pas partager>
Address = $ip/32

[Peer]
PublicKey = $SERVEUR_PUBKEY
Endpoint = $SERVEUR_ENDPOINT
AllowedIPs = $SERVEUR_ALLOWED
PersistentKeepalive = 25
EOF

echo
echo "--- Configuration à donner à l'utilisateur ---"
cat "$conf"
echo "---"
echo "Également écrite dans : $conf"
echo
echo "Prochaines étapes :"
echo "  1. git checkout -b access/wg-$nom"
echo "  2. git add group_vars/all/wireguard.yml && git commit -m \"access: pair wireguard $nom\""
echo "  3. git push -u origin access/wg-\$nom  puis ouvrir la Pull Request"
echo "  4. après fusion : ansible-playbook site.yml --tags wireguard"
