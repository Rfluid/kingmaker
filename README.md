# kingmaker

TidalCycles experiments.

## Setup

See [docs/ubuntu-setup.md](docs/ubuntu-setup.md) for a one-shot Ubuntu install
(apt deps, ghcup, tidal lib, SuperDirt, PipeWire/JACK, neovim plugin).

## Per-session boot

1. **sclang** — leave running:
   ```bash
   pw-jack sclang
   ```
   At the prompt:
   ```supercollider
   SuperDirt.start
   ```
2. **nvim** — open a `.tidal` file, then `:TidalLaunch`.
3. Cursor on a `d1 $ ...` line, `<S-CR>` to play.

Cleanup: `<leader><Esc>` (hush) → `:TidalQuit` → Ctrl-D in sclang.

## Keybindings (in `.tidal` buffers)

| Key             | Action                          |
| --------------- | ------------------------------- |
| `<S-CR>`        | Send line or visual selection   |
| `<M-CR>`        | Send contiguous block           |
| `<leader><CR>`  | Send expression under cursor    |
| `<leader>D`     | Silence pattern (takes count)   |
| `<leader><Esc>` | Hush all                        |

## Layout

- `experiments/` — sketches, one file per idea
- `samples/` — local sample packs (gitignored; SuperDirt ships Dirt-Samples)
- `docs/` — setup + notes
