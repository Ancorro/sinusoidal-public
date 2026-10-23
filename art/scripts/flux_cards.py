# Sent to the Colab kernel after colab_flux_cached.py: card portraits, sigils and the frame.
# Keys are the `art` keys in data/cards.json; sigil icons are the sigil ids with hyphens. Runs in a thread; writes /content/out/cards/DONE at the end.
# Send once to define the prompts, then one `card(key)` / `sigil(key)` / `frame()` per exec (foreground, so the VM
# stays busy and each call stays under the client timeout).

# Picked from the probe (art/STYLE.md): full-body woodcut silhouettes read at ~15 px; close-up busts turned to blobs.
STYLE = ("a bold black woodcut print of {}, a single large figure filling most of the page, solid black ink shapes and "
         "thick carved outlines, strong simple silhouette, high contrast, few large white cuts, plain cream paper "
         "background, old 17th century chapbook woodcut, no text, no letters, no signature, no border, no frame")
SIGIL = ("a single bold black woodcut emblem of {}, one simple solid black symbol centered on plain cream paper, "
         "thick carved lines, heraldic, minimal, high contrast, no text, no letters, no signature, no border")

CREATURES = {
    "squirrel": "a squirrel sitting upright holding an acorn, bushy tail curled behind it",
    "rat": "a lean rat with a long curling tail",
    "skeleton": "a grinning human skeleton, skull and ribcage",
    "grave-digger": "a hunched old grave digger with a shovel and a lantern",
    "bat": "a bat with outstretched ribbed wings and small fangs",
    "beetle": "a heavy horned beetle with a thick shell",
    "bone-hound": "a skeletal dog made of bones, snarling",
    "lamp-moth": "a large moth with spread wings over a small oil lamp flame",
    "shade": "a hooded ghostly shadow figure with two pale eyes and a ragged cloak",
    "black-cat": "a black cat with an arched back and glowing eyes",
    "spider": "a large spider hanging from a single thread",
    "hedgehog": "a hedgehog curled with sharp spines raised",
    "mole": "a mole with huge digging claws emerging from earth",
    "adder": "a coiled adder snake ready to strike, forked tongue out",
    "ghoul": "a hunched gaunt ghoul with long claws and a wide jaw",
    "raven": "a raven with spread wings and a sharp beak",
    "hound": "a lean black hunting hound, alert",
    "hydra": "a three-headed serpent hydra",
    "vulture": "a bald vulture hunched on a bone",
    "tortoise": "an old tortoise with a thick ridged shell",
    "grizzly": "a roaring grizzly bear",
}
SIGILS = {
    "flying": "a pair of feathered wings",
    "reach": "a tall thorny vine reaching upward",
    "guard": "a raised round shield",
    "poison": "a skull and crossbones",
    "thorns": "a bramble of sharp thorns",
    "shield": "a heater shield with a cross",
    "splash": "a three-pronged trident fork",
    "many-lives": "a cat's head with a ring of small dots around it",
    "bone-hoarder": "a pile of crossed bones",
}
FRAME = ("an ornate empty woodcut border frame for a playing card, black carved vines, bones and moths along the edges, "
         "completely blank cream paper in the middle, portrait card shape, no text, no letters")


def card(k):
    gen("cards/" + k, STYLE.format(CREATURES[k]), n=3)


def sigil(k):
    gen("cards/sigils/" + k, SIGIL.format(SIGILS[k]), n=2, w=768, h=768)


def frame():
    gen("cards/frame/frame", FRAME, n=3, w=768, h=1088)
