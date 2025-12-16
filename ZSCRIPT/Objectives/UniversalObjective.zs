// ============================================================================
// UniversalObjective.zs
// A clean, universal objective system for GZDoom mods
// Based on Blade of Agony's architecture, simplified by Vortex for universal use
// MIT LICENSE - Please include README.md, CREDITS.txt and LISCENSE files in your mod
// ============================================================================

class UniversalObjective : Thinker
{
	String description;
	int current;
	int required;
	bool completed;
	int objectiveType;  // 0=KILL, 1=COLLECT, 2=DESTROY, 3=CUSTOM
	name targetClass;   // Actor class to auto-track (for KILL/COLLECT/DESTROY)
	int timer;          // For fade-out animation
	
	// Static constants for objective types
	const TYPE_KILL = 0;
	const TYPE_COLLECT = 1;
	const TYPE_DESTROY = 2;
	const TYPE_CUSTOM = 3;
	
	// Add a new objective or update existing one
	// ACS: ScriptCall("UniversalObjective", "Add", "Kill 10 Imps", 10, TYPE_KILL, "DoomImp");
	// ZScript: UniversalObjective.Add("Kill 10 Imps", 10, UniversalObjective.TYPE_KILL, "DoomImp");
	static UniversalObjective Add(String desc, int required = 1, int objType = TYPE_CUSTOM, name targetClass = "", int initialProgress = 0)
	{
		if (!desc.length()) { return null; }
		
		let handler = UniversalObjectiveHandler(EventHandler.Find("UniversalObjectiveHandler"));
		if (!handler) { return null; }
		
		// Check if objective with same description already exists
		int existingIndex = handler.FindByDescription(desc);
		UniversalObjective obj;
		
		if (existingIndex >= 0)
		{
			// Update existing objective
			obj = handler.objectives[existingIndex];
		}
		else
		{
			// Create new objective
			obj = new("UniversalObjective");
			handler.objectives.Push(obj);
			Console.Printf("\c[Green]New Objective: \c[White]%s", desc);
		}
		
		obj.description = desc;
		obj.required = required;
		obj.current = initialProgress;
		obj.objectiveType = objType;
		obj.targetClass = targetClass;
		obj.completed = false;
		obj.timer = -1;
		
		return obj;
	}
	
	// Update progress on an objective
	// ACS: ScriptCall("UniversalObjective", "UpdateProgress", "Kill 10 Imps", 5);
	// ZScript: UniversalObjective.UpdateProgress("Kill 10 Imps", 5);
	static void UpdateProgress(String desc, int progress)
	{
		if (!desc.length()) { return; }
		
		let handler = UniversalObjectiveHandler(EventHandler.Find("UniversalObjectiveHandler"));
		if (!handler) { return; }
		
		int index = handler.FindByDescription(desc);
		if (index < 0) { return; }
		
		let obj = handler.objectives[index];
		obj.current = progress;
		
		if (obj.current >= obj.required && !obj.completed)
		{
			obj.MarkComplete();
		}
	}
	
	// Mark an objective as complete
	// ACS: ScriptCall("UniversalObjective", "Complete", "Kill 10 Imps");
	// ZScript: UniversalObjective.Complete("Kill 10 Imps");
	static void Complete(String desc)
	{
		if (!desc.length()) { return; }
		
		let handler = UniversalObjectiveHandler(EventHandler.Find("UniversalObjectiveHandler"));
		if (!handler) { return; }
		
		int index = handler.FindByDescription(desc);
		if (index < 0) { return; }
		
		handler.objectives[index].MarkComplete();
	}
	
	// Complete this objective (instance method)
	void MarkComplete()
	{
		if (completed) { return; }
		
		completed = true;
		timer = 105; // 3 seconds fade-out
		
		// Play completion sound
		let pmo = players[consoleplayer].mo;
		if (pmo)
		{
			pmo.A_StartSound("misc/p_pkup", CHAN_AUTO, CHANF_UI | CHANF_NOPAUSE);
		}
		
		// Tell handler to display completion message
		let handler = UniversalObjectiveHandler(EventHandler.Find("UniversalObjectiveHandler"));
		if (handler)
		{
			handler.ShowCompletionMessage(description);
		}
	}
	
	// Increment progress (used by auto-tracking)
	void IncrementProgress()
	{
		if (completed) { return; }
		
		current++;
		
		if (current >= required)
		{
			MarkComplete();
		}
	}
	
	// Draw this objective on the HUD
	ui void DrawObjective(Font fnt, double x, double y, double w = 800, double h = 600, double alpha = 1.0)
	{
		String status = completed ? "[X]" : "[ ]";
		String progress = "";
		
		// Show progress for non-complete objectives with requirements
		if (!completed && required > 1)
		{
			progress = String.Format(" (%d/%d)", current, required);
		}
		
		String output = String.Format("%s %s%s", status, description, progress);
		
		int color = completed ? Font.CR_GREEN : Font.CR_WHITE;
		
		screen.DrawText(fnt, color, x, y, output, 
			DTA_VirtualWidthF, w, 
			DTA_VirtualHeightF, h, 
			DTA_Alpha, alpha);
	}
}