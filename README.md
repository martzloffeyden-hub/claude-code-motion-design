# SINGULARITY

Court métrage de motion design de 36 secondes, entièrement original et
entièrement procédural. Aucune image, aucun modèle 3D, aucun son ni aucune
texture externe : chaque pixel est calculé par des shaders de raymarching et
chaque son est synthétisé.

**Fichier final : [`output/SINGULARITY.mp4`](output/SINGULARITY.mp4)**
(1920 × 1080, 60 i/s, H.264 High, AAC stéréo 48 kHz, 36,000 s)

---

## Intention

> Une structure impossible émerge de l'obscurité, puis déforme la matière, la
> lumière et l'espace jusqu'à s'effondrer en un point.

Un seul motif traverse tout le film : **l'anneau**. On découvre d'abord un
gyroscope de cinq anneaux usinés en titane sombre, en lévitation au-dessus
d'un océan d'obsidienne liquide. Les anneaux s'arrachent ensuite pour former
un disque d'accrétion autour d'une singularité. Le film se termine sur un
dernier anneau de lumière, qui se referme en point.

**Palette.** Le noir profond domine, avec un graphite légèrement froid. L'unique
source chaude va du blanc-or à l'ambre, comme un filament incandescent.
Les franges spectrales n'apparaissent qu'aux moments où l'espace se déforme.

**Langage de caméra.** Le film est cadré en 2.39:1, comme au cinéma. Au moment
de l'impact final, le bandeau s'ouvre en 16:9, et l'image respire enfin.

## Découpage (80 BPM, un acte = 8 temps = 6 s)

| Temps | Acte | Image | Son |
|---|---|---|---|
| 0:00 – 4:50 | **I. Vide** | Macro sur l'arête d'un anneau en métal brossé, en faible profondeur de champ. Un joint de lumière s'allume en courant le long de la courbe. | Sub-basse, air, crépitements électriques, ton de verre ascendant, souffle inversé |
| 4:50 – 10:50 | **II. Émergence** | Contre-jour : l'astre s'allume derrière la structure, qui sort de l'eau. Rayons volumétriques, reflet dans le miroir liquide. Les anneaux s'allument un par un, sur chaque temps. | Impact géant, grondement. Chaque anneau ajoute une note à l'accord (ré, la, ré, mi, la). |
| 10:50 – 16:50 | **III. Anatomie** | Les anneaux se déverrouillent et prennent trois poses de gyroscope, verrouillées sur le temps. La caméra tourne autour de la structure. | Pulsation cardiaque, servomoteurs, chocs métalliques modaux à chaque verrouillage |
| 16:50 – 22:50 | **IV. Distorsion** | Une singularité naît au cœur. Les rayons sont courbés, l'astre devient un **anneau d'Einstein**, les anneaux se déforment. L'océan est aspiré en une colonne de liquide incandescent. | « Redshift » : toutes les hauteurs glissent vers le grave. Passages Doppler qui accélèrent, gamme de Shepard. |
| 22:50 – 28:50 | **V. Effondrement** | Disque d'accrétion lentillé, avec rotation différentielle, effet Doppler relativiste et décalage gravitationnel. Les cinq anneaux y survivent en fins anneaux de débris. Puis tout implose. | Rugissement turbulent, montée de Shepard, tics qui accélèrent, aspiration |
| 28:50 – 29:25 | *Respiration* | Un temps de noir absolu et un seul point de lumière | Silence réel (-60 dB), un battement, inspiration |
| 29:25 – 36:00 | **VI. Singularité** | Flash, onde de pression chromatique, poussière soufflée. Le bandeau s'ouvre, l'anneau final se déploie. Le point s'étire en ligne, d'où le titre se condense lettre par lettre depuis le centre. Tout revient au point. | Impact maximal, résolution en ré majeur add9, carillon de verre synchronisé sur les lettres |

Toutes les coupes, tous les impacts et tous les verrouillages sont définis une
seule fois dans [`src/timeline.py`](src/timeline.py). Ce fichier est injecté dans
les shaders (`#define`) et lu par le moteur sonore. La synchronisation est donc
exacte par construction, puis vérifiée sur le MP4 encodé (voir plus bas).

## Technique

Le rendu tourne sur un conteneur cloud **sans GPU** (4 cœurs CPU). J'ai choisi
des shaders GLSL exécutés par OpenGL 4.5 en rendu logiciel (Mesa llvmpipe),
pilotés en Python par `moderngl`. C'est le meilleur compromis
qualité/temps de calcul : une image 1080p complète prend de 1,5 à 8 s.

```
scène (raymarching, 4 à 7 échantillons/pixel avec jitter d'obturateur borné au plan)
  → profondeur de champ (bokeh « scatter-as-gather »)
  → bloom (pyramide 7 niveaux, moyenne de Karis anti-fireflies)
  → flare anamorphique horizontal
  → rayons de lumière en espace écran / zoom-blur d'implosion
  → composite : tonemapping AgX, étalonnage, aberration chromatique,
    vignettage, grain argentique, dithering 8 bits, bandeau 2.39:1
  → ffmpeg (intermédiaires x264 4:4:4 CRF 8) → MP4 final 2 passes
```

Principaux éléments :

- **Anneaux** ([`shaders/scene_world.glsl`](shaders/scene_world.glsl)) : champs de distance
  signée avec chanfreins, panneaux, rainures, canal lumineux et finition brossée.
  Les normales et la rugosité sont filtrées selon l'empreinte du pixel
  (anti-aliasing spéculaire) pour éviter le scintillement à 60 i/s.
- **Gravitation** : les rayons suivent les géodésiques nulles de Schwarzschild,
  avec l'accélération `a = -3/2 · h² · x / r⁵`. L'anneau d'Einstein, l'arc
  supérieur du disque et l'image secondaire sous l'ombre ne sont pas dessinés :
  ils émergent de la physique.
- **Disque d'accrétion** ([`shaders/scene_blackhole.glsl`](shaders/scene_blackhole.glsl)) :
  profil de température de type Shakura-Sunyaev, rotation képlérienne
  différentielle, facteur Doppler relativiste `g⁴` et décalage gravitationnel.
- **Titre** ([`src/title_texture.py`](src/title_texture.py)) : Inter Display ExtraLight,
  convertie en champ de distance signée. Le shader peut ainsi flouter, faire
  luire, condenser et « découper » l'anneau autour des lettres.
- **Son** ([`src/sound_design.py`](src/sound_design.py)) : synthèse additive et FM,
  résonateurs modaux, bruits filtrés, gammes de Shepard et réverbérations à
  convolution générées. Le mixage est automatisé par acte selon des cibles de
  loudness EBU R128, avec un limiteur crête à anticipation (programme ≈ -16 LUFS).

## Reproduire le film

```bash
pip install moderngl numpy scipy pillow pyloudnorm
Xvfb :99 -screen 0 1920x1080x24 &           # contexte GL headless
./render_all.sh                             # rendu des 6 plans + son + assemblage
python3 src/verify.py output/SINGULARITY.mp4
```

Prévisualisation rapide : `python3 src/render.py --shot anatomy --scale .25 --fps 15`.
Image fixe : `python3 src/render.py --still 25.5`.

## Licences et ressources

- Images, shaders, sons et musique : création originale de ce projet, 100 % procédurale.
- Police : **Inter Display** (Rasmus Andersson), licence SIL Open Font License 1.1.
- Aucun logo ni aucune marque.
