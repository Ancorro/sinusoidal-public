# Inscryption look comparison (reference only, not shipped)

Inscryption's battle table was compared from its official Steam store screenshots (https://store.steampowered.com/app/1092790/Inscryption/), viewed locally and not kept in the repo.

## What Inscryption does

- Leshy is mostly black. Only his eyes, the tops of his cheeks and his hands catch light. His head sits at the top edge of the frame and he looms large behind the board.
- One lamp lights the board, with deep falloff: the board is bright and everything past it sinks into palette-snapped shadow. Candles on a skull add small warm points near the opponent. Mullins credits a shader that "snapped dark colors to a defined palette but left bright colors alone" ([thread](https://x.com/DMullinsGames/status/1451601471003234314)).
- Each scene has a strong overall tint (green or blue) from one palette ([palette credit](https://x.com/DMullinsGames/status/1451601475818254336)). The props (scales, bell, skull, scissors) are chunky, low-poly and low-texture, and read by silhouette and a few lit edges.
- Mullins on low-fi: "When you lose detail, there's more ambiguity, and sometimes that can make things spookier" ([Game Rant](https://gamerant.com/inscryption-interview-developer-daniel-mullins-3d-retro-horror-games/)).

## Gaps in the Dealer, since fixed

- **Lighting:** the front key light made the Dealer a lit display piece. It is now mostly in shadow, with a dim warm rim light from behind, a low glow from the candle side, and glowing eyes.
- **Framing and scale:** the Dealer is 1.25 times bigger, closer and lower, so it looms as a bust with its eyes near the top of the frame. The open-head camera follows the scale.
- **Materials:** the texture is 64px, snapped to four walnut and three brass tones. The 256px photo projection had turned to noise at 320x180.

## Cabin pass (table, lamp, tint, frame edges)

`cabin-before-after.png` (480x270): before on the left, after on the right. The top row is the battle (`--demo-board`) and the bottom row is the map; the map seed is random, so its nodes differ.

- **Table:** it is now planks instead of noise that snapped to rug-like blobs. Boards about 0.3 wide, 2px dark seams and board ends, a stretched grain, and a heavy dark rim along the player's edge.
- **Lamp:** the bulb is tucked inside the shade and the shade is dark and rough, so no speck shows above the Dealer. The spot falls off toward the cone edge. The height is unchanged, since raising it washed out the map.
- **Tint:** deep shadows, fog and ambient light are a cold green-black, and the browns are kept for the lamp-lit middle. Warm board, cold cabin.
- **Frame edges:** dark low-poly silhouettes in our own Renaissance theme: a brass orrery on the left, and on the right an hourglass and a book stack with a candle stub (set dressing, not a life candle). Chains hang at both edges, and a faint cold back light rims them.

## Props pass (real models)

`props-before-after.png` (480x270): before on the left, after on the right, battle on top and map below. The stand-ins
for the candles, lamp, bell, scale, armillary, hourglass and books are now Hunyuan3D-2 models. New: the Dealer's carved
hands on the far table edge, a bone dish by the scale, and two wall shelves of workshop clutter behind the Dealer.
The lamp now hangs above the frame.

Not done: a card deck and slot models (the slots are game-readable boxes and the deck is off screen), a squirrel
pile, cabin walls.

## Still open

- Board slots are plain dark boxes. Inscryption's glow in the scene tint.
- The post shader has one palette for the whole run. A per-area hue would need the run map to pass one in.
- The hand and three buttons still cover the lower third.
