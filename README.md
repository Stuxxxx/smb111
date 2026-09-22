# SMB111 — Infrastructure as Code

Déploiement et exposition sécurisée d'une application dans un SI automatisé.
Cluster Kubernetes (k3s), automatisation Ansible, identité centralisée, supervision et MCO/MCS.

Ce dépôt contient **tout** ce qui permet de reconstruire le SI : playbooks Ansible,
manifests Kubernetes, documentation et schémas.

- **Machine d'administration** : `rasb` (Raspberry Pi 5). C'est depuis elle que tout est déployé.
- **Dépôt public** : aucun secret en clair. Les secrets sont chiffrés avec `ansible-vault`.
- **Branche `main` protégée** : toute modification passe par une Pull Request relue.

---

## 1. Obtenir un accès administrateur

Les accès sont gérés **par le dépôt**, pas à la main sur les machines. Ajouter sa clé
publique dans `keys/` et son nom dans la liste des administrateurs suffit : Ansible crée
le compte, installe la clé et accorde les droits `sudo` sur toutes les machines du projet.

> Une fusion dans `main` revient à distribuer un accès `root` sur l'ensemble du SI.
> C'est pour cette raison que chaque ajout est relu avant d'être appliqué.

### Étape 1 — Générer une paire de clés SSH

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

### Étape 2 — Proposer ton accès

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
permet au playbook de les associer.

```bash
git add keys/prenom.pub group_vars/all/admins.yml
git commit -m "access: ajout de prenom"
git push -u origin access/prenom
```

Ouvre ensuite la Pull Request sur GitHub.

### Étape 3 — Après la fusion

Un administrateur relit, fusionne, puis applique le playbook. Tu peux alors te connecter :

```bash
ssh prenom@<adresse-de-la-machine>
```

Ton compte n'a **pas** de mot de passe : la connexion se fait uniquement par clé, et `sudo`
fonctionne sans mot de passe pour le groupe `admins`.

### Départ d'un membre

On ne supprime pas la ligne : on la marque `absent`, pour garder la trace dans l'historique.

```yaml
  - name: prenom
    state: absent
```

Au passage suivant du playbook, le compte et son dossier personnel sont supprimés sur toutes
les machines.

---

## 2. Travailler proprement sur le dépôt

### Prérequis sur la machine de travail

```bash
sudo apt install -y git pipx
pipx install --include-deps ansible
pipx inject ansible kubernetes proxmoxer requests
ansible-galaxy collection install -r requirements.yml
```

La plupart des opérations se lancent **depuis `rasb`**, la machine d'administration, où tout
est déjà installé. Pour éditer confortablement, utilise VS Code avec l'extension
**Remote - SSH** : tu édites depuis ton poste, tout s'exécute sur `rasb`.

### Le cycle de travail

La branche `main` est protégée : aucun push direct. Le cycle est toujours le même.

```bash
git checkout main && git pull            # 1. partir de la dernière version
git checkout -b feat/sujet-court         # 2. une branche par sujet

# 3. modifier, puis TOUJOURS simuler avant d'appliquer
ansible-playbook <playbook>.yml --check --diff

# 4. appliquer et vérifier l'idempotence (2e exécution : changed=0)
ansible-playbook <playbook>.yml
ansible-playbook <playbook>.yml

git add -A
git commit -m "feat: description courte à l'impératif"
git push -u origin feat/sujet-court      # 5. puis ouvrir la Pull Request
```

Après la fusion :

```bash
git checkout main && git pull
git branch -d feat/sujet-court
```

### Nommage

| Type | Branche | Commit |
|---|---|---|
| Nouvelle fonctionnalité | `feat/nom` | `feat: ajoute le rôle k3s_server` |
| Correction | `fix/nom` | `fix: corrige le chemin du kubeconfig` |
| Accès | `access/prenom` | `access: ajout de prenom` |
| Documentation | `docs/nom` | `docs: complète la matrice des flux` |

Un commit = un changement cohérent. Message à l'impératif, en français, sans point final.

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

## 3. Les secrets

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

## 4. Structure du dépôt

```
smb111/
├── ansible.cfg                 # configuration Ansible (inventaire, vault, clé SSH)
├── inventory.ini               # machines de production
├── inventory-lab.ini           # machines du laboratoire
├── requirements.yml            # collections Ansible requises
├── admins.yml                  # playbook de gestion des accès
├── site.yml                    # playbook principal : déploie tout
├── group_vars/all/
│   ├── admins.yml              # liste des administrateurs
│   └── vault.yml               # secrets chiffrés
├── keys/                       # clés publiques des administrateurs
├── roles/                      # rôles Ansible
├── playbooks/                  # playbooks spécifiques (maintenance, sauvegarde…)
├── k8s/                        # manifests Kubernetes
├── app/                        # code source et Dockerfile de l'application
└── docs/                       # documentation technique
```

---

## 5. Reconstruire depuis zéro

```bash
git clone git@github.com:Stuxxxx/smb111.git && cd smb111
ansible-galaxy collection install -r requirements.yml
# placer le mot de passe du vault dans ~/.vault_pass
ansible-playbook site.yml
```

Prérequis : Ansible, les collections, un accès au Proxmox et le mot de passe du vault.

---

## 6. Règles de sécurité

1. La clé privée ne quitte **jamais** la machine sur laquelle elle a été générée.
2. Aucune modification manuelle sur les serveurs : tout passe par Ansible et le dépôt.
   Une clé ajoutée à la main est supprimée au passage suivant du playbook.
3. Toujours simuler (`--check --diff`) avant d'appliquer.
4. Ne jamais pousser sur `main` : la protection est là pour éviter l'erreur, pas pour gêner.
5. Un doute sur un secret ou un accès : demander avant d'agir.
# test
