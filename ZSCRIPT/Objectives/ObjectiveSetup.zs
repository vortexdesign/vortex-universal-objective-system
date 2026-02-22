// ============================================================================
// ObjectiveSetup.zs
// Objectives for Doom 2 with standard actors
// Customize these for your own mod
// 
// ============================================================================
// EXIT BLOCKING - TWO MODES:
// ============================================================================
// 
// MODE 1: WARNING MESSAGE ONLY (Current - No map editing required)
// - Player gets visual/audio feedback when trying to exit without completing
//   required objectives
// - Exit still happens, but player knows they shouldn't have exited yet
// - Works automatically on any map without editing
// 
// MODE 2: TRUE EXIT BLOCKING (Requires map editing)
// - Exit will NOT work until all required primary objectives are complete
// - Requires editing each map's exit linedef:
//   1. Open map in SLADE or Ultimate Doom Builder
//   2. Find the exit linedef (usually Special 11, 52, or 124)
//   3. Change Special to: 80 (ACS_Execute)
//   4. Set Script Name to: CheckObjectivesAndExit
//   5. Save map
// - After editing, the exit physically won't work until objectives complete
// 
// The ACS bridge (OBJECTIVES_BRIDGE_ACS) handles the exit checking logic.
// ============================================================================

class VUOS_ObjectiveSetup : VUOS_ObjectiveHandler
{
	// Tracking/Counter variable Examples
	int switchesActivated; // Track switch activation count for multi-switch objectives
	int secretsFound; // Track secrets found count
	bool hasRedKey; // Track if player has picked up red key
	bool playerDiedOnMAP01; // Track if player died on MAP01
	
	// Callback event tests
	override void OnObjectiveActivate(string objectiveID)
	{
		if (objectiveID == "Kill 5 demons")
        {
             if (IsDebugEnabled()) Console.Printf("\c[Green]Kill 5 demons objective added!");
        }
	}

	override void OnObjectiveComplete(string objectiveID)
    {
        if (objectiveID == "Kill 5 demons")
        {
            if (IsDebugEnabled()) Console.Printf("\c[Green]All demons eliminated! Security door unlocked!");
        }
    }

    override void OnObjectiveFail(string objectiveID)
    {
        if (objectiveID == "Don't shoot 4 barrels")
        {
            if (IsDebugEnabled()) Console.Printf("\c[Red]Too many explosions! Enemy reinforcements incoming!");
        }
    }

	override void OnObjectiveReset(string objectiveID)
	{
		if (objectiveID == "Survive the ambush")
		{
			if (IsDebugEnabled()) Console.Printf("\c[Yellow]Objective reset - try again!");
		}
	}

	override void OnAllRequiredComplete()
	{
		if (IsDebugEnabled()) Console.Printf("\c[Green]All required objectives complete! Exit is unlocked!");
	}
	
	// ========================================================================
	// WorldLoaded: Set up objectives when each map loads
	// ========================================================================
	override void WorldLoaded(WorldEvent e)
	{
		// Run parent cleanup first (removes non-persistent objectives from previous map)
		Super.WorldLoaded(e);

		// Check if objectives already exist for this map (e.g. revisiting via hub)
		if (MapObjectivesExist())
		{
			// Restore tracking counters from existing objective progress
			// to prevent regression when revisiting a map
			RestoreCountersFromObjectives();

			if (IsDebugEnabled())
			{
				Console.Printf("DEBUG: Objectives already exist for %s, not recreating", level.MapName);

				// Show current state of all objectives
				let handler = VUOS_ObjectiveHandler.GetSetupHandler();
				if (handler)
				{
					Console.Printf("DEBUG: === Current Objective States ===");
					int skill = G_SkillPropertyInt(SKILLP_ACSReturn);
					for (int i = 0; i < handler.objectives.Size(); i++)
					{
						let obj = handler.objectives[i];
						Console.Printf("DEBUG: [%d] '%s' - map=%s, completed=%s, failed=%s, count=%d/%d, skill=%d-%d, validSkill=%s",
							i, obj.objectiveDescription, obj.mapName,
							obj.isCompleted ? "YES" : "NO",
							obj.hasFailed ? "YES" : "NO",
							obj.currentCount, obj.targetCount,
							obj.minSkillLevel, obj.maxSkillLevel,
							obj.IsValidForCurrentSkill(skill) ? "YES" : "NO");
					}
					Console.Printf("DEBUG: ===========================");
				}
			}

			return;
		}

		// Fresh map entry — reset tracking counters before creating objectives
		switchesActivated = 0;
		secretsFound = 0;
		hasRedKey = false;

		if (level.MapName ~== "MAP01")
		{
			playerDiedOnMAP01 = false;
			if (IsDebugEnabled()) Console.Printf("DEBUG: Reset playerDiedOnMAP01 to false");
		}

		// Set up objectives based on which map is loaded
		if (level.MapName ~== "MAP01")
		{
			SetupMAP01Objectives();
		}
		else if (level.MapName ~== "MAP02")
		{
			SetupMAP02Objectives();
		}
	}
	
	// Check if objectives already exist for the current map
	bool MapObjectivesExist()
	{
		let handler = VUOS_ObjectiveHandler.GetSetupHandler();
		if (!handler)
			return false;

		// Check if any objectives exist for current map
		for (int i = 0; i < handler.objectives.Size(); i++)
		{
			if (handler.objectives[i].mapName ~== level.MapName)
				return true;
		}

		return false;
	}

	// Restore tracking counters from existing persistent objectives
	// Prevents progress regression when revisiting a map (e.g. hub maps)
	void RestoreCountersFromObjectives()
	{
		let obj_switches = VUOS_ObjectiveHandler.FindByDescription("Activate 3 power switches");
		if (obj_switches && obj_switches.mapName ~== level.MapName)
			switchesActivated = obj_switches.currentCount;

		let obj_secrets = VUOS_ObjectiveHandler.FindByDescription("Find 2 secret areas");
		if (obj_secrets && obj_secrets.mapName ~== level.MapName)
			secretsFound = obj_secrets.currentCount;

		// Restore red key state from objective completion
		let obj_redkey = VUOS_ObjectiveHandler.FindByDescription("Find the red key");
		if (obj_redkey && obj_redkey.mapName ~== level.MapName)
			hasRedKey = obj_redkey.isCompleted;

		// Restore death tracking from objective state
		if (level.MapName ~== "MAP01")
		{
			let obj_nodeaths = VUOS_ObjectiveHandler.FindByDescription("Complete this map without dying");
			if (obj_nodeaths)
				playerDiedOnMAP01 = obj_nodeaths.hasFailed;
		}

		if (IsDebugEnabled()) Console.Printf("DEBUG: Restored counters - switches=%d, secrets=%d, hasRedKey=%s, diedOnMAP01=%s",
			switchesActivated, secretsFound,
			hasRedKey ? "true" : "false",
			playerDiedOnMAP01 ? "true" : "false");
	}
	
	// ========================================================================
	// MAP01 Objectives
	// ========================================================================
	void SetupMAP01Objectives()
	{
		// ====================================================================
		// PERSISTENCE AND HUB SUPPORT:
		// ====================================================================
		// The objective system uses EventHandler, which is per-map in GZDoom.
		// This means objective state (completed, failed, progress) is scoped
		// to a single map by default.
		//
		// LINEAR PLAY (Doom 2 style: MAP01 -> MAP02 -> MAP03):
		//   Objectives are created fresh on each map. Previous map objectives
		//   are not carried forward. This is the expected behavior for linear
		//   progression since the player never revisits maps.
		//
		// HUB PLAY (Hexen style: MAP01 -> MAP02 -> back to MAP01):
		//   GZDoom automatically preserves per-map state (including objectives)
		//   when maps are configured as a hub cluster in MAPINFO. When a player
		//   leaves MAP01 and returns later, all objectives are restored exactly
		//   as they were (completed status, progress, timers, etc).
		//
		//   To enable hub persistence, add a MAPINFO lump with a hub cluster:
		//
		//     cluster 1 { hub }
		//     map MAP01 "Entryway" { cluster 1 }
		//     map MAP02 "Underhalls" { cluster 1 }
		//
		//   The persist flag controls whether an objective survives revisits:
		//     persist=true  (default) -> kept when returning to the map
		//     persist=false -> deleted on map exit, fresh on revisit
		//
		// GLOBAL JOURNAL (seeing all maps' objectives at once):
		//   Not currently supported. Each map's objectives are only visible
		//   while on that map. To implement a global cross-map journal, you
		//   would need to:
		//   1. Change VUOS_ObjectiveHandler from EventHandler to StaticEventHandler
		//      (persists across maps without hub configuration)
		//   2. Add a serializable storage mechanism (e.g. a Thinker subclass or
		//      ACS global arrays) to mirror objective completion flags, because
		//      StaticEventHandler state is NOT serialized in save games
		//   3. On save load (WorldLoaded with e.IsSaveGame), rebuild objective
		//      state from the serialized storage
		//   This is a significant architectural change with save/load complexity.
		//
		// ====================================================================

		// ====================================================================
		// PARAMETER AND METHOD REFERENCE:
		// ====================================================================
		// Parameter              Type     Default   Description
		// ---------              ----     -------   -----------
		// desc                   String   (none)    Objective description text shown to player
		// target                 name     ''        Actor class to track (e.g. 'ZombieMan', 'Demon')
		// count                  int      1         Number of targets needed to complete/fail
		// objType                int      0         0 = kill, 1 = destroy, 2 = collect (inventory), 3 = custom
		// hidden                 bool     false     If true, objective is not shown on HUD/screen
		// persist                bool     true      If true, survives map changes; false = deleted on map exit
		// inverse                bool     false     If true, FAILS when count reached instead of completing
		// timeLimit              int      0         Time limit in seconds (0 = no limit). Fails when expired
		// isPrimary              bool     true      true = PRIMARY (green header), false = SECONDARY (cyan header)
		//                                           (Not present in convenience methods - set automatically)
		// requiredToComplete     int      -1        -1 = auto (true for primary, false for secondary)
		//                                           0 = not required, 1 = required to exit map
		// minSkillLevel          int      0         Minimum skill level (0=ITYTD, 1=HNTR, 2=HMP, 3=UV, 4=NM)
		// maxSkillLevel          int      4         Maximum skill level (0=ITYTD, 1=HNTR, 2=HMP, 3=UV, 4=NM)
		//
		// AddObjective (full control - all parameters):
		//   AddObjective(desc, target, count, objType, hidden, persist, inverse, timeLimit, isPrimary, requiredToComplete, minSkillLevel, maxSkillLevel)
		//
		// AddPrimaryObjective (convenience - isPrimary is always true):
		//   AddPrimaryObjective(desc, target, count, objType, hidden, persist, inverse, timeLimit, requiredToComplete, minSkillLevel, maxSkillLevel)
		//
		// AddSecondaryObjective (convenience - isPrimary is always false):
		//   AddSecondaryObjective(desc, target, count, objType, hidden, persist, inverse, timeLimit, requiredToComplete, minSkillLevel, maxSkillLevel)
		//
		// AddPrimaryCollectObjective (convenience - objType is always 2, isPrimary is always true):
		//   AddPrimaryCollectObjective(desc, target, count, hidden, persist, requiredToComplete, minSkillLevel, maxSkillLevel)
		//
		// AddSecondaryCollectObjective (convenience - objType is always 2, isPrimary is always false):
		//   AddSecondaryCollectObjective(desc, target, count, hidden, persist, requiredToComplete, minSkillLevel, maxSkillLevel)
		//
		// ====================================================================
		// PRIMARY/SECONDARY OBJECTIVE EXAMPLES:
		// ====================================================================
		// By default, all objectives are PRIMARY and REQUIRED to complete before exiting the map.
		//
		// EXAMPLES:
		// Primary objective (required by default, all skill levels):
		//   AddPrimaryObjective("Kill all enemies", 'ZombieMan', 5);
		//
		// Secondary objective (not required by default):
		//   AddSecondaryObjective("Find secrets", '', 2);
		//
		// Primary objective that is NOT required:
		//   AddPrimaryObjective("Bonus objective", '', 1, 0, false, true, false, 0, false);
		//
		// Secondary objective that IS required:
		//   AddSecondaryObjective("Must complete this", '', 1, 0, false, true, false, 0, true);
		//
		// ====================================================================
		// SKILL LEVEL FILTERING EXAMPLES:
		// ====================================================================
		// Skill levels: 0=ITYTD, 1=HNTR, 2=HMP, 3=UV, 4=NM
		// Default: minSkillLevel=0, maxSkillLevel=4 (all skill levels)
		//
		// Secondary objective only on UV and Nightmare (skill 3-4):
		//   AddSecondaryObjective("Hard mode bonus", 'ArchVile', 2, 0, false, true, false, 0, -1, 3, 4);
		//
		// Primary objective only on easy skills (ITYTD and HNTR, skill 0-1):
		//   AddPrimaryObjective("Easy guidance task", '', 1, 0, false, true, false, 0, -1, 0, 1);
		//
		// Primary objective for HMP and above (skill 2-4):
		//   AddPrimaryObjective("Kill the Baron", 'BaronOfHell', 1, 0, false, true, false, 0, -1, 2, 4);
		// ====================================================================
		//
		// ====================================================================
		// SET WAYPOINT EXAMPLES:
		// ====================================================================
		// Waypoints place a compass marker at a world position for an objective.
		// Can be set inline via AddObjective/AddPrimaryObjective/AddSecondaryObjective
		// using the wpX, wpY, wpZ parameters, or after creation via SetWaypoint:
		//
		// Inline (last 3 params are wpX, wpY, wpZ):
		//   AddPrimaryObjective("Kill demons in entry way", 'ZombieMan', 2, 0, false, true, false, 0, -1, 0, 4, -69, 1143, 40);
		//
		// After creation:
		//   AddSecondaryObjective("Reach the exit");
		//   VUOS_ObjectiveHandler.SetWaypoint("Reach the exit", 1007, 1077, 0);
		//
		// Clear a waypoint:
		//   VUOS_ObjectiveHandler.ClearWaypoint("Reach the exit");
		//
		// ====================================================================
		// TIMED OBJECTIVE EXAMPLES:
		// ====================================================================
		// timeLimit is in seconds. Objective auto-fails when time expires.
		//
		// Kill 2 zombiemen within 30 seconds (primary, required):
		//   AddPrimaryObjective("Kill 2 demons in under 30 seconds", 'ZombieMan', 2, 0, false, true, false, 30);
		//
		// Find the secret room within 60 seconds (secondary, optional):
		//   AddSecondaryObjective("Find the secret room quickly", '', 1, 0, false, true, false, 60);
		//
		// ====================================================================
		// INVERSE OBJECTIVE EXAMPLES (fail when count reached):
		// ====================================================================
		// Inverse objectives FAIL instead of completing when the target count
		// is reached. Use for "don't do X" style objectives.
		//
		// Fail if player destroys 4 barrels (secondary, objType=1 for destroy):
		//   AddSecondaryObjective("Don't shoot 4 barrels", 'ExplosiveBarrel', 4, 1, false, true, true);
		//
		// Fail if player kills 3 friendly NPCs (primary, objType=0 for kill):
		//   AddPrimaryObjective("Don't kill the civilians", 'FriendlyNPC', 3, 0, false, true, true);
		//
		// ====================================================================
		// OBJECTIVE TYPE EXAMPLES:
		// ====================================================================
		// objType 0 = kill tracking (WorldThingDied) — for monsters/enemies
		// objType 1 = destroy tracking (WorldThingDestroyed) — for barrels, breakables, etc.
		// objType 2 = collect tracking (inventory poll) — for keys, puzzle items, pickups
		// objType 3 = custom (no auto-tracking, use Complete/UpdateProgress/IncrementProgress)
		//
		// Destroy 5 explosive barrels (objType=1):
		//   AddSecondaryObjective("Destroy 5 barrels", 'ExplosiveBarrel', 5, 1);
		//
		// Collect a key (auto-completes when player picks it up):
		//   AddPrimaryCollectObjective("Find the red key", 'RedCard');
		//   AddSecondaryCollectObjective("Find a health pack", 'Medikit');
		//
		// Collect via full AddObjective (objType=2):
		//   AddPrimaryObjective("Find the red key", 'RedCard', 1, 2);
		//
		// Custom objective (objType=3, manually tracked via IncrementProgress):
		//   AddPrimaryObjective("Activate 3 power switches", '', 3, 3);
		//
		// ====================================================================
		// NON-PERSISTENT OBJECTIVE EXAMPLES (persist = false):
		// ====================================================================
		// Non-persistent objectives are deleted when the player leaves the map.
		// Use for objectives that only matter on that specific visit.
		// Persistent objectives (default) survive map changes for hub-style maps.
		//
		// Only counts on this visit (deleted on map exit):
		//   AddSecondaryObjective("Complete this map without dying", '', 1, 0, false, false);
		//
		// Non-persistent kill objective:
		//   AddSecondaryObjective("Find 2 secret areas", '', 2, 0, false, false);
		//
		// ====================================================================
		// HIDDEN OBJECTIVE EXAMPLES (hidden = true):
		// ====================================================================
		// Hidden objectives are not shown on the HUD or objective screen.
		// Use for internal tracking, secret objectives revealed later,
		// or objectives you complete/fail via code without player visibility.
		//
		// Hidden tracker (not shown to player):
		//   AddPrimaryObjective("Internal trigger", '', 1, 0, true);
		//
		// Hidden secondary objective:
		//   AddSecondaryObjective("Secret bonus", 'ArchVile', 1, 0, true);
		//
		// ====================================================================
		// API METHODS - COMPLETING, FAILING, AND MANAGING OBJECTIVES:
		// ====================================================================
		// These static methods can be called from ObjectiveSetup event overrides
		// (NetworkProcess, WorldTick, OnObjectiveComplete, etc.) or from ACS
		// via ScriptCall.
		//
		// Complete an objective:
		//   VUOS_ObjectiveHandler.Complete("Find the red key");
		//
		// Fail an objective:
		//   VUOS_ObjectiveHandler.Fail("Protect the reactor");
		//
		// Increment progress by 1 (auto-completes/fails at target):
		//   VUOS_ObjectiveHandler.IncrementProgress("Activate 3 power switches");
		//
		// Increment progress by a custom amount:
		//   VUOS_ObjectiveHandler.IncrementProgress("Collect 10 data chips", 5);
		//
		// Set progress to an absolute value (auto-completes/fails at target):
		//   VUOS_ObjectiveHandler.UpdateProgress("Activate 3 power switches", 2);
		//
		// Reveal a hidden objective (e.g. after completing a prerequisite):
		//   VUOS_ObjectiveHandler.SetHidden("Escape the collapsing base", false);
		//
		// Hide an active objective:
		//   VUOS_ObjectiveHandler.SetHidden("Escape the collapsing base", true);
		//
		// Reset a completed/failed objective back to active (zeroes progress):
		//   VUOS_ObjectiveHandler.ResetObjective("Survive the ambush");
		//
		// Remove an objective entirely:
		//   VUOS_ObjectiveHandler.RemoveObjective("Obsolete task");
		//
		// ====================================================================
		// QUERY METHODS - CHECKING OBJECTIVE STATE:
		// ====================================================================
		// Use these in WorldTick, NetworkProcess, OnObjectiveComplete callbacks,
		// or anywhere you need to check objective state for game logic.
		//
		// Check if an objective exists:
		//   VUOS_ObjectiveHandler.Exists("Kill 5 demons")
		//
		// Check if completed:
		//   VUOS_ObjectiveHandler.IsComplete("Kill 5 demons")
		//
		// Check if active (not completed, not failed):
		//   VUOS_ObjectiveHandler.IsActive("Kill 5 demons")
		//
		// Check if failed:
		//   VUOS_ObjectiveHandler.HasFailed("Don't shoot 4 barrels")
		//
		// Get current / max progress:
		//   VUOS_ObjectiveHandler.GetProgress("Activate 3 power switches")
		//   VUOS_ObjectiveHandler.GetMaxProgress("Activate 3 power switches")
		//
		// Check if any required objectives are incomplete (used for exit blocking):
		//   VUOS_ObjectiveHandler.HasIncompleteRequiredObjectives()
		//
		// Find objective data object for direct field access:
		//   let obj = VUOS_ObjectiveHandler.FindByDescription("Kill 5 demons");
		//   if (obj) { Console.Printf("Count: %d/%d", obj.currentCount, obj.targetCount); }
		//
		// ====================================================================
		// EVENT CALLBACKS:
		// ====================================================================
		// Override these in your ObjectiveSetup class to react to objective
		// state changes. All callbacks are optional.
		//
		// OnObjectiveActivate(string objectiveID)
		//   Called when an objective is added. Use to trigger intro events.
		//
		// OnObjectiveComplete(string objectiveID)
		//   Called when an objective is completed. Use to unlock doors,
		//   spawn rewards, reveal hidden objectives, etc.
		//
		// OnObjectiveFail(string objectiveID)
		//   Called when an objective fails. Use to spawn reinforcements,
		//   trigger penalties, etc.
		//
		// OnObjectiveReset(string objectiveID)
		//   Called when an objective is reset back to active. Use to
		//   re-lock doors, respawn enemies, reset tracking counters, etc.
		//
		// OnAllRequiredComplete()
		//   Called when the last required objective on the current map is
		//   completed. Use to open exit doors, play victory sounds, show
		//   messages, or spawn rewards. Only fires for required objectives.
		//
		
		// ====================================================================
		// Manual objectives used for testing taken from the examples above
		// ====================================================================
		//// PRIMARY OBJECTIVES (required to exit)
		////VUOS_ObjectiveHandler.AddPrimaryObjective("Kill 5 demons", 'ZombieMan', 5);
		//VUOS_ObjectiveHandler.AddPrimaryObjective("Kill demons in entry way", 'ZombieMan', 2, 0, false, true, false, 0, -1, 0, 4, -69, 1143, 40);
		
		//// Timed objective example - kill 2 zombiemen in 60 seconds (PRIMARY)
		//VUOS_ObjectiveHandler.AddPrimaryObjective("Kill 2 demons in under 60 seconds", 'ZombieMan', 2, 0, false, true, false, 60);

		//// Custom objectives (PRIMARY, required to exit)
		//VUOS_ObjectiveHandler.AddPrimaryObjective("Find the red key");

		//// SECONDARY OBJECTIVES (optional, not required to exit)
		//// Inverse objective: FAIL when 4 barrels are destroyed (SECONDARY)
		//VUOS_ObjectiveHandler.AddSecondaryObjective("Don't shoot 4 barrels", 'ExplosiveBarrel', 4, 1, false, true, true);

		//// Use Setwaypoint
		//VUOS_ObjectiveHandler.AddSecondaryObjective("Reach the exit");
		//VUOS_ObjectiveHandler.SetWaypoint("Reach the exit", 1007, 1077, 0);

		//// NON-PERSISTENT objective example (gets deleted when you leave MAP01) - SECONDARY
		//VUOS_ObjectiveHandler.AddSecondaryObjective("Complete this map without dying", '', 1, 0, false, false);

	}
	
	// ========================================================================
	// MAP02 Objectives
	// ========================================================================
	void SetupMAP02Objectives()
	{
		// // PRIMARY OBJECTIVES (required to exit)
		// VUOS_ObjectiveHandler.AddPrimaryObjective("Defeat the demons", 'Demon', 8);
		
		// VUOS_ObjectiveHandler.AddPrimaryObjective("Slay the hell knights", 'HellKnight', 5);
		
		// // Custom objective (triggered by pickups/linedefs/buttons) - PRIMARY
		// VUOS_ObjectiveHandler.AddPrimaryObjective("Activate 3 power switches", '', 3);
		
		// // SECONDARY OBJECTIVES (optional)
		// VUOS_ObjectiveHandler.AddSecondaryObjective("Hunt the chaingunners", 'ChaingunGuy', 3);
		
		// // Non-persistent example: Find secrets only counts on this map visit - SECONDARY
		// VUOS_ObjectiveHandler.AddSecondaryObjective("Find 2 secret areas", '', 2, 0, false, false);
	}
	
	// ========================================================================
	// WorldThingSpawned: Detect special items, switches, triggers
	// ========================================================================
	override void WorldThingSpawned(WorldEvent e)
	{
		if (!e.Thing) { return; }
		
		// You can add custom trigger actors here later
		// Example:
		// if (e.Thing is "YourCustomTrigger")
		// {
		//     let obj = VUOS_ObjectiveHandler.FindByDescription("Some objective");
		//     if (obj) {
		//         obj.isCompleted = true;
		//         Console.Printf("Objective Complete: %s", obj.objectiveDescription);
		//     }
		// }
	}
	
	// ========================================================================
	// WorldLineActivated: Detect exit switch activation and block if required objectives incomplete
	// 
	// IMPORTANT: This provides visual/audio feedback but CANNOT actually prevent exit activation!
	// 
	// TO TRULY BLOCK EXITS, you must edit your maps:
	// 1. In SLADE/UDB, find the exit linedef
	// 2. Change Special from 11/52/124 to 80 (ACS_Execute)
	// 3. Set Script Name to: CheckObjectivesAndExit
	// 4. Now the exit will only work when required objectives are complete
	// 
	// Without map editing, this code only shows a warning message.
	// ========================================================================
	override void WorldLineActivated(WorldEvent e)
	{
		if (!e.ActivatedLine) return;
		
		int special = e.ActivatedLine.special;
		
		// Print all line activations to see what's being triggered
		if (IsDebugEnabled()) Console.Printf("DEBUG: Line activated - special=%d on %s", special, level.MapName);
		
		// GZDoom translates all Doom-format exit specials (52, 124, etc.)
		// to Hexen-format specials during map loading:
		//   243 = Exit_Normal
		//   244 = Exit_Secret
		// So level.Lines[].special always uses these translated values.
		bool isExit = (special == 243 || special == 244);
		
		if (isExit)
		{
			if (IsDebugEnabled()) Console.Printf("DEBUG: Exit activated on %s", level.MapName);
			
			// Complete the "Reach the exit" objective for current map FIRST
			let obj = VUOS_ObjectiveHandler.FindByDescription("Reach the exit");
			if (obj && obj.mapName ~== level.MapName && !obj.isCompleted)
			{
				VUOS_ObjectiveHandler.CompleteObjective(obj);
			}
			
			// Then check if there are incomplete required objectives
			if (VUOS_ObjectiveHandler.HasIncompleteRequiredObjectives())
			{
				if (IsDebugEnabled()) Console.Printf("DEBUG: Exit blocked - incomplete required objectives");
				
				// Show the blocking message
				let renderer = VUOS_ObjectiveHandler.GetRenderer();
				if (renderer)
				{
					renderer.ShowRequiredObjectivesMessage();
				}

				// Play error sound on ALL players
				VUOS_ObjectiveHandler.PlaySoundAllPlayers("*usefail");

				// NOTE: ZScript CANNOT prevent the exit from activating.
				// This only provides user feedback (message + sound).
				// The map designer needs to use ACS/MAPINFO to properly block the exit
				// So to actually block exits, use the ACS method described above.
			}
		}
	}

	// ========================================================================
	// WorldUnloaded: Check when leaving MAP01 to complete death objective
	// ========================================================================
	override void WorldUnloaded(WorldEvent e)
	{
		// If leaving MAP01 and player didn't die, complete the objective
		if (level.MapName ~== "MAP01" && !playerDiedOnMAP01)
		{
			if (IsDebugEnabled()) Console.Printf("DEBUG: Leaving MAP01 without dying, completing objective");
			let obj = VUOS_ObjectiveHandler.FindByDescription("Complete this map without dying");
			if (obj && !obj.isCompleted)
			{
				VUOS_ObjectiveHandler.CompleteObjective(obj);
			}
		}
	}
	
	// ========================================================================
	// WorldThingDied: Detect player death on MAP01
	// ========================================================================
	override void WorldThingDied(WorldEvent e)
	{
		Super.WorldThingDied(e); // Call parent to handle kill objectives
		
		// Check if a player died on MAP01
		if (e.Thing && e.Thing.player && level.MapName ~== "MAP01")
		{
			if (IsDebugEnabled()) Console.Printf("DEBUG: Player died on MAP01, failing objective");
			playerDiedOnMAP01 = true;
			
			// Fail the objective
			let obj = VUOS_ObjectiveHandler.FindByDescription("Complete this map without dying");
			if (obj && !obj.hasFailed)
			{
				VUOS_ObjectiveHandler.FailObjective(obj);
			}
		}
	}
	
	// ========================================================================
	// WorldTick: Check player inventory for items like keys
	// ========================================================================
	override void WorldTick()
	{
		// CRITICAL: Call parent's WorldTick to handle timer countdown for timed objectives
		Super.WorldTick();
		
		// Only check if objective is still active
		if (hasRedKey) return;
		
		// Check all players for red key (card or skull version)
		for (int i = 0; i < MAXPLAYERS; i++)
		{
			if (!playeringame[i]) continue;
			
			let player = players[i].mo;
			if (!player) continue;
			
			// Check if player has red keycard or red skull key
			if (player.CountInv("RedCard") > 0 || player.CountInv("RedSkull") > 0)
			{
				hasRedKey = true;
				
				// Complete the objective
				let obj = VUOS_ObjectiveHandler.FindByDescription("Find the red key");
				if (obj)
				{
					VUOS_ObjectiveHandler.CompleteObjective(obj);
				}
				break;
			}
		}
	}
	
	// ========================================================================
	// NetworkProcess: Handle custom events from ACS or other sources
	// ========================================================================
	override void NetworkProcess(ConsoleEvent e)
	{
		// Handle exit blocking from ACS
		if (e.Name ~== "check_objectives_and_exit")
		{
			// Check if there are incomplete required objectives
			if (VUOS_ObjectiveHandler.HasIncompleteRequiredObjectives())
			{
				if (IsDebugEnabled()) Console.Printf("DEBUG: Exit blocked by ACS - incomplete required objectives");
				
				// Show the blocking message
				let renderer = VUOS_ObjectiveHandler.GetRenderer();
				if (renderer)
				{
					renderer.ShowRequiredObjectivesMessage();
				}

				// Play error sound on ALL players
				VUOS_ObjectiveHandler.PlaySoundAllPlayers("*usefail");
				// Don't call exit - just return and do nothing
			}
			else
			{
				// All required objectives complete - exit the map
				if (IsDebugEnabled()) Console.Printf("DEBUG: All required objectives complete - exiting map");
				Level.ExitLevel(0, false);
			}
			return;
		}
		
		// Test API methods via console
		// netevent test_objective_api
		if (e.Name ~== "test_objective_api")
		{
			string testObj = "Kill 5 demons";

			if (IsDebugEnabled())
			{
				Console.Printf("=== API Test Results for '%s' ===", testObj);
				Console.Printf("IsComplete: %d", VUOS_ObjectiveHandler.IsComplete(testObj));
				Console.Printf("IsActive: %d", VUOS_ObjectiveHandler.IsActive(testObj));
				Console.Printf("GetProgress: %d", VUOS_ObjectiveHandler.GetProgress(testObj));
				Console.Printf("GetMaxProgress: %d", VUOS_ObjectiveHandler.GetMaxProgress(testObj));
				Console.Printf("HasFailed: %d", VUOS_ObjectiveHandler.HasFailed(testObj));
			}
		}
		
		// DEBUG: Manually complete the "Complete this map without dying" objective
		// Usage: netevent test_complete_map
		if (e.Name ~== "test_complete_map")
		{
			let obj = VUOS_ObjectiveHandler.FindByDescription("Complete this map without dying");
			if (obj)
			{
				if (IsDebugEnabled())
				{
					Console.Printf("DEBUG: Manually completing objective '%s'", obj.objectiveDescription);
					Console.Printf("DEBUG: Before - isCompleted=%s, currentCount=%d",
						obj.isCompleted ? "true" : "false", obj.currentCount);
				}
				VUOS_ObjectiveHandler.CompleteObjective(obj);
				if (IsDebugEnabled()) Console.Printf("DEBUG: After - isCompleted=%s, currentCount=%d",
					obj.isCompleted ? "true" : "false", obj.currentCount);
			}
			else
			{
				if (IsDebugEnabled()) Console.Printf("DEBUG: Could not find 'Complete this map without dying' objective");
			}
		}
	
		// Track switch activations
		if (e.Name ~== "switch_activated")
		{
			switchesActivated++;
			if (IsDebugEnabled()) Console.Printf("DEBUG [Setup]: switch_activated - count now %d", switchesActivated);
			
			// Update progress
			let obj = VUOS_ObjectiveHandler.FindByDescription("Activate 3 power switches");
			if (obj)
			{
				obj.currentCount = switchesActivated;
				
				if (switchesActivated >= 3)
				{
					VUOS_ObjectiveHandler.CompleteObjective(obj);
					Console.Printf("\c[Green]All switches activated! Power restored!");
				}
			}
		}
		
		// Track secret discoveries
		if (e.Name ~== "secret_found")
		{
			secretsFound++;
			if (IsDebugEnabled()) Console.Printf("DEBUG [Setup]: secret_found - count now %d", secretsFound);
			
			// Update progress
			let obj = VUOS_ObjectiveHandler.FindByDescription("Find 2 secret areas");
			if (obj)
			{
				obj.currentCount = secretsFound;
				
				if (secretsFound >= 2)
				{
					VUOS_ObjectiveHandler.CompleteObjective(obj);
					Console.Printf("\c[Green]All secrets found!");
				}
			}
		}
	}
}