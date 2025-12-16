// ============================================================================
// ObjectiveCommands.zs
// Console commands for testing and managing objectives
// ============================================================================

class ObjectiveCommands : EventHandler
{
    // Command: obj_add <description> <required> <type> [targetClass]
    // Add a new objective via console
    static void AddFromConsole(String description, int required, int objType, name targetClass = "")
    {
        UniversalObjective.Add(description, required, objType, targetClass);
    }
    
    // Command: obj_complete <description>
    // Complete an objective via console
    static void CompleteFromConsole(String description)
    {
        UniversalObjective.Complete(description);
    }
    
    // Command: obj_update <description> <progress>
    // Update objective progress via console
    static void UpdateFromConsole(String description, int progress)
    {
        UniversalObjective.UpdateProgress(description, progress);
    }
    
    // Command: obj_list
    // List all objectives
    static void ListFromConsole()
    {
        UniversalObjectiveHandler.ListObjectives();
    }
    
    // Command: obj_clear
    // Clear all objectives
    static void ClearFromConsole()
    {
        UniversalObjectiveHandler.ClearObjectives();
    }
    
    // Command: obj_toggle
    // Toggle objectives display
    static void ToggleFromConsole()
    {
        let cvar = CVar.GetCVar('obj_show', players[consoleplayer]);
        if (cvar)
        {
            bool newVal = !cvar.GetBool();
            cvar.SetBool(newVal);
            Console.Printf("Objectives display: %s", newVal ? "ON" : "OFF");
        }
    }
    
    // Command: obj_test
    // Add some test objectives
    static void TestFromConsole()
    {
        Console.Printf("Adding test objectives...");
        UniversalObjective.Add("Kill 5 Imps", 5, UniversalObjective.TYPE_KILL, "DoomImp");
        UniversalObjective.Add("Kill 3 Cacodemons", 3, UniversalObjective.TYPE_KILL, "Cacodemon");
        UniversalObjective.Add("Find the secret", 1, UniversalObjective.TYPE_CUSTOM);
        Console.Printf("Test objectives added. Spawn some enemies to test!");
    }
}