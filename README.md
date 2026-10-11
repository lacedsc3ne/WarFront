# War Front

War Front is a Roblox game: a 2D territory-conquest strategy game where you grow your land, attack neighbours, build structures, send boats and launch nukes.

It is a modified port of **OpenFront** (https://github.com/openfrontio/OpenFrontIO), re-implemented in Luau for Roblox. It is not affiliated with or endorsed by OpenFront.

© OpenFront and Contributors

## Contents

- `src/` - the game's Luau scripts (ModuleScripts, server Scripts and client LocalScripts). The header comment of each file says what it does. Scripts nested in Studio are in matching subfolders (for example `src/NightMenu/Pages/`).
- `tools/` - Python scripts that generate the icon, flag, sprite, map catalog, quick-chat and tribe-name data modules from OpenFront's `resources/` folder (run them against a clone of the OpenFront repo).

Map terrain data is generated from Natural Earth (public domain) and stored in Roblox Studio under `ReplicatedStorage.Shared.Maps`. It is not included here, and neither are the menu background image modules (`MenuBackgroundData1`-`20`).

## License

The War Front source code is licensed under the **GNU Affero General Public License v3.0 or later** (see `LICENSE`), the same license as OpenFront.

OpenFront's images, sprites, flags and sounds used by the game are licensed under **CC BY-SA 4.0** by OpenFront and Contributors.
