# Vortex's Universal Objective System (VUOS) v0.2.0

A universal objective and waypoint system for GZDoom/UZDoom mods.
Inspired by Blade of Agony, Hellscape Navigator, and Cynic Games Minimap.

- Pure ZScript or ZScript + ACS via the included bridge (`OBJECTIVES_BRIDGE_ACS.txt`)
- Compatible with Cynic Games Minimap mod (auto-detected at runtime)
- Full options menu under **Options > Universal Objectives**

## License

- MIT (see LICENSE file)
- Credit appreciated (see CREDITS.txt)

## Getting Started

1. Add VUOS to your project's load order
2. Customize your objectives in `ObjectiveSetup.zs` (subclass of `VUOS_ObjectiveHandler`)
3. Configure settings in-game via **Options > Universal Objectives**

## Features

### Objective Types
- **TYPE_KILL (0)** — Auto-tracked via `WorldThingDied`
- **TYPE_DESTROY (1)** — Auto-tracked via `WorldThingDestroyed`
- **TYPE_COLLECT (2)** — Manual tracking required
- **TYPE_CUSTOM (3)** — Manual tracking required

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

- **Warning mode** (default, no map editing) — Player gets visual/audio feedback when exiting with incomplete required objectives but exit still happens
- **True exit blocking** (requires map editing) — Edit the exit linedef to use ACS script `CheckObjectivesAndExit` and the exit physically won't work until all required primary objectives are complete

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

## Multiplayer / Co-op Notes

VUOS is primarily a single-player system, but its architecture avoids multiplayer desync by design. If your mod supports co-op, here's what you need to know:

**Shared state** — Objectives are stored on the `EventHandler` instance (server-side), not on any player's pawn. All players share the same objective list, progress, and completion state. If one player kills an imp that completes a kill objective, it completes for everyone.

**Per-player rendering** — HUD, journal, compass, and waypoint indicators render per-client using `consoleplayer`. Each player sees distances from their own position, can navigate the journal cursor independently, and has their own CVar settings (HUD position, scale, colors, etc.).

**Sound** — Completion, failure, and exit-blocking sounds play on all active players via `PlaySoundAllPlayers()`. No player misses a notification.

**For modders** — When overriding `NetworkProcess`, use `e.Player` to identify which player triggered the event. Avoid using `consoleplayer` in play-scope code (use `GetFirstPlayer()` or iterate `playeringame[]` instead). All static API methods (`Complete`, `Fail`, `UpdateProgress`, etc.) are multiplayer-safe.

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

### v0.2.0 (February 2026)

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
- Inverse objectives — auto-fail when target count reached instead of completing
- Timed objectives with configurable countdown and auto-fail
- Skill-level filtering (min/max skill per objective)
- Required objectives with two-mode exit blocking (warning or true ACS-based blocking)
- Event callbacks: `OnObjectiveComplete`, `OnObjectiveFail`, `OnObjectiveActivate`, `OnObjectiveReset`, `OnAllRequiredComplete`
- `OnAllRequiredComplete` fires when the last required objective on the current map is completed
- Failed objectives no longer permanently block map exit
- Objective tracking toggle (per-objective, controlled via journal cursor)
- `SetHidden`, `ResetObjective`, `RemoveObjective` methods
- `AddPrimaryObjective` / `AddSecondaryObjective` convenience methods
- Expanded query API: `Exists`, `IsComplete`, `IsActive`, `HasFailed`, `GetProgress`, `GetMaxProgress`

**Navigation & Spatial Features**
- Waypoint system — objectives can have 3D world positions (`SetWaypoint` / `ClearWaypoint`)
- Compass ribbon — horizontal bar with cardinal directions and waypoint diamonds
- On-screen 3D waypoint indicators with world-to-screen projection and off-screen arrows
- Automap markers (X or numbered 1–9) for waypoint objectives
- Automap legend overlay showing active objectives
- Distance display on HUD, compass, and waypoint indicators (map units or meters)

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
- `P` — Cycle HUD position
- `I` — Cycle waypoint indicator mode (Always On / Off / Toggle with HUD)
- `C` — Toggle compass ribbon
- `obj_help` console command added

**Compatibility**
- Cynic Games Minimap bridge with runtime auto-detection (zero overhead when not loaded)
- All keybinds rebindable under Options > Customize Controls > Objectives

**ACS Bridge Additions**
- `CheckObjectivesAndExit` — True exit blocking script
- `FailObjective` — Fail an objective from ACS
- `IncrementObjective` — Increment progress by 1
- `SetObjectiveHidden` — Show/hide objectives
- `ResetObjective` — Reset completed/failed objectives
- `SetObjectiveWaypoint` — Set waypoint position from map editor
- `obj_complete_all` — Complete all active objectives

### v0.1.0 (December 2025)

- Initial release
- Thinker-based objective system with auto-tracked kill and destroy types
- HUD mode and full objectives screen
- Pickup fade handler (optional add-on)
- Console commands for testing
- ACS bridge for ZScript interop
- Basic API: `Add`, `UpdateProgress`, `Complete`
