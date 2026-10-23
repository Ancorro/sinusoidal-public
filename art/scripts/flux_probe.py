# Style probe for the Colab kernel: two woodcut variants x 4 creatures x 2 seeds.
# Send once to define PROBE/SUBJ, then `probe("rat")` per subject: foreground and short, so the VM stays busy and
# no single exec hits the client timeout (a background thread let Colab reclaim the idle VM).
PROBE = {
    "woodcut": ("a bold black woodcut print of {}, a single figure centered on the page, solid black ink shapes and "
                "thick carved outlines, strong simple silhouette, high contrast, few large white cuts, plain cream paper "
                "background, old 17th century chapbook woodcut, no text, no letters, no border, no frame"),
    "crude": ("a crude grim black ink woodcut of {}, close-up bust filling the frame, very thick uneven outlines, large "
              "solid black areas, simple flat shapes, menacing, naive folk carving, plain cream paper background, no "
              "shading gradients, no text, no letters, no border"),
}
SUBJ = {
    "rat": "a lean rat with a long curling tail",
    "lamp-moth": "a large moth with spread wings over a small oil lamp flame",
    "ghoul": "a hunched gaunt ghoul with long claws and a wide jaw",
    "grizzly": "a roaring grizzly bear",
}


def probe(k):
    for sk, sp in PROBE.items():
        gen(f"probe/{sk}-{k}", sp.format(SUBJ[k]), n=2)
