# Keycloak (VM `idp`) — installation

Comment la VM `idp` est construite, de zéro. Pour l'usage quotidien, voir
[`utilisation-idp.md`](utilisation-idp.md).

Tout se lance **depuis `rasb`**, dans le dossier du dépôt (`cd ~/smb111`).

---

## Ce qui est installé

| Élément | Détail |
|---|---|
| VM | `idp`, vmid 120, `10.10.0.5`, 1,5 Gio de mémoire (`group_vars/all/vms.yml`) |
| Logiciels | Keycloak (version dans `roles/keycloak/defaults/main.yml`), Java 21, PostgreSQL |
| Adresse | `https://idp.smb111.lan` (nom fourni par le DNS de `fw`) |
| Rôle `keycloak` | installe Keycloak et sa base |
| Rôle `keycloak_comptes` | crée le realm `smb111`, les groupes et les comptes, envoie les invitations |
| Rôle `relais_mail` (sur `fw`) | transmet les e-mails de Keycloak ([`relais-mail.md`](relais-mail.md)) |

---

## Les 6 étapes

### 1. Vérifier les prérequis

```bash
ls -l /etc/ansible/smb111                # clé des machines, partagée par le groupe admins
sudo wg show wg1 latest-handshakes       # le lien vers fw est actif
ansible-galaxy collection list 2>/dev/null | grep -E 'community.postgresql|middleware_automation.keycloak'
```

Si la clé manque : `ansible-playbook site.yml --limit rasb`.
Si une collection manque :

```bash
sudo /usr/local/bin/ansible-galaxy collection install -r requirements.yml -p /usr/share/ansible/collections
```

### 2. Les secrets du vault

```bash
ansible-vault edit group_vars/all/vault.yml
```

| Variable | Contenu |
|---|---|
| `vault_keycloak_db_password` | tiré par `openssl rand -base64 32` |
| `vault_keycloak_admin_password` | tiré par `openssl rand -base64 32` (compte de démarrage) |
| `vault_keycloak_ansible_password` | tiré par `openssl rand -base64 32` (compte d'Ansible) |
| `vault_mail_service_utilisateur`, `vault_mail_service_mdp` | le compte d'envoi des e-mails |

Les comptes des personnes ne sont **pas** dans le vault : ils se créent en ligne de
commande (voir [`utilisation-idp.md`](utilisation-idp.md)).

Ne jamais copier ces valeurs ailleurs que dans le vault.

### 3. Le relais des e-mails

```bash
ansible-playbook site.yml --limit fw --tags mail,fw
```

Puis l'envoi de test décrit dans [`relais-mail.md`](relais-mail.md).

### 4. Créer la VM

```bash
ansible-playbook playbooks/provision.yml -e cible=idp
ansible idp -m ping                      # doit répondre "pong"
```

### 5. Installer et configurer

```bash
ansible-playbook site.yml --limit idp
```

Dans l'ordre : sécurité de base, Keycloak, puis le realm, les groupes et le SMTP.
Les comptes des personnes se créent ensuite un par un, en ligne de commande
(voir [`utilisation-idp.md`](utilisation-idp.md)).

### 6. Vérifier

```bash
ansible idp -a 'systemctl is-active keycloak postgresql'    # active / active
ansible-playbook site.yml --limit idp --tags keycloak       # doit finir avec changed=0
```

Le second passage ne doit rien changer : en particulier, aucune invitation n'est renvoyée.

---

## Les comptes techniques

| Compte | Où | Rôle |
|---|---|---|
| `admin-temp` | realm `master` | créé au premier démarrage, sert uniquement à créer `ansible`, puis **supprimé automatiquement** |
| `ansible` | realm `master` | utilisé par Ansible ; console de secours `https://idp.smb111.lan/admin/` |

Les personnes n'ont **pas** de compte dans `master` : les membres du groupe `admins` du realm
`smb111` gèrent ce realm depuis sa propre console.

---

## Mettre à jour Keycloak

1. Sauvegarder la base : `ansible-playbook playbooks/sauvegarde.yml` ([`sauvegarde.md`](sauvegarde.md)).
2. Ajouter `keycloak_version: "x.y.z"` dans `host_vars/idp/main.yml`, puis Pull Request.
3. `ansible-playbook site.yml --limit idp --tags keycloak`

La base est convertie au premier démarrage de la nouvelle version, sans retour possible :
d'où la sauvegarde.

---

## Reste à faire

- Ouvrir Keycloak aux utilisateurs hors WireGuard (redirection du port 443 sur `fw`).

Fait : certificat émis par la PKI du SI ([`pki.md`](pki.md)) ; sauvegarde nocturne rapatriée
sur `rasb` ([`sauvegarde.md`](sauvegarde.md)).
