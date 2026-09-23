# SMB111 — Infrastructure as Code

Déploiement et exposition sécurisée d'une application dans un SI automatisé.
Cluster Kubernetes (k3s), automatisation Ansible, identité centralisée, supervision et MCO/MCS.

Ce dépôt contient **tout** ce qui permet de reconstruire le SI : playbooks Ansible,
manifests Kubernetes, documentation et schémas.

- **Machine d'administration** : `rasb` (Raspberry Pi 5). C'est depuis elle que tout est déployé.
- **Dépôt public** : aucun secret en clair. Les secrets sont chiffrés avec `ansible-vault`.
- **Branche `main` protégée** : toute modification passe par une Pull Request relue.
- **Convergence automatique** : les accès sont réappliqués toutes les 10 minutes depuis `main`.

---

## 1. Obtenir un accès administrateur

Les accès sont gérés **par le dépôt**, pas à la main sur les machines. Ajouter sa clé
publique dans `keys/` et son nom dans la liste des administrateurs suffit : Ansible crée
le compte, installe la clé et accorde les droits `sudo` sur toutes les machines du projet.

> Une fusion dans `main` revient à distribuer un accès `root` sur l'ensemble du SI.
> C'est pour cette raison que chaque ajout est relu avant d'être appliqué.

### Étape 1 — Être ajouté comme collaborateur

Le responsable du projet ajoute le nouveau membre dans
*Settings → Collaborators*, avec le rôle **Write**. Sans ce droit, impossible de pousser une
branche sur le dépôt.

Cette étape ne donne **aucun accès aux machines** : elle permet seulement de proposer des
modifications.

À défaut, il reste possible de contribuer par un **fork** du dépôt : la suite de la procédure
est identique.

### Étape 2 — Générer une paire de clés SSH

Sur **ta** machine (ton poste de travail, jamais sur un serveur) :

```bash
ssh-keygen -t ed25519 -C "prenom@laptop"
```

- Choisis une **phrase de passe** : cette clé donne un accès administrateur.
- Le fichier `~/.ssh/id_ed25519` (sans `.pub`) est **privé** : il ne sort jamais de ta machine,
  ne se copie nulle part, ne se colle dans aucun chat.
- Le fichier `~/.ssh/id_ed25519.pub` est **public** : c'est lui que tu partages.

Pour ne pas retaper la phrase de passe à chaque connexion, utilise un agent SSH :

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

Ajoute par ailleurs une clé dans **ton** compte GitHub (*Settings → SSH and GPG keys*) pour
pouvoir pousser.

### Étape 3 — Proposer son accès

```bash
git clone git@github.com:Stuxxxx/smb111.git
cd smb111
git checkout -b access/prenom

cp ~/.ssh/id_ed25519.pub keys/prenom.pub
```

Puis ajoute-toi dans `group_vars/all/admins.yml` :

```yaml
admins:
  - name: sacha
  - name: prenom        # <- ta ligne
```

Le nom du fichier `keys/<nom>.pub` doit être **identique** au `name` déclaré : c'est ce qui
permet au playbook de les associer. Identifiants en **minuscules**, sans accent ni espace.

```bash
git add keys/prenom.pub group_vars/all/admins.yml
git commit -m "access: ajout de prenom"
git push -u origin access/prenom
```

Ouvre ensuite la Pull Request sur GitHub. Ansible n'est pas nécessaire sur ton poste : tu ne
modifies que des données, pas du code.

### Étape 4 — Relecture et application

Le responsable relit (la PR ne doit contenir que le fichier `.pub` et la ligne ajoutée),
approuve, fusionne, puis applique depuis la machine d'administration.

**Le déclencheur de l'accès est la fusion suivie de l'exécution du playbook**, jamais
l'ouverture de la Pull Request. Une PR ouverte ne donne rien à personne.

### Étape 5 — Première connexion

```bash
ssh prenom@<adresse-de-la-machine>
sudo -n true && echo "sudo OK"
```

Ton compte n'a **pas** de mot de passe : la connexion se fait uniquement par clé, et `sudo`
fonctionne sans mot de passe pour le groupe `admins`.

### Ajouter une seconde machine

Une clé **par machine** : ne recopie jamais une clé privée d'un poste à l'autre. Ajoute la
nouvelle clé publique **à la suite** dans ton fichier existant, sans écraser l'ancienne :

```bash
cat ~/.ssh/id_ed25519.pub >> keys/prenom.pub
cat keys/prenom.pub      # doit contenir DEUX lignes
```

Chaque ligne du fichier devient une clé autorisée.

### Départ d'un membre

On ne supprime pas la ligne : on la marque `absent`, pour garder la trace dans l'historique.

```yaml
  - name: prenom
    state: absent
```

Au passage suivant du playbook, le compte et son dossier personnel sont supprimés de toutes
les machines.

---

## 2. Travailler proprement sur le dépôt

### Où lancer les commandes

| Action | Où |
|---|---|
| Éditer les fichiers | ton poste (VS Code + extension **Remote - SSH**) ou directement sur `rasb` |
| Git (pull, branche, commit, push) | **sur `rasb`**, dans ton propre clone |
| `ansible-playbook` | **sur `rasb`** |
| Ouvrir et fusionner les PR | navigateur |

Les commandes Ansible s'exécutent **toujours depuis la machine d'administration** : c'est elle
qui détient l'inventaire, la clé `smb111` et le mot de passe du vault.

Chaque membre travaille dans **son propre clone** (`/home/<prenom>/smb111`), jamais dans celui
d'un autre : deux personnes sur le même dossier se marcheraient dessus.

### Prérequis

```bash
sudo apt install -y git pipx
pipx install --include-deps ansible
pipx inject ansible kubernetes proxmoxer requests
ansible-galaxy collection install -r requirements.yml
```

Tout est déjà installé sur `rasb`.

### Le cycle de travail

La branche `main` est protégée : aucun push direct. Le cycle est toujours le même.

```bash
git checkout main && git pull            # 1. partir de la dernière version
git checkout -b feat/sujet-court         # 2. une branche par sujet

# 3. modifier, puis TOUJOURS simuler avant d'appliquer
ansible-playbook site.yml --check --diff

# 4. appliquer et vérifier l'idempotence (2e exécution : changed=0)
ansible-playbook site.yml
ansible-playbook site.yml

git add -A
git commit -m "feat: description courte à l'impératif"
git push -u origin feat/sujet-court      # 5. puis ouvrir la Pull Request
```

Après la fusion :

```bash
git checkout main && git pull
git branch -d feat/sujet-court
```

### Pourquoi simuler d'abord

`--check --diff` montre ce qu'Ansible **ferait**, sans rien modifier. C'est le moment de
repérer une erreur de nom de fichier ou une clé sur le point d'être écrasée. Un exemple de
lecture :

```
TASK [Clés SSH]
ok:      [rasb] => (item=sacha)     <- inchangé, c'est normal
changed: [rasb] => (item=prenom)    <- la clé serait installée
```

Un `changed` sur une clé **existante** est une anomalie : arrête-toi et vérifie.

### Pourquoi vérifier l'idempotence

La seconde exécution doit afficher `changed=0`. C'est la preuve que le code décrit un **état**
et non des actions. Sans cela, chaque passage referait le travail et redémarrerait des
services inutilement.

Un `changed` persistant signale un bug, le plus souvent une tâche `command` ou `shell` sans
condition, qui s'exécute quoi qu'il arrive.

### Nommage

| Type | Branche | Commit |
|---|---|---|
| Nouvelle fonctionnalité | `feat/nom` | `feat: ajoute le rôle k3s_server` |
| Correction | `fix/nom` | `fix: corrige le chemin du kubeconfig` |
| Accès | `access/prenom` | `access: ajout de prenom` |
| Documentation | `docs/nom` | `docs: complète la matrice des flux` |

Un commit = un changement cohérent. Message à l'impératif, en français, sans point final.

Un changement d'accès fait l'objet d'une **PR séparée** : il doit rester lisible d'un coup
d'œil, sans être noyé dans une modification de rôle.

### Avant d'ouvrir une Pull Request

- [ ] `ansible-playbook … --check --diff` relu, sans surprise
- [ ] Le playbook est **idempotent** : la seconde exécution donne `changed=0`
- [ ] Aucun secret ajouté en clair (gitleaks le vérifie, mais relis-toi)
- [ ] Les chemins et variables sont paramétrés, rien n'est codé en dur
- [ ] La documentation est mise à jour si le comportement change

### Ce que la CI vérifie

À chaque push et chaque Pull Request, GitHub Actions exécute **gitleaks**, qui analyse tout
l'historique à la recherche de clés privées, mots de passe et jetons. Un échec bloque la
fusion. Le résultat est visible dans l'onglet **Actions** et dans la Pull Request.

---

## 3. Convergence automatique (`ansible-pull`)

### Principe

Un **timer systemd** installé par le rôle `admin` lance `ansible-pull` toutes les
**10 minutes** sur la machine d'administration. Celui-ci clone `main` et applique le playbook
**en local**, sans SSH.

Conséquence directe : une clé SSH ajoutée à la main sur une machine, ou un fichier modifié
hors du dépôt, est **annulé au passage suivant**. Le dépôt est la seule source de vérité, en
permanence — c'est ce qui donne sa valeur au dispositif côté sécurité.

### Configuration actuelle

Définie dans `roles/admin/defaults/main.yml`, surchargée par machine dans `host_vars/` :

| Variable | Valeur sur `rasb` | Rôle |
|---|---|---|
| `admin_pull_enabled` | `true` | active ou désactive le timer |
| `admin_pull_playbook` | `admins.yml` | ce qui est réappliqué automatiquement |
| `admin_pull_interval` | `10min` | fréquence |
| `admin_repo_branch` | `main` | branche appliquée |

Le pull est volontairement limité à `admins.yml` : les **accès** convergent seuls, ce qui est
l'essentiel en sécurité, tandis que le reste de la configuration reste sous contrôle manuel
pendant la phase de développement. Passer à `site.yml` fera converger l'infrastructure
complète.

### Suivre et déclencher

```bash
systemctl list-timers ansible-pull.timer --no-pager   # prochaine exécution
sudo systemctl start ansible-pull.service             # déclencher maintenant
journalctl -u ansible-pull.service -n 30 --no-pager   # ce qu'a fait le dernier passage
```

Prends le réflexe de consulter le journal après une fusion : c'est là que tu verras ce qui a
réellement été appliqué.

### Suspendre le timer

**Pour une séance de travail** (temporaire, non tracé) :

```bash
sudo systemctl stop ansible-pull.timer
# ... développement et tests ...
sudo systemctl start ansible-pull.timer
```

Cet arrêt est une modification manuelle : le prochain `ansible-playbook site.yml` rétablira
l'état décrit par `admin_pull_enabled`.

**Durablement** (par le code, donc tracé) — dans `host_vars/rasb.yml` :

```yaml
admin_pull_enabled: false
```

puis `ansible-playbook site.yml`. Les unités systemd restent installées, simplement inactives.

### Le piège à connaître

Tant qu'une branche n'est pas fusionnée, ce que tu appliques à la main et ce que le timer
applique **divergent** : le timer clone `main`, où ton travail n'existe pas encore.

Exemple : tu testes une nouvelle valeur depuis ta branche, elle est bien appliquée ; dix
minutes plus tard le timer la remplace par celle de `main`, sans erreur ni message. Ce n'est
pas un bug, c'est la convergence qui fait son travail.

Trois façons de procéder, selon le contexte :

1. **Cycle court** : tester, puis fusionner rapidement. Le décalage ne dure que quelques minutes.
2. **Session longue** : suspendre le timer pendant le travail.
3. **Cible séparée** (à venir) : développer contre les VM du laboratoire avec
   `-i inventory-lab.ini`, et réserver `rasb` à l'application de `main`.

Réflexe de diagnostic : si un fichier ne correspond plus à ce que tu attends, vérifie d'abord
que ce que tu voulais est bien dans `main`.

---

## 4. Les secrets

**Aucun secret ne doit apparaître en clair dans ce dépôt.** Tout passe par `ansible-vault`.

```bash
ansible-vault view group_vars/all/vault.yml     # consulter
ansible-vault edit group_vars/all/vault.yml     # modifier
```

Le mot de passe du vault est stocké dans `~/.vault_pass` sur `rasb` **uniquement**. Il est
exclu du dépôt par `.gitignore` et n'est transmis que de la main à la main.

Sont concernés : mots de passe, clés privées, jetons d'API, secrets OIDC, clé de la PKI.
Ne sont **pas** des secrets : les clés publiques `.pub`, les adresses IP privées, les noms d'hôte.

Si un secret a été poussé par erreur : préviens immédiatement, **révoque-le** (il est
compromis, même après suppression), puis nettoie l'historique.

---

## 5. Structure du dépôt

```
smb111/
├── ansible.cfg                 # configuration Ansible (inventaire, vault, clé SSH)
├── inventory.ini               # machines de production
├── inventory-lab.ini           # machines du laboratoire
├── requirements.yml            # collections Ansible requises
├── site.yml                    # playbook principal : appelle les rôles
├── admins.yml                  # playbook de gestion des accès
├── group_vars/all/
│   ├── admins.yml              # liste des administrateurs
│   └── vault.yml               # secrets chiffrés
├── host_vars/                  # variables propres à une machine
├── keys/                       # clés publiques des administrateurs
├── roles/
│   ├── common/                 # paquets, durcissement SSH, fail2ban
│   └── admin/                  # machine d'administration, timers systemd
├── playbooks/                  # maintenance, sauvegarde, vérifications
├── k8s/                        # manifests Kubernetes
├── app/                        # code source et Dockerfile de l'application
└── docs/                       # documentation technique
```

### Où mettre une variable

| Emplacement | Portée |
|---|---|
| `roles/<rôle>/defaults/main.yml` | valeur par défaut du rôle |
| `group_vars/<groupe>.yml` | toutes les machines du groupe |
| `host_vars/<machine>.yml` | cette machine seulement |

Un rôle reste générique ; les exceptions vivent à côté.

---

## 6. Reconstruire depuis zéro

```bash
git clone git@github.com:Stuxxxx/smb111.git && cd smb111
ansible-galaxy collection install -r requirements.yml
# placer le mot de passe du vault dans ~/.vault_pass
ansible-playbook site.yml
```

Prérequis : Ansible, les collections, un accès au Proxmox et le mot de passe du vault.

Cibler une partie du parc :

```bash
ansible-playbook site.yml --limit web        # un groupe
ansible-playbook site.yml --limit web1       # une machine
```

---

## 7. Règles de sécurité

1. La clé privée ne quitte **jamais** la machine sur laquelle elle a été générée.
2. Aucune modification manuelle sur les serveurs : tout passe par Ansible et le dépôt.
   Une clé ajoutée à la main est supprimée au passage suivant du playbook.
3. Toujours simuler (`--check --diff`) avant d'appliquer.
4. Ne jamais pousser sur `main` : la protection est là pour éviter l'erreur, pas pour gêner.
5. Un changement d'accès fait l'objet d'une PR séparée, relue attentivement.
6. Un doute sur un secret ou un accès : demander avant d'agir.

Le détail du modèle de droits (rôles GitHub, ruleset, CODEOWNERS, procédures de révocation)
figure dans `docs/gestion-des-droits.md`.
