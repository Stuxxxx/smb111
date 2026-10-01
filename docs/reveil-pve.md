# Démarrer l'hyperviseur à distance (Wake-on-LAN)

L'hyperviseur `pve` peut être allumé depuis n'importe où : le PC passe par `wg0` jusqu'à `rasb`,
qui envoie un « paquet magique » sur le réseau local. La carte `eno1` de `pve`, restée alimentée,
rallume le serveur. Les VM démarrent ensuite seules (option `onboot`).

```
PC --wg0--> rasb --paquet magique (192.168.1.255)--> eno1 de pve --> démarrage --> VM
```

## Utilisation

Tunnel `wg0` actif :

```bash
ssh rasb reveil-pve
```

La commande envoie le paquet, puis attend que `pve` réponde en SSH (5 minutes au plus). Si `pve`
est déjà allumé, elle le dit et ne fait rien.

Éteindre : `ssh pve sudo poweroff`, ou le bouton *Arrêter* de l'interface web.

## Ce que fait Ansible (rôle `wol`, play *Hyperviseur*)

| Où | Quoi |
|---|---|
| `pve` | service `wol-eno1` : `ethtool -s eno1 wol g` à chaque démarrage (le pilote peut remettre le réglage à `d`) |
| `rasb` | paquet `wakeonlan`, commande `/usr/local/bin/reveil-pve` |
| `rasb` | MAC de `eno1` relevée pendant que `pve` est allumé, dans `/etc/smb111/pve-wol.mac` |

Mise en place ou mise à jour : `ansible-playbook site.yml --limit pve --tags wol` (pve allumé).

## Réglages manuels (BIOS, une seule fois, sur place)

- **Wake on LAN** (ou *Power on by PCI-E / LAN*) : activé.
- **Restore on AC power loss** : *Power On*, pour redémarrer seul après une coupure de courant.

## Limites

Le réveil dépend de `rasb` et de la box : sans courant ou sans Internet à la maison, aucun réveil à
distance n'est possible. Le paquet magique ne traverse pas Internet, il part toujours du réseau local.

## Vérifier

```bash
ansible pve -b -a 'ethtool eno1'      # « Wake-on: g »
cat /etc/smb111/pve-wol.mac           # sur rasb
```
