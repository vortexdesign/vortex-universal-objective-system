# Vortex's Universal Objective System (VUOS) v0.4.0

A universal objective and waypoint system for GZDoom/UZDoom mods.
Inspired by Blade of Agony, Hellscape Navigator, and Cynic Games Minimap.

- Pure ZScript or ZScript + ACS via the included bridge (`OBJECTIVES_BRIDGE_ACS.txt`)
- Compatible with Cynic Games Minimap mod (auto-detected at runtime)
- Full options menu under **Options > Universal Objectives**

## License

- MIT (see LICENSE file)
- Credit appreciated (see CREDITS.txt)

## Getting Started (Players)

1. Load the VUOS PK3 file alongside any GZDoom/UZDoom mod
2. Auto-generated objectives will appear for keys, bosses, exits, kills, and secrets
3. Customize what gets generated in **Options > Universal Objectives > Auto Objectives**
4. Optionally enable the random objectives layer for replayability variety. Each map can roll different objectives based on per-category spawn chances, with an optional rare "bounty" tier (e.g. "[BOUNTY] Slay the Cyberdemon"). Off by default, configure in **Options > Universal Objectives > Random Objectives Layer**.

## Getting Started (Modders)

1. Add VUOS to your project's load order
2. Define custom objectives in `ObjectiveSetup.zs` (subclass of `VUOS_ObjectiveHandler`)
3. Use `VUOS_AutoObjectives.SuppressMap("MAP01")` on maps where you define your own objectives
4. Configure settings in-game via **Options > Universal Objectives**

### Custom Enemy Scanners

Enemy mods that want to auto-generate objectives for their own monster classes (e.g. "Hunt the elite boss", "Rescue the civilians") don't need to modify VUOS. The clean pattern is a **standalone EventHandler** that calls VUOS's static API. Do NOT subclass `VUOS_ObjectiveSetup` for this - VUOS looks up the setup handler by exact class name, so a subclass becomes an orphan that doesn't participate in callbacks or regeneration.

Example - scan the map at load time for your mod's custom monster classes, create a kill objective per unique class with waypoints on each instance:

```c
class MyBossObjectives : EventHandler
{
    // Wait 3 tics so RandomSpawner-replaced actors are in the thinker list.
    // Without this delay, bosses spawned via RandomSpawner get missed at WorldLoaded.
    bool pendingScan;
    int scanDelayTics;

    override void WorldLoaded(WorldEvent e)
    {
        if (e.IsSaveGame) return;
        pendingScan = true;
        scanDelayTics = 0;
    }

    override void WorldTick()
    {
        if (!pendingScan) return;
        scanDelayTics++;
        if (scanDelayTics < 3) return;
        pendingScan = false;

        // Bucket instances by class name (one pass over all actors)
        Array<String> classNames;
        Array<int> classCounts;
        Array<Actor> allInstances;
        let it = ThinkerIterator.Create("Actor");
        Actor act;
        while (act = Actor(it.Next()))
        {
            if (!act.bIsMonster || act.Health <= 0) continue;
            String cn = act.GetClassName();

            // Replace these with your mod's own class names
            if (cn != "MyEliteBoss" && cn != "MyArcaneHunter"
                && cn != "MyArmoredBrute") continue;

            int idx = classNames.Find(cn);
            if (idx == classNames.Size())
            {
                classNames.Push(cn);
                classCounts.Push(1);
            }
            else
            {
                classCounts[idx]++;
            }
            allInstances.Push(act);
        }

        // Build one objective per unique class with waypoints
        for (int c = 0; c < classNames.Size(); c++)
        {
            String cn = classNames[c];
            int count = classCounts[c];

            // Collect this class's instance positions
            Array<double> posX, posY, posZ;
            Array<Actor> actors;
            String tag;
            for (int i = 0; i < allInstances.Size(); i++)
            {
                if (allInstances[i].GetClassName() != cn) continue;
                if (tag.Length() == 0) tag = allInstances[i].GetTag();
                posX.Push(allInstances[i].pos.X);
                posY.Push(allInstances[i].pos.Y);
                posZ.Push(allInstances[i].pos.Z);
                actors.Push(allInstances[i]);
            }
            if (tag.Length() == 0) tag = VUOS_AutoObjectives.CleanClassName(cn);

            String desc = count == 1
                ? String.Format("Hunt the %s", tag)
                : String.Format("Hunt %d %ss", count, tag);

            // Use the static VUOS API - no subclassing required
            VUOS_ObjectiveHandler.AddPrimaryObjective(desc, cn, count, 0 /* TYPE_KILL */);
            VUOS_ObjectiveHandler.SetWaypointMultiWithActors(desc, posX, posY, posZ, actors);
        }
    }
}
```

Register it in your mod's `ZMAPINFO`:

```
gameinfo
{
    AddEventHandlers = "MyBossObjectives"
}
```

**Why this works:**

- `AddPrimaryObjective` and `SetWaypointMultiWithActors` are static on `VUOS_ObjectiveHandler`, so any EventHandler can call them
- Objectives added this way default to `isAutoGenerated = false`, so they are not cleared when the user toggles `vuos_auto_*` CVars mid-map
- VUOS's built-in boss scanner checks for existing manual objectives by `targetClass` before creating its own, so it won't duplicate your "Hunt the elite boss" objective
- Kill tracking in VUOS is now replacement-aware (v0.4.0+), so mods that use `replaces Cacodemon` or subclass `Cacodemon` count against a `Cacodemon`-targeted objective

**Helpful reusables:** `VUOS_AutoObjectives.CleanClassName("ZombieManPlus")` returns `"Zombie Man Plus"` if you need a fallback display name when an actor has no tag.

**Inverse variant - Rescue / Don't-die objectives:**

For "escort" or "save the civilians" style scanners where every death is a failure condition (e.g. an Undead Nightmare-style mod where the goal is to prevent civilians from dying), set the `inverse` flag on `AddPrimaryObjective`. With inverse enabled the objective **fails** when the count is reached instead of completing, which matches the gameplay intent of rescue/escort scenarios:

```c
// Signature: AddPrimaryObjective(desc, target, count, objType, hidden, persist, inverse, ...)
// The 7th argument `true` flips kill tracking into fail-on-death semantics.
VUOS_ObjectiveHandler.AddPrimaryObjective(
    "Don't let the civilians die", cn, count,
    0 /* TYPE_KILL */, false /* hidden */, true /* persist */, true /* inverse */);
```

Everything else in the scanner loop stays the same (waypoints, tag resolution, bucketing). Only the flag and the description wording change.

### Suppressing Redundant Auto-Objectives

If your mod's custom objectives overlap with what VUOS auto-generates (kills, bosses, keys, secrets, exits), disable the overlap. Two levels of control:

**Per-map suppression** - disable ALL auto-generation on specific maps from your `VUOS_ObjectiveSetup` subclass:

```c
override void WorldLoaded(WorldEvent e)
{
    Super.WorldLoaded(e);

    // Suppress auto-generation on maps where you ship hand-crafted objectives
    if (level.MapName ~== "MAP03" || level.MapName ~== "MAP05")
    {
        VUOS_AutoObjectives.SuppressMap(level.MapName);
    }

    // (your per-map custom objectives go here)
}
```

**Per-category suppression** - tell players to set the relevant CVars to 0 in **Options > Universal Objectives > Auto Objectives**. For example, if your mod already tracks kills via its own progression system, `vuos_auto_kills = 0` disables the "Kill all enemies" auto-objective mod-wide without affecting keys, bosses, or secrets. If you want a mod-wide default, ship a `DEFCVARS` lump overriding the defaults.

### Survival & Hold-Out Objectives

VUOS's built-in `timeLimit` parameter **auto-fails** an objective when the timer expires - it's for "complete X within N seconds" scenarios. A "hold out for N seconds" survival objective is the inverse (complete when timer expires, fail if the player dies), so you drive it yourself via `TYPE_CUSTOM` plus your own WorldTick timer:

```c
class HordeSurvivalSetup : VUOS_ObjectiveSetup
{
    int survivalTicsRemaining;
    bool survivalActive;

    override void WorldLoaded(WorldEvent e)
    {
        Super.WorldLoaded(e);

        // TYPE_CUSTOM = 3: VUOS tracks and displays, your code controls completion
        AddPrimaryObjective("Hold the line for 60 seconds", '', 1, 3 /* TYPE_CUSTOM */);
        survivalTicsRemaining = 35 * 60;  // 35 tics per second
        survivalActive = true;

        // Your horde-spawning code goes here
    }

    override void WorldTick()
    {
        Super.WorldTick();
        if (!survivalActive) return;

        survivalTicsRemaining--;
        if (survivalTicsRemaining <= 0)
        {
            let obj = VUOS_ObjectiveHandler.FindByDescription("Hold the line for 60 seconds");
            if (obj) VUOS_ObjectiveHandler.CompleteObjective(obj);
            survivalActive = false;
        }
    }
}
```

Register your Setup subclass in your mod's `ZMAPINFO`:

```
gameinfo
{
    AddEventHandlers = "HordeSurvivalSetup"
}
```

The same pattern drives ambush scenarios, escort missions, defend-this-point objectives, and anything else where VUOS tracks the state and your mod's gameplay code decides when completion happens. Key rule: **VUOS tracks, your mod drives gameplay.**

### Granting Rewards on Objective Completion

The `OnObjectiveComplete` and `OnAllRequiredComplete` callbacks on your `VUOS_ObjectiveSetup` subclass are where to hook reward logic - weapons, XP, allies, inventory items, whatever your progression system uses:

```c
override void OnObjectiveComplete(string objectiveID)
{
    // Grant rewards based on which objective completed.
    // Loop over all players so the grant runs deterministically in multiplayer
    // (consoleplayer is per-client and would desync reward state).
    if (objectiveID == "Hunt the elite boss")
    {
        for (int i = 0; i < MAXPLAYERS; i++)
        {
            if (!playeringame[i] || !players[i].mo) continue;
            players[i].mo.GiveInventory("PlasmaRifle", 1);
            players[i].mo.GiveInventory("Cell", 40);
        }
        Console.Printf("\c[Gold]Reward: Plasma Rifle acquired!");
    }
    else if (objectiveID == "Hold the line for 60 seconds")
    {
        for (int i = 0; i < MAXPLAYERS; i++)
        {
            if (!playeringame[i] || !players[i].mo) continue;
            players[i].mo.GiveInventory("MyModXPToken", 500);
        }
        // Your ally-spawn code could go here too
    }
}

override void OnAllRequiredComplete()
{
    // Bigger reward when ALL required objectives on the current map are done
    for (int i = 0; i < MAXPLAYERS; i++)
    {
        if (!playeringame[i] || !players[i].mo) continue;
        players[i].mo.GiveInventory("BFG9000", 1);
    }
}
```

These callbacks fire on whichever `VUOS_ObjectiveSetup` subclass last registered itself as the "active setup" (handled automatically via `Super.WorldLoaded(e)`). Modders who want their subclass's callbacks to win over the base `VUOS_ObjectiveSetup` should set `SetOrder` higher than the default 0 in their subclass's `OnRegister`.

## Features

### Objective Types
- **TYPE_KILL (0)** - Auto-tracked via `WorldThingDied`
- **TYPE_DESTROY (1)** - Auto-tracked via `WorldThingDestroyed`
- **TYPE_COLLECT (2)** - Auto-tracked via inventory polling
- **TYPE_CUSTOM (3)** - Manual tracking required

### Primary & Secondary Objectives
Objectives are categorized as primary (green header) or secondary (cyan header). Primary objectives can be marked as required for map exit. Secondary objectives are optional challenges.

### Objective Failure & Inverse Objectives
Objectives can fail explicitly or via the inverse flag. An inverse objective automatically fails when its target count is reached instead of completing (e.g., "Don't destroy 4 barrels").

### Timed Objectives
Objectives can have a time limit in seconds. A countdown displays on the HUD and the objective auto-fails when time runs out.

### Skill-Level Filtering
Each objective has min/max skill level fields (0–4). Objectives outside the current skill range are automatically excluded.

### Exit Blocking
Two modes for preventing map exit until required objectives are complete:

- **Warning mode** (default, no map editing) - Player gets visual/audio feedback when exiting with incomplete required objectives but exit still happens
- **True exit blocking** (requires map editing) - Edit the exit linedef to use ACS script `CheckObjectivesAndExit` and the exit physically won't work until all required primary objectives are complete

### Event Callbacks
Override these in your `ObjectiveSetup` subclass:
```c
virtual void OnObjectiveComplete(string objectiveID) {}
virtual void OnObjectiveFail(string objectiveID) {}
virtual void OnObjectiveActivate(string objectiveID) {}
virtual void OnObjectiveReset(string objectiveID) {}
virtual void OnAllRequiredComplete() {}
```

## Display Modes

### HUD Mode (`O` key)
- Configurable position (top-left, top-right, bottom-left, bottom-right) with fine-tune offsets
- Shows active/incomplete objectives with progress counters
- Primary and secondary objectives grouped under colored headers
- Distance to waypoint objectives displayed inline
- Completed objectives flash green and fade out
- Failed objectives flash red and fade out
- Dims automatically when picking up items (configurable)

### Journal Screen (`J` key)
- Background image overlay (OBJBG.png)
- Shows ALL objectives including completed and failed
- Cursor navigation with Up/Down keys to select objectives
- Press Enter/Use to toggle tracking on selected objective
- Scrollable when objectives exceed visible area
- Two-column layout: descriptions on left, progress on right

### Compass Ribbon (`C` key to toggle)
- Horizontal bar at top of screen with cardinal/intercardinal direction labels
- Objective waypoints shown as colored diamonds (green = primary, cyan = secondary)
- Distance text below each diamond (configurable)
- Configurable FOV (45–360°), opacity, scale, and position offsets
- Procedural or textured rendering style
- Edge-clamped indicators for waypoints outside visible range

### On-Screen Waypoint Indicators (`I` key to cycle mode)
- 3D world-to-screen projected diamond indicators pointing to objective locations
- Distance-based alpha fade and icon scaling
- Off-screen arrows pointing toward out-of-view waypoints
- Procedural or textured rendering style
- Three modes: Always On, Always Off, Toggle with HUD

### Automap Markers
- Waypoint objectives appear as markers on the automap
- Two styles: X markers or numbered (1–9)
- Color-coded: green (primary), cyan (secondary), grey (untracked), yellow (completed), red (failed)
- Configurable via options menu

### Automap Legend
- Objective legend overlay displayed when automap is open
- Lists active objectives with their marker colors/numbers
- Configurable scale and show/hide for completed/failed objectives

### Cynic Games Minimap Bridge
- Auto-detects minimap mod at runtime via class lookup
- Syncs waypoint objectives to minimap waypoints
- Zero overhead when minimap is not loaded

### Random Objectives Layer (0.4.0+)
Optional layer on top of the auto-generator that rerolls which objectives appear per map. Off by default so upgraders get unchanged behavior; players opt in via menu or `vuos_random_enabled 1`.

- **Per-category spawn chance** (0-100%): each category (keys, puzzle items, bosses, exit, secret exit, kills, secrets) rolls independently per map. Defaults are tuned conservative (90% for keys, 100% for exit, 50-60% for the rest)
- **Subset sampling**: when a category has multiple candidates (e.g. 3 different key types on the map), pick N random ones instead of always all of them
- **Elite "bounty" tier**: rare additional objective (default 10% chance) that injects a hunt for a specific boss, key recovery, or kill-all challenge with a `[BOUNTY]` prefix in the description. Tier priority is boss > key > puzzle > kill-all fallback
- **Skill weighting**: optional multiplier on elite chance from 0.5x at ITYTD up to 1.75x at Nightmare
- **Minimum floor**: guarantee at least N objectives per map so bad rolls don't leave the map empty
- **Deterministic seeding**: same map + same skill + same salt produces the same roll outcomes; reload a save and you get the same objectives back
- **Reroll any time**: change `vuos_random_seed_salt` to get a fresh roll without changing map or skill
- **Live menu changes**: any setting tweak in the menu triggers automatic regeneration on the current map (no reload needed)
- **One-click reset**: "Reset Random Settings to Defaults" menu item or the `vuos_random_reset` console command restores all 16 random CVars to their defaults

For modders: the random layer also exposes `VUOS_RandomObjectives.ForceCategoryRoll(mapName, categoryName, result)` and `VUOS_RandomObjectives.ForceEliteClass(mapName, className)` static APIs for pinning specific outcomes on scripted maps. See the source for full signatures.

## Multiplayer / Co-op Notes

VUOS is primarily a single-player system, but its architecture avoids multiplayer desync by design. If your mod supports co-op, here's what you need to know:

**Shared state** - Objectives are stored on the `EventHandler` instance (server-side), not on any player's pawn. All players share the same objective list, progress, and completion state. If one player kills an imp that completes a kill objective, it completes for everyone.

**Per-player rendering** - HUD, journal, compass, and waypoint indicators render per-client using `consoleplayer`. Each player sees distances from their own position, can navigate the journal cursor independently, and has their own CVar settings (HUD position, scale, colors, etc.).

**Sound** - Completion, failure, and exit-blocking sounds play on all active players via `PlaySoundAllPlayers()`. No player misses a notification.

**For modders** - When overriding `NetworkProcess`, use `e.Player` to identify which player triggered the event. Avoid using `consoleplayer` in play-scope code (use `GetFirstPlayer()` or iterate `playeringame[]` instead). All static API methods (`Complete`, `Fail`, `UpdateProgress`, etc.) are multiplayer-safe.

## Keybinds

All rebindable under **Options > Customize Controls > Objectives**:

| Key | Action |
|-----|--------|
| `J` | Toggle journal screen |
| `O` | Toggle HUD objective list |
| `P` | Cycle HUD position (4 corners) |
| `I` | Cycle waypoint indicator mode |
| `C` | Toggle compass ribbon |

## API Reference

### Adding Objectives
```c
// Full parameters
static void AddObjective(
    String desc,                    // Description text
    name target = '',               // Actor class for auto-tracking
    int count = 1,                  // Required count
    int objType = 0,                // 0=kill, 1=destroy, 2=collect, 3=custom
    bool hidden = false,            // Hidden from HUD
    bool persist = true,            // Survive map changes
    bool inverse = false,           // Fail on target instead of complete
    int timeLimit = 0,              // Time limit in seconds (0=none)
    bool isPrimary = true,          // Primary or secondary
    int requiredToComplete = -1,    // Required for exit (-1=auto: primary=yes, secondary=no)
    int minSkillLevel = 0,          // Minimum skill (0-4)
    int maxSkillLevel = 4,          // Maximum skill (0-4)
    double wpX = 0, double wpY = 0, double wpZ = 0  // Waypoint position
)

// Convenience methods
static void AddPrimaryObjective(...)    // isPrimary = true
static void AddSecondaryObjective(...)  // isPrimary = false
static void AddPrimaryCollectObjective(desc, target, count, hidden, persist, requiredToComplete, minSkillLevel, maxSkillLevel, wpX, wpY, wpZ)    // objType=2, isPrimary=true
static void AddSecondaryCollectObjective(desc, target, count, hidden, persist, requiredToComplete, minSkillLevel, maxSkillLevel, wpX, wpY, wpZ)  // objType=2, isPrimary=false
```

### Progress & Completion
```c
static void UpdateProgress(String desc, int progress)  // Set absolute progress
static void IncrementProgress(String desc, int amount)  // Add to progress
static void Complete(String desc)                        // Force complete
static void Fail(String desc)                            // Force fail
static void ResetObjective(String desc)                  // Reset to active
static void RemoveObjective(String desc)                 // Delete entirely
```

### Waypoints
```c
static void SetWaypoint(String desc, double x, double y, double z)
static void ClearWaypoint(String desc)
```

### Queries
```c
static bool Exists(string objectiveID)
static bool IsComplete(string objectiveID)
static bool IsActive(string objectiveID)
static bool HasFailed(string objectiveID)
static int GetProgress(string objectiveID)
static int GetMaxProgress(string objectiveID)
static bool HasIncompleteRequiredObjectives()
static VUOS_ObjectiveData FindByDescription(String desc)
static VUOS_ObjectiveData FindByTargetClass(name targetClass, int objType)
```

### Utility
```c
static void SetHidden(String desc, bool hidden)
static void ClearAll()
```

## Console Commands
```
obj_help           - Show all commands
obj_list           - List all objectives with status and skill info
obj_clear          - Clear all objectives
obj_test           - Add test objectives
obj_complete_test  - Complete first active objective
obj_complete_all   - Complete ALL active objectives
vuos_auto_list     - Auto-objective debug info (requires obj_debug 1)
vuos_random_reset  - Reset all 16 vuos_random_* CVars to their defaults
```

## ACS Bridge Scripts
```
CompleteObjective(objName)           - Complete an objective
UpdateObjectiveProgress(objName, n)  - Set progress
SwitchActivated()                    - Increment switch counter
SecretFound()                        - Increment secret counter
CheckObjectivesAndExit()             - Exit blocking check
FailObjective(objName)               - Fail an objective
IncrementObjective(objName)          - Increment progress by 1
SetObjectiveHidden(objName, flag)    - Show/hide objective
ResetObjective(objName)              - Reset to active
SetObjectiveWaypoint(objName, x,y,z) - Set waypoint position
```

## Architecture
```
VUOS_ObjectiveData (Plain class)
  - objectiveDescription, targetClass, targetCount, currentCount
  - objectiveType, isCompleted, hasFailed, isInverse, isHidden
  - isPrimary, requiredToComplete, persist, mapName
  - timeLimit, timeRemaining, timer
  - minSkillLevel, maxSkillLevel
  - waypointPos, hasWaypoint, isTracked, cachedDistances
  - markerActor (automap marker reference)

VUOS_ObjectiveHandler (Abstract EventHandler)
  - objectives[] storage, hub persistence, auto-tracking
  - Static API methods, ACS bridge functions
  - Event callbacks (OnObjectiveComplete/Fail/Activate)
  - Automap marker management

VUOS_ObjectiveSetup (extends VUOS_ObjectiveHandler)
  - Your mod's objective definitions per map

VUOS_AutoObjectives (EventHandler)
  - Scans maps at load for keys, bosses, exits, kills, secrets
  - Per-category CVar toggles with primary/secondary priority
  - Auto-waypoints, per-map suppression, mid-map regeneration

VUOS_ObjectiveRenderer (EventHandler)
  - HUD mode, journal screen, notifications
  - Pickup fade, completion/failure message queues
  - Journal cursor navigation and tracking toggle

VUOS_ObjectiveCompass (UI class)
  - Compass ribbon rendering with cardinal labels
  - Waypoint diamond indicators with distance

VUOS_ObjectiveWaypoints (UI class)
  - 3D world-to-screen waypoint projection
  - Off-screen arrow indicators

VUOS_ObjectiveAutomap (MapMarker actor)
  - Automap marker sprites (X or numbered)

VUOS_ObjectiveAutomapOverlay (UI class)
  - Automap legend rendering

VUOS_ObjectiveMinimapBridge (EventHandler)
  - Cynic Games Minimap sync

VUOS_ObjectiveCommands (EventHandler)
  - Console command processing
```

## Examples

### Example 1: Kill Objective with Waypoint (Auto-tracked)
```c
class MyObjectiveSetup : VUOS_ObjectiveHandler
{
    override void WorldLoaded(WorldEvent e)
    {
        super.WorldLoaded(e);
        if (level.MapName ~== "MAP01")
        {
            VUOS_ObjectiveHandler.AddObjective("Kill 10 Imps", 'DoomImp', 10, 0,
                false, true, false, 0, true, -1, 0, 4, 1024, 2048, 0);
            //                                          waypoint at X=1024 Y=2048
        }
    }
}
```

### Example 2: Inverse Objective (Fail on Target)
```c
// Automatically fails when 4 barrels are destroyed
VUOS_ObjectiveHandler.AddSecondaryObjective("Don't destroy 4 barrels",
    'ExplosiveBarrel', 4, 1, false, true, true);
//                                        ^ inverse = true
```

### Example 3: Timed Objective
```c
// Must complete within 60 seconds or it fails
VUOS_ObjectiveHandler.AddObjective("Reach the exit in 60 seconds", '', 1, 3,
    false, true, false, 60);
//                      ^ timeLimit = 60 seconds
```

### Example 4: Event Callbacks
```c
class MyObjectiveSetup : VUOS_ObjectiveHandler
{
    override void OnObjectiveComplete(string objectiveID)
    {
        if (objectiveID == "Find the red key")
        {
            // Reveal a hidden objective when the key is found
            VUOS_ObjectiveHandler.SetHidden("Escape the base", false);
        }
    }

    override void OnObjectiveFail(string objectiveID)
    {
        if (objectiveID == "Protect the reactor")
            Console.Printf("The reactor has been destroyed!");
    }

    override void OnObjectiveReset(string objectiveID)
    {
        if (objectiveID == "Survive the ambush")
            Console.Printf("Objective reset - try again!");
    }

    override void OnAllRequiredComplete()
    {
        Console.Printf("All required objectives complete! Exit is unlocked!");
    }
}
```

### Example 5: Using Trigger Actors
```c
class ExitTrigger : Actor
{
    Default { +NOBLOCKMAP; +NOGRAVITY; }
    States { Spawn: TNT1 A -1; Stop; }

    override void Touch(Actor toucher)
    {
        if (toucher && toucher.player)
        {
            VUOS_ObjectiveHandler.Complete("Reach the exit");
            Destroy();
        }
    }
}
```

---

## Changelog

### v0.4.0 (April 2026)

**Random Objectives Layer (new)**
- New optional `VUOS_RandomObjectives` EventHandler that adds a seeded randomization layer on top of the auto-generator. Default OFF via `vuos_random_enabled` so upgraders get unchanged behavior; players opt in via menu or console.
- Per-category spawn chance CVars (0-100%) for keys, puzzle items, bosses, exit, secret exit, kills, and secrets. Each category rolls independently per map load with the seeded RNG.
- Subset sampling for keys/puzzle items/bosses: pick N random classes from the discovered pool instead of always generating objectives for ALL candidates. New CVars `vuos_random_sample_keys`, `vuos_random_sample_puzzleitems`, `vuos_random_sample_bosses`.
- Elite "bounty" tier: rare additional objective (default 10% chance, modifiable) that injects a focused hunt with `[BOUNTY]` description prefix. Tier priority is boss > key > puzzle > kill-all sentinel. Includes optional skill weighting (0.5x at ITYTD up to 1.75x at Nightmare) so elites scale with difficulty.
- Minimum floor fallback (`vuos_random_min_floor`, default 1): if all category rolls fail and the map would be empty, force-generates exit (and kill-all if needed) so the player always has at least one objective.
- Deterministic seeding via FNV-1a hash of `level.MapName + skill + vuos_random_seed_salt`. Same inputs always produce the same roll outcomes; save/reload preserves the rolled objective set. Change `vuos_random_seed_salt` to reroll without changing map or skill.
- Mid-map regeneration: any `vuos_random_*` CVar change (via menu or console) triggers automatic regeneration on the current map without needing a map reload.
- Modder Force* APIs: `VUOS_RandomObjectives.ForceCategoryRoll(mapName, categoryName, result)` pins a category's outcome on a specific map; `ForceEliteClass(mapName, className)` pins which class becomes the elite bounty. Both mirror the existing `SuppressMap()` pattern.
- New `vuos_random_reset` console alias chains `set` commands to restore all 16 `vuos_random_*` CVars to their defaults in one command. Available via menu as a SafeCommand item too.
- Full menu integration under **Options > Universal Objectives > Random Objectives Layer** with sliders for every CVar plus the reset action.

**Waypoint Fixes**
- Fixed pitch sign bug where on-screen waypoint indicators appeared to move WITH the player's aim instead of against it. Waypoints now correctly stay pinned to their world position when looking up or down.
- New `obj_waypoint_vertical_mode` setting (Options > Objectives > Waypoint Indicators > Vertical Mode) with two modes:
  - **Centered** - diamond pinned to the vertical middle of the screen, pitch ignored (compass-ribbon style)
  - **Fixed** (default) - full 3D projection, diamond stays anchored to the objective's world position

**Enemy Mod Compatibility**
- Auto-objective boss scan is now deferred 3 tics after map load so RandomSpawner-replaced actors have time to resolve. Custom bosses spawned via RandomSpawner are now detected by the auto-objective generator, and `total_monsters` counts are accurate for the "Kill All Enemies" objective.
- Kill and destroy objective tracking is now replacement-aware. An enemy mod that uses `replaces DoomImp` or subclasses DoomImp will now count toward objectives that target "DoomImp" by name, matching the same three-way match pattern VUAS already uses (direct name, `GetReplacee` chain, `is` subclass).

**Modder Subclass Callback Fix**
- Fixed a long-standing issue where virtual callbacks (`OnObjectiveComplete`, `OnObjectiveFail`, `OnObjectiveActivate`, `OnObjectiveReset`, `OnAllRequiredComplete`) never fired on modder subclasses of `VUOS_ObjectiveSetup`. Previously `GetSetupHandler()` used an exact-name `EventHandler.Find` lookup that silently ignored subclasses, so modders who registered their own `MyCustomSetup : VUOS_ObjectiveSetup` got no callbacks.
- `VUOS_ObjectiveRenderer` now owns an `activeSetup` reference, and `VUOS_ObjectiveHandler.WorldLoaded` registers `self` on it (inherited automatically by subclasses via `Super.WorldLoaded(e)`). `GetSetupHandler()` prefers this reference, falling back to the old Find lookup only when nothing has registered. Later-running subclasses win, so modders who want their subclass's callbacks to override the base sample should set `SetOrder` higher than the default 0.
- Matches the long-documented pattern VUAS already uses.

**Modder Documentation**
- New Getting Started (Modders) sections in the README with worked examples for:
  - **Custom Enemy Scanners** - standalone EventHandler pattern for enemy mods that want to auto-generate "Hunt the X" objectives from their own monster classes, including the 3-tic RandomSpawner delay and multi-position waypoint wiring
  - **Suppressing Redundant Auto-Objectives** - per-map `SuppressMap()` and per-category CVar disabling to prevent overlap with your mod's own progression tracking
  - **Survival & Hold-Out Objectives** - `TYPE_CUSTOM` with modder-owned tic counter and manual `CompleteObjective` for "hold the line for 60 seconds" scenarios (opposite of the built-in auto-fail `timeLimit` pattern)
  - **Granting Rewards on Objective Completion** - multiplayer-safe `OnObjectiveComplete` and `OnAllRequiredComplete` hooks with `GiveInventory` examples

### v0.3.0 (February 2026)

**Auto-Generate Objectives**
- Automatic objective generation for keys, puzzle items, bosses, exits, secret exits, kills, and secrets
- Per-category toggle with Primary/Secondary/Off priority selection
- Auto-waypoints for keys, puzzle items, bosses, and exit linedefs
- Optional secret sector waypoints (disabled by default to avoid spoilers)
- Kill tracking with fixed or dynamic count modes
- Singular/plural secret descriptions ("Find the secret" vs "Find all secrets")
- CVar change detection with mid-map regeneration (preserves current progress)
- Per-map suppression API (`SuppressMap`) for maps with custom objectives
- Settings applied after closing menu (uses deferred CVar caching to avoid false triggers)

**Multi-Waypoint Display**
- Configurable display mode for waypoint indicators, compass, and automap: show closest only or show all tracked waypoints
- Separate CVars for on-screen/compass (`vuos_waypoint_multi_mode`) and automap (`vuos_automap_multi_mode`)

### v0.2.0 (January 2026)

**Architecture Overhaul**
- Complete rewrite from Thinker-based to EventHandler-based objective storage
- Added `VUOS_` namespace prefix to all classes for mod compatibility
- Separated rendering into dedicated `VUOS_ObjectiveRenderer` class
- Replaced `UniversalObjective` (Thinker) with `VUOS_ObjectiveData` (plain class)
- Merged `ObjectiveFadeHandler_Optional` into `ObjectiveRenderer` (pickup fade now built-in)
- Hub persistence via EventHandler serialization (objectives survive map changes)
- ACS bridge rewritten to use `ScriptCall` instead of `ConsoleCommand`
- Multiplayer-safe architecture: per-player distance caching, journal cursors, sound on all players, play-scope avoids `consoleplayer`

**New Objective Features**
- Primary and secondary objective categories with separate colored headers
- Objective failure support (`Fail()`, `FailObjective()`)
- Inverse objectives - auto-fail when target count reached instead of completing
- Timed objectives with configurable countdown and auto-fail
- Skill-level filtering (min/max skill per objective)
- Required objectives with two-mode exit blocking (warning or true ACS-based blocking)
- Event callbacks: `OnObjectiveComplete`, `OnObjectiveFail`, `OnObjectiveActivate`, `OnObjectiveReset`, `OnAllRequiredComplete`
- `OnAllRequiredComplete` fires when the last required objective on the current map is completed
- Failed objectives no longer permanently block map exit
- Objective tracking toggle (per-objective, controlled via journal cursor)
- `SetHidden`, `ResetObjective`, `RemoveObjective` methods
- `AddPrimaryObjective` / `AddSecondaryObjective` convenience methods
- `AddPrimaryCollectObjective` / `AddSecondaryCollectObjective` convenience methods for inventory-polled collect objectives
- Expanded query API: `Exists`, `IsComplete`, `IsActive`, `HasFailed`, `GetProgress`, `GetMaxProgress`

**Navigation & Spatial Features**
- Waypoint system - objectives can have 3D world positions (`SetWaypoint` / `ClearWaypoint`)
- Compass ribbon - horizontal bar with cardinal directions and waypoint diamonds
- On-screen 3D waypoint indicators with world-to-screen projection and off-screen arrows
- Automap markers (X or numbered 1-9) for waypoint objectives
- Automap legend overlay showing active objectives
- Distance display on HUD, compass, and waypoint indicators (map units or meters)
- Configurable compass bearing interval (15, 30, 60, or 90 degrees)

**UI & Customization**
- Full options menu (`MENUDEF`) under Options > Universal Objectives
- Journal screen with cursor navigation (Up/Down) and tracking toggle (Enter/Use)
- HUD position cycling across 4 corners with fine-tune X/Y offsets
- 44 CVars for colors, positions, scales, opacity, styles, and behavior
- Configurable notification duration and center/console display options
- Procedural or textured rendering styles for compass and waypoint indicators
- Customizable colors for headers, objective states, notifications, and distance text
- Debug mode CVar (`obj_debug`) for development/troubleshooting

**Keybinds**
- `P` - Cycle HUD position
- `I` - Cycle waypoint indicator mode (Always On / Off / Toggle with HUD)
- `C` - Toggle compass ribbon
- `obj_help` console command added

**Compatibility**
- Cynic Games Minimap bridge with runtime auto-detection (zero overhead when not loaded)
- All keybinds rebindable under Options > Customize Controls > Objectives

**ACS Bridge Additions**
- `CheckObjectivesAndExit` - True exit blocking script
- `FailObjective` - Fail an objective from ACS
- `IncrementObjective` - Increment progress by 1
- `SetObjectiveHidden` - Show/hide objectives
- `ResetObjective` - Reset completed/failed objectives
- `SetObjectiveWaypoint` - Set waypoint position from map editor
- `obj_complete_all` - Complete all active objectives

### v0.1.0 (December 2025)

- Initial release
- Thinker-based objective system with auto-tracked kill and destroy types
- HUD mode and full objectives screen
- Pickup fade handler (optional add-on)
- Console commands for testing
- ACS bridge for ZScript interop
- Basic API: `Add`, `UpdateProgress`, `Complete`
