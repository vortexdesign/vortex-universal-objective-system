// ObjectiveMinimapBridge.zs
// Optional bridge between VUOS and Cynic Games Minimap mod
// Runtime detection — zero overhead when minimap is not loaded.
// Uses the minimap's own network event API for waypoint management.

class VUOS_ObjectiveMinimapBridge : EventHandler
{
    // Detection state
    bool minimapDetected;
    bool notificationShown;
    
    // Track which objective descriptions we've synced to the minimap
    // so we only add/remove on state changes, not every tick.
    Array<String> syncedWaypoints;
    
    // Queued removals — processed one per tic through NetworkProcess
    // because removal requires setting a CVar then chaining the minimap's delete event.
    Array<String> pendingRemoves;
    
    // ====================================================================
    // DETECTION
    // ====================================================================
    
    override void WorldLoaded(WorldEvent e)
    {
        // Check if the minimap mod is loaded by looking for one of its classes.
        // FindClass() only returns non-null when the class is actually registered at runtime.
        // Unlike CVar detection, this won't false-positive from saved config values.
        minimapDetected = (FindClass("UCMinimap_EventHandler") != null);
        
        // Show one-time console notification per play session
        if (minimapDetected && !notificationShown)
        {
            Console.Printf("\c[Gold]UCMinimap detected\c- - adjust HUD position in \c[Green]Options > Objectives\c- if overlapping");
            notificationShown = true;
        }
        
        // Clear sync tracking on map load
        // The minimap clears all its waypoints in WorldLoaded, so we need to re-sync.
        syncedWaypoints.Clear();
        pendingRemoves.Clear();
    }
    
    // ====================================================================
    // PERIODIC SYNC
    // ====================================================================
    
    override void WorldTick()
    {
        // Zero overhead when minimap not loaded
        if (!minimapDetected) return;
        
        // Process one pending removal per tic (chained network event approach)
        if (pendingRemoves.Size() > 0)
        {
            String wpName = pendingRemoves[0];
            pendingRemoves.Delete(0);
            EventHandler.SendNetworkEvent(String.Format("vuos_minimap_remove:%s", wpName));
        }
        
        // Sync every 35 tics (~1/sec), starting at tic 35 to let minimap initialize first
        if (level.maptime < 35 || level.maptime % 35 != 0) return;
        
        let handler = VUOS_ObjectiveHandler.GetSetupHandler();
        if (!handler) return;

        // Build list of currently active waypoint objectives for this map
        Array<String> activeWaypoints;

        int skill = G_SkillPropertyInt(SKILLP_ACSReturn);
        for (int i = 0; i < handler.objectives.Size(); i++)
        {
            let obj = handler.objectives[i];

            // Only sync active, visible, tracked waypoint objectives for current map
            if (!obj.IsVisibleForCurrentMap(skill)) continue;
            if (!obj.hasWaypoint) continue;
            if (obj.isCompleted || obj.hasFailed) continue;
            if (!obj.isTracked) continue;

            String wpName = SanitizeName(obj.objectiveDescription);
            activeWaypoints.Push(wpName);
            
            // Add to minimap if not already synced
            if (!IsInArray(syncedWaypoints, wpName))
            {
                // Colors: primary = gold (0xFFFFD700), secondary = cyan (0xFF00FFFF)
                String colorHex;
                if (obj.isPrimary)
                    colorHex = "FFFFD700";
                else
                    colorHex = "FF00FFFF";
                
                int x = int(obj.waypointPos.x);
                int y = int(obj.waypointPos.y);
                
                // Use the minimap's built-in create event API
                EventHandler.SendNetworkEvent(
                    String.Format("ucm.waypoint.create:%d:%d:%s:%s", x, y, wpName, colorHex)
                );
                
                syncedWaypoints.Push(wpName);
            }
        }
        
        // Queue removal for any synced waypoints that are no longer active
        for (int i = syncedWaypoints.Size() - 1; i >= 0; i--)
        {
            if (!IsInArray(activeWaypoints, syncedWaypoints[i]))
            {
                pendingRemoves.Push(syncedWaypoints[i]);
                syncedWaypoints.Delete(i);
            }
        }
    }
    
    // ====================================================================
    // REMOVAL BRIDGE
    // ====================================================================
    // The minimap's delete-by-name reads from the "waypoint_name" CVar.
    // We set that CVar, then fire the minimap's own delete event.
    // This two-step approach is necessary because we can't directly call
    // I_WaypointStorage.RemoveNamedWaypoint() without a compile-time dependency.
    
    override void NetworkProcess(ConsoleEvent e)
    {
        if (!minimapDetected) return;
        
        // Parse our custom removal event: "vuos_minimap_remove:WaypointName"
        Array<String> parts;
        e.Name.Split(parts, ":");
        
        if (parts.Size() >= 2 && parts[0] == "vuos_minimap_remove")
        {
            PlayerInfo plr = players[e.Player];
            if (!plr || !plr.mo) return;
            
            // Reconstruct the name (in case it was split on colons, though we sanitize these out)
            String wpName = parts[1];
            for (int i = 2; i < parts.Size(); i++)
                wpName = wpName .. ":" .. parts[i];
            
            // Set the minimap's waypoint_name CVar to our waypoint name
            let cv = CVar.GetCVar("waypoint_name", plr);
            if (cv)
            {
                cv.SetString(wpName);
                // Fire the minimap's own delete-by-name event
                // This queues for the next tic's NetworkProcess where the minimap handler picks it up
                EventHandler.SendNetworkEvent("ucm.waypointmenu.delete.byname");
            }
        }
    }
    
    // ====================================================================
    // UTILITY
    // ====================================================================
    
    // Sanitize objective description for use as a minimap waypoint name.
    // Colons break the colon-delimited network event format.
    static String SanitizeName(String desc)
    {
        String result = desc;
        result.Replace(":", "-");
        return result;
    }
    
    // Check if a string exists in an array
    static bool IsInArray(Array<String> arr, String val)
    {
        for (int i = 0; i < arr.Size(); i++)
        {
            if (arr[i] == val) return true;
        }
        return false;
    }
}