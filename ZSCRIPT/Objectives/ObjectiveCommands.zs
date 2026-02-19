// ObjectiveCommands.zs
// Console commands for objective management

class VUOS_ObjectiveCommands : EventHandler
{
    override void OnRegister()
    {
        if (VUOS_ObjectiveHandler.IsDebugEnabled())
            Console.Printf("Universal Objective System loaded. Type 'obj_help' for commands.");
    }
    
    override void NetworkProcess(ConsoleEvent e)
    {
        PlayerInfo player = players[e.Player];
        
        if (e.Name ~== "obj_help")
        {
            Console.Printf("=== Universal Objective Commands ===");
            Console.Printf("obj_list          - Show all objectives");
            Console.Printf("obj_clear         - Clear all objectives");
            Console.Printf("obj_test          - Add test objectives");
            Console.Printf("obj_complete_test - Complete first active objective");
            Console.Printf("obj_complete_all  - Complete all active objectives");
            return;
        }
        
        if (e.Name ~== "obj_list")
        {
            let handler = VUOS_ObjectiveHandler.GetSetupHandler();
            if (!handler || handler.objectives.Size() == 0)
            {
                Console.Printf("No active objectives");
                return;
            }

            int currentSkill = G_SkillPropertyInt(SKILLP_ACSReturn);
            Console.Printf("=== Active Objectives (%d) === [Current Skill: %d]", handler.objectives.Size(), currentSkill);
            for (int i = 0; i < handler.objectives.Size(); i++)
            {
                let obj = handler.objectives[i];
                String status;
                if (obj.hasFailed)
                    status = "[FAILED]";
                else if (obj.isCompleted)
                    status = "[COMPLETE]";
                else
                    status = "[ACTIVE]";
                    
                String hidden = obj.isHidden ? " (HIDDEN)" : "";
                String tracked = obj.isTracked ? "" : " (UNTRACKED)";
                String progress = "";
                if (obj.targetCount > 1)
                {
                    progress = String.Format(" (%d/%d)", obj.currentCount, obj.targetCount);
                }
                
                // Show skill range and whether it's valid for current skill
                String skillInfo = "";
                if (obj.minSkillLevel > 0 || obj.maxSkillLevel < 4)
                {
                    bool validForSkill = obj.IsValidForCurrentSkill(currentSkill);
                    skillInfo = String.Format(" [Skill %d-%d%s]", obj.minSkillLevel, obj.maxSkillLevel,
                        validForSkill ? "" : " INACTIVE");
                }
                
                Console.Printf("%d. [%s] %s %s%s%s%s%s", i+1, obj.mapName, status, obj.objectiveDescription, progress, hidden, tracked, skillInfo);
                
                // Show waypoint info if set
                if (obj.hasWaypoint)
                {
                    Console.Printf("   Waypoint: (%d, %d, %d) Distance: %d Marker: %s",
                        int(obj.waypointPos.x), int(obj.waypointPos.y), int(obj.waypointPos.z), obj.GetDistance(e.Player),
                        obj.markerActor ? "active" : "none");
                }
            }
            return;
        }
        
        if (e.Name ~== "obj_clear")
        {
            VUOS_ObjectiveHandler.ClearAll();
            return;
        }

        if (e.Name ~== "obj_test")
        {
            // Add test objectives for debugging
            VUOS_ObjectiveHandler.AddPrimaryObjective("Test: Kill 3 Imps", 'DoomImp', 3);
            VUOS_ObjectiveHandler.AddSecondaryObjective("Test: Kill 2 Cacodemons", 'Cacodemon', 2);
            Console.Printf("Test objectives added.");
            return;
        }

        if (e.Name ~== "obj_complete_test")
        {
            // Complete the first active (incomplete, not failed) objective
            let handler = VUOS_ObjectiveHandler.GetSetupHandler();
            if (!handler)
            {
                Console.Printf("No objectives to complete");
                return;
            }

            int skill = G_SkillPropertyInt(SKILLP_ACSReturn);
            for (int i = 0; i < handler.objectives.Size(); i++)
            {
                let obj = handler.objectives[i];
                // Note: intentionally does NOT check isHidden so debug can complete hidden objectives
                if (obj.mapName ~== level.MapName && obj.IsValidForCurrentSkill(skill) && !obj.isCompleted && !obj.hasFailed)
                {
                    VUOS_ObjectiveHandler.CompleteObjective(obj);
                    Console.Printf("Completed: %s", obj.objectiveDescription);
                    return;
                }
            }
            Console.Printf("No active objectives to complete");
            return;
        }

        if (e.Name ~== "obj_complete_all")
        {
            // Complete ALL active objectives for current map
            let handler = VUOS_ObjectiveHandler.GetSetupHandler();
            if (!handler)
            {
                Console.Printf("No objectives to complete");
                return;
            }

            int completed = 0;
            int skill = G_SkillPropertyInt(SKILLP_ACSReturn);
            for (int i = 0; i < handler.objectives.Size(); i++)
            {
                let obj = handler.objectives[i];
                // Note: intentionally does NOT check isHidden so debug can complete hidden objectives
                if (obj.mapName ~== level.MapName && obj.IsValidForCurrentSkill(skill) && !obj.isCompleted && !obj.hasFailed)
                {
                    VUOS_ObjectiveHandler.CompleteObjective(obj);
                    completed++;
                }
            }
            Console.Printf("Completed %d objective(s)", completed);
            return;
        }
    }
}