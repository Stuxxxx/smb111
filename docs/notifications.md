# Tâches programmées et notifications

`rasb` exécute seul les tâches de MCO / MCS, et prévient les administrateurs par e-mail quand
quelque chose ne va pas. Tout est installé par le rôle `admin`.

---

## Les tâches programmées

| Timer | Quand | Playbook | E-mail |
|---|---|---|---|
| `sauvegarde.timer` | chaque nuit, 02:00 | `playbooks/sauvegarde.yml` | en cas d'échec |
| `maintenance.timer` | dimanche, 03:00 | `playbooks/maintenance.yml` | **bilan à chaque passage**, ou échec |
| `check.timer` | chaque jour, 06:00 | `playbooks/check.yml` | si un hôte n'est pas conforme (rapport joint) |
| `ansible-pull.timer` | 10 min (désactivé) | `admins.yml` | en cas d'échec |

Elles s'exécutent dans une **copie du dépôt qui leur est réservée**, `/var/lib/smb111/depot`,
réalignée sur `main` juste avant chaque passage. Ce qui tourne la nuit est donc toujours l'état
fusionné et relu, jamais une branche en cours dans le clone de quelqu'un.

```bash
systemctl list-timers sauvegarde.timer maintenance.timer check.timer --no-pager
sudo systemctl start check.service            # lancer maintenant
journalctl -u maintenance.service -n 50 --no-pager
```

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
| Envoyer un message | `/usr/local/bin/smb111-notifier` |
| Prévenir d'un échec | `/usr/local/bin/smb111-notifier-echec`, via `notification-echec@.service` |

Chaque service programmé déclare `OnFailure=notification-echec@%n.service` : en cas d'échec,
les admins reçoivent la fin du journal du service (et le rapport de conformité pour `check`).

### Choisir les destinataires

Les adresses des personnes sont des données personnelles : elles vont **dans le vault**, jamais
en clair dans ce dépôt public.

```bash
ansible-vault edit group_vars/all/vault.yml
```

```yaml
vault_notification_destinataires:
  - premiere.personne@exemple.org
  - deuxieme.personne@exemple.org
```

Puis : `ansible-playbook site.yml --limit rasb`. Sans cette variable, les notifications vont à
la boîte du compte d'envoi lui-même.

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
