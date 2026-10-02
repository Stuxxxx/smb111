# Sauvegarde et restauration

L'état persistant du SI est sauvegardé chaque nuit et **rapatrié sur `rasb`**. Aujourd'hui :
la base de Keycloak (comptes, groupes, double authentification). L'application du cluster
viendra s'ajouter au même mécanisme.

Tout se lance **depuis `rasb`**, dans son clone du dépôt (`cd ~/smb111`).

---

## Principe

```
02:00  sauvegarde.timer (rasb)
         └─ playbooks/sauvegarde.yml
              ├─ sur idp : pg_dump de la base keycloak, vérifié par pg_restore --list
              ├─ copie rapatriée sur rasb : /var/backups/smb111/idp/
              └─ conservation : 3 jours sur idp, 30 jours sur rasb (7 plus récentes toujours gardées)
06:00  check.yml : alerte si aucune sauvegarde de moins de 26 h
```

**Pourquoi `rasb` vient chercher la sauvegarde, et non l'inverse :**

- le pare-feu interdit aux VM de joindre le réseau local : une VM compromise ne peut ni lire
  ni effacer les sauvegardes ;
- `rasb` est hors de l'hyperviseur : la copie survit à la perte de la VM, du disque de `pve`, ou
  de `pve` entier.

Le nom du fichier porte la date et la **version de Keycloak** :
`keycloak_2026-10-03_020112_26.4.0.dump`. Une base ne se restaure que sous la même version :
Keycloak la migre au démarrage, sans retour possible.

| Où | Dossier | Droits |
|---|---|---|
| `idp` | `/var/backups/keycloak/` | `postgres`, 0700 |
| `rasb` | `/var/backups/smb111/idp/` | groupe `admins`, fichiers 0640 |

Les réglages (durées de conservation) sont dans `group_vars/all/sauvegarde.yml`.

---

## Sauvegarder à la demande

Avant toute intervention lourde (mise à jour de Keycloak, test de restauration) :

```bash
ansible-playbook playbooks/sauvegarde.yml
ls -lh /var/backups/smb111/idp/
```

## Restaurer

```bash
ansible-playbook playbooks/restauration.yml                     # liste les sauvegardes disponibles
ansible-playbook playbooks/restauration.yml -e fichier=keycloak_2026-10-03_020112_26.4.0.dump
```

Le playbook :

1. vérifie que la sauvegarde existe et vient de la **même version** de Keycloak ;
2. demande de taper `oui` (`-e confirmer=oui` pour s'en passer, en démonstration) ;
3. fait une **sauvegarde de sécurité** de l'état actuel (`…_avant-restauration.dump`) ;
4. arrête Keycloak, restaure la base **en une seule transaction** (une erreur laisse la base
   intacte), redémarre Keycloak et attend qu'il soit prêt ;
5. prévient les administrateurs par e-mail.

Keycloak est indisponible une à deux minutes. Les comptes créés depuis la sauvegarde sont perdus.

### Démonstration (soutenance)

```bash
ansible-playbook playbooks/sauvegarde.yml
ansible-playbook site.yml --limit idp --tags comptes -e "nom=demo email=<adresse> groupes=utilisateurs"
ansible-playbook site.yml --limit idp --tags comptes -e "diag=true"        # demo existe
ansible-playbook playbooks/restauration.yml -e fichier=<sauvegarde d'avant> -e confirmer=oui
ansible-playbook site.yml --limit idp --tags comptes -e "diag=true"        # demo a disparu
```

---

## Surveillance

| Quoi | Comment |
|---|---|
| La sauvegarde échoue | `sauvegarde.service` en échec → e-mail aux admins ([`notifications.md`](notifications.md)) |
| Elle ne tourne plus du tout | `check.yml`, contrôle `sauvegarde` : KO si rien de moins de 26 h → e-mail |
| Le timer est désactivé | `check.yml`, contrôle `timers` |

```bash
systemctl list-timers sauvegarde.timer --no-pager
journalctl -u sauvegarde.service -n 30 --no-pager
```

---

## Limites

- Les sauvegardes sur `rasb` ne sont **pas chiffrées** : elles contiennent les empreintes des
  mots de passe et les secrets de double authentification. Elles sont réservées au groupe
  `admins`, qui a de toute façon accès au vault. Piste : chiffrement `age` avec la clé publique
  d'un responsable.
- Pas de copie **hors de la maison** : un sinistre qui touche à la fois `pve` et `rasb` emporte
  tout. Piste : disque USB sur `rasb`, ou stockage distant.
