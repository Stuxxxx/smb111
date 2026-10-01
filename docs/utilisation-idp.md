# Keycloak (VM `idp`) — mode d'emploi

## C'est quoi ?

Keycloak, c'est le **compte unique du projet** : un « Se connecter avec SMB111 », comme
« Se connecter avec Google ». Chaque personne a un seul identifiant et un seul mot de passe
pour tous les services hébergés.

Il tourne sur la VM `idp`, à l'adresse `https://idp.smb111.lan`.

---

## Ce que tu fais le plus souvent

| Je veux… | Je fais… |
|---|---|
| Ajouter, bloquer ou retirer quelqu'un | une commande `ansible-playbook` (section 3) |
| Gérer mon compte (mot de passe, double authentification) | `https://idp.smb111.lan/realms/smb111/account` |
| Gérer les comptes à la souris (groupe `admins`) | `https://idp.smb111.lan/admin/smb111/console/` |
| Entrer dans la VM | `ssh idp` (section 2) |

---

## 1. Ouvrir les pages web

Il suffit que **WireGuard soit actif** sur ton PC. Une seule fois, ajoute ces deux réglages
dans la configuration de ton client WireGuard (*Modifier* le tunnel) :

```
[Interface]
...
DNS = 10.10.0.1

[Peer]
...
AllowedIPs = 10.99.0.0/24, 192.168.1.0/24, 10.10.0.0/24
```

- `DNS` : ton PC trouve les noms en `.smb111.lan` (Internet continue de fonctionner).
- `AllowedIPs` : ton PC sait que le réseau des VM passe par le tunnel.

Ensuite, ouvre l'adresse dans ton navigateur et accepte l'avertissement de certificat
(c'est attendu : le certificat n'est pas encore officiel).

Si tu avais ajouté `idp.smb111.lan` dans ton fichier `hosts`, retire cette ligne : elle
passerait avant le DNS.

---

## 2. Entrer dans la VM (SSH)

La VM n'accepte SSH qu'en passant par `rasb`. Une seule fois, dans
`%USERPROFILE%\.ssh\config` (fichier **sans extension**) :

```powershell
notepad "$env:USERPROFILE\.ssh\config."
```

```
Host rasb
    HostName 10.99.0.1
    User <ton_nom>

Host idp
    HostName 10.10.0.5
    User <ton_nom>
    ProxyJump rasb
```

Le point à la fin de `config.` empêche le Bloc-notes d'ajouter `.txt`. Ensuite : `ssh idp`.

---

## 3. Gérer les comptes

### La règle

Les comptes se gèrent **en ligne de commande**, depuis `rasb` : une commande par action,
rien à éditer (ni fichier, ni vault). Les comptes vivent dans Keycloak, pas dans le dépôt —
pense donc à la sauvegarde (fin de section 4).

**Ajouter quelqu'un** (l'email n'est demandé qu'ici, il n'est stocké nulle part dans le dépôt) :

```bash
ansible-playbook site.yml --limit idp --tags comptes \
  -e "nom=alice email=alice@exemple.org groupes=utilisateurs"
```

| Paramètre | Rôle | Défaut |
|---|---|---|
| `nom` | identifiant de connexion | obligatoire |
| `email` | où la personne reçoit son invitation | obligatoire à la création |
| `groupes` | `admins` et/ou `utilisateurs`, séparés par des virgules | `utilisateurs` |
| `actif` | `false` = compte bloqué mais conservé | `true` |
| `etat` | `absent` = compte supprimé | `present` |

**Mettre dans le groupe `admins`** (peut gérer les comptes à la console) :

```bash
ansible-playbook site.yml --limit idp --tags comptes \
  -e "nom=bob email=bob@exemple.org groupes=admins"
```

**Bloquer** (sans supprimer), puis **réactiver** :

```bash
ansible-playbook site.yml --limit idp --tags comptes -e "nom=alice actif=false"
ansible-playbook site.yml --limit idp --tags comptes -e "nom=alice actif=true"
```

**Supprimer** :

```bash
ansible-playbook site.yml --limit idp --tags comptes -e "nom=alice etat=absent"
```

> Un run **sans** `-e nom=...` ne touche à aucun compte : il se contente de maintenir le
> realm, les groupes et le SMTP.

### Ce que reçoit un nouveau compte

1. Un **e-mail d'invitation** (lien valable 48 h).
2. En cliquant, la personne **choisit son mot de passe** (12 caractères minimum) et **active
   la double authentification** (application type Google Authenticator, FreeOTP ou Aegis).
3. Personne d'autre ne connaît jamais son mot de passe.

**Lien expiré ou e-mail perdu** (renvoyer l'invitation) :

```bash
ansible-playbook site.yml --limit idp --tags comptes -e "nom=alice renvoyer=true"
```

**Mot de passe oublié** : la personne clique sur « Mot de passe oublié ? » sur la page de
connexion et reçoit un lien par e-mail.

**Compte bloqué après 5 essais ratés** : il se débloque seul après quelques minutes, ou
console → *Users* → la personne → *Unlock*.

### Les groupes

- `utilisateurs` : accès aux services.
- `admins` : en plus, gère les comptes dans la console.

---

## 4. En cas de problème

| Problème | Solution |
|---|---|
| La page web ne s'ouvre pas | WireGuard actif ? réglages `DNS` et `AllowedIPs` de la section 1 ? |
| `Could not resolve hostname idp` | fichier SSH absent ou nommé `config.txt` (section 2) |
| L'invitation n'arrive pas | regarder les spams, puis le relais : [`relais-mail.md`](relais-mail.md) |
| Keycloak semble arrêté | depuis `rasb` : `ansible idp -a 'systemctl is-active keycloak postgresql'` |
| Voir les erreurs de Keycloak | depuis `rasb` : `ansible idp -b -a 'journalctl -u keycloak -n 50 --no-pager'` |
| Redémarrer Keycloak | depuis `rasb` : `ansible idp -b -a 'systemctl restart keycloak'` |

**Sauvegarde** : les comptes et les mots de passe sont dans la base de la VM, pas dans le
dépôt. Avant toute intervention lourde, depuis `rasb` :

```bash
ansible idp -b -m shell -a 'sudo -u postgres pg_dump -Fc keycloak > /var/backups/keycloak_$(date +%F).dump'
```
