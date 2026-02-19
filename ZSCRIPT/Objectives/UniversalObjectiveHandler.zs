// VUOS_ObjectiveHandler.zs
// Event handler for objective system — stores objectives on the EventHandler
// instance (not on any player's pawn) for proper multiplayer/co-op support.

class VUOS_ObjectiveHandler : EventHandler abstract
{
    // ====================================================================
    // OBJECTIVE STORAGE
    // Stored on the EventHandler instance — persists across maps, serializes
    // with save/load, and doesn't depend on any specific player's pawn.
    // ====================================================================
    Array<VUOS_ObjectiveData> objectives;
    String previousMapName;  // Track previous map for non-persistent objective cleanup

    // CVar change tracking for responsive automap marker updates
    int prevMarkerStyle;       // Previous obj_automap_marker_style value
    bool prevMarkersEnabled;   // Previous obj_automap_markers value
    bool prevShowCompleted;    // Previous obj_automap_show_completed value
    bool prevMarkerCVarsInit;  // Whether the above have been initialized

    // Dirty flag for automap marker refresh — when true, the next periodic
    // refresh cycle (every 35 tics) will rebuild markers. Set by any operation
    // that affects marker state (add/complete/fail/remove objectives, waypoint changes).
    // CVar-triggered refreshes bypass this flag for immediate visual feedback.
    bool markersDirty;

    // ====================================================================
    // EVENT CALLBACKS - Override these in your own EventHandler
    // ====================================================================

    // Called when an objective is completed
    virtual void OnObjectiveComplete(string objectiveID) {}

    // Called when an objective fails
    virtual void OnObjectiveFail(string objectiveID) {}

    // Called when an objective is activated/added
    virtual void OnObjectiveActivate(string objectiveID) {}

    // Called when an objective is reset back to active
    virtual void OnObjectiveReset(string objectiveID) {}

    // Called when the last required objective on the current map is completed
    virtual void OnAllRequiredComplete() {}

    // ====================================================================
    // CORE METHODS
    // ====================================================================

    // Check if debug output is enabled via the obj_debug CVar
    static bool IsDebugEnabled()
    {
        PlayerInfo fp = GetFirstPlayer();
        if (!fp) return false;
        return GetCVarBool('obj_debug', fp);
    }

    // CVar helper methods — clearscope so they work from both play and UI contexts.
    // Eliminates the repetitive null-check pattern: let cv = CVar.GetCVar(...); val = cv ? cv.GetX() : default;
    clearscope static int GetCVarInt(string name, PlayerInfo p, int defaultVal = 0)
    {
        let cv = CVar.GetCVar(name, p);
        return cv ? cv.GetInt() : defaultVal;
    }

    clearscope static bool GetCVarBool(string name, PlayerInfo p, bool defaultVal = false)
    {
        let cv = CVar.GetCVar(name, p);
        return cv ? cv.GetBool() : defaultVal;
    }

    clearscope static double GetCVarFloat(string name, PlayerInfo p, double defaultVal = 0.0)
    {
        let cv = CVar.GetCVar(name, p);
        return cv ? cv.GetFloat() : defaultVal;
    }

    // Get the first valid player (multiplayer-safe alternative to consoleplayer)
    // Use this in play-scope methods instead of players[consoleplayer]
    static PlayerInfo GetFirstPlayer()
    {
        for (int i = 0; i < MAXPLAYERS; i++)
        {
            if (playeringame[i] && players[i].mo)
                return players[i];
        }
        return null;
    }

    // Centralized handler lookups — consolidates EventHandler.Find() to one location
    static VUOS_ObjectiveHandler GetSetupHandler()
    {
        return VUOS_ObjectiveHandler(EventHandler.Find('VUOS_ObjectiveSetup'));
    }

    static VUOS_ObjectiveRenderer GetRenderer()
    {
        return VUOS_ObjectiveRenderer(EventHandler.Find('VUOS_ObjectiveRenderer'));
    }

    // Play a sound on ALL active players' pawns (multiplayer-safe)
    // Replaces the old pattern of playing on GetFirstPlayer().mo only
    static void PlaySoundAllPlayers(Sound snd)
    {
        for (int i = 0; i < MAXPLAYERS; i++)
        {
            if (!playeringame[i] || !players[i].mo) continue;
            players[i].mo.A_StartSound(snd, CHAN_AUTO, CHANF_UI | CHANF_NOPAUSE, 1.0, ATTN_NONE);
        }
    }

    // Add a new objective
    // timeLimit is in seconds, will be converted to tics (35 tics = 1 second)
    // isPrimary: if true, shown as primary objective (green header), else secondary (grey header)
    // requiredToComplete: if true, must be completed before exiting map (default: true for primary, false for secondary)
    // minSkillLevel: minimum skill level for this objective (0-4, default 0 = all skills)
    // maxSkillLevel: maximum skill level for this objective (0-4, default 4 = all skills)
    //   Skill levels: 0=ITYTD, 1=HNTR, 2=HMP, 3=UV, 4=NM
    static void AddObjective(String desc, name target = '', int count = 1, int objType = 0, bool hidden = false, bool persist = true, bool inverse = false, int timeLimit = 0, bool isPrimary = true, int requiredToComplete = -1, int minSkillLevel = 0, int maxSkillLevel = 4, double wpX = 0, double wpY = 0, double wpZ = 0)
    {
        if (IsDebugEnabled()) Console.Printf("DEBUG: AddObjective called for: %s", desc);

        let handler = GetSetupHandler();
        if (!handler)
        {
            if (IsDebugEnabled()) Console.Printf("DEBUG: No handler found!");
            return;
        }

        // Create new objective data
        let obj = new("VUOS_ObjectiveData");
        obj.objectiveDescription = desc;         // Description text displayed to the player
        obj.targetClass = target;                // Class name of the target actor (e.g. 'DoomImp')
        obj.targetCount = count;                 // Number of targets required to complete
        obj.currentCount = 0;                    // Current progress toward targetCount
        obj.objectiveType = objType;             // 0 = kill (WorldThingDied), 1 = destroy (WorldThingDestroyed)
        obj.isHidden = hidden;                   // If true, objective is not shown on HUD
        obj.isCompleted = false;                 // Whether this objective has been completed
        obj.hasFailed = false;                   // Whether this objective has failed
        obj.isInverse = inverse;                 // If true, FAIL when target reached instead of completing
        obj.mapName = level.MapName;             // Track which map this objective belongs to
        obj.persist = persist;                   // If false, objective is deleted when leaving its map
        obj.timer = -1;                          // For fade-out animation after completion/failure
        obj.timeLimit = timeLimit * 35;          // Time limit in tics (35 tics = 1 second), 0 = no time limit
        obj.timeRemaining = obj.timeLimit;       // Remaining time in tics
        obj.isPrimary = isPrimary;               // If true, primary objective (green header), else secondary (grey header)
        obj.minSkillLevel = minSkillLevel;       // Minimum skill level for this objective (0-4, default 0 = all skills)
        obj.maxSkillLevel = maxSkillLevel;       // Maximum skill level for this objective (0-4, default 4 = all skills)

        // Waypoint position - set if any coordinate is non-zero
        // NOTE: A waypoint at exact world origin (0,0,0) will not register as having a waypoint.
        // This is an accepted limitation — world origin is rarely a valid objective location.
        obj.waypointPos = (wpX, wpY, wpZ);
        obj.hasWaypoint = (wpX != 0 || wpY != 0 || wpZ != 0);
        obj.isTracked = true;                     // All objectives tracked by default

        // Set requiredToComplete - defaults to true for primary, false for secondary if not specified
        if (requiredToComplete == -1)
            obj.requiredToComplete = isPrimary;
        else
            obj.requiredToComplete = (requiredToComplete != 0);

        handler.objectives.Push(obj);

        // Flag markers for refresh so numbering stays correct
        if (obj.hasWaypoint)
            MarkMarkersDirty();

        // Check if this objective is valid for current skill
        int skill = G_SkillPropertyInt(SKILLP_ACSReturn);
        bool validForSkill = obj.IsValidForCurrentSkill(skill);

        if (IsDebugEnabled()) Console.Printf("DEBUG: Added %s objective #%d for %s: %s (persist=%s, inverse=%s, required=%s, skill=%d-%d, validForSkill=%s)",
            obj.isPrimary ? "PRIMARY" : "SECONDARY",
            handler.objectives.Size(), obj.mapName, desc,
            persist ? "true" : "false",
            inverse ? "true" : "false",
            obj.requiredToComplete ? "true" : "false",
            obj.minSkillLevel, obj.maxSkillLevel,
            validForSkill ? "true" : "false");

        // Show notification if not hidden AND valid for current skill
        if (!hidden && validForSkill)
        {
            if (IsDebugEnabled()) Console.Printf("New Objective: %s", desc);
        }

        // Fire OnObjectiveActivate callback only if valid for current skill
        if (validForSkill)
        {
            handler.OnObjectiveActivate(desc);
        }
    }

    // Convenience method: Add a PRIMARY objective (isPrimary=true, requiredToComplete defaults to true)
    static void AddPrimaryObjective(String desc, name target = '', int count = 1, int objType = 0, bool hidden = false, bool persist = true, bool inverse = false, int timeLimit = 0, int requiredToComplete = -1, int minSkillLevel = 0, int maxSkillLevel = 4, double wpX = 0, double wpY = 0, double wpZ = 0)
    {
        AddObjective(desc, target, count, objType, hidden, persist, inverse, timeLimit, true, requiredToComplete, minSkillLevel, maxSkillLevel, wpX, wpY, wpZ);
    }

    // Convenience method: Add a SECONDARY objective (isPrimary=false, requiredToComplete defaults to false)
    static void AddSecondaryObjective(String desc, name target = '', int count = 1, int objType = 0, bool hidden = false, bool persist = true, bool inverse = false, int timeLimit = 0, int requiredToComplete = -1, int minSkillLevel = 0, int maxSkillLevel = 4, double wpX = 0, double wpY = 0, double wpZ = 0)
    {
        AddObjective(desc, target, count, objType, hidden, persist, inverse, timeLimit, false, requiredToComplete, minSkillLevel, maxSkillLevel, wpX, wpY, wpZ);
    }

    // Mark an objective as complete (play sound, show message, start fade)
    static void CompleteObjective(VUOS_ObjectiveData obj)
    {
        if (!obj || obj.isCompleted || obj.hasFailed) return;

        obj.isCompleted = true;

        // Flag markers for refresh — RefreshAllMarkers will either respawn
        // as a completed marker (yellow) or destroy it based on CVars
        MarkMarkersDirty();

        // Read notification duration from CVar
        PlayerInfo fp = GetFirstPlayer();
        obj.timer = GetCVarInt('obj_notification_duration', fp, 105);
        if (obj.timer < 35) obj.timer = 35;

        // Play completion sound on ALL players
        PlaySoundAllPlayers("misc/p_pkup");

        // Tell VUOS_ObjectiveRenderer to display completion message
        let fadeHandler = GetRenderer();
        if (fadeHandler)
        {
            fadeHandler.ShowCompletionMessage(obj.objectiveDescription);
        }

        if (IsDebugEnabled()) Console.Printf("Objective Complete: %s", obj.objectiveDescription);

        // Fire OnObjectiveComplete callback
        let handler = GetSetupHandler();
        if (handler)
        {
            handler.OnObjectiveComplete(obj.objectiveDescription);

            // If this was required and all required objectives are now complete, fire OnAllRequiredComplete
            if (obj.requiredToComplete && !HasIncompleteRequiredObjectives())
            {
                handler.OnAllRequiredComplete();
            }
        }
    }

    // Mark an objective as failed (play sound, show message, turn red)
    static void FailObjective(VUOS_ObjectiveData obj)
    {
        if (!obj || obj.isCompleted || obj.hasFailed) return;

        obj.hasFailed = true;

        // Flag markers for refresh — RefreshAllMarkers will either respawn
        // as a failed marker (red) or destroy it based on CVars
        MarkMarkersDirty();

        // Read notification duration from CVar
        PlayerInfo fp = GetFirstPlayer();
        obj.timer = GetCVarInt('obj_notification_duration', fp, 105);
        if (obj.timer < 35) obj.timer = 35;

        if (IsDebugEnabled()) Console.Printf("DEBUG: FailObjective called - about to play failure sound");

        // Play failure sound on ALL players
        PlaySoundAllPlayers("*usefail");

        // Tell VUOS_ObjectiveRenderer to display failure message
        let fadeHandler = GetRenderer();
        if (fadeHandler)
        {
            fadeHandler.ShowFailureMessage(obj.objectiveDescription);
        }

        if (IsDebugEnabled()) Console.Printf("Objective Failed: %s", obj.objectiveDescription);

        // Fire OnObjectiveFail callback
        let handler = GetSetupHandler();
        if (handler)
        {
            handler.OnObjectiveFail(obj.objectiveDescription);
        }
    }

    // Remove an objective by description
    static void RemoveObjective(String desc)
    {
        let handler = GetSetupHandler();
        if (!handler) return;

        for (int i = 0; i < handler.objectives.Size(); i++)
        {
            if (handler.objectives[i].objectiveDescription ~== desc)
            {
                DestroyMarker(handler.objectives[i]);
                handler.objectives.Delete(i);
                MarkMarkersDirty();
                return;
            }
        }
    }

    // Show or hide an objective by description
    // Use to reveal hidden objectives later (e.g. after completing a prerequisite)
    static void SetHidden(String desc, bool hidden)
    {
        let obj = FindByDescription(desc);
        if (!obj) return;

        obj.isHidden = hidden;
        MarkMarkersDirty();
    }

    // Reset a completed or failed objective back to active with progress zeroed
    // Use for repeatable objectives or "try again" mechanics
    static void ResetObjective(String desc)
    {
        let obj = FindByDescription(desc);
        if (!obj) return;

        obj.isCompleted = false;
        obj.hasFailed = false;
        obj.currentCount = 0;
        obj.timer = -1;

        // Reset timer if timed objective
        if (obj.timeLimit > 0)
            obj.timeRemaining = obj.timeLimit;

        MarkMarkersDirty();

        // Fire OnObjectiveReset callback
        let handler = GetSetupHandler();
        if (handler)
        {
            handler.OnObjectiveReset(desc);
        }
    }

    // Set or update the waypoint position for an existing objective
    static void SetWaypoint(String desc, double x, double y, double z)
    {
        let obj = FindByDescription(desc);
        if (!obj) return;

        obj.waypointPos = (x, y, z);
        obj.hasWaypoint = (x != 0 || y != 0 || z != 0); // (0,0,0) clears waypoint — use ClearWaypoint() for explicit removal
        obj.cachedDistances.Clear();

        // Flag markers for refresh so numbering stays correct
        MarkMarkersDirty();
    }

    // Remove the waypoint from an existing objective
    static void ClearWaypoint(String desc)
    {
        let obj = FindByDescription(desc);
        if (!obj) return;

        DestroyMarker(obj);
        obj.waypointPos = (0, 0, 0);
        obj.hasWaypoint = false;
        obj.cachedDistances.Clear();

        // Flag markers for refresh (numbering may change)
        MarkMarkersDirty();
    }

    // ====================================================================
    // AUTOMAP MARKER MANAGEMENT
    // ====================================================================

    // Flag that markers need rebuilding on the next periodic refresh cycle.
    // Use this instead of calling RefreshAllMarkers() directly for deferred updates
    // (objective state changes, waypoint changes). CVar-triggered refreshes
    // call RefreshAllMarkers() directly for immediate visual feedback.
    static void MarkMarkersDirty()
    {
        let handler = GetSetupHandler();
        if (handler) handler.markersDirty = true;
    }

    // Spawn an automap marker for an objective with a waypoint.
    // markerNumber: 0 = use X marker, 1-9 = use numbered marker sprite.
    // When markerNumber > 9 or style is X mode, falls back to X marker.
    // Completed/failed objectives always use VOMK X marker with yellow/red frame.
    // Frame indices: A(0)=primary, B(1)=secondary, C(2)=untracked, D(3)=completed, E(4)=failed
    static void SpawnMarker(VUOS_ObjectiveData obj, int markerNumber = 0)
    {
        if (!obj || !obj.hasWaypoint) return;
        if (!(obj.mapName ~== level.MapName)) return; // Don't spawn markers for other maps

        // Check CVAR
        if (!GetCVarBool('obj_automap_markers', GetFirstPlayer(), true)) return;

        // Destroy existing marker first
        DestroyMarker(obj);

        // Spawn marker at waypoint position
        let marker = Actor.Spawn("VUOS_ObjectiveMarker", obj.waypointPos);
        if (marker)
        {
            marker.ChangeStatNum(Actor.STAT_MAPMARKER);
            marker.args[2] = 1; // Scale with automap zoom

            // Completed/failed always use VOMK X marker with special frames
            if (obj.isCompleted)
            {
                marker.sprite = Actor.GetSpriteIndex('VOMK');
                marker.frame = 3; // D = completed/yellow
            }
            else if (obj.hasFailed)
            {
                marker.sprite = Actor.GetSpriteIndex('VOMK');
                marker.frame = 4; // E = failed/red
            }
            else
            {
                // Active objective: pick frame based on tracking state
                // Frame 0 = A (primary/green), Frame 1 = B (secondary/cyan), Frame 2 = C (untracked/grey)
                int frameIdx;
                if (!obj.isTracked)
                    frameIdx = 2; // Grey for untracked
                else
                    frameIdx = obj.isPrimary ? 0 : 1; // Green for primary, cyan for secondary

                if (markerNumber >= 1 && markerNumber <= 9)
                {
                    // Numbered mode: set sprite to VOM1-VOM9
                    if      (markerNumber == 1) marker.sprite = Actor.GetSpriteIndex('VOM1');
                    else if (markerNumber == 2) marker.sprite = Actor.GetSpriteIndex('VOM2');
                    else if (markerNumber == 3) marker.sprite = Actor.GetSpriteIndex('VOM3');
                    else if (markerNumber == 4) marker.sprite = Actor.GetSpriteIndex('VOM4');
                    else if (markerNumber == 5) marker.sprite = Actor.GetSpriteIndex('VOM5');
                    else if (markerNumber == 6) marker.sprite = Actor.GetSpriteIndex('VOM6');
                    else if (markerNumber == 7) marker.sprite = Actor.GetSpriteIndex('VOM7');
                    else if (markerNumber == 8) marker.sprite = Actor.GetSpriteIndex('VOM8');
                    else if (markerNumber == 9) marker.sprite = Actor.GetSpriteIndex('VOM9');
                    marker.frame = frameIdx;
                }
                else
                {
                    // X mode: VOMK frame A (primary), B (secondary), or C (untracked)
                    marker.frame = frameIdx;
                }
            }

            obj.markerActor = marker;
        }
    }

    // Destroy the automap marker for an objective
    static void DestroyMarker(VUOS_ObjectiveData obj)
    {
        if (!obj) return;

        if (obj.markerActor)
        {
            obj.markerActor.Destroy();
            obj.markerActor = null;
        }
    }

    // Refresh all automap markers with correct numbering.
    // Called from WorldTick when the markersDirty flag is set, and directly
    // on CVar changes for immediate visual feedback. Clears the dirty flag
    // on completion.
    // Uses the same ordering as the legend: primary first, then secondary,
    // filtered to active (not completed, not failed) objectives with waypoints.
    // Completed/failed objectives get yellow/red X markers when CVar is enabled.
    static void RefreshAllMarkers()
    {
        let handler = GetSetupHandler();
        if (!handler) return;

        PlayerInfo fp = GetFirstPlayer();
        if (!fp) return;

        // Check if markers are enabled
        bool markersEnabled = GetCVarBool('obj_automap_markers', fp, true);

        // Check marker style (0 = X, 1 = numbered)
        int markerStyle = GetCVarInt('obj_automap_marker_style', fp, 0);

        // Check if completed/failed markers should be shown
        bool showCompleted = GetCVarBool('obj_automap_show_completed', fp, true);

        int skill = G_SkillPropertyInt(SKILLP_ACSReturn);

        // Build ordered list of active waypoint objectives (primary first, then secondary)
        // This MUST match the ordering used in ObjectiveAutomapOverlay.DrawAutomapLegend
        Array<VUOS_ObjectiveData> activeWaypoints;
        // Primary first
        for (int i = 0; i < handler.objectives.Size(); i++)
        {
            let obj = handler.objectives[i];
            if (!obj.IsVisibleForCurrentMap(skill)) continue;
            if (obj.isCompleted || obj.hasFailed) continue;
            if (!obj.hasWaypoint) continue;
            if (obj.isPrimary) activeWaypoints.Push(obj);
        }
        // Then secondary
        for (int i = 0; i < handler.objectives.Size(); i++)
        {
            let obj = handler.objectives[i];
            if (!obj.IsVisibleForCurrentMap(skill)) continue;
            if (obj.isCompleted || obj.hasFailed) continue;
            if (!obj.hasWaypoint) continue;
            if (!obj.isPrimary) activeWaypoints.Push(obj);
        }

        // Build list of completed/failed waypoint objectives (if CVar enabled)
        Array<VUOS_ObjectiveData> finishedWaypoints;
        if (showCompleted)
        {
            for (int i = 0; i < handler.objectives.Size(); i++)
            {
                let obj = handler.objectives[i];
                if (!obj.IsVisibleForCurrentMap(skill)) continue;
                if (!obj.isCompleted && !obj.hasFailed) continue;
                if (!obj.hasWaypoint) continue;
                finishedWaypoints.Push(obj);
            }
        }

        // Destroy markers for objectives that should NOT have markers
        for (int i = 0; i < handler.objectives.Size(); i++)
        {
            let obj = handler.objectives[i];
            if (!obj.markerActor) continue;

            bool shouldHaveMarker = markersEnabled
                && obj.hasWaypoint
                && obj.IsVisibleForCurrentMap(skill);

            // Active objectives always get markers; completed/failed only when CVar is on
            if (obj.isCompleted || obj.hasFailed)
                shouldHaveMarker = shouldHaveMarker && showCompleted;

            if (!shouldHaveMarker)
                DestroyMarker(obj);
        }

        if (!markersEnabled) return;

        // Spawn/update markers for active objectives with correct numbering
        for (int i = 0; i < activeWaypoints.Size(); i++)
        {
            let obj = activeWaypoints[i];
            int number = (markerStyle == 1) ? (i + 1) : 0;

            // If number exceeds 9, fall back to X marker
            if (number > 9) number = 0;

            // Always respawn to ensure correctness
            // (only runs when dirty flag is set, so performance is minimal)
            if (obj.markerActor) DestroyMarker(obj);
            SpawnMarker(obj, number);
        }

        // Spawn/update markers for completed/failed objectives (always X markers)
        for (int i = 0; i < finishedWaypoints.Size(); i++)
        {
            let obj = finishedWaypoints[i];
            if (obj.markerActor) DestroyMarker(obj);
            SpawnMarker(obj, 0); // Always X marker for completed/failed
        }

        // Markers are now up to date — clear the dirty flag
        handler.markersDirty = false;
    }

    // Clear all objectives
    static void ClearAll()
    {
        let handler = GetSetupHandler();
        if (!handler) return;

        // Destroy all automap markers before clearing
        for (int i = 0; i < handler.objectives.Size(); i++)
            DestroyMarker(handler.objectives[i]);

        handler.objectives.Clear();
        Console.Printf("All objectives cleared");
    }

    // Find objective by description
    static VUOS_ObjectiveData FindByDescription(String desc)
    {
        let handler = GetSetupHandler();
        if (!handler) return null;

        for (int i = 0; i < handler.objectives.Size(); i++)
        {
            if (handler.objectives[i].objectiveDescription ~== desc)
                return handler.objectives[i];
        }
        return null;
    }

    // Find objective by target class and type
    static VUOS_ObjectiveData FindByTargetClass(name targetClass, int objType)
    {
        let handler = GetSetupHandler();
        if (!handler) return null;

        for (int i = 0; i < handler.objectives.Size(); i++)
        {
            let obj = handler.objectives[i];
            if (obj.targetClass == targetClass && obj.objectiveType == objType)
                return obj;
        }
        return null;
    }

    // ====================================================================
    // STATIC QUERY METHODS
    // ====================================================================

    // Check if an objective exists (any state)
    static bool Exists(string objectiveID)
    {
        let obj = FindByDescription(objectiveID);
        return obj != null;
    }

    // Check if an objective is complete
    static bool IsComplete(string objectiveID)
    {
        let obj = FindByDescription(objectiveID);
        return obj ? obj.isCompleted : false;
    }

    // Check if an objective exists and is active (not completed, not failed)
    static bool IsActive(string objectiveID)
    {
        let obj = FindByDescription(objectiveID);
        return obj ? (!obj.isCompleted && !obj.hasFailed) : false;
    }

    // Get current progress count
    static int GetProgress(string objectiveID)
    {
        let obj = FindByDescription(objectiveID);
        return obj ? obj.currentCount : 0;
    }

    // Get maximum progress count
    static int GetMaxProgress(string objectiveID)
    {
        let obj = FindByDescription(objectiveID);
        return obj ? obj.targetCount : 0;
    }

    // Check if an objective has failed
    static bool HasFailed(string objectiveID)
    {
        let obj = FindByDescription(objectiveID);
        return obj ? obj.hasFailed : false;
    }

    // Check if there are any incomplete required objectives for current map
    // Only considers objectives valid for the current skill level
    static bool HasIncompleteRequiredObjectives()
    {
        let handler = GetSetupHandler();
        if (!handler) return false;

        int skill = G_SkillPropertyInt(SKILLP_ACSReturn);
        for (int i = 0; i < handler.objectives.Size(); i++)
        {
            let obj = handler.objectives[i];

            // Skip objectives not visible on the current map (wrong map, hidden, or wrong skill)
            if (!obj.IsVisibleForCurrentMap(skill))
                continue;

            // If this objective is required and not completed, return true
            // Skip failed objectives — they can never be completed, so they
            // should not permanently block the exit
            if (obj.requiredToComplete && !obj.isCompleted && !obj.hasFailed)
                return true;
        }

        return false;
    }

    // ====================================================================
    // ACS BRIDGE METHODS
    // Called via ScriptCall from ACS scripts (e.g. OBJECTIVES_BRIDGE_ACS)
    // These accept string descriptions so ACS can reference objectives by name
    // ====================================================================

    // Complete an objective by description (ACS-callable wrapper)
    static void Complete(String desc)
    {
        let obj = FindByDescription(desc);
        if (obj) CompleteObjective(obj);
    }

    // Fail an objective by description (ACS-callable wrapper)
    static void Fail(String desc)
    {
        let obj = FindByDescription(desc);
        if (obj) FailObjective(obj);
    }

    // Update objective progress by description (ACS-callable wrapper)
    // Auto-completes or auto-fails (if inverse) when targetCount is reached
    static void UpdateProgress(String desc, int progress)
    {
        let obj = FindByDescription(desc);
        if (!obj || obj.isCompleted || obj.hasFailed) return;

        obj.currentCount = progress;

        if (obj.targetCount > 0 && obj.currentCount >= obj.targetCount)
        {
            if (obj.isInverse)
                FailObjective(obj);
            else
                CompleteObjective(obj);
        }
    }

    // Increment objective progress by amount (default 1)
    // Auto-completes or auto-fails (if inverse) when targetCount is reached
    static void IncrementProgress(String desc, int amount = 1)
    {
        let obj = FindByDescription(desc);
        if (!obj || obj.isCompleted || obj.hasFailed) return;

        obj.currentCount += amount;

        if (obj.targetCount > 0 && obj.currentCount >= obj.targetCount)
        {
            if (obj.isInverse)
                FailObjective(obj);
            else
                CompleteObjective(obj);
        }
    }

    // Signal a switch activation (ACS-callable, replaces ConsoleCommand("netevent switch_activated"))
    static void ACS_SwitchActivated()
    {
        EventHandler.SendNetworkEvent("switch_activated");
    }

    // Signal a secret found (ACS-callable, replaces ConsoleCommand("netevent secret_found"))
    static void ACS_SecretFound()
    {
        EventHandler.SendNetworkEvent("secret_found");
    }

    // Check objectives and exit map (ACS-callable, replaces ConsoleCommand("netevent check_objectives_and_exit"))
    static void ACS_CheckObjectivesAndExit()
    {
        EventHandler.SendNetworkEvent("check_objectives_and_exit");
    }

    // Generic event forwarder (ACS-callable, replaces ConsoleCommand("netevent <name>"))
    static void ACS_SendEvent(String eventName)
    {
        EventHandler.SendNetworkEvent(eventName);
    }

    // ====================================================================
    // EVENT HANDLERS
    // ====================================================================

    // Clean up non-persistent objectives when changing maps
    // Lives in the handler (not renderer) because it mutates objective data.
    // VUOS_ObjectiveSetup.WorldLoaded calls Super.WorldLoaded(e) so this runs
    // before new objectives are created, guaranteeing correct ordering.
    override void WorldLoaded(WorldEvent e)
    {
        if (IsDebugEnabled()) Console.Printf("DEBUG: WorldLoaded fired in VUOS_ObjectiveHandler");

        String currentMap = level.MapName;
        if (IsDebugEnabled()) Console.Printf("DEBUG: previousMapName='%s', currentMap='%s'", previousMapName, currentMap);

        // If we're on a new map (not first load and not same map)
        if (previousMapName.Length() > 0 && !(previousMapName ~== currentMap))
        {
            if (IsDebugEnabled()) Console.Printf("DEBUG: Map changed from %s to %s, cleaning up non-persistent objectives", previousMapName, currentMap);

            // Delete non-persistent objectives from the previous map
            int skill = G_SkillPropertyInt(SKILLP_ACSReturn);
            for (int i = objectives.Size() - 1; i >= 0; i--)
            {
                let obj = objectives[i];

                if (IsDebugEnabled()) Console.Printf("DEBUG: Checking objective '%s' - mapName='%s', persist=%s, validSkill=%s",
                    obj.objectiveDescription, obj.mapName, obj.persist ? "true" : "false",
                    obj.IsValidForCurrentSkill(skill) ? "true" : "false");

                // If objective is from previous map AND not persistent, delete it
                if ((obj.mapName ~== previousMapName) && !obj.persist)
                {
                    if (IsDebugEnabled()) Console.Printf("DEBUG: Deleting non-persistent objective: %s", obj.objectiveDescription);
                    objectives.Delete(i);
                }
            }
        }
        else
        {
            if (IsDebugEnabled()) Console.Printf("DEBUG: Skipping cleanup - previousMapName.Length=%d, maps match=%s",
                previousMapName.Length(), (previousMapName ~== currentMap) ? "true" : "false");
        }

        // Update previous map name for next map change
        previousMapName = currentMap;
        if (IsDebugEnabled()) Console.Printf("DEBUG: Set previousMapName to '%s'", previousMapName);

        // Flag markers for refresh on new map (different objectives may be visible)
        markersDirty = true;
    }

    // Countdown timed objectives and cache per-player distances
    override void WorldTick()
    {
        // Update every 6 tics (~6 times per second) for distance caching
        bool updateDistance = (level.maptime % 6 == 0);

        // Countdown timers for all timed objectives FOR CURRENT MAP ONLY
        int skill = G_SkillPropertyInt(SKILLP_ACSReturn);
        for (int i = 0; i < objectives.Size(); i++)
        {
            let obj = objectives[i];

            // Skip objectives not visible on the current map (wrong map, hidden, or wrong skill)
            if (!obj.IsVisibleForCurrentMap(skill))
                continue;

            // Update cached distance for waypoint objectives — PER PLAYER
            if (updateDistance && obj.hasWaypoint && !obj.isCompleted && !obj.hasFailed)
            {
                for (int p = 0; p < MAXPLAYERS; p++)
                {
                    if (!playeringame[p] || !players[p].mo) continue;

                    vector3 playerPos = players[p].mo.pos;
                    playerPos.z = players[p].viewz; // Use eye height for more accurate distance
                    vector3 diff = level.Vec3Diff(playerPos, obj.waypointPos);
                    obj.SetDistance(p, int(diff.Length()));
                }
            }

            // Skip if not a timed objective or already completed/failed
            if (obj.timeLimit <= 0 || obj.isCompleted || obj.hasFailed)
                continue;

            // Countdown timer
            obj.timeRemaining--;

            // Check if time ran out
            if (obj.timeRemaining <= 0)
            {
                FailObjective(obj);
            }
        }

        // ---- Automap marker CVar change detection (every tic) ----
        // Check if marker-related CVars changed so markers update instantly
        // when the player closes the options menu (WorldTick is paused during menu,
        // so this fires on the first tic after menu close).
        PlayerInfo fp = GetFirstPlayer();
        if (fp)
        {
            bool curEnabled = GetCVarBool('obj_automap_markers', fp, true);
            int curStyle = GetCVarInt('obj_automap_marker_style', fp, 0);
            bool curShowCompleted = GetCVarBool('obj_automap_show_completed', fp, true);

            if (!prevMarkerCVarsInit)
            {
                // First tic: initialize tracked values without triggering a refresh
                prevMarkersEnabled = curEnabled;
                prevMarkerStyle = curStyle;
                prevShowCompleted = curShowCompleted;
                prevMarkerCVarsInit = true;
            }
            else if (curEnabled != prevMarkersEnabled || curStyle != prevMarkerStyle || curShowCompleted != prevShowCompleted)
            {
                // CVar changed — refresh markers immediately
                prevMarkersEnabled = curEnabled;
                prevMarkerStyle = curStyle;
                prevShowCompleted = curShowCompleted;
                RefreshAllMarkers();
            }
        }

        // Periodic refresh (every 35 tics = ~1/sec) only when markers need updating.
        // The dirty flag is set by any operation that affects marker state
        // (add/complete/fail/remove objectives, waypoint changes, map transitions).
        if (level.maptime % 35 == 0 && markersDirty)
        {
            RefreshAllMarkers();
        }
    }

    // Handle enemy deaths
    override void WorldThingDied(WorldEvent e)
    {
        if (!e.Thing) return;

        // Check all kill objectives FOR CURRENT MAP ONLY
        int skill = G_SkillPropertyInt(SKILLP_ACSReturn);
        for (int i = 0; i < objectives.Size(); i++)
        {
            let obj = objectives[i];

            // Skip objectives not visible on the current map (wrong map, hidden, or wrong skill)
            if (!obj.IsVisibleForCurrentMap(skill))
                continue;

            if (obj.objectiveType == 0 && !obj.isCompleted && !obj.hasFailed)
            {
                // Check if this matches the target class
                if (e.Thing.GetClassName() == obj.targetClass)
                {
                    if (IsDebugEnabled()) Console.Printf("DEBUG [VUOS_ObjectiveHandler]: Processing kill objective '%s' - count=%d/%d, failed=%d",
                        obj.objectiveDescription, obj.currentCount, obj.targetCount, obj.hasFailed);

                    obj.currentCount++;

                    if (IsDebugEnabled()) Console.Printf("DEBUG [VUOS_ObjectiveHandler]: Incremented to %d/%d",
                        obj.currentCount, obj.targetCount);

                    if (obj.currentCount >= obj.targetCount)
                    {
                        // Check if this is an inverse objective (fail on completion)
                        if (obj.isInverse)
                        {
                            if (IsDebugEnabled()) Console.Printf("DEBUG [VUOS_ObjectiveHandler]: Failing inverse objective '%s'", obj.objectiveDescription);
                            FailObjective(obj);
                        }
                        else
                        {
                            if (IsDebugEnabled()) Console.Printf("DEBUG [VUOS_ObjectiveHandler]: Completing objective '%s'", obj.objectiveDescription);
                            CompleteObjective(obj);
                        }
                    }
                }
            }
        }
    }

    // Handle object destruction (barrels, etc)
    override void WorldThingDestroyed(WorldEvent e)
    {
        if (!e.Thing) return;

        // Check all destroy/find objectives FOR CURRENT MAP ONLY
        int skill = G_SkillPropertyInt(SKILLP_ACSReturn);
        for (int i = 0; i < objectives.Size(); i++)
        {
            let obj = objectives[i];

            // Skip objectives not visible on the current map (wrong map, hidden, or wrong skill)
            if (!obj.IsVisibleForCurrentMap(skill))
                continue;

            if (obj.objectiveType == 1 && !obj.isCompleted && !obj.hasFailed)
            {
                if (e.Thing.GetClassName() == obj.targetClass)
                {
                    if (IsDebugEnabled()) Console.Printf("DEBUG [VUOS_ObjectiveHandler]: Processing destroy objective '%s' - count=%d/%d, failed=%d",
                        obj.objectiveDescription, obj.currentCount, obj.targetCount, obj.hasFailed);

                    obj.currentCount++;

                    if (obj.currentCount >= obj.targetCount)
                    {
                        // Check if this is an inverse objective (fail on completion)
                        if (obj.isInverse)
                        {
                            if (IsDebugEnabled()) Console.Printf("DEBUG [VUOS_ObjectiveHandler]: Failing inverse objective '%s'", obj.objectiveDescription);
                            FailObjective(obj);
                        }
                        else
                        {
                            if (IsDebugEnabled()) Console.Printf("DEBUG [VUOS_ObjectiveHandler]: Completing objective '%s'", obj.objectiveDescription);
                            CompleteObjective(obj);
                        }
                    }
                }
            }
        }
    }
}