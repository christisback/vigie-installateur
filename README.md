# Vigie Billets, Vigie Parc, Vigie Inventory, Vigie Simulation & Suite Vigie  Installation Windows

## Les programmes

Applications web indépendantes de C.T Informatique. Chacune a son propre `package.json`, ses propres dépendances et tourne comme un service Windows séparé.

### Vigie Billets  Billetterie de support

Système de gestion des billets de service pour une équipe de support technique.

- Création, suivi et fermeture de billets (statuts : ouvert, en cours, en attente, fermé)
- Pointage automatique du temps travaillé par billet  démarre à l'ouverture du formulaire de création, se met en pause pendant le statut "en attente", se ferme à la fermeture du billet
- Statistiques et indicateurs de performance (KPI) : temps de résolution moyen, respect du SLA, charge active par technicien, taux de réouverture
- Niveaux de compétence technicien (N1/N2/N3), assignés par un superviseur ou un admin
- Gestion des clients et des employés, rôles (technicien / superviseur / admin) avec permissions configurables
- Messagerie interne entre employés, pièces jointes sur les billets
- Authentification à deux facteurs (TOTP), historique de connexions
- Sauvegardes SQL automatiques et manuelles
- Notifications courriel au client (SMTP configurable)

**Port par défaut :** 3500 · **Base de données :** `tickets_db`

### Vigie Parc  Inventaire de parc informatique

Compagnon de Vigie Billets, pour le suivi du parc d'équipement d'une entreprise.

- Inventaire des actifs (appareils, statut, garantie, emplacement, personne/client assigné)
- Fournisseurs, licences logicielles et contrats de service
- Comptes employés et permissions propres à Vigie Parc (indépendants de ceux de Vigie Billets)
- Partage volontairement la base de données de Vigie Billets pour réutiliser directement les mêmes clients, sans ressaisie ni synchronisation  **nécessite donc que Vigie Billets soit installé en premier**

**Port par défaut :** 3501 · **Base de données :** `tickets_db` (partagée avec Vigie Billets)

### Vigie Inventory  Inventaire générique autonome

Le même type d'inventaire que Vigie Parc, mais pensé comme produit indépendant pour n'importe quelle entreprise (pas seulement de l'informatique).

- Actifs, catégories et départements entièrement personnalisables (informatique, outils, véhicules, équipement de cuisine…)
- Champs personnalisés configurables par catégorie
- Fournisseurs, contrats, notifications
- Base de données et comptes complètement séparés - aucune dépendance à Vigie Billets ni Vigie Parc

**Port par défaut :** 3502 · **Base de données :** `vigie_inventory_db` (indépendante)

### Vigie Simulation  Scénarios de formation

Outil de formation pour équipes de soutien informatique - aucun lien technique avec les trois autres programmes.

- 200 scénarios de mise en situation (140 niveau N1 simple, 60 niveau N2 intermédiaire)
- Chaque scénario fournit une entreprise et un contact fictifs (nom, courriel, téléphone, adresse, numéro de poste) et un problème décrit du point de vue du client
- Un élève joue le client avec Vigie Simulation, un autre joue le technicien avec Vigie Billets  exercice mené hors informatique (téléphone, en personne)
- **Aucune base de données, aucun compte**  les scénarios sont un fichier de données chargé au démarrage

**Port par défaut :** 3503 · **Base de données :** aucune

### Stack technique

- **Backend :** Node.js + [Express](https://expressjs.com/)
- **Base de données :** PostgreSQL pour Billets/Parc/Inventory, via le module [`pg`](https://node-postgres.com/) - requêtes SQL directes (pas d'ORM), migrations idempotentes exécutées au démarrage du serveur. Vigie Simulation n'en a pas besoin.
- **Authentification :** jetons JWT (`jsonwebtoken`), mots de passe hachés avec `bcryptjs` (sauf Vigie Simulation, sans compte)
- **Sécurité :** `helmet` (en-têtes HTTP), `express-rate-limit`, secrets (`JWT_SECRET`, `PGPASSWORD`) obligatoires via variables d'environnement pour les apps avec base de données
- **Frontend :** HTML/CSS/JavaScript "vanilla" (aucun framework), page unique (SPA) servie directement par Express
- **Déploiement :** service Windows via [NSSM](https://nssm.cc/), installateurs [Inno Setup](https://jrsoftware.org/isinfo.php) (ce dépôt)

Code source des applications : [vigie-suite](https://github.com/christisback/vigie-suite) (privé).

## Quel fichier utiliser

**Suite Vigie** (icône unifiée dans la barre système pour les 4 apps  voir sa propre section plus bas) :
- `Vigie-Suite-Installateur.exe` (~2 Mo)  à installer **en plus** d'au moins une des 4 apps ci-dessous, dans n'importe quel ordre.

**Vigie Billets** (billetterie de support, indépendant) :
- **Première installation** sur un nouveau PC → `Vigie-Billets-Installateur.exe` (~420 Mo, tout-en-un hors-ligne : inclut Node.js et PostgreSQL).
- **Mise à jour** d'une installation existante → `Vigie-Billets-MiseAJour.exe` (~4 Mo, rapide, suppose que Node.js/PostgreSQL sont déjà installés).

**Vigie Parc** (inventaire de parc informatique, compagnon de Vigie Billets  voir sa propre section plus bas) :
- `Vigie-Parc-Installateur.exe` (~4 Mo)  **nécessite que Vigie Billets soit déjà installé** sur le même poste (il réutilise son Node.js, son PostgreSQL et sa base de données).

**Vigie Inventory** (inventaire de matériel générique, pour n'importe quelle entreprise  voir sa propre section plus bas)  **aucune dépendance de code** à Vigie Billets ni à Vigie Parc, mais **nécessite qu'une instance PostgreSQL soit déjà présente sur le poste** (via Vigie Billets, par exemple) :
- `Vigie-Inventory-Installateur.exe` (~36 Mo) - inclut Node.js, mais pas PostgreSQL. Installez Vigie Billets d'abord si PostgreSQL n'est pas déjà sur ce poste.
- `Vigie-Inventory-MiseAJour.exe` - identique à l'installateur ci-dessus (même détection de Node.js/PostgreSQL déjà présents), gardé sous ce nom pour compatibilité avec `VigieTout-MiseAJour.exe`.

**Vigie Simulation** (scénarios de formation, indépendant  voir sa propre section plus bas) :
- `Vigie-Simulation-Installateur.exe` (~35 Mo)  sert à la fois pour la première installation et les mises à jour (pas besoin de PostgreSQL, donc pas de gros installateur séparé).

## Avant d'installer sur un NOUVEAU PC : éviter le blocage de sécurité

Tous les installateurs sont signés numériquement avec le certificat de l'éditeur (**C.T Informatique**), mais ce certificat est auto-généré - il n'est pas encore reconnu par une autorité de certification publique, donc Windows ne lui fait pas automatiquement confiance sur un PC qui ne l'a jamais vu. Sur certains PC Windows 11, une protection appelée **Smart App Control** ("Contrôle d'application intelligente") peut donc quand même bloquer complètement le lancement de l'installateur avant même qu'il ait pu installer son propre certificat dans le magasin de confiance de Windows. Voici comment vérifier et éviter ce problème **avant** de lancer l'installateur.

### Étape 1 - Vérifier si c'est actif

Ouvrez PowerShell **en administrateur** et tapez :

```powershell
Get-MpComputerStatus | Select-Object SmartAppControlState
```

- **`On`** → actif, va bloquer l'installateur. Passez à l'étape 2.
- **`Eval`** → encore en mode évaluation, pas de blocage strict pour l'instant. Vous pouvez généralement installer normalement.
- **Aucun résultat / erreur** → la fonctionnalité n'existe pas sur ce PC (souvent parce que le matériel ne répond pas aux critères requis, comme le Secure Boot). Aucun blocage de ce type n'est possible ici.

### Étape 2 - Si c'est `On`

**⚠️ Important à savoir avant de choisir une option : Smart App Control ne peut PAS être réactivé après coup.** Une fois désactivé, il ne peut être remis en marche qu'en réinstallant Windows au complet - ce n'est **pas** un interrupteur temporaire comme l'antivirus. Pour cette raison, essayez d'abord l'option réversible ci-dessous.

**Option A  Réversible (à essayer en premier) : désactiver temporairement la protection en temps réel de Windows Defender**
1. Sécurité Windows → Protection contre les virus et menaces → Gérer les paramètres.
2. Basculez **Protection en temps réel** sur Désactivé.
3. Installez Vigie Billets normalement.
4. Remettez **Protection en temps réel** sur Activé immédiatement après l'installation.

Si l'installateur passe avec cette option seule, tant mieux  Smart App Control n'était probablement pas la cause réelle du blocage.

**Option B  Permanente mais irréversible : désactiver Smart App Control**
1. `Win + R`, tapez `windowsdefender://smartappcontrol`, Entrée.
2. Basculez sur **Désactivé**.
3. Confirmez que vous comprenez que ceci est définitif pour ce PC.

## Installation  Vigie Billets

1. Double-cliquez sur le fichier `.exe` choisi ci-dessus (une fenêtre "Contrôle de compte d'utilisateur" apparaîtra - cliquez **Oui**, l'installation nécessite les droits administrateur).
2. Suivez l'assistant (langue déjà en français, choix du dossier d'installation - laissez la valeur par défaut sauf raison particulière).
3. Si une installation existante est détectée, l'assistant propose **Mettre à jour**, **Réinstaller** ou **Désinstaller**  choisissez selon le cas.
4. L'installation peut prendre plusieurs minutes (Node.js et PostgreSQL s'installent silencieusement en arrière-plan si absents).
5. Une fois terminé, l'application s'ouvre automatiquement dans le navigateur à `http://localhost:3500`.

> ⚠️ **Poste tout neuf (sans PostgreSQL) - bug connu de `Vigie-Billets-Installateur.exe`** : l'installation silencieuse de PostgreSQL par ce fichier échoue actuellement avec une erreur du type *« option attendu mais contient Files\PostgreSQL\18 »* (bug de citation PowerShell - corrigé dans le code source, mais le fichier `.exe` de 420 Mo n'a pas pu être reconstruit ici, faute d'accès au binaire PostgreSQL). **Solution en attendant** : sur un poste neuf, installez [PostgreSQL 18](https://www.postgresql.org/download/windows/) manuellement d'abord (port 5432 par défaut, mot de passe superutilisateur **`123`** pour rester cohérent avec les autres postes - sinon définissez la variable d'environnement `PGPASSWORD_EXISTANT` sur le mot de passe choisi avant de lancer l'installateur), puis lancez `Vigie-Billets-MiseAJour.exe` à la place - il détecte PostgreSQL déjà présent et ne touche jamais au code concerné par ce bug.

### Après l'installation

- Un fichier `IMPORTANT  Identifiants.txt` est créé dans le dossier d'installation (et copié sur le bureau) avec les mots de passe générés (PostgreSQL, secret de sécurité interne)  à conserver en lieu sûr, puis à supprimer du bureau.
- Une icône apparaît dans la barre des tâches (barre système, en bas à droite) pour redémarrer le serveur facilement  clic droit dessus pour les options (Redémarrer / Démarrer / Arrêter). Si **Suite Vigie** est aussi installée, c'est son icône unifiée qui prend le relais automatiquement (voir plus bas) au lieu d'une icône dédiée à Vigie Billets.
- Identifiant admin par défaut : `ADMIN001` / `Admin1234!` (changement du mot de passe obligatoire à la première connexion).
- Pour l'accès depuis d'autres appareils sur le réseau : voir l'adresse IP réseau affichée à la fin de l'installation, ou dans le fichier récapitulatif.

## Installation  Vigie Parc

Vigie Parc est un compagnon de Vigie Billets pour l'inventaire de parc informatique (appareils, licences, fournisseurs, contrats). Il a ses propres comptes employés/techniciens/admin (indépendants de Vigie Billets) mais réutilise la même base de données PostgreSQL.

**Prérequis : Vigie Billets doit déjà être installé sur ce poste** (Node.js, PostgreSQL et la base `tickets_db` doivent exister)  l'installateur de Vigie Parc s'arrête proprement avec un message clair si ce n'est pas le cas, plutôt que de tout réinstaller en double.

1. Double-cliquez sur `Vigie-Parc-Installateur.exe` (droits administrateur requis, comme pour Vigie Billets).
2. Suivez l'assistant  même principe que Vigie Billets (Mettre à jour / Réinstaller / Désinstaller si une version existe déjà).
3. Une fois terminé, l'application s'ouvre automatiquement à `http://localhost:3501`.

### Après l'installation

- Un fichier `IMPORTANT  Identifiants.txt` est créé dans le dossier d'installation (et copié sur le bureau).
- Icône dans la barre système (Redémarrer / Démarrer / Arrêter), raccourci bureau, comme pour Vigie Billets - reprise par **Suite Vigie** si elle est installée.
- Identifiant admin par défaut : `ADMIN001` / `Admin1234!` (changement du mot de passe obligatoire à la première connexion).

## Installation  Vigie Inventory

Vigie Inventory est un inventaire de matériel générique destiné à n'importe quelle entreprise (articles, licences, fournisseurs, contrats) - **produit autonome**, avec sa propre base de données et ses propres comptes, sans aucun lien avec Vigie Billets ou Vigie Parc. Les catégories de matériel, les départements et des champs personnalisés se configurent dans Paramètres pour adapter l'outil au domaine de l'entreprise (informatique, outils, véhicules, équipement de cuisine…).

1. Double-cliquez sur le fichier `.exe` choisi ci-dessus (droits administrateur requis).
2. Suivez l'assistant  même principe que Vigie Billets (Mettre à jour / Réinstaller / Désinstaller si une version existe déjà).
3. Avec l'installateur complet, l'installation peut prendre plusieurs minutes (Node.js et PostgreSQL s'installent silencieusement en arrière-plan si absents  comme pour Vigie Billets, aucun autre logiciel Vigie n'est requis).
4. Une fois terminé, l'application s'ouvre automatiquement à `http://localhost:3502`.

### Après l'installation

- Un fichier `IMPORTANT  Identifiants.txt` est créé dans le dossier d'installation (et copié sur le bureau) avec les mots de passe générés (PostgreSQL, secret de sécurité interne)  à conserver en lieu sûr, puis à supprimer du bureau.
- Icône dans la barre système (Redémarrer / Démarrer / Arrêter), raccourci bureau, comme pour Vigie Billets  reprise par **Suite Vigie** si elle est installée.
- Identifiant admin par défaut : `ADMIN001` / `Admin1234!` (changement du mot de passe obligatoire à la première connexion).
- Pour adapter l'outil : Paramètres → Catégories de matériel / Départements / Champs personnalisés.

## Installation  Vigie Simulation

Vigie Simulation est un outil de formation indépendant  pas de base de données, pas de compte à créer.

1. Double-cliquez sur `Vigie-Simulation-Installateur.exe` (droits administrateur requis). Installation rapide (~1 minute, pas de PostgreSQL à installer).
2. Suivez l'assistant - même principe que les autres (Node.js s'installe silencieusement si absent).
3. Une fois terminé, l'application s'ouvre automatiquement à `http://localhost:3503`.

### Après l'installation

- Un fichier `IMPORTANT  Installation.txt` est créé dans le dossier d'installation.
- Raccourci bureau vers l'application.
- Aucun identifiant à retenir  ouvrez la page et cliquez « Piger un scénario ».

## Installation  Suite Vigie

Suite Vigie remplace les icônes individuelles de Vigie Billets / Parc / Inventory / Simulation par **une seule icône** dans la barre système, avec un sous-menu par application (Ouvrir / Redémarrer / Démarrer / Arrêter). Elle ne contient aucun serveur ni base de données - c'est uniquement une icône de gestion.

**Peut s'installer avant ou après les 4 apps, dans n'importe quel ordre.**

1. Double-cliquez sur `Vigie-Suite-Installateur.exe` (droits administrateur requis). Installation quasi instantanée.
2. L'icône détecte automatiquement, à son démarrage, quelles applications (Billets / Parc / Inventory / Simulation) sont installées sur ce poste - les icônes individuelles existantes sont retirées pour éviter les doublons.
3. Si une des 4 apps est installée ou mise à jour **après** Suite Vigie, l'icône la détecte d'elle-même dans les 5 secondes suivantes (vérification périodique) - pas besoin de la relancer ni de redémarrer Windows.
4. Clic droit sur l'icône pour voir le sous-menu de chaque application détectée ; double-clic pour ouvrir la première.

### Désinstallation

Désinstaller Suite Vigie (Panneau de configuration → Applications) pose deux questions successives :

1. **« Désinstaller aussi Vigie Billets, Vigie Parc, Vigie Inventory et Vigie Simulation ? »**
   - **Oui** → tous les programmes Vigie présents sur ce poste sont désinstallés (services Windows, fichiers, icônes).
   - **Non** → seule l'icône Suite Vigie est retirée ; les programmes restent installés et fonctionnels (fin de la désinstallation, la question 2 n'apparaît pas).
2. *(seulement si Oui à la question 1)* **« Voulez-vous CONSERVER les données existantes (billets, employés, parc, inventaire) ? »**
   - **Oui (recommandé, bouton par défaut)** → les bases de données PostgreSQL (`tickets_db`, `vigie_inventory_db`) sont conservées intactes ; vous les retrouverez si vous réinstallez plus tard.
   - **Non** → les bases de données sont **définitivement supprimées**, en plus des programmes. Action irréversible.

En mode silencieux (`/VERYSILENT`), les programmes sont désinstallés mais les données sont **toujours conservées** - la suppression des données n'est jamais automatique, elle demande une confirmation à l'écran.

## Raccourcis sur les autres postes du réseau

Pour créer un raccourci bureau (avec le bon logo) vers une application qui tourne sur **un autre poste** (pas besoin d'y installer quoi que ce soit) : voir [`shortcut-creator/`](shortcut-creator/)  deux petits fichiers à copier sur le poste voulu (`Creer-Raccourci-Vigie.bat` + `.ps1`), on double-clique, on choisit l'application et l'adresse IP du serveur, et le raccourci se crée avec le logo téléchargé automatiquement.
