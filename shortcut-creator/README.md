# Créateur de raccourcis Vigie

Crée un raccourci bureau, avec le bon logo, vers une application Vigie (Billets, Parc, Inventory ou Simulation) qui tourne sur **un autre poste du réseau**, pas besoin d'installer quoi que ce soit, juste ce script.

## Utilisation

1. Copiez `Creer-Raccourci-Vigie.bat` et `Creer-Raccourci-Vigie.ps1` (les deux fichiers, ensemble) sur le poste où vous voulez le raccourci.
2. Double-cliquez sur `Creer-Raccourci-Vigie.bat`.
3. Choisissez l'application (1 à 4).
4. Entrez l'adresse IP du poste qui héberge cette application (ex: `192.168.1.50`).
5. Le raccourci apparaît sur le Bureau, avec le logo téléchargé directement depuis le serveur.

Le port de chaque application est déjà connu du script (3500 Billets, 3501 Parc, 3502 Inventory, 3503 Simulation), inutile de le chercher.

## Notes

- Si le serveur est injoignable au moment de créer le raccourci, celui-ci est quand même créé (sans logo personnalisé), utile pour le préparer à l'avance.
- Le logo téléchargé est mis en cache dans `%LOCALAPPDATA%\VigieRaccourcis\` sur le poste où le script est exécuté.
