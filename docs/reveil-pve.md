# Démarrer les hyperviseurs à distance (Wake-on-LAN)

Les hyperviseurs `pve` et `pve2` (le portable, voir [cluster-proxmox.md](cluster-proxmox.md))
peuvent être allumés depuis n'importe où : le PC passe par `wg0` jusqu'à `rasb`, qui envoie un
« paquet magique » sur le réseau local. La carte de chaque nœud, restée alimentée, le rallume :
`eno1` pour `pve` (depuis l'arrêt complet), l'adaptateur USB `nic0` pour `pve2` (depuis la veille
seulement). Les VM démarrent ensuite seules (option `onboot`).

Les deux nœuds sont toujours réveillés ensemble : un nœud seul n'a pas le quorum du cluster et ne
démarre pas ses VM.

```
PC --wg0--> rasb --paquet magique (192.168.1.255)--> eno1 de pve, nic0 de pve2 --> démarrage --> VM
```

## Utilisation

Tunnel `wg0` actif :

```bash
ssh rasb reveil-pve
```

La commande envoie un paquet à chaque nœud éteint, puis attend qu'ils répondent en SSH (5 minutes
au plus). Un nœud déjà allumé est laissé tel quel.

Éteindre :

```bash
ssh rasb extinction-pve          # les deux : arrêt de pve, puis veille de pve2
ssh rasb extinction-pve pve2     # seulement ceux nommés
```

`pve` est arrêté d'abord (il garde le quorum pendant l'arrêt de ses VM), puis `pve2` est mis en
veille. Jamais de `poweroff` sur `pve2` : son Wake-on-LAN ne marche pas depuis l'arrêt complet.

## Les tâches de nuit avec pve éteint

`pve` et `pve2` peuvent rester éteints la nuit : la sauvegarde (02:00), la maintenance du dimanche
(03:00) et le contrôle (06:00) les réveillent eux-mêmes. Chaque tâche passe par `smb111-avec-pve`
sur `rasb` :

1. si un nœud est éteint, `reveil-pve` rallume les nœuds éteints, puis la tâche attend que toutes les machines
   répondent (10 minutes au plus, `admin_reveil_attente`), puis que leur heure soit synchronisée
   (5 minutes au plus, `admin_reveil_attente_ntp`), sans quoi `check.yml` signalerait l'horloge ;
2. la tâche s'exécute normalement ;
3. les nœuds éteints au départ sont rééteints par `extinction-pve`, selon `wol_extinction`
   (`host_vars`) : `pve` est arrêté (`poweroff`), puis, une fois qu'il ne répond plus, `pve2` est
   mis en veille (`suspend`). Un nœud allumé au départ le reste.

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
| `pve`, `pve2` | service `wol-<carte>` : `ethtool -s <carte> wol g` à chaque démarrage (le pilote peut remettre le réglage à `d`) ; carte `wol_interface`, `eno1` par défaut, `nic0` pour `pve2` |
| `rasb` | paquet `wakeonlan`, commande `/usr/local/bin/reveil-pve` |
| `rasb` | commandes `/usr/local/bin/extinction-pve` et `/usr/local/bin/smb111-avec-pve` (rôle `admin`), qui éteint les nœuds et encadre les tâches de nuit |
| `rasb` | MAC de chaque nœud relevée pendant qu'il est allumé, dans `/etc/smb111/wol/<nœud>.mac` |

Mise en place ou mise à jour : `ansible-playbook site.yml --limit pve,pve2 --tags wol` (nœuds
allumés), puis `ansible-playbook site.yml --limit rasb` pour `smb111-avec-pve`.

## Réglages manuels (BIOS, une seule fois, sur place)

- **Wake on LAN** (ou *Power on by PCI-E / LAN*) : activé.
- **Restore on AC power loss** : *Power On*, pour redémarrer seul après une coupure de courant.
- `pve2` : toujours branché sur secteur, adaptateur USB toujours branché, couvercle ignoré
  (voir [cluster-proxmox.md](cluster-proxmox.md)).

## Limites

Le réveil dépend de `rasb` et de la box : sans courant ou sans Internet à la maison, aucun réveil à
distance n'est possible. Le paquet magique ne traverse pas Internet, il part toujours du réseau local.

## Vérifier

```bash
ansible pve -b -a 'ethtool eno1'      # « Wake-on: g »
ansible pve2 -b -a 'ethtool nic0'     # « Wake-on: g »
cat /etc/smb111/wol/*.mac             # sur rasb
```
