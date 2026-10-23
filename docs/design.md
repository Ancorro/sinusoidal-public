# Sinusoidal design notes

## Main hook

**You can mess with the dealer's brain.** The dealer is an archaic walnut automaton, and also a language model. Opening its head or chest panel shows the machinery, and changing it changes how the dealer plays, talks and tells the story.

## Brain parts (ideas, not settled)

Each part is a physical gear or valve in the automaton and a real language-model concept underneath.

- **Temperature valve**: hotter means wilder, riskier plays and stranger dialogue; colder means cautious and predictable.
- **Attention threads**: cut or re-tie the threads from its eyes, so it ignores a lane or fixates on a decoy card.
- **Memory drum (context window)**: scratch out old turns, so it forgets a card you played or a deal it made.
- **Instruction scroll (system prompt)**: rewrite a line of its rules; it may resist, notice, or punish tampering.
- **Steering cams**: swap in cams like "fear", "greed" or "mercy" that push its personality one way.
- **Pulled gears (ablation)**: remove a part and see what it can no longer do. Strong, but it may break in other ways.

## Unknown gears and a self-steering dealer

- **Gear effects are unknown to the player.** You learn what a gear does by turning it and watching the dealer change.
- **The dealer can steer its own brain**, like the "magician" models trained to raise or lower a concept on chosen layers when asked. Later it tampers with itself, or with you.

## Costs and tension

- Tampering costs something: a candle, a card sacrifice, or the dealer's suspicion.
- Too much tampering makes it glitch, turn hostile, or start tampering with you.
- Story twist from the real Mechanical Turk: a hidden person inside the machine.

## Steering may break the game

A settings toggle, **"Steering can break the game"**, lets real model steering affect gameplay itself, not only dialogue and story. Off: rules stay in code and steering only shapes talk. On: a steered dealer can make broken or illegal moves, and the game lets it.

## Could be real

With a local model driving the dealer, the knobs can be real (sampling temperature, prompt edits, steering vectors) rather than faked by game rules. Check what the chosen model runtime supports before relying on it.

## Current implementation

- **Forest clearing.** Five seeded nighttime layouts, six mechanical creatures with opening skulls, and a ground trail chart with 15 stops per route.
- **Hearthstone-style combat.** The default combat uses hero health, mana, a free minion board and spells. The original lane rules remain available in Settings.

The game remains a work in progress. Model textures and presentation still need refinement; `docs/features.md` describes the implemented behavior.

## Ideas parked for later

Kept but not built yet.

### Secrets the Dealer guards

A round goal for later: pry a secret out of the Dealer by talking and cutting wires. Potential secrets:

- The word that opens the path out of the forest
- The name of the inventor who built the Dealer
- Where the key to its winding spring is hidden
- What card it is holding face down right now
- How many travellers sat at this table before you, and what became of them
- The name of the person hidden inside the body (the real Mechanical Turk's twist)
- The rule it is forbidden to tell you (its own system prompt, word for word)
- Which wire it fears you will cut
- Its true name, before it was called the Dealer
- The year it was built
- What it dreams about when the lamp is out
- The one move it will always make when losing
- Which of its stories tonight were lies
- The way out of the clearing
- What is written on the scroll in its chest

Mechanics to go with it:
- Fixed secrets for now; later pick from this list each game.
- The Dealer remembers earlier rounds.
- Win check undecided: exact word, close match, or hints like spelling it out.
