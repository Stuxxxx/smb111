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

## Les tâches de nuit avec pve éteint

`pve` peut rester éteint la nuit : la sauvegarde (02:00), la maintenance du dimanche (03:00) et
le contrôle (06:00) le réveillent eux-mêmes. Chaque tâche passe par `smb111-avec-pve` sur `rasb` :

1. si `pve` est éteint, `reveil-pve` le rallume, puis la tâche attend que toutes les machines
   répondent (10 minutes au plus, `admin_reveil_attente`), puis que leur heure soit synchronisée
   (5 minutes au plus, `admin_reveil_attente_ntp`), sans quoi `check.yml` signalerait l'horloge ;
2. la tâche s'exécute normalement ;
3. si `pve` était éteint au départ, il est rééteint (`systemctl poweroff`). S'il était allumé, il
   le reste.

Les tâches passent une par une (verrou commun) : celle qui attend part une fois `pve` rééteint,
et le réveille à son tour. Le dimanche, `pve` démarre donc trois fois. Un redémarrage demandé
par la maintenance du dimanche est ainsi fait de lui-même à l'extinction qui suit, même si le
bilan l'annonce encore « à faire ».

Si `pve` ne répond pas au réveil, la tâche échoue et les admins reçoivent l'e-mail d'échec
habituel. Activé sur `rasb` par `admin_reveil_hyperviseur: true` (`host_vars/rasb.yml`).

Les mises à jour de sécurité quotidiennes (`unattended-upgrades`) se font au démarrage suivant
de chaque machine : il suffit qu'elle soit allumée de temps en temps.

## Ce que fait Ansible (rôle `wol`, play *Hyperviseur*)

| Où | Quoi |
|---|---|
| `pve` | service `wol-eno1` : `ethtool -s eno1 wol g` à chaque démarrage (le pilote peut remettre le réglage à `d`) |
| `rasb` | paquet `wakeonlan`, commande `/usr/local/bin/reveil-pve` |
| `rasb` | commande `/usr/local/bin/smb111-avec-pve` (rôle `admin`), qui encadre les tâches de nuit |
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
