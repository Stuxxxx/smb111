# Cluster Proxmox : `pve` + `pve2` (portable)

`pve` (192.168.1.180) porte les VM du SI. `pve2` (192.168.1.181, un portable relié par un
adaptateur Ethernet USB) forme avec lui un cluster Proxmox : une seule interface web pour les deux,
et des VM qu'on peut déplacer de l'un à l'autre.

## Le quorum, et pourquoi les deux nœuds sont réveillés ensemble

Chaque nœud a une voix. Le cluster n'accepte de travailler (démarrer une VM, modifier une
configuration) que s'il voit **plus de la moitié des voix**, le *quorum*. Sinon, deux nœuds qui ne
se voient plus pourraient chacun démarrer la même VM. Avec deux nœuds, il faut donc **les deux
allumés** : un nœud seul se bloque et ses VM `onboot` ne démarrent pas.

D'où le fonctionnement retenu ([reveil-pve.md](reveil-pve.md)) :

- `reveil-pve` et les tâches de nuit réveillent toujours **les deux** nœuds ;
- `pve` est rééteint par un arrêt complet, `pve2` par une **mise en veille** : l'adaptateur USB
  n'est plus alimenté à l'arrêt complet, son Wake-on-LAN ne marche que depuis la veille ;
- `pve2` reste **branché sur secteur**, adaptateur branché.

Si `pve2` ne se réveille pas, `pve` démarre sans quorum : la tâche échoue et les admins reçoivent
l'e-mail d'échec. Dépannage sur place, en dernier recours, pour faire tourner `pve` seul :
`pvecm expected 1` sur `pve` (jusqu'à son prochain redémarrage).

**Pas de haute disponibilité (HA)** : avec des nœuds éteints volontairement, un nœud qui perd le
quorum avec des ressources HA se redémarre de force.

## Ce que fait Ansible

| Où | Quoi |
|---|---|
| `inventory.ini` | `pve2` dans le groupe `proxmox`, joint par le réseau local depuis `rasb` |
| `group_vars/proxmox` | `pve_cluster_ips` : les IP des nœuds, utilisées ci-dessous |
| pare-feu Proxmox | les nœuds dans l'ensemble `management` (SSH et API entre eux ; corosync est ouvert par Proxmox) |
| `sshd` des nœuds | `root` par clé depuis les autres nœuds seulement (migration, consoles), `PermitRootLogin no` partout ailleurs |
| `fail2ban` des nœuds | `rasb` et les nœuds jamais bannis |
| `rasb` (wg0) | les postes `wg0` ne joignent pas `pve2` en direct (`wg_lan_interdits`) |
| `provision.yml` | les VM sont clonées sur `pve`, puis migrées vers le nœud de leur champ `node` (`sup` sur `pve2`) |
| `maintenance.yml` | `pve2` mis à jour comme `pve`, sans redémarrage automatique |

La création du cluster elle-même (`pvecm`) se fait à la main, une seule fois.

## Mise en place

### 1. Préparer pve2 (sur le portable, en root)

- Proxmox **à la même version** que `pve` (`pveversion`), dépôts *no-subscription*.
- **Aucune VM ni conteneur** (`qm list`, `pct list`) : un nœud qui rejoint un cluster doit être vide.
- Nom **`pve2`**, `/etc/hosts` : `192.168.1.181 pve2.cameleo.local pve2` et
  `192.168.1.180 pve.cameleo.local pve` (et la ligne de `pve2` dans le `/etc/hosts` de `pve`).
- Réseau : `vmbr0` sur l'adaptateur USB (`nic0`) avec `192.168.1.181/24`, et un pont `vmbr1` sans
  carte, comme sur `pve`, pour pouvoir y déplacer des VM.
- `/etc/systemd/logind.conf` : `HandleLidSwitch=ignore`, `HandleLidSwitchExternalPower=ignore`,
  `HandleLidSwitchDocked=ignore`.
- Compte `ansible`, comme sur `pve` :

  ```bash
  apt install sudo
  useradd -m -s /bin/bash ansible
  echo 'ansible ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/ansible && chmod 440 /etc/sudoers.d/ansible
  install -d -m 700 -o ansible -g ansible /home/ansible/.ssh
  # coller le contenu de /etc/ansible/smb111.pub de rasb :
  echo 'from="192.168.1.90" <clé publique>' > /home/ansible/.ssh/authorized_keys
  chown ansible:ansible /home/ansible/.ssh/authorized_keys && chmod 600 /home/ansible/.ssh/authorized_keys
  ```

### 2. Appliquer le dépôt (depuis rasb, nœuds allumés)

```bash
ansible pve2 -m ping
ansible-playbook site.yml --limit pve      # pare-feu et SSH de pve ouverts à pve2
ansible-playbook site.yml --limit pve2     # durcissement, comptes, pare-feu, Wake-on-LAN
ansible-playbook site.yml --limit rasb     # smb111-avec-pve et wg0 pour deux nœuds
```

### 3. Créer le cluster

Sur `pve` (il garde ses VM) :

```bash
pvecm create smb111 --link0 192.168.1.180
```

Sur `pve2` :

```bash
pvecm add 192.168.1.180 --link0 192.168.1.181   # mot de passe root de pve, empreinte du certificat
pvecm status                                     # Nodes: 2, Quorate: Yes
```

`pvecm` se lance **en root** (`sudo -i`) : en compte nominatif, il échoue avec
`ipcc_send_rec failed`. S'il répond `hostname verification failed`, relancer en donnant
l'empreinte affichée à la première tentative : `pvecm add … --fingerprint <empreinte>`.

Puis, depuis `rasb`, `ansible-playbook site.yml --limit pve,pve2 --tags pve_firewall` : le pare-feu
est maintenant commun au cluster.

### 4. Vérifier le réveil

```bash
ssh rasb extinction-pve                         # pve arrêté, pve2 en veille
ssh rasb reveil-pve                              # les deux répondent
```

## Limites

- `local-lvm` reste propre à chaque nœud : déplacer une VM recopie son disque (VM arrêtée, ou en
  ligne avec `--with-local-disks`). Pas de bascule automatique.
- `vmbr1` de `pve` et `vmbr1` de `pve2` ne sont pas reliés : une VM interne déplacée sur `pve2` ne
  voit plus `fw`, qui reste sur `pve`. C'est pourquoi `sup`, sur `pve2`, est branchée sur le réseau
  local ([supervision.md](supervision.md)).
