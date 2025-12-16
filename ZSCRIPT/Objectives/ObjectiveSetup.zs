// ============================================================================
// ObjectiveSetup.zs
// Objectives for Doom 2 with standard actors
// Customize these for your own mod
// ============================================================================

class ObjectiveSetup : EventHandler
{
	
	int switchesActivated; // Track switch activation count for multi-switch objectives
	int secretsFound; // Track secrets found count
	bool hasRedKey; // Track if player has picked up red key
	
	// ========================================================================
	// WorldLoaded: Set up objectives when each map loads
	// ========================================================================
	override void WorldLoaded(WorldEvent e)
	{
		// Reset counters
		switchesActivated = 0;
		secretsFound = 0;
		hasRedKey = false; // Reset red key tracking
		
		// Set up objectives based on which map is loaded
		if (level.MapName ~== "MAP01")
		{
			SetupMAP01Objectives();
		}
		else if (level.MapName ~== "MAP02")
		{
			SetupMAP02Objectives();
		}
		
		// Add more maps as needed...
		
		// Anything outside of a an if statement checking for map will persist automatically to MAP02, MAP03, etc.
	}
	
	// ========================================================================
	// MAP01 Objectives
	// ========================================================================
	void SetupMAP01Objectives()
	{
		// Kill objectives with Doom 2 standard enemies
		UniversalObjective.Add("Clear the entrance of zombies", 3, 
			UniversalObjective.TYPE_KILL, "ZombieMan");
		
		UniversalObjective.Add("Eliminate the shotgun guys", 3, 
			UniversalObjective.TYPE_KILL, "ShotgunGuy");
		
		UniversalObjective.Add("Eliminate the chaingunners", 3, 
			UniversalObjective.TYPE_KILL, "ChaingunGuy");
		
		// Destroy objectives
		UniversalObjective.Add("Destroy explosive barrels", 4, 
			UniversalObjective.TYPE_DESTROY, "ExplosiveBarrel");
		
		// Custom objectives (triggered by pickups/linedefs/buttons)
		UniversalObjective.Add("Find the red key", 1, 
			UniversalObjective.TYPE_CUSTOM); // <- Manual tracking defined in WorldTick() method below
		UniversalObjective.Add("Reach the exit", 1, 
			UniversalObjective.TYPE_CUSTOM); // <- Manual tracking defined in WorldTick() method below
	}
	
	// ========================================================================
	// MAP02 Objectives
	// ========================================================================
	void SetupMAP02Objectives()
	{
		// Tougher enemies for MAP02
		UniversalObjective.Add("Defeat the demons", 8, 
			UniversalObjective.TYPE_KILL, "Demon");
		
		UniversalObjective.Add("Slay the hell knights", 5, 
			UniversalObjective.TYPE_KILL, "HellKnight");
		
		UniversalObjective.Add("Hunt the chaingunners", 3, 
			UniversalObjective.TYPE_KILL, "ChaingunGuy");
		
		// Custom objectives (triggered by pickups/linedefs/buttons)
		UniversalObjective.Add("Activate 3 power switches", 3, 
			UniversalObjective.TYPE_CUSTOM);
		
		UniversalObjective.Add("Find 2 secret areas", 2, 
			UniversalObjective.TYPE_CUSTOM);
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
		//     UniversalObjective.Complete("Some objective");
		// }
	}
	
	// ========================================================================
	// WorldTick: Check if player has picked up red key
	// ========================================================================
	override void WorldTick()
	{
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
				UniversalObjective.Complete("Find the red key");
				break;
			}
		}
	}
	
	// ========================================================================
	// NetworkProcess: Handle custom events from ACS or other sources
	// ========================================================================
	override void NetworkProcess(ConsoleEvent e)
	{
		// Track switch activations
		if (e.Name ~== "switch_activated")
		{
			switchesActivated++;
			UniversalObjective.UpdateProgress("Activate 3 power switches", switchesActivated);
			
			if (switchesActivated >= 3)
			{
				Console.Printf("\c[Green]All switches activated! Power restored!");
			}
		}
		
		// Track secret discoveries
		if (e.Name ~== "secret_found")
		{
			secretsFound++;
			UniversalObjective.UpdateProgress("Find 2 secret areas", secretsFound);
			
		    if (secretsFound >= 2)
			{
				Console.Printf("\c[Green]All secrets found!");
			}
		}
	}
}