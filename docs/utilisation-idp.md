# Utilisation de la VM `idp` (Keycloak)

Guide du quotidien. L'installation est décrite dans [`procedure-keycloak.md`](procedure-keycloak.md).

| Élément | Valeur |
|---|---|
| VM | `idp`, vmid 120, `10.10.0.5`, réseau interne |
| Service | Keycloak (SSO), base PostgreSQL locale |
| URL | `https://idp.smb111.lan` |
| Console d'administration | `https://idp.smb111.lan/admin/` |
| Page de compte des utilisateurs | `https://idp.smb111.lan/realms/smb111/account` |

---

## 1. Se connecter à la VM

La VM n'est joignable que depuis `rasb` (`fw` n'accepte SSH que de lui). Depuis son PC, on
rebondit donc par `rasb`, WireGuard actif.

**Configuration SSH, une seule fois** — fichier `%USERPROFILE%\.ssh\config` (sans extension) :

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

Host idp-console
    HostName 10.10.0.5
    User <ton_nom>
    ProxyJump rasb
    LocalForward 443 localhost:443
```

Le point final de `config.` empêche le Bloc-notes d'ajouter `.txt` : SSH ignorerait le fichier.

Ensuite :

```powershell
ssh idp
```

Compte nominatif, sans mot de passe, `sudo` sans mot de passe : les mêmes règles que sur les
autres machines (voir le README).

---

## 2. Vérifier que tout fonctionne

Sur `idp` :

```bash
systemctl is-active keycloak postgresql                              # active / active
curl -sk https://localhost:9000/health/ready                          # "status": "UP"
curl -sk -o /dev/null -w '%{http_code}\n' https://localhost/realms/master   # 200
```

Depuis `rasb`, sans se connecter à la VM :

```bash
ansible idp -a 'systemctl is-active keycloak postgresql'
ansible-playbook playbooks/check.yml --limit idp
```

---

## 3. Ouvrir la console d'administration

Avec WireGuard (`wg0`) actif, la console s'ouvre directement dans le navigateur. Le flux passe
par `rasb` puis `wg1` jusqu'à `fw`, qui ne laisse passer vers `idp` que le port 443 depuis les
postes de `wg0` (liste `services_web_admin` dans `group_vars/all/reseau.yml`). SSH reste en rebond.

**Une seule fois sur le PC**, dans la configuration WireGuard du client :

```
[Interface]
...
DNS = 10.10.0.1

[Peer]
...
AllowedIPs = 10.99.0.0/24, 192.168.1.0/24, 10.10.0.0/24
```

`DNS` fait résoudre les noms par le DNS du SI (dnsmasq sur `fw`) tant que le tunnel est actif :
`idp.smb111.lan` et les futurs services fonctionnent sans fichier hosts, Internet reste résolu
normalement, et `mabbox.bytel.fr` est transmis à la box. Retirer toute ligne `idp.smb111.lan` du fichier
hosts : elle passerait avant le DNS.

**Ensuite :** ouvrir `https://idp.smb111.lan/admin/` et accepter l'avertissement (certificat
autosigné, en attendant la PKI interne). Le nom doit rester `idp.smb111.lan` : Keycloak redirige
vers l'URL exacte.

**Sans WireGuard** (secours) : tunnel SSH par `rasb`, avec la ligne `127.0.0.1   idp.smb111.lan`
dans le fichier hosts (à retirer ensuite), puis `ssh -N -L 443:localhost:443 -J <ton_nom>@192.168.1.90 <ton_nom>@10.10.0.5`
(ou `ssh -N idp-console`), fenêtre laissée ouverte.

---

## 4. Les utilisateurs

Deux sortes de comptes, à ne pas confondre :

| | Comptes Linux de la VM | Utilisateurs Keycloak |
|---|---|---|
| Servent à | administrer la VM en SSH | se connecter aux services par le SSO |
| Définis | dans le dépôt (`group_vars/all/admins.yml`, `keys/`) | dans la console Keycloak |
| Stockés | sur la machine, réappliqués par Ansible | dans la base PostgreSQL de `idp` |
| Mot de passe | aucun (clé SSH uniquement) | oui, choisi par chacun |
| Modifier | Pull Request sur le dépôt | console d'administration |

### Realms

- `master` : réservé à l'administration de Keycloak. N'y créer que des comptes d'administrateur.
- `smb111` : les utilisateurs et les services du projet.

### Créer un utilisateur

Realm `smb111` → *Users* → *Add user* : identifiant, e-mail, prénom, nom → *Create*.
Onglet *Groups* → *Join group* (`admins` ou `utilisateurs`).
Onglet *Credentials* → *Set password*, **Temporary activé** : la personne choisira le sien à
la première connexion.

### Changer un mot de passe

- **Par un administrateur** : *Users* → l'utilisateur → *Credentials* → *Reset password*,
  Temporary activé.
- **Par l'utilisateur lui-même** : `https://idp.smb111.lan/realms/smb111/account` → *Signing in*.
- **Un utilisateur bloqué** (trop d'essais) : *Users* → l'utilisateur → bascule *Enabled*, ou
  *Brute force* → *Unlock*.

### Retirer un utilisateur

Désactiver plutôt que supprimer (*Enabled* sur off) : l'historique reste consultable.
Supprimer seulement quand le départ est définitif.

### L'administrateur `admin-temp`

Créé au premier démarrage avec le mot de passe du vault (`vault_keycloak_admin_password`), qui
**n'est plus relu ensuite** : modifier le vault ne change rien. Il doit être remplacé par des
comptes nominatifs (realm `master`, rôle `admin`), puis supprimé.

---

## 5. Exploitation

| Besoin | Commande (depuis `rasb`) |
|---|---|
| Journaux | `ansible idp -b -a 'journalctl -u keycloak -n 100 --no-pager'` |
| Redémarrer Keycloak | `ansible idp -b -a 'systemctl restart keycloak'` |
| Réappliquer la configuration | `ansible-playbook site.yml --limit idp --tags keycloak` |
| Sauvegarder la base | `ansible idp -b -m shell -a 'sudo -u postgres pg_dump -Fc keycloak > /var/backups/keycloak_$(date +%F).dump'` |
| Mettre à jour Keycloak | `keycloak_version` dans `host_vars/idp.yml`, Pull Request, sauvegarde, puis `--tags keycloak` |

Les utilisateurs et la configuration de Keycloak ne sont **pas** dans le dépôt : sans
sauvegarde de la base, une VM recréée repart vide.

---

## 6. Dépannage

| Symptôme | Cause probable | À faire |
|---|---|---|
| `Could not resolve hostname idp` | fichier SSH absent ou nommé `config.txt` | voir section 1 |
| `ssh idp` refusé | WireGuard coupé, ou clé absente de `keys/` | activer WireGuard, vérifier sa clé dans le dépôt |
| La console ne s'ouvre pas | tunnel fermé, ou ligne absente du fichier `hosts` | relancer `ssh -N idp-console`, vérifier `hosts` |
| Redirection vers une autre adresse | port local différent de 443 | utiliser exactement `idp-console` |
| Keycloak ne démarre pas | base arrêtée, mémoire insuffisante | `journalctl -u keycloak`, `systemctl status postgresql`, `free -m` |
| `health/ready` répond `DOWN` | base injoignable | `systemctl restart postgresql`, puis `keycloak` |

La VM n'a que 1,5 Gio : si Keycloak s'arrête avec `OutOfMemoryError` dans le journal, il faut
lui donner plus de mémoire dans `group_vars/all/vms.yml` (en la retirant à une autre VM).
