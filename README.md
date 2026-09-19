# Vigie Billets, Vigie Parc, Vigie Inventory, Vigie Simulation et Suite Vigie : installation Windows

## Les programmes

Applications web indépendantes de C.T Informatique. Chacune a son propre `package.json`, ses propres dépendances et tourne comme un service Windows séparé.

### Vigie Billets : billetterie de support

Système de gestion des billets de service pour une équipe de support technique.

- Création, suivi et fermeture de billets (statuts : ouvert, en cours, en attente, fermé)
- Pointage automatique du temps travaillé par billet : il démarre à l'ouverture du formulaire de création, se met en pause pendant le statut "en attente" et se ferme à la fermeture du billet
- Statistiques et indicateurs de performance (KPI) : temps de résolution moyen, respect du SLA, charge active par technicien, taux de réouverture
- Niveaux de compétence technicien (N1/N2/N3), assignés par un superviseur ou un admin
- Gestion des clients et des employés, rôles (technicien / superviseur / admin) avec permissions configurables
- Messagerie interne entre employés, pièces jointes sur les billets
- Authentification à deux facteurs (TOTP), historique de connexions
- Base de connaissances de dépannage (plus de 80 solutions en français et en anglais, livrées avec le programme)
- Sauvegardes SQL automatiques et manuelles, avec choix du dossier de sauvegarde
- Rapport de billet imprimable en PDF
- Notifications courriel au client (SMTP configurable)

**Port par défaut :** 3500 · **Base de données :** `tickets_db`

### Vigie Parc : inventaire de parc informatique

Compagnon de Vigie Billets, pour le suivi du parc d'équipement d'une entreprise.

- Inventaire des actifs (appareils, statut, garantie, emplacement, personne/client assigné)
- Fournisseurs, licences logicielles et contrats de service
- Comptes employés et permissions propres à Vigie Parc (indépendants de ceux de Vigie Billets)
- Partage volontairement la base de données de Vigie Billets pour réutiliser directement les mêmes clients, sans ressaisie ni synchronisation, donc **nécessite que Vigie Billets soit installé en premier**

**Port par défaut :** 3501 · **Base de données :** `tickets_db` (partagée avec Vigie Billets)

### Vigie Inventory : inventaire générique autonome

Le même type d'inventaire que Vigie Parc, mais pensé comme produit indépendant pour n'importe quelle entreprise (pas seulement de l'informatique).

- Actifs, catégories et départements entièrement personnalisables (informatique, outils, véhicules, équipement de cuisine…)
- Champs personnalisés configurables par catégorie
- Fournisseurs, contrats, notifications
- Base de données et comptes complètement séparés, sans dépendance à Vigie Billets ni à Vigie Parc

**Port par défaut :** 3502 · **Base de données :** `vigie_inventory_db` (indépendante)

### Vigie Simulation : scénarios de formation

Outil de formation pour équipes de soutien informatique, sans lien technique avec les trois autres programmes.

- 200 scénarios de mise en situation (140 de niveau N1 simple, 60 de niveau N2 intermédiaire)
- Chaque scénario fournit une entreprise et un contact fictifs (nom, courriel, téléphone, adresse, numéro de poste) et un problème décrit du point de vue du client
- Un élève joue le client avec Vigie Simulation, un autre joue le technicien avec Vigie Billets. L'exercice se fait hors informatique (téléphone, en personne)
- **Aucune base de données, aucun compte** : les scénarios sont un fichier de données chargé au démarrage

**Port par défaut :** 3503 · **Base de données :** aucune

### Suite Vigie : icône unique

Une seule icône dans la barre système Windows pour gérer les quatre programmes (ouvrir, démarrer, redémarrer, arrêter). Elle ne contient aucun serveur ni base de données.

### Stack technique

- **Backend :** Node.js + [Express](https://expressjs.com/)
- **Base de données :** PostgreSQL pour Billets, Parc et Inventory, via le module [`pg`](https://node-postgres.com/). Requêtes SQL directes (pas d'ORM), migrations idempotentes exécutées au démarrage du serveur. Vigie Simulation n'en a pas besoin.
- **Authentification :** jetons JWT (`jsonwebtoken`), mots de passe hachés avec `bcryptjs` (sauf Vigie Simulation, sans compte)
- **Sécurité :** `helmet` (en-têtes HTTP), `express-rate-limit`, secrets (`JWT_SECRET`, `PGPASSWORD`) obligatoires via variables d'environnement pour les apps avec base de données
- **Frontend :** HTML/CSS/JavaScript "vanilla" (aucun framework), page unique (SPA) servie directement par Express
- **Déploiement :** service Windows via [NSSM](https://nssm.cc/), installateurs [Inno Setup](https://jrsoftware.org/isinfo.php) (ce dépôt)

Code source des applications : [vigie-suite](https://github.com/christisback/vigie-suite) (privé).

## Quoi télécharger

Dans la section **Releases** de ce dépôt, deux fichiers sont publiés :

- **`Suite-Vigie-Installateur-Combine.exe`** (environ 480 Mo) : l'installateur de tous les programmes. Une fenêtre permet de cocher ce que l'on veut installer, puis il lance l'installateur de chaque programme dans le bon ordre.
- **`Creer-Raccourci-Vigie.zip`** (quelques Ko) : petit outil pour créer un raccourci sur le bureau d'un autre poste du réseau (voir la dernière section).

Programmes proposés dans l'installateur combiné :

| Case à cocher | Programme | À savoir |
|---|---|---|
| Vigie Billets | Billetterie de support (port 3500) | Première installation ou mise à jour. Nécessite PostgreSQL 18 (voir l'avertissement plus bas). |
| Vigie Parc | Inventaire de parc informatique (port 3501) | Nécessite Vigie Billets, qui est coché automatiquement. |
| Vigie Inventory | Inventaire générique (port 3502) | Autonome, avec sa propre base de données. Nécessite qu'un PostgreSQL soit présent sur le poste (par exemple celui de Vigie Billets). |
| Vigie Simulation | Scénarios de formation (port 3503) | Autonome, sans base de données, installation rapide. |
| Suite Vigie | Icône unique dans la barre système | À installer en plus d'au moins un des quatre programmes, dans n'importe quel ordre. |

Chaque programme garde son propre assistant, sa propre désinstallation et son propre mode de mise à jour. Relancer le combiné sur un poste déjà installé propose de **mettre à jour**, **réinstaller** ou **désinstaller**.

## Avant d'installer sur un NOUVEAU PC : éviter le blocage de sécurité

Tous les installateurs sont signés numériquement avec le certificat de l'éditeur (**C.T Informatique**), mais ce certificat est auto-généré. Il n'est pas encore reconnu par une autorité de certification publique, donc Windows ne lui fait pas automatiquement confiance sur un PC qui ne l'a jamais vu. Sur certains PC Windows 11, une protection appelée **Smart App Control** ("Contrôle d'application intelligente") peut donc quand même bloquer complètement le lancement de l'installateur avant même qu'il ait pu installer son propre certificat dans le magasin de confiance de Windows. Voici comment vérifier et éviter ce problème **avant** de lancer l'installateur.

### Étape 1 : vérifier si c'est actif

Ouvrez PowerShell **en administrateur** et tapez :

```powershell
Get-MpComputerStatus | Select-Object SmartAppControlState
```

- **`On`** → actif, va bloquer l'installateur. Passez à l'étape 2.
- **`Eval`** → encore en mode évaluation, pas de blocage strict pour l'instant. Vous pouvez généralement installer normalement.
- **Aucun résultat / erreur** → la fonctionnalité n'existe pas sur ce PC (souvent parce que le matériel ne répond pas aux critères requis, comme le Secure Boot). Aucun blocage de ce type n'est possible ici.

### Étape 2 : si c'est `On`

**⚠️ Important à savoir avant de choisir une option : Smart App Control ne peut PAS être réactivé après coup.** Une fois désactivé, il ne peut être remis en marche qu'en réinstallant Windows au complet. Ce n'est **pas** un interrupteur temporaire comme l'antivirus. Pour cette raison, essayez d'abord l'option réversible ci-dessous.

**Option A (réversible, à essayer en premier) : désactiver temporairement la protection en temps réel de Windows Defender**
1. Sécurité Windows → Protection contre les virus et menaces → Gérer les paramètres.
2. Basculez **Protection en temps réel** sur Désactivé.
3. Lancez l'installation normalement.
4. Remettez **Protection en temps réel** sur Activé immédiatement après l'installation.

Si l'installateur passe avec cette option seule, tant mieux : Smart App Control n'était probablement pas la cause réelle du blocage.

**Option B (permanente mais irréversible) : désactiver Smart App Control**
1. `Win + R`, tapez `windowsdefender://smartappcontrol`, Entrée.
2. Basculez sur **Désactivé**.
3. Confirmez que vous comprenez que ceci est définitif pour ce PC.

## Installation

1. Double-cliquez sur `Suite-Vigie-Installateur-Combine.exe`. Une fenêtre "Contrôle de compte d'utilisateur" apparaîtra : cliquez **Oui**, l'installation nécessite les droits administrateur.
2. Cochez les programmes voulus. Cocher Vigie Parc coche automatiquement Vigie Billets.
3. Suivez l'assistant de chaque programme (langue déjà en français, dossier d'installation par défaut conseillé). Si une installation existante est détectée, l'assistant propose **Mettre à jour**, **Réinstaller** ou **Désinstaller**.
4. Prévoyez plusieurs minutes pour Vigie Billets (Node.js et PostgreSQL peuvent s'installer silencieusement en arrière-plan s'ils sont absents).
5. À la fin, chaque application s'ouvre dans le navigateur : `http://localhost:3500` (Billets), `3501` (Parc), `3502` (Inventory), `3503` (Simulation).

> ⚠️ **Poste tout neuf (sans PostgreSQL) : bug connu de l'installateur complet de Vigie Billets inclus dans le combiné.** Son installation silencieuse de PostgreSQL peut échouer avec une erreur du type *« option attendu mais contient Files\PostgreSQL\18 »* (problème de guillemets PowerShell, corrigé dans le code source, mais le gros fichier n'a pas pu être reconstruit faute d'accès au binaire PostgreSQL). **Solution :** sur un poste neuf, installez d'abord [PostgreSQL 18](https://www.postgresql.org/download/windows/) manuellement (port 5432 par défaut, mot de passe superutilisateur **`123`** pour rester cohérent avec les autres postes; sinon, définissez la variable d'environnement `PGPASSWORD_EXISTANT` sur le mot de passe choisi avant de lancer l'installateur), puis lancez le combiné. Quand PostgreSQL est déjà présent, le combiné utilise automatiquement la version légère et corrigée de l'installateur de Vigie Billets. Il affiche un avertissement si PostgreSQL est absent.

### Après l'installation de Vigie Billets

- Un fichier `IMPORTANT - Identifiants.txt` est créé dans le dossier d'installation (et copié sur le bureau) avec les mots de passe générés (PostgreSQL, secret de sécurité interne). À conserver en lieu sûr, puis à supprimer du bureau.
- Une icône apparaît dans la barre système (en bas à droite) pour gérer le serveur : clic droit pour les options (Redémarrer, Démarrer, Arrêter). Si **Suite Vigie** est aussi installée, c'est son icône unique qui est affichée, sans doublon.
- Identifiant admin par défaut : `ADMIN001` / `Admin1234!` (changement du mot de passe obligatoire à la première connexion).
- Pour l'accès depuis d'autres appareils du réseau : voir l'adresse IP réseau affichée à la fin de l'installation, ou dans le fichier récapitulatif.

### Après l'installation de Vigie Parc

Vigie Parc utilise la même base de données que Vigie Billets, mais ses propres comptes (employés, techniciens, admin).

- Un fichier `IMPORTANT - Identifiants.txt` est créé dans le dossier d'installation (et copié sur le bureau).
- Icône dans la barre système et raccourci bureau, comme pour Vigie Billets (icône unique de **Suite Vigie** si elle est installée).
- Identifiant admin par défaut : `ADMIN001` / `Admin1234!` (changement du mot de passe obligatoire à la première connexion).

### Après l'installation de Vigie Inventory

Produit autonome, avec sa propre base de données et ses propres comptes. Les catégories de matériel, les départements et les champs personnalisés se configurent dans Paramètres pour adapter l'outil au domaine de l'entreprise (informatique, outils, véhicules, équipement de cuisine…).

- Un fichier `IMPORTANT - Identifiants.txt` est créé dans le dossier d'installation (et copié sur le bureau) avec les mots de passe générés. À conserver en lieu sûr, puis à supprimer du bureau.
- Icône dans la barre système et raccourci bureau, comme pour Vigie Billets (icône unique de **Suite Vigie** si elle est installée).
- Identifiant admin par défaut : `ADMIN001` / `Admin1234!` (changement du mot de passe obligatoire à la première connexion).
- Pour adapter l'outil : Paramètres → Catégories de matériel / Départements / Champs personnalisés.

### Après l'installation de Vigie Simulation

Outil de formation indépendant : pas de base de données, pas de compte à créer. Installation rapide (environ une minute).

- Un fichier `IMPORTANT - Installation.txt` est créé dans le dossier d'installation.
- Raccourci bureau vers l'application.
- Aucun identifiant à retenir : ouvrez la page et cliquez « Piger un scénario ».

### Mises à jour et données

Une mise à jour ne supprime jamais la base de données (employés, clients, billets, pièces jointes). Avant de modifier quoi que ce soit, l'installateur :

- relit le mot de passe PostgreSQL et le secret de session du service déjà installé (les utilisateurs restent connectés),
- n'applique jamais `schema.sql` sur une base qui contient déjà des tables,
- crée une copie de sécurité `avant-mise-a-jour_....sql` dans le dossier `backups` de l'application (les 3 dernières sont gardées, visibles dans Paramètres > Données),
- remet en marche l'ancien service si la mise à jour échoue.

Les nouvelles colonnes et tables sont ajoutées automatiquement au démarrage du serveur, sans toucher aux données existantes.

## Suite Vigie : une seule icône

Suite Vigie remplace les icônes individuelles de Vigie Billets, Parc, Inventory et Simulation par **une seule icône** dans la barre système, avec un sous-menu par application (Ouvrir, Redémarrer, Démarrer, Arrêter). Elle ne contient aucun serveur ni base de données : c'est uniquement une icône de gestion.

**Elle peut s'installer avant ou après les 4 applications, dans n'importe quel ordre.**

1. Cochez Suite Vigie dans l'installateur combiné. L'installation est quasi instantanée.
2. À son démarrage, l'icône détecte automatiquement quelles applications (Billets, Parc, Inventory, Simulation) sont installées sur ce poste. Les icônes individuelles sont retirées, et celles qui démarreraient quand même s'effacent d'elles-mêmes, pour éviter les doublons.
3. Si une des 4 applications est installée ou mise à jour **après** Suite Vigie, l'icône la détecte d'elle-même dans les 5 secondes suivantes. Pas besoin de la relancer ni de redémarrer Windows.
4. Clic droit sur l'icône pour voir le sous-menu de chaque application détectée, double-clic pour ouvrir la première.
5. L'entrée « Quitter et fermer tous les serveurs » arrête aussi les serveurs, après confirmation.

### Désinstallation

Désinstaller Suite Vigie (Panneau de configuration → Applications) pose deux questions successives :

1. **« Désinstaller aussi Vigie Billets, Vigie Parc, Vigie Inventory et Vigie Simulation ? »**
   - **Oui** → tous les programmes Vigie présents sur ce poste sont désinstallés (services Windows, fichiers, icônes).
   - **Non** → seule l'icône Suite Vigie est retirée. Les programmes restent installés et fonctionnels (fin de la désinstallation, la question 2 n'apparaît pas).
2. *(seulement si Oui à la question 1)* **« Voulez-vous CONSERVER les données existantes (billets, employés, parc, inventaire) ? »**
   - **Oui (recommandé, bouton par défaut)** → les bases de données PostgreSQL (`tickets_db`, `vigie_inventory_db`) sont conservées intactes. Vous les retrouverez si vous réinstallez plus tard.
   - **Non** → les bases de données sont **définitivement supprimées**, en plus des programmes. Action irréversible.

En mode silencieux (`/VERYSILENT`), les programmes sont désinstallés mais les données sont **toujours conservées**. La suppression des données n'est jamais automatique, elle demande une confirmation à l'écran.

## Raccourcis sur les autres postes du réseau

Pour créer un raccourci bureau (avec le bon logo) vers une application qui tourne sur **un autre poste** (pas besoin d'y installer quoi que ce soit) : téléchargez `Creer-Raccourci-Vigie.zip` dans les Releases (ou voir [`shortcut-creator/`](shortcut-creator/)). Ce sont deux petits fichiers à copier sur le poste voulu (`Creer-Raccourci-Vigie.bat` et `.ps1`). On double-clique, on choisit l'application et l'adresse IP du serveur, et le raccourci se crée avec le logo téléchargé automatiquement.
