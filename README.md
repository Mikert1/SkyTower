# Sky Tower

A precision platformer inspired by Jump King, built with the LÖVE 2D framework in Lua.

## Overview

This is a physics-based platformer where timing and precision are everything. Hold space to charge your jump, then release to leap with varying power. Navigate through platforms, avoid enemies, and reach the finish line as quickly as possible.

## Features

- **Charged Jump System**: Hold and release space to control jump power and angle
- **Speedrun Timer**: Track your completion times with best time saving
- **Physics-Based Movement**: Realistic gravity
- **Multiple Platform Types**:
  - Standard platforms
  - One-way platforms (can jump up through)
  - Ice platforms (reduced player control)
  - Platforms with enemy's
- **Enemy System**: Circular enemies that patrol platform perimeters
- **Level Editor Support**: Compatible with Tiled map editor (Library)
- **Camera System**: Smooth following camera with lookahead (Library)

## Controls

- **←/A, →/D**: Move left/right
- **Space**: Hold to charge jump, release to jump
- **R**: Restart from spawn point

## Installation & Running

### Dubble click the [.exe](run/SkyTower.exe)

Or

### Download love and clone the repository:
1. Install [LÖVE 2D](https://love2d.org/) (version 11.x recommended)
2. Clone or download this repository
3. Run the game:
   ```bash
   love path/to/game/directory
   ```
   Or drag the game folder onto the LÖVE executable

   *.love Files are dubble clickable if love is installed*

## Dependencies

The game uses the following Lua libraries:
- **[bump.lua](bump.lua)**: Physics collision detection ([GitHub](https://github.com/kikito/bump.lua))
- **[STI (Simple Tiled Implementation)](sti/)**: Optional Tiled map support ([GitHub](https://github.com/karai17/Simple-Tiled-Implementation))

## Level Creation

Levels can be created using the [Tiled Map Editor](https://www.mapeditor.org/). The game supports:

- **Object layers** for platforms and interactive elements
- **Custom properties**:
  - `oneWay`: Makes platforms passable from below
  - `ice`: Creates slippery surfaces
  - `moving`: Creates moving platforms
  - `enemy`: Adds patrolling enemies
  - `spawn`: Sets player spawn point
  - `finish`: Defines level completion area

Example Tiled maps are available in:
- [`maps/Template.tmx`](Template.tmx)

## Save Data

- Best completion times are automatically saved to `besttime.dat`
- Save data persists between game sessions

## Technical Details

- **Engine**: LÖVE 2D (Lua)
- **Physics**: Custom implementation with [`bump.lua`](bump.lua) for collision detection
- **Map Editor**: Tiled

*Master the jump, conquer the heights!*