# Relais de messagerie (sur `fw`)

## C'est quoi ?

Keycloak envoie des e-mails (invitations, mot de passe oublié). Il les dépose sur `fw`, qui
les **transmet à un service d'envoi reconnu** (Gmail), seul capable de les faire arriver
dans les vraies boîtes mail.

```
idp (Keycloak) ──port 25──▶ fw (Postfix) ──chiffré──▶ Gmail ──▶ boîte de la personne
```

Pourquoi ne pas envoyer directement depuis `fw` ? Gmail et Outlook refusent les mails venant
d'une connexion de particulier : pas de nom de domaine public, port 25 bloqué par la box,
adresse IP sur liste noire.

Seules les VM internes peuvent déposer un mail sur `fw` : le relais n'écoute pas sur le
réseau local.

---

## Mise en place (une fois)

### 1. Le compte d'envoi

Un compte Gmail **dédié au projet** (pas un compte personnel) :

1. activer la validation en deux étapes du compte ;
2. créer un **mot de passe d'application** : *Compte Google → Sécurité → Mots de passe
   des applications*. Il fait 16 lettres.

### 2. Le vault

```bash
ansible-vault edit group_vars/all/vault.yml
```

```yaml
vault_mail_service_utilisateur: "adresse-du-compte@gmail.com"
vault_mail_service_mdp: "le mot de passe d'application"
```

### 3. Appliquer

```bash
ansible-playbook site.yml --limit fw --tags mail,fw
```

---

## Tester

Envoyer un mail de test depuis `fw` (remplacer l'adresse par la tienne) :

```bash
ansible fw -b -m shell -a "printf 'Subject: Test SMB111\n\nLe relais fonctionne.\n' | sendmail ton.adresse@exemple.org"
```

Voir ce qu'il s'est passé :

```bash
ansible fw -b -a "journalctl -t postfix/smtp -n 20 --no-pager"
```

| Dans le journal | Signification |
|---|---|
| `status=sent` | parti, vérifier la boîte (et les spams) |
| `Authentication failed` / `535` | mauvais identifiants : revoir le vault |
| `Connection timed out` | `fw` ne joint pas Gmail (réseau) |
| `status=deferred` | nouvel essai automatique plus tard ; lire la raison sur la ligne |

---

## Changer de service d'envoi

Modifier `mail_service_hote` et `mail_service_port` dans `group_vars/all/mail.yml` (par
exemple un serveur de l'école ou Brevo), mettre les identifiants dans le vault, puis
réappliquer.
