Vortex's Universal Objective System v0.1 12/2025.  
A clean, universal objective system for GZDoom/UZDoom mods.  
Based on Blade of Agony's architecture, simplified by Vortex for universal use.  
Can be used with pure ZScript or ZScript + ACS using the ACS bridge (OBJECTIVES_BRIDGE_ACS.txt).

## License
- MIT (see LICENSE file)
- Credit appreciated (see CREDITS.txt)

## Getting Started
- Start adding/removing/modifying your objectives in ObjectiveSetup.zs

## Display Modes

### HUD Mode (Simple, uses 'O' key by default)
- Always visible in top-left corner
- Shows only active/incomplete objectives
- Green "OBJECTIVES" header
- Single-column layout with progress counters inline
- Completed objectives turn green with [X] and fade out

### Full Objectives Screen (Detailed, uses 'J' key by default)
- Has background image screen (OBJBG.png)
- Shows ALL objectives (completed and incomplete)
- Two-column layout: descriptions on left, green progress counters on right
- Completed objectives stay visible in green with [X]

## Objective types
- TYPE_KILL for enemies/players (auto-tracked via WorldThingDied)
- TYPE_DESTROY for destructible actors (auto-tracked via WorldThingDestroyed)
- TYPE_COLLECT for items and pickups (manual tracking required)
- TYPE_CUSTOM for custom pickups/linedefs/buttons (manual tracking required)

## API Reference (Static Methods)
```text
Add(description, required, objType, targetClass, initialProgress)
UpdateProgress(description, progress)
Complete(description)
```

## API Reference (Instance Methods)
```text
IncrementProgress()  - Add 1 to progress, auto-completes if threshold met
MarkComplete()       - Force complete the objective
```

## Console commands
```text
obj_list           - List all objectives with status
obj_clear          - Clear all objectives
obj_test           - Add test objectives
obj_complete_test  - Complete first active objective
obj_complete_all   - Complete ALL active objectives
```

## CVars
```text
obj_show       - Full Objectives Screen display (default: false)
obj_hud_show   - HUD objectives display (default: true)
```

## Architecture
```text
UniversalObjective (Thinker)
- description     - Objective text
- current        - Current progress (e.g., 5)
- required       - Required amount (e.g., 10)
- completed      - Is it complete?
- objectiveType  - KILL/COLLECT/DESTROY/CUSTOM
- targetClass    - Actor class to auto-track
- timer          - For fade-out animation (105 tics / 3 seconds)

UniversalObjectiveHandler (EventHandler)
- objectives[]           - Array of all objectives
- objBackground          - Cached CRT monitor texture
- WorldThingDied()       - Auto-track kills
- WorldThingDestroyed()  - Auto-track destroys
- RenderOverlay()        - Draw HUD or Full Screen
- RenderHUD()            - Simple HUD mode rendering
- RenderFullScreen()     - Detailed screen rendering
- Static methods         - Console commands
```

## Examples

### Example 1: Kill Objective (Auto-tracked)
```c
class MAP01Handler : EventHandler
{
    override void WorldLoaded(WorldEvent e)
    {
        if (level.MapName ~== "MAP01")
        {
            // This will automatically count when DoomImps die
            UniversalObjective.Add("Kill 10 Imps", 10, 
                UniversalObjective.TYPE_KILL, "DoomImp");
        }
    }
}
```

### Example 2: Custom Objective with Manual Tracking
```c
class SwitchCounter : EventHandler
{
    int switchesActivated;

    override void WorldLoaded(WorldEvent e)
    {
        switchesActivated = 0;
        UniversalObjective.Add("Activate 3 switches", 3, 
            UniversalObjective.TYPE_CUSTOM);
    }

    override void NetworkProcess(ConsoleEvent e)
    {
        if (e.Name ~== "switch_activated")
        {
            switchesActivated++;
            UniversalObjective.UpdateProgress("Activate 3 switches", 
                switchesActivated);
        }
    }
}
```

### Example 3: Using Trigger Actors
```c
// Place this invisible actor in your map
class ExitTrigger : Actor
{
    Default
    {
        +NOBLOCKMAP
        +NOGRAVITY
    }

    States
    {
        Spawn:
            TNT1 A -1;
            Stop;
    }

    override void Touch(Actor toucher)
    {
        if (toucher && toucher.player)
        {
            UniversalObjective.Complete("Reach the exit");
            Destroy();
        }
    }
}
```


