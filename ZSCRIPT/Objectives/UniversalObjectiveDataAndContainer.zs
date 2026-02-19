// UniversalObjectiveDataAndContainer.zs

// Single struct to hold objective data

class VUOS_ObjectiveData
{
    String objectiveDescription; // Description text displayed to the player
    name targetClass;            // Class name of the target actor (e.g. 'DoomImp')
    int targetCount;             // Number of targets required to complete
    int currentCount;            // Current progress toward targetCount
    int objectiveType;           // 0 = kill (WorldThingDied), 1 = destroy (WorldThingDestroyed)
    bool isHidden;               // If true, objective is not shown on HUD
    bool isCompleted;            // Whether this objective has been completed
    bool hasFailed;              // Whether this objective has failed
    bool isInverse;              // If true, FAIL when target reached instead of completing
    String mapName;              // Track which map this objective belongs to
    bool persist;                // If false, objective is deleted when leaving its map
    int timer;                   // For fade-out animation after completion/failure
    int timeLimit;               // Time limit in tics (35 tics = 1 second), 0 = no time limit
    int timeRemaining;           // Remaining time in tics
    bool isPrimary;              // If true, primary objective (green header), else secondary (grey header)
    bool requiredToComplete;     // If true, must be completed before exiting map
    int minSkillLevel;           // Minimum skill level for this objective (0-4, default 0 = all skills)
    int maxSkillLevel;           // Maximum skill level for this objective (0-4, default 4 = all skills)
    
    // Waypoint / spatial data
    vector3 waypointPos;    // World position for this objective's waypoint
    bool hasWaypoint;       // Whether this objective has a spatial location (false if waypoint is at origin 0,0,0)
    Array<int> cachedDistances; // Per-player cached distances in map units, updated periodically in WorldTick
    Actor markerActor;      // Reference to automap marker actor for this objective
    bool isTracked;         // If true, objective appears on waypoints, compass, and HUD (default: true)

    // Get cached distance for a specific player (multiplayer-safe)
    int GetDistance(int playerNum)
    {
        if (playerNum >= 0 && playerNum < cachedDistances.Size())
            return cachedDistances[playerNum];
        return 0;
    }

    // Set cached distance for a specific player (auto-grows array if needed)
    void SetDistance(int playerNum, int dist)
    {
        while (cachedDistances.Size() <= playerNum)
            cachedDistances.Push(0);
        cachedDistances[playerNum] = dist;
    }

    // Check if this objective is valid for the current game skill level
    // Uses G_SkillPropertyInt(SKILLP_ACSReturn) which returns 0-4 for standard Doom skills:
    //   0 = "I'm too young to die" (ITYTD)
    //   1 = "Hey, not too rough" (HNTR)
    //   2 = "Hurt me plenty" (HMP)
    //   3 = "Ultra-Violence" (UV)
    //   4 = "Nightmare!" (NM)
    // Pass skill >= 0 to avoid redundant G_SkillPropertyInt() calls in loops.
    bool IsValidForCurrentSkill(int skill = -1)
    {
        if (skill < 0) skill = G_SkillPropertyInt(SKILLP_ACSReturn);
        return (skill >= minSkillLevel && skill <= maxSkillLevel);
    }

    // Check if this objective should be visible on the current map.
    // Combines the three most common filter checks: map match, hidden state, and skill validity.
    // Pass skill >= 0 to avoid redundant G_SkillPropertyInt() calls in loops.
    bool IsVisibleForCurrentMap(int skill = -1)
    {
        if (!(mapName ~== level.MapName)) return false;
        if (isHidden) return false;
        return IsValidForCurrentSkill(skill);
    }
}

// Per-frame rendering settings populated once in RenderOverlay
// Passed to compass, waypoints, and other UI drawing methods to avoid
// redundant CVar lookups every frame across multiple classes.
class VUOS_RenderSettings
{
    // Shared settings (used by compass + waypoints + renderer)
    int distanceUnits;       // 0 = map units, 1 = meters
    int primaryColorIdx;     // Font.CR_ index for primary header
    int secondaryColorIdx;   // Font.CR_ index for secondary header

    // Compass settings
    bool compassShow;
    int compassStyle;        // 0 = procedural, 1 = textured
    double compassOpacity;
    int compassOffsetX;
    int compassOffsetY;
    int compassFOV;
    double compassScale;
    bool compassShowDistance;
    double compassTextScale;

    // Waypoint settings
    double waypointScale;
    int waypointMaxDistance;
    double waypointTextScale;
    int waypointStyle;       // 0 = procedural, 1 = textured

    // Refresh all CVar values in-place (called once per frame from RenderOverlay).
    // Avoids per-frame allocation — the single VUOS_RenderSettings instance is
    // created once on the renderer and reused every frame.
    void Refresh()
    {
        let p = players[consoleplayer];

        // Shared
        distanceUnits = VUOS_ObjectiveHandler.GetCVarInt('obj_distance_units', p, 1);
        primaryColorIdx = VUOS_ObjectiveHandler.GetCVarInt('obj_color_primary_header', p, 3);
        secondaryColorIdx = VUOS_ObjectiveHandler.GetCVarInt('obj_color_secondary_header', p, 21);

        // Compass
        compassShow = VUOS_ObjectiveHandler.GetCVarBool('obj_compass_show', p, true);
        compassStyle = VUOS_ObjectiveHandler.GetCVarInt('obj_compass_style', p, 0);
        compassOpacity = VUOS_ObjectiveHandler.GetCVarFloat('obj_compass_opacity', p, 0.90);
        compassOffsetX = VUOS_ObjectiveHandler.GetCVarInt('obj_compass_offset_x', p, 0);
        compassOffsetY = VUOS_ObjectiveHandler.GetCVarInt('obj_compass_offset_y', p, 0);
        compassFOV = VUOS_ObjectiveHandler.GetCVarInt('obj_compass_fov', p, 180);
        if (compassFOV < 45) compassFOV = 45;
        if (compassFOV > 360) compassFOV = 360;
        compassScale = VUOS_ObjectiveHandler.GetCVarFloat('obj_compass_scale', p, 0.75);
        if (compassScale < 0.5) compassScale = 0.5;
        if (compassScale > 2.0) compassScale = 2.0;
        compassShowDistance = VUOS_ObjectiveHandler.GetCVarBool('obj_compass_show_distance', p, true);
        compassTextScale = VUOS_ObjectiveHandler.GetCVarFloat('obj_compass_text_scale', p, 0.75);
        if (compassTextScale < 0.5) compassTextScale = 0.5;
        if (compassTextScale > 3.0) compassTextScale = 3.0;

        // Waypoints
        waypointScale = VUOS_ObjectiveHandler.GetCVarFloat('obj_waypoint_scale', p, 1.0);
        if (waypointScale < 0.25) waypointScale = 0.25;
        if (waypointScale > 3.0) waypointScale = 3.0;
        waypointMaxDistance = VUOS_ObjectiveHandler.GetCVarInt('obj_waypoint_max_distance', p, 0);
        if (waypointMaxDistance > 0 && distanceUnits == 1)
            waypointMaxDistance *= 32;
        waypointTextScale = VUOS_ObjectiveHandler.GetCVarFloat('obj_waypoint_text_scale', p, 0.75);
        if (waypointTextScale < 0.5) waypointTextScale = 0.5;
        if (waypointTextScale > 3.0) waypointTextScale = 3.0;
        waypointStyle = VUOS_ObjectiveHandler.GetCVarInt('obj_waypoint_style', p, 0);
    }
}