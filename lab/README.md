# Laboratoire de compilation DOS

Ce dossier recompile le compilateur XDC (`xdc_comp`) avec Turbo Pascal 7.0 dans DOSBox-X. Les sources XDC ne sont pas modifiées. Les binaires DOS ne sont lancés que dans l'émulateur.

## Prérequis

- DOSBox-X (`sudo apt install dosbox-x` sur Ubuntu 24.04). Le script le démarre sans fenêtre (`SDL_VIDEODRIVER=dummy`).
- Votre propre copie de Turbo Pascal 7.0 : l'archive zip qui contient `TP70/PASCAL.EXE`, ou `PASCAL.EXE` lui-même (auto-extracteur PKSFX 2.04g). Ces fichiers ne font pas partie du dépôt.
- Les sous-modules, depuis la racine du dépôt :

```
git submodule update --init --recursive
```

## Compilation

```
./lab/build.sh /chemin/vers/tp7.zip
```

Au premier lancement, le script :

1. extrait `PASCAL.EXE` de l'archive zip avec l'outil zip de l'hôte (ce n'est pas un binaire DOS) ;
2. exécute `PASCAL.EXE -d -o` dans DOSBox-X, ce qui installe l'arbre `TP\` dans `lab/tp/` ;
3. lance `TPC.EXE` sur `XDC_COMP.PAS`, avec les unités `C:\TP\UNITS`, `UNITS` et `TPLibs\CGA\LIB` ;
4. exécute le `XDC_COMP.EXE` produit, sans argument, et écrit l'aide dans `lab/out/HELP.TXT`.

Les lancements suivants réutilisent `lab/tp/` et n'ont plus besoin du chemin de l'archive. Pour réinstaller : `rm -rf lab/tp`.

Le journal du compilateur est `lab/out/COMP.LOG`. Une compilation réussie se termine par une ligne du type `4097 lines, … bytes code, … bytes data`, sans `Error` ni `Warning`.

## Lecteur (`xdc_play`)

```
./lab/build.sh play
```

`XDC_PLAY.PAS` compile ses autres unités puis s'arrête sur `Error 15: File not found (SOUNDLIB.TPU)`. `SOUNDLIB.PAS` a été retiré d'upstream ; ce dépôt n'en fournit pas de remplacement.

## Commande TPC

`S:` est la racine du dépôt, `O:` est `lab/out`, `C:\TP` est l'installation Turbo Pascal.

```
TPC -UC:\TP\UNITS;S:\UNITS;S:\TPLIBS\CGA\LIB -EO:\ -B S:\XDC_COMP.PAS
```

## Fichiers ignorés

`lab/tp/`, `lab/dist/`, `lab/out/` et les `*.zip` placés dans `lab/` sont ignorés par git. Ne commitez ni les fichiers Borland, ni l'archive, ni les `.EXE` et `.TPU` produits.
