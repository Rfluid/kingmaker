# Ubuntu setup

Tested on Ubuntu 24.04 LTS, PipeWire 1.0.5, SuperCollider 3.13.0, GHC 9.6.7.

## 1. System packages

```bash
sudo apt-get install -y \
  build-essential \
  libgmp-dev \
  supercollider
```

- `build-essential` — cabal builds Tidal's deps from source; needs `gcc`, `make`, etc.
- `libgmp-dev` — Haskell's `integer-gmp` links against system GMP. Without it
  `cabal install tidal --lib` fails with linker errors mid-build.
- `supercollider` — provides `sclang` (the language interpreter) and `scsynth`
  (the audio server).

## 2. Haskell toolchain via ghcup

```bash
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
```

Accept the defaults. ghcup writes its env file to `~/.ghcup/env` and tries to
wire `~/.profile` — which **zsh does not source**. For zsh, add this once to
your zsh init (already done in this repo owner's `workspace-config/zsh/zshenv`):

```sh
[ -f "$HOME/.ghcup/env" ] && . "$HOME/.ghcup/env"
```

In the current shell:

```bash
source ~/.ghcup/env
which ghc cabal ghci   # all under ~/.ghcup/bin/
```

## 3. Tidal Haskell library

```bash
cabal update
cabal install tidal --lib
```

5–10 min on first install (pulls a lot of transitive deps). Verify:

```bash
echo 'import Sound.Tidal.Context' | ghci -v0
```

No output = success. Error = re-check step 1 (especially `libgmp-dev`).

## 4. SuperDirt (SuperCollider quark)

One-time install — in `sclang`:

```bash
sclang
```

At the `sc3>` prompt, paste and Enter:

```supercollider
Quarks.checkForUpdates({Quarks.install("SuperDirt", "v1.7.3"); thisProcess.recompile()})
```

Wait for `compile done` followed by the SuperCollider welcome banner. Ctrl-D
to exit.

## 5. PipeWire / JACK — important

Ubuntu 24.04 uses **PipeWire** for audio. SuperCollider's default is to launch
real `jackd` if no JACK server is found — and real `jackd` grabs the audio
device exclusively, which preempts PipeWire and breaks audio for the browser,
system, everything.

**Always run `sclang` via PipeWire's JACK shim:**

```bash
pw-jack sclang
```

`pw-jack` makes scsynth's JACK client talk to PipeWire transparently — no
daemon collision, no audio takeover.

If you already ran raw `sclang` and broke audio:

```bash
pkill -TERM sclang scsynth jackd
```

PipeWire's sink will unsuspend the next time something plays.

## 6. Neovim plugin

Already wired in `~/.config/nvim/lua/plugins/tidal.lua`
([`grddavies/tidal.nvim`](https://github.com/grddavies/tidal.nvim)). On a fresh
machine, open nvim once and run `:Lazy sync`.

## Per-session boot

1. **Terminal A** (leave running):
   ```bash
   pw-jack sclang
   ```
   At the prompt:
   ```supercollider
   SuperDirt.start
   ```
   Wait for `SuperDirt: listening to Tidal on port 57120`.

2. **Terminal B**:
   ```bash
   nvim experiments/foo.tidal
   ```
   Then in nvim:
   ```
   :TidalLaunch
   ```
   Opens a vertical split with `ghci -v0` + bundled `BootTidal.hs`. Wait for
   the `tidal>` prompt.

3. Cursor on a `d1 $ ...` line, `<S-CR>` to play.

4. To stop: `<leader><Esc>` (hush) → `:TidalQuit` → Ctrl-D in sclang.
