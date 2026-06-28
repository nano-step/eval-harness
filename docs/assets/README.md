# Demo assets

## Recording the demo GIF

The hero GIF at the top of the main README is produced from [`demo.tape`](./demo.tape) using [Charm `vhs`](https://github.com/charmbracelet/vhs).

```bash
# install vhs (one-time)
brew install vhs           # macOS
go install github.com/charmbracelet/vhs@latest   # any

# render the GIF + webm + mp4
cd docs/assets
vhs demo.tape
```

Produces `demo.gif` (~ 2-3 MB), `demo.webm`, `demo.mp4`. Commit only `demo.gif`; the README references it.

## Alternative: asciinema

If `vhs` isn't available, record an asciinema cast instead:

```bash
asciinema rec docs/assets/demo.cast
# (run through the demo manually)
# exit when done
agg docs/assets/demo.cast docs/assets/demo.gif --theme monokai
```

## What the demo shows

1. Edit a baselined skill → regression injected
2. `git push` fires the pre-push hook
3. Harness runs 3 cases, 1 fails
4. 3-sample stability check confirms real FAIL (not flaky)
5. 4-class attribution narrows to `SKILL_CHANGED`
6. 6-field FAIL output + `fix_proposal` rendered

The "money shot" is the attribution line. That's the differentiator vs every other LLM eval tool — they tell you _something_ failed, eval-harness tells you _why_.
