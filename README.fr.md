# Ambilight temps réel avec le boîtier Action « LSC Smart Connect HDMI Sync Box » (OpenBeken + Hyperion)

*English version: [README.md](README.md)*

Piloter en temps réel la bande LED du boîtier Action « LSC Smart Connect HDMI Sync Box » (réf. Action 3017060, modèle 6204000100, Eurodomest, base Tuya) depuis [Hyperion.NG](https://hyperion-project.org/), sans utiliser le traitement HDMI d'origine du boîtier. Dans la configuration décrite ici, l'image vient d'une TV LG OLED sous webOS (PicCap / hyperion-webos), ce qui couvre aussi les applications natives comme Netflix. Les autres sources Hyperion n'ont pas encore été testées.

```
TV (PicCap, port 19400) -> Hyperion.NG -> udpddp (DDP, UDP 4048) -> boîtier sous OpenBeken -> bande LED
```

État : fonctionne de bout en bout (testé avec couleurs unies, pixels individuels, arc-en-ciel et vidéo en direct). Projet amateur, testé sur un seul exemplaire.

## Contenu du dépôt

| Chemin | Contenu |
|--------|---------|
| `patches/openbeken-1.18.219-ws2811bb.patch` | Ajoute un driver `WS2811BB` à OpenBeken 1.18.219 (`OpenBK7231T_App`). |
| `patches/openbeken-main-168cba5-ws2811bb.patch` | Le même driver porté sur `main` d'OpenBeken (commit 168cba5, 6 nov. 2026) : s'applique proprement et compile. À utiliser pour le travail amont. |
| `patches/sdk-OpenBK7231N-itcm.patch` | Une ligne dans le script de liens du SDK BK7231N, pour placer la boucle d'envoi en ITCM. |
| `Dockerfile` | Environnement de compilation (Ubuntu 22.04 + chaîne ARM). |

Aucun binaire de firmware n'est distribué : OpenBeken et son SDK (`openshwprojects/OpenBK7231N`, code Tuya/Beken) ne déclarent aucune licence. Il faut donc compiler soi-même.

## Pourquoi un nouveau driver

Le boîtier contient un ESP32 (traitement de l'image HDMI) et un module BK7231N / CBU (cloud Tuya et bande LED). Teardown : [elektroda 4090571](https://www.elektroda.com/rtvforum/topic4090571.html). La ligne de données des LED a ces propriétés, trouvées dans [elektroda 4123137](https://www.elektroda.com/rtvforum/topic4123137.html) :

- Sur le BK7231N, **P0 et P8 sont les deux entrées d'une porte NOR** dont la sortie est la ligne de données de la bande. **P8 doit être tenu bas** et **les données sortent sur P0**.
- Le signal est du **WS2812B inversé** : repos haut, impulsions basses.
- P0 est UART2_TXD, le SPI n'est donc pas utilisable dessus. D'où un driver à bit-banging.

Le driver `WS2811BB` écrit directement dans le registre de configuration du GPIO, avec les interruptions coupées pendant une trame. La boucle d'envoi est placée en ITCM par le script de liens : le code exécuté depuis la flash subit des états d'attente aléatoires qui ruinent la largeur des impulsions, et un code exécuté depuis la RAM `.data` a fait planter le boîtier (watchdog). **Le patch du SDK n'est pas facultatif** : nous avons compilé le driver sans la ligne ITCM et, avec Hyperion qui envoie des images en DDP, la bande scintillait de façon visible (constat à l'œil ; une mesure donnait environ 87 ns par boucle au lieu d'environ 55 ns avec ITCM, d'après nos notes). Le driver se branche sur la couche LED partagée d'OpenBeken : `SM16703P_Init`, `SM16703P_SetPixel`, `SM16703P_Start` et le driver DDP fonctionnent donc par-dessus.

Commandes :

- `WS2811BB_Timing n0h n0l n1h n1l` : timing des bits en boucles (environ 55 ns chacune ici).
- `WS2811BB_Invert 0|1` : 1 par défaut (repos haut, impulsions basses).
- `WS2811BB_Calib` : mesure la période réelle d'un bit, résultat dans `/lograw`.

Limites : une trame fait 450 octets au maximum (150 pixels RGB), car elle est envoyée interruptions coupées. BK7231N uniquement, et seulement pour le build avec le SDK standard : le patch pour `main` n'active pas le driver pour `OpenBK7231N_ALT` (`beken_freertos_sdk`), où il n'a pas été testé.

## Notes matérielles

- Bande : **12 V**, 1,5 A max (étiquettes), **28 circuits de 3 LED, donc 28 pixels**, ordre des couleurs GRB. **Ne jamais brancher le connecteur USB de la bande sur un port USB normal** (il porte du 12 V).
- Le connecteur USB de la bande peut faire mauvais contact : un contact qui bouge provoque scintillements et états aléatoires qui ressemblent à des bugs logiciels. Le sécuriser (ruban adhésif) avant de déboguer.
- Flasher le boîtier avec CloudCutter **efface le firmware Tuya d'origine, sans sauvegarde possible avec cette méthode**. À accepter avant de commencer.

## Pas à pas

### 1. Flasher OpenBeken

Utiliser [tuya-cloudcutter](https://github.com/tuya-cloudcutter/tuya-cloudcutter) avec le profil `lsc-3017060-hdmi-light-sync-box-v1.0.7`, puis mettre le boîtier sur le réseau.

### 2. Compiler le firmware patché

```sh
git clone --depth 1 --branch 1.18.219 https://github.com/openshwprojects/OpenBK7231T_App.git
cd OpenBK7231T_App
git submodule update --init --depth 1 libraries/berry sdk/OpenBK7231N
git apply ../patches/openbeken-1.18.219-ws2811bb.patch
(cd sdk/OpenBK7231N && git apply ../../../patches/sdk-OpenBK7231N-itcm.patch)

docker build --platform linux/amd64 -t obk-build-x86 - < ../Dockerfile
docker run --rm --platform linux/amd64 -v "$PWD:/src" obk-build-x86 bash -c \
  'git config --global --add safe.directory "*"; make APP_VERSION=1.18.219 APP_NAME=OpenBK7231N VARIANT=default OpenBK7231N'
```

Résultat : `output/1.18.219/OpenBK7231N_1.18.219.rbl`. La compilation a été vérifiée sur un tag propre : elle réussit, et le `.bin` non compressé ne diffère du premier build que de quelques octets (date de compilation).

### 3. Mise à jour par OTA

```sh
curl -X POST --data-binary @OpenBK7231N_1.18.219.rbl http://<ip-boîtier>/api/ota
sleep 30        # redémarrer trop tôt (environ 6 s) laisse l'ancienne version
curl "http://<ip-boîtier>/index?restart=1"
```

Vérifier la date de compilation dans `http://<ip-boîtier>/api/info`. Retour arrière : flasher de la même façon le `.rbl` officiel d'OpenBeken 1.18.219.

### 4. Configurer les broches et la commande de démarrage

Rôles de broches (enregistrés durablement) : `UCS1912_DIN` sur **P0** (données) et `AlwaysLow` sur **P8**. Remettre un rôle à `None` ne libère pas toujours la broche tant qu'on n'a pas redémarré.

Commande de démarrage (le boîtier remet lui-même la lumière d'ambiance après un redémarrage) :

```
backlog startDriver WS2811BB; SM16703P_Init 28 GRB; WS2811BB_Timing 4 13 12 4; startDriver DDP; SM16703P_SetPixel all 204 117 33; SM16703P_Start
```

`WS2811BB_Timing 4 13 12 4` a fonctionné sur notre exemplaire. Utiliser `WS2811BB_Calib` et ses propres mesures si la bande se comporte autrement. Les commandes s'envoient par `http://<ip-boîtier>/cm?cmnd=<commande>`.

### 5. Configurer Hyperion.NG (2.2.1)

Appareil LED de type **`udpddp`** (pas `ddp`), hôte = IP du boîtier, port 4048, 28 LED, **ordre des couleurs `rbg`** (le chemin DDP du boîtier échange le vert et le bleu, Hyperion doit donc compenser). Disposer les LED dans l'ordre physique le long de la bande.

Pièges de l'API JSON (port 19444) si on la pilote par script :

- S'authentifier, puis `instance switchTo 0`, sinon les commandes `color` réussissent sans effet.
- `config setconfig` exige la configuration complète renvoyée par `getconfig`.
- `color` n'accepte qu'un seul `[r,g,b]` pour toute la bande ; ne pas passer `duration: 0`.
- `rewriteTime` est interdit pour `udpddp` ; `enableAttempts` et `enableAttemptsInterval` sont obligatoires.

Lumière d'ambiance quand la TV est éteinte : activer le `backgroundEffect` d'Hyperion (type `color`) avec la même valeur que la commande de démarrage. Hyperion ne rafraîchit pas périodiquement une couleur fixe, d'où la commande de démarrage.

### 6. PicCap sur la TV LG

Installé depuis le Homebrew Channel. Réglages qui ont fonctionné sur une OLED55G4 : résolution **128x78**, 30 images/s max, VSync décoché, moteur vidéo **`libvtcapture`**, moteur graphique `libhalgal`. `libdile_vt` ne capture que les menus sur cette TV.

- **Retard :** avec des images plus grandes (320x180, 256x144), le Wi-Fi de la TV saturait (environ 3 Mo/s) et le retard atteignait 1 à 2 s. À 128x78, le flux est d'environ 0,9 Mo/s et le retard n'est plus perceptible. Si le retard réapparaît, brancher la TV en Ethernet.
- **Après une mise en veille ou un redémarrage**, PicCap peut capturer les menus mais pas la vidéo (images vidéo noires). Ouvrir PicCap et appuyer sur **Save** relance le service de capture.
- **Ne pas changer un réglage de PicCap pendant que la capture tourne** : cela a fait planter Hyperion (SIGSEGV) chez nous. Arrêter Hyperion, changer et sauvegarder, relancer Hyperion.

## Crédits

- **emarck**, pour le brochage P0 / P8 et la découverte du WS2812B inversé ([elektroda 4123137](https://www.elektroda.com/rtvforum/topic4123137.html)).
- Le projet [OpenBeken](https://github.com/openshwprojects/OpenBK7231T_App) et ses contributeurs ; le modérateur du fil, p.kaczmarek2, avait demandé un driver à bit-banging avec la fonction d'envoi en RAM.
- [Hyperion.NG](https://hyperion-project.org/), [PicCap / hyperion-webos](https://repo.webosbrew.org/apps/org.webosbrew.piccap/), [tuya-cloudcutter](https://github.com/tuya-cloudcutter/tuya-cloudcutter).
- Teardown : [elektroda 4090571](https://www.elektroda.com/rtvforum/topic4090571.html).

## Assistance par IA

Ce projet a été réalisé avec l'aide de Claude Code (Anthropic), utilisé pour l'analyse, le code, les scripts de compilation et la documentation. Tous les résultats ont été vérifiés sur le matériel réel.

## Licence

Les patchs, le Dockerfile et la documentation de ce dépôt sont publiés sous [licence MIT](LICENSE). OpenBeken et son SDK n'ont aucune licence déclarée à ce jour ; ce dépôt ne contient aucun de leurs fichiers, hormis les lignes de contexte des patchs, et la licence MIT ne couvre que ce que nous avons ajouté.

## Avertissement

Vous flashez et câblez à vos risques : le firmware d'origine est perdu après CloudCutter, la bande fonctionne en 12 V, et de mauvais timings ou un mauvais câblage peuvent laisser la bande dans un état aléatoire.
