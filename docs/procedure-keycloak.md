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
| Chemin d'administration | `rasb` → `wg1` → `fw` → `idp` (SSH uniquement) |

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
| Clé du projet dans ton compte | `ls ~/.ssh/smb111 ~/.ssh/smb111.pub` | les deux fichiers |
| Lien `wg1` vers `fw` actif | `sudo wg show wg1 latest-handshakes` | un horodatage récent |
| `fw` joignable par le lien | `ping -c2 10.10.0.1` | réponses |
| `fw` donne Internet et DNS aux VM | — | sinon Keycloak ne peut pas être téléchargé |
| Collection PostgreSQL | `ansible-galaxy collection list community.postgresql` | une version listée |

Si la clé manque :

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ansible rasb -m ansible.builtin.copy -a '{"content": "{{ vault_smb111_private_key }}", "dest": "'"$HOME"'/.ssh/smb111", "mode": "0600"}'
ssh-keygen -y -f ~/.ssh/smb111 > ~/.ssh/smb111.pub
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

Le port 443 n'est pas ouvert de `rasb` vers les VM (`fw` n'y laisse passer que SSH et l'API
Kubernetes) : la vérification se fait donc depuis la VM elle-même.

---

## 7. Accéder à la console d'administration

On passe par SSH : `rasb`, puis `idp`, et le port 443 de `idp` est ramené sur ton PC.

1. **PC (PowerShell lancé en administrateur)** — faire pointer le nom vers ton PC :

   ```powershell
   Add-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Value "127.0.0.1   idp.smb111.lan"
   ```

2. **PC (PowerShell normal)**, WireGuard actif — ouvrir le tunnel et laisser la fenêtre ouverte :

   ```powershell
   ssh -N -L 443:localhost:443 -J Orfeo@10.99.0.1 Orfeo@10.10.0.5
   ```

3. Ouvrir `https://idp.smb111.lan/admin/`, accepter l'avertissement (certificat autosigné),
   se connecter avec `admin-temp` et le mot de passe du vault.

Le port local doit être **443** : Keycloak redirige vers l'URL exacte.

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
