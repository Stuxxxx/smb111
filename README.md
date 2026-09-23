# SMB111 — Infrastructure as Code

Déploiement et exposition sécurisée d'une application dans un SI automatisé.

Ce dépôt contient **tout** ce qui permet de reconstruire le SI : playbooks Ansible,
manifests Kubernetes, documentation et schémas.

- **Machine d'administration** : `rasb` (Raspberry Pi 5), à l'adresse `192.168.1.90`.
  C'est depuis elle que tout est déployé.
- **Dépôt public** : aucun secret en clair. Les secrets sont chiffrés avec `ansible-vault`.
- **Branche `main` protégée** : toute modification passe par une Pull Request relue.
- **Convergence automatique** : les accès sont réappliqués toutes les 10 minutes depuis `main`.

**Documentation :**

| Fichier | Contenu |
|---|---|
| ce README | comment obtenir un accès et comment le dépôt fonctionne |
| [`guide-travail.md`](https://drive.google.com/drive/folders/1WJwpEPPmBV-zM0xtxLpxt1AR8KT95yFS) | la suite : configuration sur `rasb`, commandes du quotidien |
| [`gestion-des-droits.md`](https://drive.google.com/drive/folders/1WJwpEPPmBV-zM0xtxLpxt1AR8KT95yFS) | modèle de droits complet, procédures de révocation |
| [`installation-admin.md`](https://drive.google.com/drive/folders/1WJwpEPPmBV-zM0xtxLpxt1AR8KT95yFS) | état technique de la machine d'administration |

---

## 1. Obtenir un accès administrateur

Les accès sont gérés **par le dépôt**, pas à la main sur les machines. Ajouter sa clé publique
dans `keys/` et son nom dans la liste des administrateurs suffit : Ansible crée le compte,
installe la clé et accorde les droits `sudo` sur toutes les machines du projet.

> Une fusion dans `main` revient à distribuer un accès `root` sur l'ensemble du SI.
> C'est pour cette raison que chaque ajout est relu avant d'être appliqué.

**Tout ce qui suit se fait depuis ton PC**, avant d'avoir le moindre accès aux machines.

### Étape 1 — Être ajouté comme collaborateur GitHub

Le responsable du projet t'ajoute dans *Settings → Collaborators* avec le rôle **Write**.
Sans ce droit, impossible de pousser une branche sur le dépôt.

Cette étape ne donne **aucun accès aux machines** : elle permet seulement de proposer des
modifications.

### Étape 2 — Créer sa clé SSH sur son PC

```bash
ssh-keygen -t ed25519 -C "prenom@laptop"
cat ~/.ssh/id_ed25519.pub        # la partie PUBLIQUE, celle qu'on partage
```

- Choisis une **phrase de passe** : cette clé donnera un accès administrateur.
- `~/.ssh/id_ed25519` (sans `.pub`) est **privé** : il ne sort jamais de ton PC, ne se copie
  nulle part, ne se colle dans aucun chat.
- `~/.ssh/id_ed25519.pub` est **public** : c'est lui que tu partages.

Pour ne pas retaper la phrase de passe à chaque connexion :

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

### Étape 3 — Déclarer cette clé dans GitHub

Sur github.com : *Settings → SSH and GPG keys → New SSH key*, titre `laptop`, et colle la clé
publique affichée à l'étape 2.

Vérifie :

```bash
ssh -T git@github.com        # doit te saluer par ton pseudo GitHub
```

Cette même clé sert donc à deux choses depuis ton PC : pousser sur GitHub, et bientôt te
connecter à `rasb`. C'est normal : une clé, une machine.

### Étape 4 — Proposer son accès

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

Ouvre ensuite la Pull Request sur GitHub. Ansible n'est pas nécessaire sur ton PC : tu ne
modifies que des données, pas du code.

### Étape 5 — Relecture et application

Le responsable relit (la PR ne doit contenir que le fichier `.pub` et la ligne ajoutée),
approuve, fusionne, puis applique le playbook depuis la machine d'administration.

**Le déclencheur de l'accès est la fusion suivie de l'exécution du playbook**, jamais
l'ouverture de la Pull Request. Une PR ouverte ne donne rien à personne.

### Étape 6 — Première connexion

```bash
ssh prenom@192.168.1.90
sudo -n true && echo "sudo OK"
```

Ton compte n'a **pas** de mot de passe : la connexion se fait uniquement par clé, et `sudo`
fonctionne sans mot de passe pour le groupe `admins`.

### Étape 7 — La suite : [`guide-travail.md`](https://drive.google.com/drive/folders/1WJwpEPPmBV-zM0xtxLpxt1AR8KT95yFS)

Une fois connecté, tu travailles **depuis `rasb`**, pas depuis ton PC : c'est là que se
trouvent l'inventaire, la clé des machines et le mot de passe du vault.

Il te faudra donc une **seconde clé, créée sur `rasb`**, pour pousser sur GitHub depuis cette
machine. Ce n'est pas un doublon : une clé privée ne se déplace jamais d'une machine à
l'autre, donc travailler depuis deux machines veut dire deux clés.

| Clé | Créée sur | Sert à | Sa partie publique va dans |
|---|---|---|---|
| clé d'accès | ton PC | te connecter à `rasb` et pousser depuis ton PC | `keys/prenom.pub` et ton compte GitHub |
| clé de travail | `rasb` | pousser sur GitHub depuis `rasb` | ton compte GitHub |

**→ Suis [`guide-travail.md`](https://drive.google.com/drive/folders/1WJwpEPPmBV-zM0xtxLpxt1AR8KT95yFS), section 1**, qui détaille la
création de cette clé, le clonage de ton propre dépôt sur `rasb` et les commandes du quotidien.

### Ajouter une seconde machine personnelle

Une clé **par machine** : ne recopie jamais une clé privée d'un poste à l'autre. Ajoute la
nouvelle clé publique **à la suite** dans ton fichier existant, sans écraser l'ancienne :

```bash
cat ~/.ssh/id_ed25519.pub >> keys/prenom.pub
cat keys/prenom.pub      # doit contenir DEUX lignes
```

Chaque ligne du fichier devient une clé autorisée.

### Nommage

| Type | Branche | Commit |
|---|---|---|
| Nouvelle fonctionnalité | `feat/nom` | `feat: ajoute le rôle k3s_server` |
| Correction | `fix/nom` | `fix: corrige le chemin du kubeconfig` |
| Accès | `access/prenom` | `access: ajout de prenom` |
| Documentation | `docs/nom` | `docs: complète la matrice des flux` |

Un commit = un changement cohérent. Message à l'impératif, en français, sans point final.
Un changement d'accès fait l'objet d'une **PR séparée** : il doit rester lisible d'un coup d'œil.

### Ce que la CI vérifie

À chaque push et chaque Pull Request, GitHub Actions exécute **gitleaks**, qui analyse tout
l'historique à la recherche de clés privées, mots de passe et jetons. Un échec bloque la
fusion. Le résultat est visible dans l'onglet **Actions** et dans la Pull Request.

---

## 3. Convergence automatique (`ansible-pull`)

Un **timer systemd** installé par le rôle `admin` lance `ansible-pull` toutes les
**10 minutes** sur `rasb`. Celui-ci clone `main` et applique le playbook **en local**, sans SSH.

Conséquence directe : une clé SSH ajoutée à la main sur une machine, ou un fichier modifié hors
du dépôt, est **annulé au passage suivant**. Le dépôt est la seule source de vérité, en
permanence.

| Variable | Valeur sur `rasb` | Rôle |
|---|---|---|
| `admin_pull_enabled` | `true` | active ou désactive le timer |
| `admin_pull_playbook` | `admins.yml` | ce qui est réappliqué automatiquement |
| `admin_pull_interval` | `10min` | fréquence |

Le pull est volontairement limité à `admins.yml` : les **accès** convergent seuls, tandis que
le reste de la configuration reste sous contrôle manuel pendant la phase de développement.

```bash
systemctl list-timers ansible-pull.timer --no-pager   # prochaine exécution
sudo systemctl start ansible-pull.service             # déclencher maintenant
journalctl -u ansible-pull.service -n 30 --no-pager   # ce qu'a fait le dernier passage
```

**Suspendre** — temporairement : `sudo systemctl stop ansible-pull.timer` (sera rétabli au
prochain `site.yml`). Durablement : `admin_pull_enabled: false` dans `host_vars/rasb.yml`,
puis `ansible-playbook site.yml`.

**Le piège** : tant qu'une branche n'est pas fusionnée, ce que tu appliques à la main et ce que
le timer applique divergent, puisque le timer clone `main`. Une modification testée depuis une
branche est donc annulée au passage suivant. Voir `docs/guide-travail.md` pour les trois façons
de procéder.

---

## 4. Les secrets

**Aucun secret ne doit apparaître en clair dans ce dépôt.** Tout passe par `ansible-vault`.

```bash
ansible-vault view group_vars/all/vault.yml     # consulter
ansible-vault edit group_vars/all/vault.yml     # modifier
```

La clé de déchiffrement est déjà sur `rasb`, dans `/etc/ansible/vault_pass`, lisible par le
groupe `admins`. Rien à installer : le vault est déchiffré automatiquement à chaque exécution.

Sont des secrets : mots de passe, clés privées, jetons d'API, secrets OIDC, clé de la PKI.
N'en sont **pas** : les clés publiques `.pub`, les adresses IP privées, les noms d'hôte.

Le détail de l'amorçage (`~/vault_bootstrap.yml`, l'option `-e`, et pourquoi la tâche apparaît
en `skipping`) est dans `docs/guide-travail.md`, section 3.

Si un secret a été poussé par erreur : préviens immédiatement, **révoque-le** (il est
compromis, même après suppression), puis nettoie l'historique.
