# What changed in this update

The core complaint — "too easy, you only crank, the fish is always in the same
spot" — was a design bug, not a tuning issue: the fish swam all the way across
the screen, so the paw's whole reach lined up with it for several seconds and
aiming never mattered. This update makes the fish live and flop **on the plate**
so both the crank and the D-pad are required.

## Gameplay
- **Fish flops on the plate** instead of swimming across. It settles and
  idle-flops, crouches as a visible "tell," then **hops in an arc** to a new spot
  on the plate. You must track it with **Up/Down** and time your **crank reach**.
- **Boop needs both axes to line up.** The plate sits far right, so you must
  crank the paw out past ~64% of its range just to reach it, and the exact
  extension depends on whether the fish is near or far on the plate. A single aim
  height only covers part of the plate, so a fish that flops higher/lower forces
  a re-aim. The resting paw can't touch anything.
- **Miss = the fish escapes.** After a few flops it makes a big leap off the
  plate. You can still clutch-boop it mid-leap. 3 escapes ends the run.
- **Difficulty ramps with score** (`difficulty()` = score / 18, clamped 0..1):
  the fish settles for less time, hops farther, and bolts after fewer flops.

## Feel / polish
- Squash-and-stretch on wind-up and landing; tail whips during hops; tumble on escape.
- Agitation ticks appear right before the fish bolts (fair warning).
- "X" eyes + dizzy stars on a successful boop.
- Asset-free synth SFX: boop, hop, escape, game over (guarded; safe if sound is unavailable).
- Cleaner HUD (single slim top bar + one bottom hint) and a little cat reaching
  from the left to match the title art. Removed the old ramen-bowl clutter.

## Tuning knobs (top of Source/main.lua)
- Reach feel: `ARM_MAX_LENGTH`, `ARM_RETRACT_PER_FRAME`, `ARM_CRANK_MULTIPLIER`.
- Aim speed: `ARM_MOVE_SPEED`; aim range: `ARM_MIN_Y` / `ARM_MAX_Y`.
- Forgiveness: `PAW_RADIUS` + `FISH_HIT_RADIUS` (combined = how close counts).
- Plate area the fish uses: `PLATE_MIN/MAX_X` and `PLATE_MIN/MAX_Y`.
- Ramp: the `lerp(easy, hard, difficulty())` calls in `enterSettle`, `spawnFish`,
  and `beginHopOrEscape` (settle duration, flops before escape, hop height/speed).
- Boop sensitivity: `TOUCH_CRANK_THRESHOLD`, `TOUCH_ENERGY_THRESHOLD`.

## Build (on your Fedora machine)
```bash
cd TouchDaFishy_restart_kit
/home/stephen/Downloads/PlaydateSDK-3.0.6/bin/pdc Source TouchDaFishy.pdx
/home/stephen/Downloads/PlaydateSDK-3.0.6/bin/PlaydateSimulator TouchDaFishy.pdx
```
Or just run `tools/build.sh` (it auto-detects `pdc` via the `PLAYDATE_PDC` env var).

The code was syntax-checked with Lua 5.4 and run for 6000 simulated frames
through every fish state (settle → wind → hop → escape → game over → restart)
with no runtime errors, but it has not been compiled with the real Playdate SDK
or tested on hardware yet — give it a build and a play and tell me what to adjust.
