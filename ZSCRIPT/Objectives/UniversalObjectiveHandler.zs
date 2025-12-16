// ============================================================================
// UniversalObjectiveHandler.zs
// EventHandler for managing objectives and auto-tracking
// ============================================================================

class UniversalObjectiveHandler : EventHandler
{
	Array<UniversalObjective> objectives;
	TextureID objBackground;  // Cache the objectives background texture
	double objectiveAlpha;    // Alpha for objectives (can be overridden by subclasses)
	
	// Completion message display
	String completionMessage;
	int completionTimer;
	
	override void OnRegister()
	{
		// Cache the objectives background graphic
		objBackground = TexMan.CheckForTexture("OBJBG", TexMan.Type_Any);
		objectiveAlpha = 0.8;
		completionMessage = "";
		completionTimer = 0;
	}
	
	// Show completion message in center of screen
	void ShowCompletionMessage(String desc)
	{
		completionMessage = desc;
		completionTimer = 105; // Same duration as objective fade
	}
	
	// Find objective by description
	int FindByDescription(String desc)
	{
		for (int i = 0; i < objectives.Size(); i++)
		{
			if (objectives[i].description ~== desc)
			{
				return i;
			}
		}
		return -1;
	}
	
	// Find objective by target class (for auto-tracking)
	int FindByTargetClass(name className, int objType)
	{
		for (int i = 0; i < objectives.Size(); i++)
		{
			let obj = objectives[i];
			if (!obj) continue; // Skip null objectives
			if (obj.targetClass == className && obj.objectiveType == objType && !obj.completed)
			{
				return i;
			}
		}
		return -1;
	}
	
	// Auto-track kill objectives
	override void WorldThingDied(WorldEvent e)
	{
		if (!e.Thing || !e.Thing.bISMONSTER) { return; }
		
		// Check if any objective tracks this enemy type
		int index = FindByTargetClass(e.Thing.GetClassName(), UniversalObjective.TYPE_KILL);
		if (index >= 0)
		{
			objectives[index].IncrementProgress();
		}
	}
	
	// Auto-track destroy objectives (non-monster actors)
	override void WorldThingDestroyed(WorldEvent e)
	{
		if (!e.Thing) { return; }
		
		// Skip monsters (they're handled by WorldThingDied)
		if (e.Thing.bISMONSTER) { return; }
		
		// Check if any objective tracks this object type
		int index = FindByTargetClass(e.Thing.GetClassName(), UniversalObjective.TYPE_DESTROY);
		if (index >= 0)
		{
			objectives[index].IncrementProgress();
		}
	}
	
	// Update objective timers
	override void WorldTick()
	{
		// Update objective completion fade timers
		for (int i = 0; i < objectives.Size(); i++)
		{
			let obj = objectives[i];
			if (!obj) continue;
			if (obj.timer > 0)
			{
				obj.timer--;
			}
		}
		
		// Update completion message timer
		if (completionTimer > 0)
		{
			completionTimer--;
		}
	}
	
	// Play objective UI sound on the player
	void PlayObjectiveSound(Sound snd)
	{
		let pmo = players[consoleplayer].mo;
		if (pmo)
		{
			pmo.A_StartSound(snd, CHAN_AUTO, CHANF_UI | CHANF_NOPAUSE);
		}
	}
	
	// Handle network events (for collection tracking)
	override void NetworkProcess(ConsoleEvent e)
	{
		// J key: Full Objectives Screen
		// If Full Screen is on → toggle it off
		// If HUD is on → switch to Full Screen
		// If both off → show Full Screen
		if (e.Name ~== "toggle_objectives")
		{
			let cvarScreen = CVar.GetCVar('obj_show', players[consoleplayer]);
			let cvarHUD = CVar.GetCVar('obj_hud_show', players[consoleplayer]);
			
			if (cvarScreen && cvarHUD)
			{
				bool screenOn = cvarScreen.GetBool();
				bool hudOn = cvarHUD.GetBool();
				
				if (screenOn)
				{
					// Full Screen is on → turn it off
					cvarScreen.SetBool(false);
					PlayObjectiveSound("switches/exitbutn");
				}
				else if (hudOn)
				{
					// HUD is on → switch to Full Screen
					cvarHUD.SetBool(false);
					cvarScreen.SetBool(true);
					PlayObjectiveSound("switches/normbutn");
				}
				else
				{
					// Both off → show Full Screen
					cvarScreen.SetBool(true);
					PlayObjectiveSound("switches/normbutn");
				}
			}
		}
		
		// O key: HUD Objectives
		// If HUD is on → toggle it off
		// If Full Screen is on → switch to HUD
		// If both off → show HUD
		else if (e.Name ~== "toggle_objectives_hud")
		{
			let cvarScreen = CVar.GetCVar('obj_show', players[consoleplayer]);
			let cvarHUD = CVar.GetCVar('obj_hud_show', players[consoleplayer]);
			
			if (cvarScreen && cvarHUD)
			{
				bool screenOn = cvarScreen.GetBool();
				bool hudOn = cvarHUD.GetBool();
				
				if (hudOn)
				{
					// HUD is on → turn it off
					cvarHUD.SetBool(false);
				}
				else if (screenOn)
				{
					// Full Screen is on → switch to HUD
					cvarScreen.SetBool(false);
					cvarHUD.SetBool(true);
					PlayObjectiveSound("switches/exitbutn");
				}
				else
				{
					// Both off → show HUD
					cvarHUD.SetBool(true);
				}
			}
		}
		
		// Developer commands
		else if (e.Name ~== "obj_list")
		{
			ListObjectives();
		}
		else if (e.Name ~== "obj_clear")
		{
			ClearObjectives();
		}
		else if (e.Name ~== "obj_test")
		{
			Console.Printf("Adding test objectives...");
			UniversalObjective.Add("Kill 5 Imps", 5, UniversalObjective.TYPE_KILL, "DoomImp");
			UniversalObjective.Add("Kill 3 Cacodemons", 3, UniversalObjective.TYPE_KILL, "Cacodemon");
			UniversalObjective.Add("Find the secret", 1, UniversalObjective.TYPE_CUSTOM);
			Console.Printf("Test objectives added. Spawn some enemies to test!");
		}
		else if (e.Name ~== "obj_complete_test")
		{
			// Complete the first active objective as a test
			if (objectives.Size() > 0 && !objectives[0].completed)
			{
				objectives[0].MarkComplete();
				Console.Printf("Completed: %s", objectives[0].description);
			}
			else
			{
				Console.Printf("No active objectives to complete");
			}
		}
		else if (e.Name ~== "obj_complete_all")
		{
			// Complete all active objectives
			int completedCount = 0;
			for (int i = 0; i < objectives.Size(); i++)
			{
				let obj = objectives[i];
				if (!obj) continue;
				if (!obj.completed)
				{
					obj.MarkComplete();
					completedCount++;
				}
			}
			
			if (completedCount > 0)
			{
				Console.Printf("Completed %d objective%s", completedCount, completedCount == 1 ? "" : "s");
			}
			else
			{
				Console.Printf("No active objectives to complete");
			}
		}
	}
	
	// Render objectives on HUD
	override void RenderOverlay(RenderEvent e)
	{
		if (automapactive || screenblocks > 11)
		{
			return;
		}
		
		// Get both CVars
		let cvarScreen = CVar.GetCVar('obj_show', players[consoleplayer]);
		let cvarHUD = CVar.GetCVar('obj_hud_show', players[consoleplayer]);
		
		bool showScreen = cvarScreen ? cvarScreen.GetBool() : false;
		bool showHUD = cvarHUD ? cvarHUD.GetBool() : true; // HUD defaults to ON
		
		// Use FIXED 640x480 virtual resolution for consistent sizing
		int virtualWidth = 640;
		int virtualHeight = 480;
		
		// PRIORITY: Full Screen mode takes precedence over HUD mode
		if (showScreen)
		{
			RenderFullScreen(virtualWidth, virtualHeight);
		}
		else if (showHUD)
		{
			RenderHUD(virtualWidth, virtualHeight);
		}
		
		// Draw completion message (always on top, regardless of screen/HUD mode)
		if (completionTimer > 0)
		{
			RenderCompletionMessage(virtualWidth, virtualHeight);
		}
	}
	
	// Render completion message in center of screen with fade
	ui void RenderCompletionMessage(int virtualWidth, int virtualHeight)
	{
		Font fnt = SmallFont;
		
		// Calculate alpha based on timer (same timing as HUD objective fade)
		double alpha = 1.0;
		
		// Fade in during first 35 tics (timer 105-71)
		if (completionTimer > 70)
		{
			alpha = (105.0 - completionTimer) / 35.0;
		}
		// Fade out during last 35 tics (timer 35-0)
		else if (completionTimer < 36)
		{
			alpha = completionTimer / 35.0;
		}
		// Hold at full alpha (timer 70-36)
		
		// Center position
		int textWidth = fnt.StringWidth(completionMessage);
		double x = (virtualWidth - textWidth) / 2;
		double y = virtualHeight / 2 - 30; // Slightly above center
		
		// Draw "OBJECTIVE COMPLETE" header
		String header = "OBJECTIVE COMPLETE";
		int headerWidth = fnt.StringWidth(header);
		double headerX = (virtualWidth - headerWidth) / 2;
		
		screen.DrawText(fnt, Font.CR_GOLD, headerX, y, header,
			DTA_VirtualWidth, virtualWidth,
			DTA_VirtualHeight, virtualHeight,
			DTA_Alpha, alpha);
		
		// Draw objective description below
		screen.DrawText(fnt, Font.CR_WHITE, x, y + fnt.GetHeight() + 4, completionMessage,
			DTA_VirtualWidth, virtualWidth,
			DTA_VirtualHeight, virtualHeight,
			DTA_Alpha, alpha);
	}
	
	// Render Full Objectives Screen (with background, 2-column, shows all objectives)
	ui void RenderFullScreen(int virtualWidth, int virtualHeight)
	{
		// Draw background graphic
		if (objBackground.IsValid())
		{
			Vector2 texsize = TexMan.GetScaledSize(objBackground);
			double bgX = -95;
			double bgY = 15;
			double targetSize = 300;
			
			// Calculate dimensions maintaining source aspect ratio
			double aspectRatio = texsize.X / texsize.Y;
			int destWidth = int(targetSize);
			int destHeight = int(targetSize / aspectRatio);
			
			// Draw with calculated dimensions to maintain aspect ratio
			screen.DrawTexture(objBackground, false, bgX, bgY,
				DTA_VirtualWidth, virtualWidth,
				DTA_VirtualHeight, virtualHeight,
				DTA_DestWidth, destWidth,
				DTA_DestHeight, destHeight,
				DTA_Alpha, objectiveAlpha * 1.125); // Slightly higher than text for visibility
		}
		
		Font fnt = SmallFont;
		int lineHeight = fnt.GetHeight() + 2;
		int objectiveSpacing = 8; // Vertical space between objectives
		
		// Position text inside the monitor's green screen area
		double x = -48;
		double y = 100;
		
		// Two-column layout with reduced widths for square monitor
		int maxDescWidth = 190;  // Left column for description
		int counterX = 138;      // Right column X position for progress counter
		
		// Check if we have any objectives
		if (objectives.Size() == 0)
		{
			screen.DrawText(fnt, Font.CR_GRAY, x, y, "No objectives", 
				DTA_VirtualWidth, virtualWidth, 
				DTA_VirtualHeight, virtualHeight,
				DTA_Alpha, objectiveAlpha);
			return;
		}
		
		// Draw ALL objectives (both completed and incomplete)
		for (int i = 0; i < objectives.Size(); i++)
		{
			let obj = objectives[i];
			if (!obj) continue;
			
			// Use dynamic alpha
			double alpha = objectiveAlpha;
			
			int color = obj.completed ? Font.CR_GREEN : Font.CR_WHITE;
			double startY = y;
			
			// Build status and description
			String status = obj.completed ? "[X]" : "[ ]";
			String description = String.Format("%s %s", status, obj.description);
			
			// Build progress counter
			String progress = "";
			if (obj.required > 1)
			{
				progress = String.Format("%d/%d", obj.current, obj.required);
			}
			
			// Check if description needs wrapping
			if (fnt.StringWidth(description) > maxDescWidth)
			{
				// Word wrapping logic
				Array<String> words;
				String currentWord = "";
				
				for (int c = 0; c < description.Length(); c++)
				{
					String ch = description.CharAt(c);
					if (ch == " ")
					{
						if (currentWord.Length() > 0)
						{
							words.Push(currentWord);
							currentWord = "";
						}
					}
					else
					{
						currentWord = currentWord .. ch;
					}
				}
				if (currentWord.Length() > 0) { words.Push(currentWord); }
				
				String currentLine = "";
				bool firstLine = true;
				for (int w = 0; w < words.Size(); w++)
				{
					String testLine = currentLine.Length() > 0 ? currentLine .. " " .. words[w] : words[w];
					
					if (fnt.StringWidth(testLine) <= maxDescWidth)
					{
						currentLine = testLine;
					}
					else
					{
						if (currentLine.Length() > 0)
						{
							screen.DrawText(fnt, color, x, y, currentLine,
								DTA_VirtualWidth, virtualWidth,
								DTA_VirtualHeight, virtualHeight,
								DTA_Alpha, alpha);
							
							if (firstLine && progress.Length() > 0)
							{
								screen.DrawText(fnt, Font.CR_GREEN, counterX, y, progress,
									DTA_VirtualWidth, virtualWidth,
									DTA_VirtualHeight, virtualHeight,
									DTA_Alpha, alpha);
								firstLine = false;
							}
							
							y += lineHeight;
						}
						currentLine = words[w];
					}
				}
				
				if (currentLine.Length() > 0)
				{
					screen.DrawText(fnt, color, x, y, currentLine,
						DTA_VirtualWidth, virtualWidth,
						DTA_VirtualHeight, virtualHeight,
						DTA_Alpha, alpha);
					
					if (firstLine && progress.Length() > 0)
					{
						screen.DrawText(fnt, Font.CR_GREEN, counterX, startY, progress,
							DTA_VirtualWidth, virtualWidth,
							DTA_VirtualHeight, virtualHeight,
							DTA_Alpha, alpha);
					}
					
					y += lineHeight;
				}
			}
			else
			{
				screen.DrawText(fnt, color, x, y, description,
					DTA_VirtualWidth, virtualWidth,
					DTA_VirtualHeight, virtualHeight,
					DTA_Alpha, alpha);
				
				if (progress.Length() > 0)
				{
					screen.DrawText(fnt, Font.CR_GREEN, counterX, y, progress,
						DTA_VirtualWidth, virtualWidth,
						DTA_VirtualHeight, virtualHeight,
						DTA_Alpha, alpha);
				}
				
				y += lineHeight;
			}
			
			y += objectiveSpacing;
		}
	}
	
	// Render Simple HUD Objectives (no background, single column, only incomplete)
	ui void RenderHUD(int virtualWidth, int virtualHeight)
	{
		Font fnt = SmallFont;
		int lineHeight = fnt.GetHeight() + 2;
		
		// Position in top-left corner (simple HUD style)
		double x = -95;
		double y = 15;
		
		// Count visible objectives (incomplete + fading completed)
		int visibleCount = 0;
		for (int i = 0; i < objectives.Size(); i++)
		{
			let obj = objectives[i];
			if (!obj) continue;
			// Show incomplete objectives, or completed ones that are still fading
			if (!obj.completed || obj.timer > 0)
			{
				visibleCount++;
			}
		}
		
		// If no visible objectives, don't draw anything
		if (visibleCount == 0) { return; }
		
		// Draw green "OBJECTIVES" header
		screen.DrawText(fnt, Font.CR_GREEN, x, y, "OBJECTIVES",
			DTA_VirtualWidth, virtualWidth,
			DTA_VirtualHeight, virtualHeight,
			DTA_Alpha, objectiveAlpha);
		
		y += lineHeight + 3; // Add spacing after header
		
		// Draw incomplete objectives and fading completed ones
		for (int i = 0; i < objectives.Size(); i++)
		{
			let obj = objectives[i];
			if (!obj) continue;
			
			// Skip completed objectives that are done fading
			if (obj.completed && obj.timer <= 0) continue;
			
			// Calculate alpha for completion fade
			double alpha = objectiveAlpha;
			if (obj.completed && obj.timer > 0 && obj.timer < 36)
			{
				alpha = (obj.timer / 35.0) * objectiveAlpha;
			}
			
			// Use green for completed, white for incomplete
			int color = obj.completed ? Font.CR_GREEN : Font.CR_WHITE;
			
			// Build simple text - ALWAYS show count if required > 1
			String status = obj.completed ? "[X]" : "[ ]";
			String progress = "";
			if (obj.required > 1)
			{
				progress = String.Format(" (%d/%d)", obj.current, obj.required);
			}
			String text = String.Format("%s %s%s", status, obj.description, progress);
			
			// Draw with fade-out alpha
			screen.DrawText(fnt, color, x, y, text,
				DTA_VirtualWidth, virtualWidth,
				DTA_VirtualHeight, virtualHeight,
				DTA_Alpha, alpha);
			
			y += lineHeight;
		}
	}
	
	// Console command: list all objectives
	static void ListObjectives()
	{
		let handler = UniversalObjectiveHandler(EventHandler.Find("UniversalObjectiveHandler"));
		if (!handler)
		{
			// Try finding the fade handler variant
			handler = UniversalObjectiveHandler(EventHandler.Find("ObjectiveFadeHandler"));
		}
		if (!handler || handler.objectives.Size() == 0)
		{
			Console.Printf("No objectives");
			return;
		}
		
		Console.Printf("=== OBJECTIVES ===");
		for (int i = 0; i < handler.objectives.Size(); i++)
		{
			let obj = handler.objectives[i];
			String status = obj.completed ? "[COMPLETE]" : "[ACTIVE]";
			String progress = obj.required > 1 ? String.Format(" (%d/%d)", obj.current, obj.required) : "";
			Console.Printf("%d. %s %s%s", i, status, obj.description, progress);
		}
	}
	
	// Console command: clear all objectives
	static void ClearObjectives()
	{
		let handler = UniversalObjectiveHandler(EventHandler.Find("UniversalObjectiveHandler"));
		if (!handler)
		{
			// Try finding the fade handler variant
			handler = UniversalObjectiveHandler(EventHandler.Find("ObjectiveFadeHandler"));
		}
		if (!handler) { return; }
		
		handler.objectives.Clear();
		Console.Printf("All objectives cleared");
	}
}