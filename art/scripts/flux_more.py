# Second asset batch for the Colab kernel (after colab_flux_cached.py): card back, map icons, event vignettes,
# the boss portrait. Same woodcut look as flux_cards.py. One `more(key)` per exec, foreground.
WOOD = ("a bold black woodcut print of {}, solid black ink shapes and thick carved outlines, high contrast, few large "
        "white cuts, plain cream paper background, old 17th century chapbook woodcut, no text, no letters, no signature, "
        "no border, no frame")
SCENE = ("a black woodcut vignette of {}, a small scene in an oval, solid black ink and thick carved lines, high "
         "contrast, simple bold shapes, plain cream paper around it, old 17th century chapbook illustration, no text, no "
         "letters, no signature")
EMBLEM = ("a single bold black woodcut emblem of {}, one simple solid black symbol centered on plain cream paper, thick "
          "carved lines, minimal, high contrast, no text, no letters, no signature, no border")

MORE = {
    # (prompt template, subject, width, height, seeds)
    "back": (WOOD, "an ornate playing card back: a symmetrical pattern of a sine wave across a ring of moths and bones "
                   "around a single open eye, filling the whole card, decorative border", 768, 1088, 3),
    "boss": (WOOD, "a gaunt Renaissance clockwork automaton dealer carved from walnut, a skull-like wooden head with a "
                   "hinged lid and two glowing eyes, gears visible in its open chest, holding a fan of cards, bust portrait",
             1024, 1024, 3),
    "node-battle": (EMBLEM, "two crossed daggers", 768, 768, 2),
    "node-event": (EMBLEM, "a question mark made of a curled snake", 768, 768, 2),
    "node-boss": (EMBLEM, "a grinning skull with a crown of gears", 768, 768, 2),
    "node-rest": (EMBLEM, "a lit candle", 768, 768, 2),
    "node-choice": (EMBLEM, "three playing cards fanned out", 768, 768, 2),
    "node-hidden": (EMBLEM, "a closed eye", 768, 768, 2),
    "event-ledger": (SCENE, "an open ledger book on a table with a quill and an inkwell, a half written name", 1024, 768, 2),
    "event-spare_wax": (SCENE, "a short stub of a melted candle with a small flame under a table", 1024, 768, 2),
    "event-bone_dice": (SCENE, "a bony hand rolling two knucklebone dice across a wooden table", 1024, 768, 2),
    "event-music_box": (SCENE, "an open wooden music box with a broken comb and a small cylinder", 1024, 768, 2),
    "event-loose_gear": (SCENE, "a single brass cog wheel rolling across a table", 1024, 768, 2),
    "event-dozing": (SCENE, "a clockwork automaton slumped asleep at a card table, its head tilted forward", 1024, 768, 2),
    "event-empty_chair": (SCENE, "an empty wooden chair with a hand of playing cards lying on its seat", 1024, 768, 2),
    "event-rats": (SCENE, "many rats squeezing out of a crack between cabin floor boards", 1024, 768, 2),
    "event-basin": (SCENE, "a basin of still black water with a ghostly reflection of a hand holding cards", 1024, 768, 2),
    "event-squirrel_cage": (SCENE, "a wire birdcage full of squirrels hanging from a rafter by a chain", 1024, 768, 2),
}


def more(k):
    t, subj, w, h, n = MORE[k]
    gen("more/" + k, t.format(subj), n=n, w=w, h=h)
