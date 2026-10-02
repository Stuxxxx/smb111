# PKI interne du SI

Les certificats TLS des services du SI (Keycloak aujourd'hui, l'ingress Kubernetes
demain) sont émis par une PKI propre au projet. Elle répond à l'exigence **TEC 01** :
`openssl s_client` doit montrer une chaîne de certification valide, pas un certificat
autosigné.

Tout se lance **depuis `rasb`**, dans son clone du dépôt (`cd ~/smb111`).

---

## Architecture

```
SMB111 Racine                  ECDSA P-384, 10 ans, signe l'intermédiaire et rien d'autre
  └── SMB111 Intermediaire     ECDSA P-384, 5 ans, pathlen:0 : signe des services, jamais une CA
        ├── idp.smb111.lan     ECDSA P-256, 1 an, renouvelé à 30 jours de l'échéance
        └── (cert-manager)     plus tard : ClusterIssuer de type CA avec cet intermédiaire
```

| Élément | Où | Versionné |
|---|---|---|
| Certificats des CA | `pki/racine.crt`, `pki/intermediaire.crt` | oui, en clair (publics) |
| Clés des CA | `pki/racine.key`, `pki/intermediaire.key` | oui, **chiffrées par ansible-vault** |
| Clé d'un service | `/etc/ssl/smb111/<nom>.key` sur la machine du service | non, elle n'en sort jamais |
| Certificat d'un service | `/etc/ssl/smb111/<nom>.crt` et `<nom>-chaine.crt` | non |
| Confiance | `/usr/local/share/ca-certificates/smb111-racine.crt` sur toutes les machines | — |

Pourquoi deux niveaux : la racine ne sert qu'une fois, à signer l'intermédiaire. Si la
clé de l'intermédiaire était compromise, on le remplace et on réémet les certificats,
sans toucher à la racine déjà installée partout (machines, postes, navigateurs).

Comment un certificat est émis (rôle `certificat`) :

1. la machine du service génère sa clé et une demande (CSR) ;
2. la CSR remonte à `rasb`, seul à pouvoir déchiffrer la clé de l'intermédiaire ;
3. `rasb` signe et renvoie le certificat, la machine l'enregistre avec la chaîne.

La CI refuse toute clé de `pki/` qui ne commencerait pas par `$ANSIBLE_VAULT;`
(job `pki` du workflow `gitleaks`).

---

## Mise en place (une seule fois)

### 1. Créer la PKI

Sur la branche qui introduit la PKI : sans `pki/racine.crt`, le rôle `pki` arrête
`site.yml`, il faut donc que les fichiers arrivent dans `main` avec le code.

```bash
git checkout feat/pki && git pull
ansible-playbook playbooks/pki-init.yml
```

Le playbook refuse d'écraser une PKI existante. Les clés en clair ne vivent que le temps
de l'exécution, dans un dossier temporaire supprimé à la fin.

### 2. Vérifier

```bash
openssl verify -CAfile pki/racine.crt pki/intermediaire.crt       # pki/intermediaire.crt: OK
openssl x509 -in pki/intermediaire.crt -noout -subject -issuer -enddate
head -1 pki/racine.key pki/intermediaire.key                      # $ANSIBLE_VAULT;1.1;AES256
```

### 3. Commiter et proposer

```bash
git add pki/
git commit -m "feat: création de la PKI du SI"
git push
```

### 4. Appliquer, une fois fusionné

```bash
ansible-playbook site.yml --tags pki                       # racine de confiance partout
ansible-playbook site.yml --limit idp --tags keycloak      # certificat de Keycloak
ansible-playbook site.yml --limit idp --tags keycloak      # 2e fois : changed=0
```

---

## Faire confiance à la PKI depuis son poste

Récupérer `pki/racine.crt` (dépôt GitHub), puis :

| Système | Commande |
|---|---|
| Windows | `certutil -user -addstore Root racine.crt` (magasin de l'utilisateur, sans droits admin) |
| Debian / Ubuntu | `sudo cp racine.crt /usr/local/share/ca-certificates/smb111-racine.crt && sudo update-ca-certificates` |
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain racine.crt` |
| Firefox | *Paramètres → Vie privée et sécurité → Certificats → Afficher les certificats → Autorités → Importer* |

Chrome et Edge utilisent le magasin du système.

---

## Vérifier un service

Depuis un poste de `wg0` (le DNS de `fw` résout `*.smb111.lan`) :

```bash
openssl s_client -connect idp.smb111.lan:443 -servername idp.smb111.lan \
  -CAfile pki/racine.crt -showcerts </dev/null 2>/dev/null \
  | grep -E '^ *[0-9] s:|^ *i:|Verify return code'
```

Résultat attendu : deux certificats envoyés (`idp.smb111.lan`, puis l'intermédiaire) et
`Verify return code: 0 (ok)`. C'est la capture à fournir pour TEC 01.

L'échéance de tous les certificats émis est surveillée par `playbooks/check.yml`
(contrôle `certificats`, seuil `check_certificats_jours`, 30 jours par défaut).

---

## Émettre un certificat pour un nouveau service

Dans le rôle du service, avant sa configuration TLS :

```yaml
- name: Certificat émis par la PKI du SI
  ansible.builtin.import_role:
    name: certificat
  vars:
    certificat_nom: monservice
    certificat_dns: [monservice.smb111.lan]
    certificat_groupe: monservice        # groupe qui doit pouvoir lire la clé
```

Le service pointe ensuite vers `/etc/ssl/smb111/monservice-chaine.crt` et
`/etc/ssl/smb111/monservice.key`. Pour qu'il redémarre au renouvellement, son handler
déclare `listen: certificat renouvelé` (voir `roles/keycloak/handlers/main.yml`).

Toutes les options sont décrites dans `roles/certificat/defaults/main.yml`.

---

## Renouvellement et incidents

| Situation | Action |
|---|---|
| Certificat de service à moins de 30 jours de l'échéance | `ansible-playbook site.yml --limit <machine>` : il est réémis automatiquement |
| Nom à ajouter à un certificat | modifier `certificat_dns`, relancer le rôle : réémis automatiquement |
| Clé d'un service compromise | supprimer `/etc/ssl/smb111/<nom>.*` sur la machine, relancer le rôle |
| Clé de l'intermédiaire compromise | `ansible-playbook playbooks/pki-init.yml -e regenerer=intermediaire`, commiter, puis `site.yml` sur toutes les machines |
| Mot de passe du vault compromis | changer le mot de passe du vault (`ansible-vault rekey`), puis traiter comme une compromission de l'intermédiaire |

---

## Limites assumées

- **Pas de liste de révocation (CRL) ni d'OCSP.** Un certificat de service compromis reste
  valide jusqu'à son échéance aux yeux d'un client qui l'a déjà vu. Compensation : durée
  courte (1 an) et réémission simple. À reconsidérer avec cert-manager, qui permet des
  durées de quelques jours.
- **La clé de la racine est dans le dépôt**, chiffrée. Dans une PKI d'entreprise, elle
  serait hors ligne (coffre, HSM). Ici, le compromis permet de reconstruire le SI depuis
  un `git clone` (GEN 02) ; sa protection repose sur le mot de passe du vault.
- **Pas de contrainte de noms** sur l'intermédiaire : il peut signer n'importe quel nom.
  Elle sera ajoutée quand le domaine public du projet sera fixé.
