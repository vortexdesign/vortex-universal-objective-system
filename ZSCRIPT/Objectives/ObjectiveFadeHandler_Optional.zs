// ============================================================================
// ObjectiveFadeHandler_Optional.zs
// Optional add-on that fades objectives when multiple pickup messages show
// 
// USAGE:
// Add to MAPINFO alongside UniversalObjectiveHandler:
//    AddEventHandlers = "UniversalObjectiveHandler", "ObjectiveSetup", "ObjectiveFadeHandler"
//
// TO DISABLE:
// Simply comment out or remove "ObjectiveFadeHandler" from MAPINFO
// ============================================================================

class ObjectiveFadeHandler : EventHandler
{
	int lastBonusCount;       // Track previous bonuscount to detect new pickups
	Array<int> pickupTimes;   // Timestamps of recent pickups
	
	// Timing constants (based on GZDoom defaults)
	// con_notifytime default = 3.0 seconds = 105 tics
	const FADE_HOLD_TIME = 105; // Match default pickup message duration
	const FADE_SPEED = 0.055;   // ~10 tics to fade in/out
	const FADE_MIN = 0.25;      // Minimum alpha when dimmed
	const FADE_MAX = 0.8;       // Normal alpha
	
	override void OnRegister()
	{
		lastBonusCount = 0;
		pickupTimes.Clear();
	}
	
	override void WorldTick()
	{
		// Find the main objective handler
		let handler = UniversalObjectiveHandler(EventHandler.Find("UniversalObjectiveHandler"));
		if (!handler) return;
		
		int currentTime = level.maptime;
		
		// Check all players for new pickups
		int currentBonusCount = 0;
		for (int i = 0; i < MAXPLAYERS; i++)
		{
			if (!playeringame[i]) continue;
			
			// bonuscount > 0 means pickup just happened (screen flash active)
			if (players[i].bonuscount > 0)
			{
				currentBonusCount = players[i].bonuscount;
				break;
			}
		}
		
		// Detect new pickup: bonuscount jumped up (reset on new pickup)
		if (currentBonusCount > lastBonusCount)
		{
			// Record this pickup time
			pickupTimes.Push(currentTime);
		}
		lastBonusCount = currentBonusCount;
		
		// Remove expired pickup times (older than FADE_HOLD_TIME)
		for (int i = pickupTimes.Size() - 1; i >= 0; i--)
		{
			if (currentTime - pickupTimes[i] > FADE_HOLD_TIME)
			{
				pickupTimes.Delete(i);
			}
		}
		
		// Count how many pickup messages are currently visible
		int activeMessages = pickupTimes.Size();
		
		// Smooth fade based on active message count
		// Only fade if there's more than 1 message visible
		if (activeMessages > 1)
		{
			// Multiple messages visible - fade down
			if (handler.objectiveAlpha > FADE_MIN)
			{
				handler.objectiveAlpha -= FADE_SPEED;
				if (handler.objectiveAlpha < FADE_MIN)
				{
					handler.objectiveAlpha = FADE_MIN;
				}
			}
		}
		else
		{
			// 0 or 1 message visible - fade back up
			if (handler.objectiveAlpha < FADE_MAX)
			{
				handler.objectiveAlpha += FADE_SPEED;
				if (handler.objectiveAlpha > FADE_MAX)
				{
					handler.objectiveAlpha = FADE_MAX;
				}
			}
		}
	}
}