# PKI interne du SI

Les certificats TLS des services du SI (Keycloak aujourd'hui, l'ingress Kubernetes
demain) sont émis par une PKI propre au projet. Elle répond à l'exigence **TEC 01** :
`openssl s_client` doit montrer une chaîne de certification valide, pas un certificat
autosigné.

Tout se lance **depuis `rasb`**, dans son clone du dépôt (`cd ~/smb111`).

---

## Architecture

```
SMB111 Racine 2026                  ECDSA P-384, 10 ans, signe l'intermédiaire et rien d'autre
  └── SMB111 Intermediaire 2026     ECDSA P-384, 5 ans, pathlen:0 : signe des services, jamais une CA
        ├── idp.smb111.lan          ECDSA P-256, 1 an, renouvelé à 30 jours de l'échéance
        └── (cert-manager)          plus tard : ClusterIssuer de type CA avec cet intermédiaire
```

**Contrainte de noms.** La racine et l'intermédiaire ne peuvent certifier que
`smb111.lan` (et ses sous-domaines) et les adresses `10.10.0.0/24`. L'extension
`nameConstraints` est critique : un poste qui installe la racine ne lui accorde
aucune confiance pour `google.com` ou sa banque, même si une clé de la PKI fuitait.
Le rôle `certificat` refuse en amont tout nom hors de cette contrainte.

| Élément | Où | Versionné |
|---|---|---|
| Certificats des CA | `pki/racine.crt`, `pki/intermediaire.crt` | oui, en clair (publics) |
| Clé de l'intermédiaire | `pki/intermediaire.key` | oui, **chiffrée par ansible-vault** |
| Clé de la racine | hors de `rasb` (poste d'un responsable, gestionnaire de mots de passe), chiffrée par ansible-vault | **non** : la CI la refuse dans `pki/` |
| Clé d'un service | `/etc/ssl/smb111/<nom>.key` sur la machine du service | non, elle n'en sort jamais |
| Certificat d'un service | `/etc/ssl/smb111/<nom>.crt` et `<nom>-chaine.crt` | non |
| Confiance | `/usr/local/share/ca-certificates/smb111-racine.crt` sur toutes les machines | — |

Pourquoi deux niveaux : la racine ne sert qu'une fois, à signer l'intermédiaire. Sa clé
peut donc rester hors ligne. Si la clé de l'intermédiaire était compromise, on le remplace
(clé de la racine rapportée sur `rasb` le temps de signer) et on réémet les certificats, sans toucher à la racine déjà installée
partout (machines, postes, navigateurs). Le SI reste reconstructible depuis un
`git clone` (GEN 02) : l'émission courante n'utilise que l'intermédiaire.

Comment un certificat est émis (rôle `certificat`) :

1. la machine du service génère sa clé et une demande (CSR) ;
2. la CSR remonte à `rasb`, seul à pouvoir déchiffrer la clé de l'intermédiaire ;
3. `rasb` signe et renvoie le certificat, la machine l'enregistre avec la chaîne.

La CI refuse toute clé de `pki/` qui ne commencerait pas par `$ANSIBLE_VAULT;`, et
la présence de `pki/racine.key` (job `pki` du workflow `gitleaks`).

---

## Mise en place

### 1. Créer (ou recréer) la PKI

Depuis `rasb`, sur une branche :

```bash
ansible-playbook playbooks/pki-init.yml                    # première création
ansible-playbook playbooks/pki-init.yml -e regenerer=tout  # tout remplacer (nouvelle racine)
```

Sans `regenerer`, le playbook refuse d'écraser une PKI existante. Les clés en clair ne
vivent que le temps de l'exécution, dans un dossier temporaire supprimé à la fin. La clé
de la racine, chiffrée, est écrite dans `~/pki-racine/racine.key`, **hors du dépôt**.

### 2. Mettre la clé de la racine hors ligne

Depuis son poste, la rapatrier, puis l'effacer de `rasb` :

```bash
scp rasb:pki-racine/racine.key smb111-racine.key
ssh rasb shred -u pki-racine/racine.key
```

La ranger en pièce jointe d'un gestionnaire de mots de passe (Bitwarden, KeePass…), ou
au moins hors d'un dossier synchronisé, puis supprimer le fichier téléchargé. Elle
reste chiffrée par le vault : le fichier seul ne suffit pas à signer.

Pour la réutiliser (nouvel intermédiaire), la renvoyer au même endroit le temps de
l'opération, puis l'effacer de nouveau :

```bash
ssh rasb mkdir -m 700 -p pki-racine
scp smb111-racine.key rasb:pki-racine/racine.key
```

### 3. Vérifier

```bash
openssl verify -CAfile pki/racine.crt pki/intermediaire.crt       # pki/intermediaire.crt: OK
openssl x509 -in pki/intermediaire.crt -noout -subject -enddate -ext nameConstraints
head -1 pki/intermediaire.key                                     # $ANSIBLE_VAULT;1.1;AES256
openssl x509 -in pki/racine.crt -noout -fingerprint -sha256       # à reporter plus bas
```

### 4. Commiter et proposer

Reporter l'empreinte SHA-256 affichée par le playbook dans la section
[Télécharger l'autorité](#télécharger-lautorité-de-certification), puis :

```bash
git add -A pki/ docs/pki.md
git commit -m "feat: PKI du SI avec contrainte de noms"
git push
```

### 5. Appliquer, une fois fusionné

```bash
ansible-playbook site.yml --tags pki                       # racine de confiance partout
ansible-playbook site.yml --limit idp --tags keycloak      # certificat de Keycloak
ansible-playbook site.yml --limit idp --tags keycloak      # 2e fois : changed=0
```

Après un `regenerer=tout`, chaque poste doit aussi retirer l'ancienne racine et installer
la nouvelle (section suivante).

---

## Télécharger l'autorité de certification

Pour accéder aux services en HTTPS sans alerte, chaque poste installe **une seule fois**
la racine de la PKI :

**[Télécharger `racine.crt`](https://raw.githubusercontent.com/Stuxxxx/smb111/main/pki/racine.crt)**

Avant de l'installer, vérifier son empreinte : un certificat racine modifié en route
permettrait d'usurper les services du SI.

| Champ | Valeur |
|---|---|
| Nom | `SMB111 Racine 2026` |
| Empreinte SHA-256 | `<à reporter après pki-init.yml>` |

```bash
openssl x509 -in racine.crt -noout -fingerprint -sha256     # Linux, macOS
certutil -hashfile racine.crt SHA256                        # Windows
```

Grâce à la contrainte de noms, cette racine ne peut servir que pour `*.smb111.lan` et
`10.10.0.0/24` : l'installer ne donne aucun pouvoir sur le reste de la navigation.

| Système | Installer | Retirer l'ancienne racine (`SMB111 Racine`) |
|---|---|---|
| Windows | double-clic → *Installer le certificat* → *Utilisateur actuel* → *Autorités de certification racines de confiance*, ou `certutil -user -addstore Root racine.crt` | `certutil -user -delstore Root "SMB111 Racine"` |
| Debian / Ubuntu | `sudo cp racine.crt /usr/local/share/ca-certificates/smb111-racine.crt && sudo update-ca-certificates` | le fichier est remplacé par la commande d'installation |
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain racine.crt` | `sudo security delete-certificate -c "SMB111 Racine" /Library/Keychains/System.keychain` |
| Firefox | *Paramètres → Vie privée et sécurité → Certificats → Afficher les certificats → Autorités → Importer*, cocher « sites web » | même écran, sélectionner `SMB111 Racine` → *Supprimer* |

Chrome et Edge utilisent le magasin du système.

> **Retirer l'ancienne racine avant d'installer la nouvelle** : sous Windows et macOS, la
> suppression par nom fonctionne par sous-chaîne et emporterait aussi `SMB111 Racine 2026`.

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
| Clé de l'intermédiaire compromise | clé de la racine renvoyée sur `rasb` (étape 2), `ansible-playbook playbooks/pki-init.yml -e regenerer=intermediaire`, l'effacer, commiter, puis `site.yml` sur toutes les machines |
| Intermédiaire bientôt expiré (5 ans) | même commande que ci-dessus |
| Mot de passe du vault compromis | changer le mot de passe du vault (`ansible-vault rekey`, y compris la copie hors ligne de la clé de la racine), puis traiter comme une compromission de l'intermédiaire |
| Clé de la racine perdue | rien d'urgent tant que le mot de passe du vault est sûr ; prévoir un `regenerer=tout` avant l'expiration de l'intermédiaire |

---

## Limites assumées

- **Pas de liste de révocation (CRL) ni d'OCSP.** Un certificat de service compromis reste
  valide jusqu'à son échéance aux yeux d'un client qui l'a déjà vu. Compensation : durée
  courte (1 an) et réémission simple. À reconsidérer avec cert-manager, qui permet des
  durées de quelques jours.
- **Un seul intermédiaire.** Quand cert-manager l'utilisera, sa clé sera dans un secret
  Kubernetes. La contrainte de noms borne les dégâts d'une fuite ; un intermédiaire dédié
  au cluster permettrait en plus de le révoquer seul.
- **Première génération abandonnée.** La racine `SMB111 Racine` (sans contrainte) et sa
  clé restent dans l'historique Git, chiffrées. Elle ne doit plus être installée nulle part.
