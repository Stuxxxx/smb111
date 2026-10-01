# Procédure — VM `idp` : Keycloak, fournisseur d'identité (SSO)

Keycloak centralise les comptes et l'authentification : chaque service hébergé délègue
la connexion à Keycloak via OpenID Connect au lieu de gérer ses propres mots de passe.

| Élément | Valeur |
|---|---|
| VM | `idp`, vmid **120**, `10.10.0.5`, 2 vCPU, 1,5 Gio, 20 Go (`group_vars/all/vms.yml`) |
| Logiciel | Keycloak `26.4.0` (archive officielle), OpenJDK 21, PostgreSQL local |
| URL | `https://idp.smb111.lan` — nom servi par le DNS de `fw` |
| Ports | `443` (HTTPS), `9000` (santé et métriques, local à la VM) |
| Service | `keycloak.service`, compte système `keycloak`, installé dans `/opt/keycloak` |
| Secrets (vault) | `vault_keycloak_db_password`, `vault_keycloak_admin_password` |
| Chemin d'administration | SSH : rebond `rasb` → `wg1` → `fw` → `idp` ; console web : 443 depuis `wg0` |

Les commandes sont à lancer **sur `rasb`** (bash), sauf celles marquées **PC (PowerShell)**.

---

## 0. L'URL

`keycloak_hostname` est inscrit dans chaque jeton émis (champ `iss`) : le changer plus tard
oblige à reconfigurer tous les services branchés sur le SSO.

Par défaut : `https://idp.smb111.lan`. Le DNS de `fw` publie déjà `idp.smb111.lan` pour les
VM internes (enregistrement déduit de `vms.yml`), il n'y a donc rien à créer.

---

## 1. Prérequis

| Vérification | Commande | Attendu |
|---|---|---|
| Clé du projet (partagée, groupe `admins`) | `ls -l /etc/ansible/smb111 /etc/ansible/smb111.pub` | les deux fichiers, `root admins` |
| Lien `wg1` vers `fw` actif | `sudo wg show wg1 latest-handshakes` | un horodatage récent |
| `fw` joignable par le lien | `ping -c2 10.10.0.1` | réponses |
| `fw` donne Internet et DNS aux VM | — | sinon Keycloak ne peut pas être téléchargé |
| Collection PostgreSQL | `ansible-galaxy collection list community.postgresql` | une version listée |

Si la clé manque, le rôle `admin` la pose depuis le vault (aucune copie dans les comptes
personnels) :

```bash
ansible-playbook site.yml --limit rasb
```

Si la collection manque :

```bash
sudo ANSIBLE_COLLECTIONS_PATH=/usr/share/ansible/collections \
  /usr/local/bin/ansible-galaxy collection install community.postgresql -p /usr/share/ansible/collections
```

---

## 2. Les fichiers concernés

```bash
cd ~/smb111
git switch main && git pull
```

| Fichier | Rôle |
|---|---|
| `roles/keycloak/` | PostgreSQL, Java, Keycloak, certificat, service systemd |
| `site.yml` | play `hosts: idp` avec le rôle `keycloak` (tag `keycloak`) |
| `inventory.ini` | `idp` ajouté au groupe `[interne]` (joint par `wg1`) |
| `host_vars/idp.yml` | URL, comptes autorisés pour `check.yml` |
| `requirements.yml` | ajout de `community.postgresql` |

---

## 3. Secrets

```bash
openssl rand -base64 32     # base de données
openssl rand -base64 32     # administrateur temporaire
ansible-vault edit group_vars/all/vault.yml
```

```yaml
vault_keycloak_db_password: "<premier mot de passe>"
vault_keycloak_admin_password: "<second mot de passe>"
```

---

## 4. Créer la VM

```bash
ansible-playbook playbooks/provision.yml -e cible=idp
ansible idp -m ping
```

**Mémoire** : `idp` a 1,5 Gio, et le budget des VM (`pve_memoire_max_vms`, 12 800 Mio) est
entièrement réparti. Keycloak est réglé pour tenir (`keycloak_java_heap`, 40 % de la RAM),
ce qui suffit pour un realm et quelques services. Lui donner plus impose de retirer la même
quantité à une autre VM dans `vms.yml` : `provision.yml` refuse tout dépassement.

---

## 5. Configurer la VM

```bash
ansible-playbook site.yml --limit idp --check --diff   # à blanc
ansible-playbook site.yml --limit idp
```

Socle commun, compte `ansible` restreint à `rasb`, comptes administrateurs, puis Keycloak.
Le rôle se termine en attendant que Keycloak soit prêt (jusqu'à 5 min).

Les passages suivants, pour ne rejouer que Keycloak :

```bash
ansible-playbook site.yml --limit idp --tags keycloak
```

---

## 6. Vérifier

```bash
ansible idp -a 'systemctl is-active keycloak postgresql'
ansible idp -b -a 'journalctl -u keycloak -n 50 --no-pager'
ansible idp -b -m ansible.builtin.uri -a 'url=https://localhost:9000/health/ready validate_certs=false'
ansible-playbook playbooks/check.yml --limit idp
```

`rasb` lui-même n'atteint pas le port 443 des VM (`fw` ne lui ouvre que SSH et l'API
Kubernetes ; le 443 n'est ouvert qu'aux postes de `wg0`) : la vérification se fait donc depuis la VM elle-même.

---

## 7. Accéder à la console d'administration

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
dans le fichier hosts (à retirer ensuite), puis `ssh -N -L 443:localhost:443 -J Orfeo@192.168.1.90 Orfeo@10.10.0.5`
(ou `ssh -N idp-console`), fenêtre laissée ouverte.

Se connecter avec `admin-temp` et le mot de passe du vault.

---

## 8. Premiers réglages dans Keycloak

1. **Administrateur permanent** — realm `master` → *Users → Add user* (ex. `admin-orfeo`),
   *Credentials* → mot de passe, *Role mapping* → rôle `admin`. Se reconnecter avec ce
   compte, puis **supprimer `admin-temp`**.
2. **Realm du projet** — *Create realm* → `smb111`. Utilisateurs et services vont **dans
   ce realm**, jamais dans `master`.
3. **Sécurité du realm `smb111`** :
   - *Authentication → Policies → Password policy* : longueur minimale 12 ;
   - *Authentication → Required actions* : *Configure OTP* activé ;
   - *Realm settings → Security defenses → Brute force detection* : activée.
4. **Groupes** `admins` et `utilisateurs`, puis un compte par personne.

---

## 9. Brancher un service sur le SSO

Realm `smb111` → *Clients → Create client* :

| Champ | Valeur |
|---|---|
| Client type | OpenID Connect |
| Client ID | nom du service (ex. `grafana`) |
| Client authentication | **On** |
| Valid redirect URIs | l'URL de retour exacte du service, jamais `*` |
| Web origins | `+` |

Le **client secret** (onglet *Credentials*) va dans le vault (`vault_<service>_oidc_secret`).
Pour transmettre les groupes : *Client scopes → <client>-dedicated → Add mapper → Group
Membership*, claim `groups`, *Full group path* décoché.

| Paramètre à donner au service | Valeur |
|---|---|
| Issuer | `https://idp.smb111.lan/realms/smb111` |
| Scopes | `openid profile email` |

Les services internes résolvent `idp.smb111.lan` par le DNS de `fw`. Tant que le certificat
est autosigné, ils doivent faire confiance à `/etc/keycloak/tls.crt`.

---

## 10. Exploitation

| Besoin | Commande |
|---|---|
| Journaux | `ansible idp -b -a 'journalctl -u keycloak -n 100 --no-pager'` |
| Redémarrer | `ansible idp -b -a 'systemctl restart keycloak'` |
| Mettre à jour | `keycloak_version` dans `host_vars/idp.yml`, PR, puis `--tags keycloak` |
| Sauvegarder | `ansible idp -b -m shell -a 'sudo -u postgres pg_dump -Fc keycloak > /var/backups/keycloak_$(date +%F).dump'` |

Toujours sauvegarder avant une mise à jour : la base est migrée au premier démarrage de la
nouvelle version, sans retour arrière.

---

## 11. Reste à faire

- **Exposition aux utilisateurs** : redirection du 443 sur `fw` (DNAT) vers `10.10.0.5`.
- **Certificat** : remplacer l'autosigné par un certificat de la PKI du projet.
- **Configuration en code** : realm, groupes et clients avec les modules `community.general.keycloak_*`.
- **Sauvegardes** : `pg_dump` programmé et copié hors de la VM.
