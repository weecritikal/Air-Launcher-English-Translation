# App icon

`build_icons.py` draws the Flux mark and writes every size the bundle references.

    python3 tools/branding/build_icons.py           # render the colourways
    python3 tools/branding/build_icons.py install   # write them into the bundle

The mark is rendered from a signed-distance field rather than stroked directly.
The distance to the curve drives both the body gradient and a light-from-above
highlight, which is what makes it read as a lit solid instead of flat neon.
Everything renders at 4x and is downsampled, so the edges stay clean without a
vector rasteriser.

Three colourways are built. To change which one ships, edit the `VARIANTS` map at
the bottom of the script and re-run `install`:

| Render      | Colourway        | Used for                  |
|-------------|------------------|---------------------------|
| `f_a.png`   | ice / cobalt     | primary + Light alternate |
| `f_dark.png`| cobalt, near-black ground | Dark alternate   |
| `f_c.png`   | mint / teal      | Development builds        |
| `f_b.png`   | magenta / violet | unused, kept as an option |

Sizes written: 1024 for each `.appiconset`, and the 120 / 152 pairs in
`Natives/resources` that `CFBundleIconFiles` names.
