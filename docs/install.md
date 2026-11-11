# Install Grassfield / Installer Grassfield

PUBLISHED, BETA ONLY (ADR-0043 h, owner decisions of 2026-11-04 and 2026-11-05). The repository is at
https://packages.grassfield.site with signing key E4921A382C349308BAA50D2F44C31B5D862EBEFA. Since 2026-11-05 the official
site's Download page gives this installation (commands, requirements, the key's fingerprint and the script's checksum, an
independent copy of the host's .sha256); the site stays noindex and the legal review stays mandatory before any public
announcement. The only channel is beta (its latest release candidate; the script installs from it by default and refuses `--channel stable`
while stable is empty). The checksum below is for the script rendered from the current `repository.conf` and `VERSION`
(`just render-install`; recompute it with `sha256sum` after any change to the template, the conf or VERSION, and update the
site's copy with it). Publié en bêta : la page Télécharger du site donne l'installation depuis le 2026-11-05 ; le site reste
noindex et la revue juridique précède toute annonce.

---

## English

Grassfield is a desktop session for **Omarchy 4.0.6 or newer** (Arch Linux, x86_64). Installing it does not remove Omarchy: you
choose which one starts at login, and you can go back at any time.

### Before you start
- A working Omarchy 4.0.6+ with about 4 GiB free, and `pacman-contrib`. If updates are waiting, the script says how many and asks "Install them now? [Y/n]" (`--yes` answers yes): it then runs Omarchy's own update and goes on; answer no and it stops, changing nothing.
- An administrator account (the script asks for your password with `sudo`).
- Omarchy's snapshots are used if they are set up: the script takes one before it changes anything, and stops if it fails.

### Install
Open a terminal in Omarchy. Do not use `sudo` yourself. One line:
```bash
curl -fsSL https://packages.grassfield.site/install/grassfield-install.sh | bash
```
Or, to look at the script and check it first (download, check, run):
```bash
curl -fsSLO https://packages.grassfield.site/install/grassfield-install.sh
curl -fsSLO https://packages.grassfield.site/install/grassfield-install.sh.sha256
sha256sum -c grassfield-install.sh.sha256 && bash grassfield-install.sh
```
Checksum: `SHA256: c395efb528b93bcc0ea2f6a43d1fed8bba7ae4d364ce62bc4e79263740964df2` (`grassfield-install.sh`), also published next to the script as `grassfield-install.sh.sha256`; the site and the README will carry it at the announcement (SITE.PLACEHOLDER, README.PLACEHOLDER).

**What each form protects against, and what it does not**
- *The one line* runs whatever the host serves at that moment. You rely on the TLS connection to the host and on the host
  itself. You cannot read the script first, but it still shows you a plan and asks you to confirm before it changes anything.
- *Download, check, run* lets you read the script and run it only if the checksum matches. A checksum downloaded **from the same
  host proves nothing against a compromised host**: whoever controls the host can serve a script and a matching checksum. It
  protects against a damaged or cut download. To get a real check, compare the checksum with the copy published at the other
  places above (the site and the README), which an attacker would also have to change.
- In both cases the signing key is pinned inside the script (fingerprint `E4921A382C349308BAA50D2F44C31B5D862EBEFA`, to compare with the site).
  The script fetches the key into a temporary keyring and checks that its **primary** key has exactly that fingerprint before
  pacman sees it. Packages are then accepted only if their signature verifies against a key pacman trusts.
- **The Grassfield key becomes trusted by pacman for every repository, not only Grassfield's** (pacman does not limit a key
  to one repository). Whoever holds that key could sign a package for any repository. This is the cost of installing from a
  third-party repository; `--uninstall` removes the key.

### What happens
1. The script checks your system first and prints what is wrong with the exact fix, without changing anything.
2. It shows a **plan** of everything it will change and asks you to confirm. `--dry-run` shows the plan and stops; `--yes` skips
   the question; `--channel beta` follows the beta channel; `--session omarchy` keeps Omarchy as your next login;
   `--without-login-themes` skips the login and boot screens; `--help` lists the options.
3. It changes, in this order: a snapshot; trusts the signing key in pacman; adds the `[grassfield]` repository
   (`/etc/pacman.d/grassfield.conf` and two lines at the end of `/etc/pacman.conf`; a dated copy of `pacman.conf` is kept next
   to it); installs `grassfield-desktop`, `grassfield-compositor`, `grassfield-store` and `grassfield-login-themes`; hands the
   repository to `grassfield-channel-set`; makes Grassfield the session of your next login; activates the Grassfield login
   screen and boot screen (the boot image is rebuilt the way Omarchy does it, which takes a minute). The snapshot does **not**
   cover `/boot` (the boot partition is outside it), so it cannot undo a boot image. If the rebuild fails, the script sets the
   previous boot theme back and runs Omarchy's rebuild again; if that fails too it stops and tells you the exact command to
   retry. In that case the computer may start the previous entry, and you can pick a snapshot entry in Limine's menu at start.
   A boot problem found later is handled with Esc at the disk prompt, Limine's menu, or `--uninstall`.
4. **If anything fails between adding the repository and installing the packages, the script puts everything back** (the
   repository lines, its file, the key, the downloaded package lists) and tells you how to retry.
5. Everything is logged to `~/.local/state/grassfield/install.log`.

It never reorders your repositories and never touches Omarchy's files.

### After the install
Restart the computer once. The first start shows the new boot screen: type the disk password as usual (Esc shows the plain text
prompt). At the login screen choose **Grassfield (uwsm)** (it is the default). Updates then arrive from Settings > Software Update.

### Go back to Omarchy
- Only for the next login: `grassfield-login set omarchy`, then log out.
- Remove Grassfield completely: run the script again with `--uninstall` (`bash grassfield-install.sh --uninstall`). It takes a
  snapshot, turns Grassfield updates off, switches the session back to Omarchy, puts the previous login and boot screens back,
  removes the packages, the `[grassfield]` repository and the key, deletes the files that only matter inside Grassfield (portal
  link, pointer theme, cache). Your Grassfield
  settings and state (including the session's default-app list) are kept: the script prints where they are and the one command
  that deletes them. The system group `grassfield-update` is kept, as Arch does for system groups. Restart once.

Run the install again at any time to repair or update: it never duplicates anything.

---

## Français

Grassfield est une session de bureau pour **Omarchy 4.0.6 ou plus récent** (Arch Linux, x86_64). L'installer ne supprime pas
Omarchy : tu choisis ce qui démarre à la connexion et tu peux revenir en arrière à tout moment.

### Avant de commencer
- Un Omarchy 4.0.6+ qui fonctionne, avec environ 4 Gio libres, et `pacman-contrib`. Si des mises à jour attendent, le script dit combien et demande « Les installer maintenant ? [O/n] » (`--yes` répond oui) : il lance alors la mise à jour d'Omarchy puis continue ; réponds non et il s'arrête sans rien changer.
- Un compte administrateur (le script demande ton mot de passe via `sudo`).
- Les snapshots d'Omarchy sont utilisés s'ils sont configurés : le script en prend un avant toute modification et s'arrête s'il échoue.

### Installer
Ouvre un terminal dans Omarchy. N'utilise pas `sudo` toi-même. Une ligne :
```bash
curl -fsSL https://packages.grassfield.site/install/grassfield-install.sh | bash
```
Ou, pour lire et vérifier le script d'abord (télécharger, vérifier, lancer) :
```bash
curl -fsSLO https://packages.grassfield.site/install/grassfield-install.sh
curl -fsSLO https://packages.grassfield.site/install/grassfield-install.sh.sha256
sha256sum -c grassfield-install.sh.sha256 && bash grassfield-install.sh
```
Limite connue : la seule somme publiée aujourd'hui est servie par le même hôte que le script ; elle protège d'un téléchargement
abîmé, pas d'un hôte compromis. Une copie indépendante (site, README) viendra avec l'annonce.

Somme de contrôle : `SHA256: c395efb528b93bcc0ea2f6a43d1fed8bba7ae4d364ce62bc4e79263740964df2` (`grassfield-install.sh`), aussi publiée à côté du script (`grassfield-install.sh.sha256`) ; le site et le README la porteront à l'annonce (SITE.PLACEHOLDER, README.PLACEHOLDER).

**Ce que chaque forme protège, et ce qu'elle ne protège pas**
- *La ligne unique* exécute ce que l'hôte sert à cet instant. Tu t'appuies sur la connexion TLS vers l'hôte et sur l'hôte
  lui-même. Tu ne peux pas lire le script avant, mais il affiche quand même un plan et demande confirmation avant de modifier quoi que ce soit.
- *Télécharger, vérifier, lancer* te permet de lire le script et de ne le lancer que si la somme correspond. Une somme
  téléchargée **depuis le même hôte ne prouve rien contre un hôte compromis** : qui contrôle l'hôte peut servir un script et la
  somme qui lui correspond. Elle protège d'un téléchargement abîmé ou coupé. Pour une vraie vérification, compare la somme avec
  la copie publiée ailleurs (le site et le README), qu'un attaquant devrait aussi modifier.
- Dans les deux cas la clé de signature est fixée dans le script (empreinte `E4921A382C349308BAA50D2F44C31B5D862EBEFA`, à comparer avec le
  site). Le script récupère la clé dans un trousseau temporaire et vérifie que sa clé **primaire** a exactement cette empreinte
  avant que pacman la voie. Les paquets ne sont ensuite acceptés que si leur signature est vérifiée par une clé de confiance de pacman.
- **La clé de Grassfield devient une clé de confiance de pacman pour tous les dépôts, pas seulement celui de Grassfield**
  (pacman ne limite pas une clé à un dépôt). Qui détient cette clé pourrait signer un paquet pour n'importe quel dépôt. C'est le
  prix d'une installation depuis un dépôt tiers ; `--uninstall` retire la clé.

### Ce qui se passe
1. Le script vérifie d'abord ton système et affiche ce qui ne va pas avec le correctif exact, sans rien modifier.
2. Il affiche un **plan** de tout ce qu'il va changer et te demande de confirmer. `--dry-run` montre le plan et s'arrête ;
   `--yes` supprime la question ; `--channel beta` suit le canal bêta ; `--session omarchy` garde Omarchy à ta prochaine
   connexion ; `--without-login-themes` saute les écrans de connexion et de démarrage ; `--help` liste les options.
3. Il modifie, dans cet ordre : un snapshot ; fait confiance à la clé de signature dans pacman ; ajoute le dépôt `[grassfield]`
   (`/etc/pacman.d/grassfield.conf` et deux lignes à la fin de `/etc/pacman.conf` ; une copie datée de `pacman.conf` est gardée à
   côté) ; installe `grassfield-desktop`, `grassfield-compositor`, `grassfield-store` et `grassfield-login-themes` ; confie le dépôt à
   `grassfield-channel-set` ; fait de Grassfield la session de ta prochaine connexion ; active l'écran de connexion et l'écran de
   démarrage Grassfield (l'image de démarrage est reconstruite comme le fait Omarchy, ce qui prend une minute). Le snapshot ne
   couvre **pas** `/boot` (la partition de démarrage est hors de lui), il ne peut donc pas annuler une image de démarrage. Si la
   reconstruction échoue, le script remet l'ancien thème de démarrage et relance la reconstruction d'Omarchy ; si elle échoue
   aussi, il s'arrête et donne la commande exacte pour réessayer. Dans ce cas l'ordinateur peut démarrer l'entrée précédente, et
   tu peux choisir une entrée de snapshot dans le menu de Limine au démarrage. Un problème de démarrage découvert plus tard se
   règle avec Échap à l'invite du disque, le menu de Limine, ou `--uninstall`.
4. **Si quelque chose échoue entre l'ajout du dépôt et l'installation des paquets, le script remet tout** (les lignes du
   dépôt, son fichier, la clé, les listes de paquets téléchargées) et t'explique comment réessayer.
5. Tout est écrit dans `~/.local/state/grassfield/install.log`.

Il ne réordonne jamais tes dépôts et ne touche jamais aux fichiers d'Omarchy.

### Après l'installation
Redémarre l'ordinateur une fois. Le premier démarrage affiche le nouvel écran de démarrage : saisis le mot de passe de disque comme
d'habitude (Échap affiche l'invite texte simple). À l'écran de connexion choisis **Grassfield (uwsm)** (c'est le choix par défaut).
Les mises à jour arrivent ensuite depuis Réglages > Mise à jour.

### Revenir à Omarchy
- Seulement pour la prochaine connexion : `grassfield-login set omarchy`, puis ferme la session.
- Retirer Grassfield complètement : relance le script avec `--uninstall` (`bash grassfield-install.sh --uninstall`). Il prend un
  snapshot, désactive les mises à jour Grassfield, remet la session sur Omarchy, remet les écrans de connexion et de démarrage
  précédents, retire les paquets, le dépôt `[grassfield]` et la clé, supprime les fichiers qui ne servent qu'à Grassfield
  (lien des portails, thème de pointeur, cache). Tes réglages et ton état Grassfield (dont la liste des applications par défaut de la session) sont gardés : le script
  indique où ils sont et la commande qui les supprime. Le groupe système `grassfield-update` est conservé, comme Arch le fait pour
  les groupes système. Redémarre une fois.

Relance l'installation à tout moment pour réparer ou mettre à jour : rien n'est jamais dupliqué.
