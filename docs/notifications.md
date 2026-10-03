# Tâches programmées et notifications

`rasb` exécute seul les tâches de MCO / MCS, et prévient les administrateurs par e-mail quand
quelque chose ne va pas. Tout est installé par le rôle `admin`.

---

## Les tâches programmées

| Timer | Quand | Playbook | E-mail |
|---|---|---|---|
| `sauvegarde.timer` | chaque nuit, 02:00 | `playbooks/sauvegarde.yml` | **bilan HTML à chaque réussite** (`playbooks/templates/sauvegarde-bilan.html.j2`), ou échec |
| `maintenance.timer` | dimanche, 03:00 | `playbooks/maintenance.yml` | **bilan HTML à chaque passage** (`playbooks/templates/maintenance-bilan.html.j2`), ou échec |
| `check.timer` | chaque jour, 06:00 | `playbooks/check.yml` | **rapport HTML à chaque passage**, conforme ou non (`playbooks/templates/check-rapport.html.j2`), ou échec du playbook |
| `ansible-pull.timer` | 10 min (désactivé) | `admins.yml` | en cas d'échec |
| `veille-supervision.timer` | toutes les 10 min | aucun (script `smb111-veille-supervision`) | « Supervision en panne » puis « rétablie », sans réveiller `pve2` ([supervision.md](supervision.md)) |

Si `pve` est éteint, chaque tâche le réveille par Wake-on-LAN puis le rééteint après
(`docs/reveil-pve.md`).

Elles s'exécutent dans une **copie du dépôt qui leur est réservée**, `/var/lib/smb111/depot`,
réalignée sur `main` juste avant chaque passage. Ce qui tourne la nuit est donc toujours l'état
fusionné et relu, jamais une branche en cours dans le clone de quelqu'un.

```bash
systemctl list-timers sauvegarde.timer maintenance.timer check.timer --no-pager
sudo systemctl start check.service            # lancer maintenant
journalctl -u maintenance.service -n 50 --no-pager
```

### Les deux mécanismes de mise à jour

| Mécanisme | Quand | Ce qu'il met à jour |
|---|---|---|
| `unattended-upgrades` (rôle `common`, sur chaque machine) | chaque jour, vers 06:00 | les correctifs de sécurité Debian seulement, jamais de redémarrage, sauf la liste `unattended_blacklist` |
| `maintenance.yml` (timer sur `rasb`) | dimanche, 03:00 | tout, y compris les paquets Proxmox de `pve` (`proxmox-ve`, `pve-manager`, noyau), qui ne viennent pas d'une origine autorisée par `unattended-upgrades` |

### La maintenance et les redémarrages

`maintenance.yml` met à jour les machines une par une. **Seules les VM redémarrent
automatiquement** (avec drain / uncordon pour les nœuds Kubernetes). Deux machines ne
redémarrent jamais seules :

| Machine | Pourquoi |
|---|---|
| `rasb` | c'est elle qui exécute le playbook : Ansible refuse de redémarrer son propre nœud de contrôle, ce qui faisait échouer toute la maintenance dès la première machine |
| `pve` | elle porte toutes les VM : la redémarrer coupe le SI entier, cluster compris |

Leur redémarrage en attente apparaît dans le bilan envoyé par e-mail, et `check.yml` le
rappelle chaque jour tant qu'il n'est pas fait. On le fait à la main, à un moment annoncé :

```bash
sudo reboot                  # rasb (la session SSH se coupe)
ssh pve sudo reboot          # pve : tout le SI s'arrête quelques minutes, les VM repartent seules
```

---

## Les notifications par e-mail

Les e-mails partent **directement de `rasb`** par le compte d'envoi du projet (le compte Gmail
du vault, déjà utilisé par le relais de `fw`). Ils ne dépendent donc ni de `pve` ni de `fw` :
`rasb` peut prévenir même quand l'hyperviseur est arrêté.

| Élément | Emplacement |
|---|---|
| Configuration d'envoi (msmtp) | `/etc/msmtprc` (root:admins 0640, contient le mot de passe d'application) |
| Destinataires | `/etc/smb111/destinataires` (root:admins 0640) |
| Envoyer un message | `/usr/local/bin/smb111-notifier [--html page.html] "Sujet" < texte` |
| Prévenir d'un échec | `/usr/local/bin/smb111-notifier-echec`, via `notification-echec@.service` |

Chaque service programmé déclare `OnFailure=notification-echec@%n.service` : en cas d'échec,
les admins reçoivent un e-mail HTML avec la cause probable (erreurs Ansible, machines
injoignables) et la fin du journal du service.

Une non-conformité n'est pas un échec : `check.service` se termine normalement et le rapport
du jour la signale (en-tête orange, « Que faire » pour chaque point). `check.service` n'est
en échec que si le playbook lui-même n'a pas pu aller au bout.

### Qui reçoit les e-mails

**Les membres actifs du groupe `admins` de Keycloak** (realm `smb111`) qui ont une adresse
e-mail. Être admin du SSO et être prévenu des incidents vont donc de pair : ajouter quelqu'un
au groupe l'abonne, le retirer ou bloquer son compte le désabonne.

```bash
ansible-playbook site.yml --limit idp --tags comptes -e "nom=alice email=alice@exemple.org groupes=admins"
```

La liste est relevée **sur `idp`** (l'API d'administration de Keycloak n'est pas ouverte à
`rasb`), puis écrite dans `/etc/smb111/destinataires` sur `rasb` :

- à chaque passage du rôle `keycloak_comptes` (`--tags comptes`), donc après toute gestion de
  compte en ligne de commande ;
- chaque nuit par `sauvegarde.yml`, pour suivre aussi les changements faits dans la console.

Les adresses ne passent jamais par ce dépôt public. Si Keycloak ne répond pas, l'ancienne liste
reste en place. Tant qu'aucune liste n'a été relevée, ou si le groupe est vide, les e-mails vont
à la boîte du compte d'envoi.

```bash
ansible-playbook site.yml --limit idp --tags comptes     # relève la liste, affiche les admins prévenus
sudo cat /etc/smb111/destinataires                       # sur rasb
```

### Tester

```bash
echo "Test des notifications SMB111" | smb111-notifier "Test"
sudo systemctl start notification-echec@check.service      # simule un échec du contrôle
journalctl -t msmtp -n 5 --no-pager                        # trace de l'envoi
```

| Dans le journal | Signification |
|---|---|
| `exitcode=EX_OK` | parti : vérifier la boîte (et les spams) |
| `authentication failed` | identifiants faux : revoir `vault_mail_service_*` |
| `cannot connect` | `rasb` ne joint pas `smtp.gmail.com:587` |
