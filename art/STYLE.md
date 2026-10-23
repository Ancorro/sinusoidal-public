# Card art style

**Style: black chapbook woodcut silhouettes, one creature per card, dark walnut ink on the card's parchment.**
FLUX.1-dev draws each creature as a woodcut on cream paper; `scripts/woodcut_post.py` keys the paper out to alpha and
makes the ink one colour (`2a1a12`, the card label ink), 64x64. The card face (`d9cbb0`) shows through.

## Why silhouettes

The game renders at 320x180. A portrait on the board is about 15 px wide, in the hand about 40 px. At 15 px only
the outline survives, so the figure is drawn as a full-body silhouette that fills the tile, with only a few large
white cuts (eyes, mouth, ribs). The probe also tried close-up "crude" busts (Inscryption-like framing): they filled
the tile but turned into blobs at 24 px. One flat ink colour also means the palette shader has no mid-tones to band.

## Compared with Inscryption

Compared against Inscryption screenshots viewed locally (not kept in the repo; sources below).

Match:
- The quality bar: crude, grim, hand-made ink on parchment, readable at a glance.
- Solid black masses with a few interior marks (eyes, teeth) that still read at small size. `--thicken 3` keeps
  those cuts; 5-7 filled them in.
- Sigils as one chunky glyph each, not a scene.

Keep different:
- Inscryption draws heavy outline art on orange parchment with thick borders. Ours is silhouette woodcut on the
  pale `d9cbb0` card, so the walnut cabin (brass, candles) supplies the warm colour.
- Their portraits are tight crops (head and shoulders). Ours show the whole body, because at our card size a pose
  reads better than a face.
- No copied subjects, poses or layouts. Shared creature names (Adder, Grizzly, Mole, Raven) are generic animals.

Sources (looked up 2026-10-22):
- Card images: https://inscryption.fandom.com/wiki/Adder, /Bullfrog, /Grizzly, /Mole, /Raven, /Wolf
- Sigils: https://inscryption.fandom.com/wiki/Sigils (icons are 49 px in the game files)

## Regenerating

`scripts/colab_flux_cached.py` (load, weights from the cloud cache), then `scripts/flux_cards.py` (`card("rat")`, `sigil(...)`,
`frame()`), then `python scripts/woodcut_post.py raw.png cards/rat.png`.

Picks and settings: `cards/picks.txt` (seed index per key; raw renders kept in cloud storage under `cards-raw/cards`, not in git).
Portraits: `woodcut_post.py raw.png cards/<key>.png` (64 px, thicken 3; despeckle drops stray border bits).
Sigils: `--size 24 --thicken 9` (13 for reach and splash, 3 for guard plus a hand-cut boss ring so it is not a plain disc).
Frame: `python scripts/woodcut_frame.py cards/src/frame.png cards/frame.png`.
`cards/src/` and `reference/` carry a `.gdignore`, so Godot never imports them.

## Earlier 480x270 presentation (historical)

- Hand cards: portraits are ~45 px and read well; the frame corners and rules stay clear of the title and cost.
- Board cards: portraits are ~12 px tall; upright silhouettes (Raven, Squirrel, Ghoul) read, coiled ones (Adder,
  Hydra) less so. The lamp blows the card faces out to near white, which is lighting, not the art.
- Sigil icons sit between attack and health (as in Inscryption). On the board they are ~6 px; in the hand that row
  is below the bottom edge of the screen with the current camera.

## 960x540 update

- Everything is re-exported from the masters at twice the size (portraits 128, sigils 48, frame 200x280) with
  `scripts/export_all.py`; the code sizes sprites by width in metres, so no code change was needed for that.
- New, same woodcut prompts (`scripts/flux_more.py`): card back (brass ink on the Dealer's red backs), the Dealer's
  own card (bust of the walnut automaton, standing at the boss stop on the map), map marks (crossed daggers, snake
  question mark, crowned skull, fanned cards, closed eye, candle for a future rest stop) and one vignette per event.
- Map marks, events and the back are white masks tinted in game (`modulate`), so one file serves pale-on-wax and
  ink-on-paper. Portraits and sigils stay walnut ink.
- At 960x540 board portraits are ~25 px and coiled creatures (Adder, Hydra) read too; sigil icons ~12 px.
