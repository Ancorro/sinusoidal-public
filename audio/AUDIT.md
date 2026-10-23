# Sound level audit (2026-10-22)

Measured by `audio/measure.py`, without listening: integrated loudness in LUFS (loudness units relative to full scale; a mono file counts as both speakers, as
Godot plays it), peak, clipped samples, DC offset, first and last samples, and loop seams. "Heard" is the file's loudness
plus its gain in `scripts/sfx.gd`.

## Found

- **Clipping:** card_thump_1 (25 samples), card_thump_2 (77) and lid_latch (15) went over full scale, with peaks up to
  +1.6 dBFS (decibels relative to full scale).
- **Uneven levels:** the files ranged from -14 to -31 LUFS. As heard, the bell (-29) and the wire snip (-28) were the
  quietest events, and the lid latch (-14) was the loudest.
- **Missing table entries:** lid_open, lid_close, snip and candle_out had no VOLUME_DB entry, so they played at 0 dB.
- **Tick buried:** the Dealer's thinking tick (-35 LUFS heard) sat 3.6 dB under the ambience bed (-32), which masked the
  main "the Dealer is thinking" cue.
- **Clicks:** creature_death stopped on a non-zero sample with no fade-out, which can click.
- **Loop seams:** the cabin ambience loop was seamless before encoding, but Vorbis treats the file's two ends
  differently. That left a seam step bigger than any step inside the file: a faint click every 20 s.
- **Silence:** clips carried 50 to 340 ms of dead tail, and the hit and candle clips had the most.
- **DC offset:** under 0.008 on every clip. Nothing to fix.

## Changed

- **New `audio/master.py`:** for each one-shot, it trims silence, fades in over 2 ms and out over 25 ms, limits peaks to
  -2 dBFS and normalises to -16 LUFS. It skips any clip listed in `audio/mastered.txt`, so no clip is encoded twice.
- **Results:** all 11 one-shots now sit within 1 dB of -16 LUFS. None clips; Vorbis overshoot puts the highest peak at
  -0.8 dBFS. Every one-shot ends in a fade.
- **Loops:** `audio/synth.py` writes the loops at a -2 dBFS peak and Vorbis quality 0.4. Each loop is rotated so the
  seam lands where the encoded file joins smoothly; the ambience seam step is now 0.06 of the file's own 99.9th
  percentile step.
- **Mix:** VOLUME_DB now lists every sound. Heard levels, in LUFS:

| Sound | Heard (LUFS) |
|---|---|
| candle out, bell, wire snip | -17 to -18 |
| death, lid open | -19 to -20 |
| hit, card, lid close | -21 to -22 |
| scale | -24 |
| tick | -27 |
| ambience bed | -30 |
| lamp creak | -31 |

- **Headless runs:** test scripts run headless, and there the ambience no longer starts. They quit without
  `Sfx.quit()`, and a stream still playing at quit was reported as a leak.

Rerun the measurement with `python audio/measure.py`.
