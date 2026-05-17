# Touch Da Fishy

A small joke game for Playdate inspired by the classic cat-and-fish meme.

## Premise
You are a strange little cat paw trying to boop a fish in a bowl before it escapes.

## Objective
Score as many touches as you can before the fish gets away 3 times.

## Controls
- **Crank clockwise**: extend the paw toward the fish
- **Stop cranking**: the paw slowly retracts
- **Up / Down**: aim the paw vertically
- **A**: start the game / restart after game over

## How scoring works
A touch only counts if you:
- line up with the fish
- extend far enough to reach it
- are actively cranking enough for it to count as a real touch

This keeps the crank central to the gameplay rather than cosmetic.

## Game flow
1. Press **A** on the title screen
2. Aim with **Up / Down**
3. **Crank** to reach the fish
4. Score points by touching it
5. Avoid 3 misses or the run ends

## Style
The game is designed to match the meme-inspired title art:
- black-and-white comic look
- cat-paw-style reaching arm
- fish moving inside a bowl area
- chunky, silly arcade presentation

## Build
Compile from the project root:

```bash
pdc Source TouchDaFishy.pdx
```
