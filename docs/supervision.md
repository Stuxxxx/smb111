# Supervision du SI : la VM `sup`

Réponse aux exigences **FCT 02** (métriques, journaux centralisés, tableau de bord), **FCT 04**
(au moins 3 alertes avec seuil et notification) et **GEN 03** (déployé par Ansible) du sujet.

| Composant | Rôle | Où |
|---|---|---|
| **Alloy** (Grafana) | agent : métriques du système et journal systemd | toutes les machines (rôle `alloy`) |
| **Prometheus** | stocke les métriques (15 jours), calcule les alertes | `sup`, conteneur |
| **Alertmanager** | envoie les alertes par e-mail aux admins | `sup`, conteneur |
| **Loki** | stocke les journaux (15 jours) | `sup`, conteneur |
| **Grafana** | tableaux de bord | `sup`, conteneur |
| **nginx** | seul point d'entrée réseau de `sup`, en HTTPS | `sup`, conteneur |

Les images sont épinglées dans `roles/supervision/defaults/main.yml`.

---

## Pourquoi une VM à part, sur `pve2` et le réseau local

- **Hors du cluster Kubernetes** : la supervision ne tombe pas avec ce qu'elle surveille. Un nœud
  arrêté (test de chaos), ou tout le cluster, reste visible et déclenche une alerte.
- **Sur `pve2`** : une panne de `pve` (qui porte toutes les autres VM) n'arrête pas la supervision.
  Avec deux nœuds, `pve2` perd alors le quorum, mais une VM déjà démarrée continue de tourner.
- **Sur le réseau local** (`vmbr0`, `192.168.1.71`) et non derrière `fw` : `vmbr1` de `pve2` n'est
  relié à rien ([cluster-proxmox.md](cluster-proxmox.md)). Et surtout, `sup` envoie ses e-mails
  directement par le service d'envoi, comme `rasb` : **les alertes partent même si `fw` est en panne**.

## Architecture et flux

```
 VM internes (idp, nœuds k3s…)                 rasb, pve, pve2            postes wg0
   Alloy ──► fw (NAT) ──┐                        Alloy ──┐                    │
                        ▼                                ▼                    ▼
              sup 192.168.1.71 : nginx (HTTPS, certificat de la PKI)     rasb (relais)
               ├─ :9090  /api/v1/write      ──► Prometheus ──► Alertmanager ──► e-mail (Gmail)
               ├─ :3100  /loki/api/v1/push  ──► Loki                 ▲
               ├─ :443   Grafana            ◄── admins (par rasb)    │
               └─ :9093  /api/v2/alerts     ◄── rasb : contrôle de veille (alerte Watchdog)
```

Matrice des flux ajoutés :

| Source | Destination | Port | Objet |
|---|---|---|---|
| VM internes (10.10.0.0/24), via `fw` en NAT | `sup` | 9090, 3100/tcp (HTTPS) | métriques et journaux |
| `rasb`, `pve`, `pve2` | `sup` | 9090, 3100/tcp (HTTPS) | métriques et journaux |
| `rasb` (et les postes wg0 qu'il relaie) | `sup` | 443/tcp (HTTPS) | Grafana |
| `rasb` | `sup` | 9093/tcp (HTTPS, GET seul) | contrôle de veille |
| `rasb` | `sup` | 22/tcp | administration (Ansible, rebond SSH) |
| `sup` | `smtp.gmail.com` | 587/tcp (STARTTLS) | e-mails d'alerte |
| `sup` | Internet | 443/tcp | paquets, images Docker |

Côté sécurité :

- Le pare-feu de `sup` (nftables, table `smb111`) n'accepte que ces sources. Les conteneurs
  utilisent le réseau de l'hôte : Docker ne publie aucun port, ses règles ne contournent donc pas
  le pare-feu. Prometheus, Loki, Alertmanager et Grafana n'écoutent que sur `127.0.0.1`.
- nginx n'expose que le chemin utile sur chaque port (écriture des métriques, écriture des
  journaux, lecture des alertes) : les API de requête et d'administration restent internes.
- Sur `fw`, la seule exception à « les VM ne joignent jamais le réseau local » : `sup`, ports 9090
  et 3100 (`fw_supervision_ip`).
- Certificat `sup.smb111.lan` émis par la PKI du SI ([pki.md](pki.md)) ; les agents vérifient la
  chaîne avec la racine installée partout par le rôle `pki`.

## Alertes

Définies dans `roles/supervision/templates/regles.yml.j2`, envoyées par e-mail aux membres du
groupe `admins` de Keycloak (même liste que les autres notifications, [notifications.md](notifications.md)),
au déclenchement puis à la résolution. Rappel toutes les 4 h tant qu'une alerte dure.

| Alerte | Seuil | Déclenchement en démonstration |
|---|---|---|
| `MachineMuette` | aucune métrique depuis 5 min, pendant 10 min | `sudo systemctl stop alloy` sur une VM, ou l'arrêter |
| `ServiceEnEchec` | un service systemd en échec, pendant 2 min | `sudo systemd-run --unit=demo-echec false` (puis `sudo systemctl reset-failed demo-echec`) |
| `CPUSature` | processeur > 90 %, pendant 10 min | `stress-ng --cpu 0 --timeout 15m` |
| `MemoireSaturee` | mémoire > 90 %, pendant 10 min | `stress-ng --vm 1 --vm-bytes 95% --timeout 15m` |
| `DisqueBientotPlein` | moins de 10 % libre, pendant 15 min | `fallocate -l <taille> /var/tmp/remplissage` |
| `ComposantSupervisionEnPanne` | Prometheus, Loki, Alertmanager ou Grafana muet 5 min | `sudo docker stop supervision-loki-1` sur `sup` |
| `Watchdog` | toujours active, jamais envoyée | voir le contrôle de veille ci-dessous |

Les seuils sont des variables du rôle (`supervision_seuil_*`). La liste des machines attendues
est l'inventaire entier : une machine ajoutée à `inventory.ini` est surveillée au passage suivant
du rôle.

Une fois k3s déployé avec ses collecteurs, `supervision_kubernetes: true`
(`group_vars/all/supervision.yml`) ajoute `KubeNoeudNonPret`, `KubeDeploiementIncomplet` (la
démonstration « arrêt d'un pod » : `kubectl scale --replicas=0`, ou un pod qui ne redémarre pas),
`KubePodNonDemarre` et `KubeAPIMuette`.

### Contrôle de veille (qui surveille la supervision ?)

Une supervision en panne ne peut pas le dire. Prometheus envoie donc en permanence l'alerte
`Watchdog` à Alertmanager, qui ne la transmet à personne. Toutes les 10 minutes, `rasb`
(`veille-supervision.timer`) vérifie qu'elle est bien là ; après 2 échecs de suite, il envoie un
e-mail « Supervision en panne », puis « Supervision rétablie » au retour. Rien n'est vérifié
quand `pve2` est éteint ou en veille : la supervision est alors arrêtée volontairement.

```bash
sudo systemctl start veille-supervision.service && journalctl -u veille-supervision -e
```

## Tableau de bord

Grafana : **https://sup.smb111.lan** depuis un poste de wg0 (la racine de la PKI installée,
[pki.md](pki.md#télécharger-lautorité-de-certification)). Compte `admin`, mot de passe
`vault_grafana_admin_mdp`.

Le tableau **SMB111 · Vue d'ensemble** (dossier SMB111, versionné dans
`roles/supervision/files/tableaux/`) montre ce que demande FCT 02 :

- machines muettes, alertes en cours, services en échec ;
- processeur et mémoire de chaque machine, disque le plus rempli ;
- cluster Kubernetes : état de l'API, nœuds Ready, pods par état, processeur et mémoire par pod
  (vide tant que les collecteurs du cluster ne sont pas déployés) ;
- erreurs récentes de toutes les machines (journaux, Loki).

Les journaux complets : *Explore → Loki*, par exemple `{host="idp", unit="keycloak.service"}`.
Les journaux des conteneurs de `sup` y sont aussi (pilote `journald` de Docker).

---

## Mise en place

Tout se lance depuis `rasb`, dans son clone du dépôt.

### 1. Prérequis

- **Adresse** : `192.168.1.71` doit être libre et hors de la plage DHCP de la box (sinon, changer
  l'`ip` de `sup` dans `group_vars/all/vms.yml`).
- **Mot de passe de Grafana**, 12 caractères minimum, dans le vault :

  ```bash
  ansible-vault edit group_vars/all/vault.yml
  # ajouter : vault_grafana_admin_mdp: "<mot de passe>"
  ```

- **Collection** `community.docker` : `ansible-galaxy collection install -r requirements.yml`.
- `pve` et `pve2` allumés, en cluster, avec le stockage `local-lvm` sur les deux.

### 2. Créer la VM

```bash
ansible-playbook playbooks/provision.yml -e cible=sup
```

`sup` est clonée sur `pve` (qui porte le template), migrée arrêtée vers `pve2`, branchée sur
`vmbr0`, puis démarrée.

### 3. Configurer

```bash
ansible-playbook site.yml --limit fw --tags fw              # DNS sup.smb111.lan, ouverture vers sup
ansible-playbook site.yml --limit sup                       # durcissement, pare-feu, Docker, pile de supervision
ansible-playbook site.yml --tags alloy                      # agent sur toutes les machines
ansible-playbook site.yml --limit rasb                      # contrôle de veille
ansible-playbook site.yml --limit sup                       # 2e fois : changed=0
```

### 4. Vérifier

```bash
ssh sup sudo docker compose -f /opt/supervision/compose.yml ps        # 5 conteneurs « running »
curl -s --cacert pki/racine.crt https://sup.smb111.lan:9093/api/v2/alerts | jq '.[].labels.alertname'
# "Watchdog" (et rien d'autre si tout va bien)
```

Puis ouvrir Grafana : chaque machine doit apparaître dans les courbes en moins d'une minute.

## Exploitation

| Situation | Action |
|---|---|
| Changer un seuil, une alerte | modifier le rôle, `ansible-playbook site.yml --limit sup --tags supervision` |
| Nouveau destinataire (admin ajouté dans Keycloak) | `ansible-playbook site.yml --limit sup --tags supervision` |
| Mettre à jour une image | changer sa version dans `supervision_images`, même commande |
| Changer le mot de passe de Grafana | `ssh sup sudo docker exec supervision-grafana-1 grafana cli admin reset-admin-password '<nouveau>'`, puis le vault (la variable ne sert qu'à la création) |
| Alerte « Supervision en panne » | `ssh sup sudo docker compose -f /opt/supervision/compose.yml ps`, puis `logs <service>` |
| Une machine reste « muette » | `sudo systemctl status alloy` et `journalctl -u alloy -e` sur la machine |

Les données de `sup` (métriques et journaux) ne sont pas sauvegardées : elles se reconstituent,
et la configuration est entièrement dans le dépôt.

## Limites assumées

- **Nuit** : `pve2` est mis en veille avec `pve`, la supervision dort avec le SI. Au réveil, chrony
  recale l'heure de `sup` d'un coup (`makestep 1 -1`) ; les courbes ont un trou pendant la nuit.
- **Pas d'authentification sur la réception** des métriques et des journaux : seules les adresses
  du SI y ont accès (pare-feu de `sup`), en HTTPS. Un poste du réseau local qui usurperait l'une
  d'elles pourrait envoyer de fausses métriques.
- **Grafana en compte local** : la connexion par Keycloak (OIDC, rôles user et admin) est une
  évolution prévue.
- **Kubernetes** : les collecteurs du cluster (kube-state-metrics, Alloy en DaemonSet) seront
  déployés avec k3s ; les règles et le tableau de bord sont prêts.
