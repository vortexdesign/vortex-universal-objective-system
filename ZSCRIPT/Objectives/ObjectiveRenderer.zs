// ObjectiveRenderer.zs
// Handles display of objectives on screen

class VUOS_ObjectiveRenderer : EventHandler
{
    TextureID objBackground;  // Cache the objectives background texture
    TextureID objCursor;      // Cache the journal selection cursor texture
    double objectiveAlpha;    // Alpha for objectives

    // Completion message queue
    Array<String> completionQueue;
    String completionMessage;
    int completionTimer;

    // Failure message queue
    Array<String> failureQueue;
    String failureMessage;
    int failureTimer;

    // Required objectives blocking message
    String requiredMessage;
    int requiredTimer;

    // Pickup monitoring for dimming objectives
    int lastBonusCount;       // Track previous bonuscount to detect new pickups
    Array<int> pickupTimes;   // Timestamps of recent pickups

    // Journal cursor for objective tracking (per-player for multiplayer support)
    // Indexed by player number — NetworkProcess uses e.Player, rendering uses consoleplayer
    int journalSelectedIndex[MAXPLAYERS];
    int journalObjectiveCount[MAXPLAYERS];
    int journalScrollOffset[MAXPLAYERS];

    // Cached handler reference for UI-scope access (set in WorldTick, read in RenderOverlay)
    // Cached for performance — avoids EventHandler.Find() lookup every frame
    VUOS_ObjectiveHandler cachedSetupHandler;

    // Cached render settings — allocated once in OnRegister, refreshed every frame
    // Avoids per-frame GC allocation from creating a new object each RenderOverlay call
    VUOS_RenderSettings cachedRenderSettings;

    // Timing constants (based on GZDoom defaults)
    const FADE_HOLD_TIME = 105; // Pickup message duration for dimming detection (3 seconds)
    const FADE_SPEED = 0.055;   // ~10 tics to fade in/out
    const FADE_MIN = 0.25;      // Minimum alpha when dimmed
    const FADE_MAX = 0.8;       // Normal alpha

    // Default virtual resolution (before StatusBar.GetHUDScale() override)
    const DEFAULT_VIRTUAL_W  = 640;
    const DEFAULT_VIRTUAL_H  = 480;

    // Journal (full screen) layout constants
    const JOURNAL_BG_X       = 12;    // Background X offset
    const JOURNAL_BG_Y       = 15;    // Background Y offset
    const JOURNAL_BG_SIZE    = 300;   // Background target size (square)
    const JOURNAL_TEXT_X     = 47;    // Text X offset from background left edge
    const JOURNAL_TEXT_Y     = 85;    // Text Y offset from background top edge
    const JOURNAL_DESC_WIDTH = 175;   // Max description column width
    const JOURNAL_COUNTER_X  = 218;   // Counter column X offset from background
    const JOURNAL_HINT_BOTTOM = 20;   // Hint line distance from background bottom
    const JOURNAL_CONTENT_BOTTOM = 35; // Content area bottom margin (hint + border)
    const JOURNAL_SECTION_GAP = 8;    // Gap between primary and secondary sections
    const JOURNAL_OBJ_SPACING = 3;    // Vertical space between objectives

    // HUD layout constants
    const HUD_MARGIN_X       = 12;    // Left/right margin for HUD text
    const HUD_MARGIN_Y       = 15;    // Top margin for HUD text
    const HUD_BOTTOM_MARGIN  = 65;    // Bottom margin for bottom-positioned HUD
    const HUD_MAX_DESC_WIDTH = 400;   // Max description width for wrapping
    const HUD_RIGHT_NUDGE    = 5;     // Right-aligned X nudge

    // Notification positioning
    const NOTIFY_COMPLETE_Y  = 30;    // Completion message offset above center
    const NOTIFY_REQUIRED_Y  = 50;    // Required message offset above center
    const NOTIFY_TEXT_GAP    = 4;     // Gap between header and description text

    // Read notification duration from CVar (clamped to minimum 35 tics = 1 second)
    // clearscope: safe to use consoleplayer here — only called from UI-scope rendering
    // and WorldTick queue management, both of which operate on the local client.
    clearscope int GetNotificationDuration()
    {
        int dur = VUOS_ObjectiveHandler.GetCVarInt('obj_notification_duration', players[consoleplayer], 105);
        if (dur < 35) dur = 35;
        return dur;
    }

    // Calculate fade alpha for notification timers (fade-in first third, hold middle, fade-out last third)
    // Timer counts down from duration to 0
    ui double CalcNotificationFadeAlpha(int timer, int duration)
    {
        int fadeThird = duration / 3;
        if (timer > duration - fadeThird)
            return (duration - timer) / double(fadeThird);
        else if (timer < fadeThird + 1)
            return timer / double(fadeThird);
        return 1.0;
    }

    // Read a color CVar and return the font color index
    ui int GetColorCVar(string cvarName, int defaultColor)
    {
        return VUOS_ObjectiveHandler.GetCVarInt(cvarName, players[consoleplayer], defaultColor);
    }

    override void OnRegister()
    {
        // Cache the objectives background graphic and cursor texture
        objBackground = TexMan.CheckForTexture("OBJBG", TexMan.Type_Any);
        objCursor = TexMan.CheckForTexture("OBJCURS", TexMan.Type_Any);
        objectiveAlpha = 0.8;
        completionMessage = "";
        completionTimer = 0;
        completionQueue.Clear();
        failureMessage = "";
        failureTimer = 0;
        failureQueue.Clear();
        requiredMessage = "";
        requiredTimer = 0;
        lastBonusCount = 0;
        pickupTimes.Clear();
        // journalSelectedIndex/Count/ScrollOffset are fixed arrays — zero-initialized automatically
        cachedRenderSettings = new("VUOS_RenderSettings");
    }

    // Show completion message in center of screen
    void ShowCompletionMessage(String desc)
    {
        // If a message is already displaying, queue this one
        if (completionTimer > 0)
        {
            completionQueue.Push(desc);
        }
        else
        {
            completionMessage = desc;
            completionTimer = GetNotificationDuration();
        }
        PlayerInfo fp = VUOS_ObjectiveHandler.GetFirstPlayer();
        if (VUOS_ObjectiveHandler.GetCVarBool('obj_console_notifications', fp))
            Console.Printf("\c[Gold]OBJECTIVE COMPLETE:\c- %s", desc);
    }

    // Show failure message in center of screen
    void ShowFailureMessage(String desc)
    {
        // If a message is already displaying, queue this one
        if (failureTimer > 0)
        {
            failureQueue.Push(desc);
        }
        else
        {
            failureMessage = desc;
            failureTimer = GetNotificationDuration();
        }
        PlayerInfo fp = VUOS_ObjectiveHandler.GetFirstPlayer();
        if (VUOS_ObjectiveHandler.GetCVarBool('obj_console_notifications', fp))
            Console.Printf("\c[Red]OBJECTIVE FAILED:\c- %s", desc);
    }

    // Show required objectives message in center of screen
    void ShowRequiredObjectivesMessage()
    {
        requiredMessage = "You still have required objectives to complete!";
        requiredTimer = GetNotificationDuration();
        PlayerInfo fp = VUOS_ObjectiveHandler.GetFirstPlayer();
        if (VUOS_ObjectiveHandler.GetCVarBool('obj_console_notifications', fp))
            Console.Printf("\c[Red]%s", requiredMessage);
    }

    // Format time remaining as MM:SS
    ui String FormatTime(int tics)
    {
        int totalSeconds = tics / 35; // Convert tics to seconds
        int minutes = totalSeconds / 60;
        int seconds = totalSeconds % 60;
        return String.Format("%d:%02d", minutes, seconds);
    }

    // Format distance for display based on unit preference CVAR
    // 32 map units ≈ 1 meter (standard Doom convention)
    // ui scope: consoleplayer is correct — each client formats its own HUD
    ui String FormatDistance(int mapUnits)
    {
        int units = VUOS_ObjectiveHandler.GetCVarInt('obj_distance_units', players[consoleplayer], 1);

        // Get distance color escape code from CVAR
        int colorIndex = VUOS_ObjectiveHandler.GetCVarInt('obj_color_distance', players[consoleplayer], 10); // default CR_YELLOW
        String colorCode = "\c" .. String.Format("%c", 65 + colorIndex);

        String distStr;
        if (units == 0)
        {
            // Raw map units
            distStr = String.Format("%du", mapUnits);
        }
        else
        {
            // Meters (32 map units ≈ 1 meter)
            int meters = mapUnits / 32;
            distStr = String.Format("%dm", meters);
        }

        // Format: " -<color>127m<reset>- "
        return " -" .. colorCode .. distStr .. "\c-" .. "- ";
    }

    // ====================================================================
    // SHARED HELPER METHODS (word-wrap, color, entry drawing)
    // ====================================================================

    // Word-wrap text into lines that fit within maxWidth
    // Eliminates duplicated word-wrapping logic across rendering methods
    ui static void WrapText(Font fnt, String text, int maxWidth, Array<String> outLines)
    {
        outLines.Clear();

        // Split into words
        Array<String> words;
        String currentWord = "";

        for (int c = 0; c < text.Length(); c++)
        {
            String ch = text.CharAt(c);
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

        // Build lines
        String currentLine = "";
        for (int w = 0; w < words.Size(); w++)
        {
            String testLine = currentLine.Length() > 0 ? currentLine .. " " .. words[w] : words[w];

            if (fnt.StringWidth(testLine) <= maxWidth)
            {
                currentLine = testLine;
            }
            else
            {
                if (currentLine.Length() > 0)
                {
                    outLines.Push(currentLine);
                }
                currentLine = words[w];
            }
        }
        if (currentLine.Length() > 0) { outLines.Push(currentLine); }
    }

    // Get the appropriate font color for an objective based on its state
    ui int GetObjectiveColor(VUOS_ObjectiveData obj)
    {
        if (obj.hasFailed) return GetColorCVar('obj_color_failed', Font.CR_RED);
        if (obj.isCompleted) return GetColorCVar('obj_color_completed', Font.CR_GREEN);
        return GetColorCVar('obj_color_active', Font.CR_WHITE);
    }

    // Separate objectives into primary and secondary arrays for the current map.
    // When hudMode is true, applies HUD-specific filters:
    //   - Respects showUntracked (skip untracked objectives if false)
    //   - Only includes incomplete objectives or those still fading out (timer > 0)
    // Returns the total number of objectives added to both arrays.
    ui static int SeparateObjectives(
        Array<VUOS_ObjectiveData> objectives,
        Array<VUOS_ObjectiveData> outPrimary,
        Array<VUOS_ObjectiveData> outSecondary,
        bool hudMode = false,
        bool showUntracked = true,
        int skill = -1)
    {
        outPrimary.Clear();
        outSecondary.Clear();

        if (skill < 0) skill = G_SkillPropertyInt(SKILLP_ACSReturn);
        for (int i = 0; i < objectives.Size(); i++)
        {
            let obj = objectives[i];

            if (!obj.IsVisibleForCurrentMap(skill)) continue;

            if (hudMode)
            {
                if (!showUntracked && !obj.isTracked) continue;
                if ((obj.isCompleted || obj.hasFailed) && obj.timer <= 0) continue;
            }

            if (obj.isPrimary)
                outPrimary.Push(obj);
            else
                outSecondary.Push(obj);
        }

        return outPrimary.Size() + outSecondary.Size();
    }

    // Draw a single objective entry in Full Screen (journal) mode
    // Returns the new Y position after drawing
    ui double DrawFullScreenEntry(
        Font fnt, VUOS_ObjectiveData obj,
        double x, double y,
        int maxDescWidth, double counterX,
        int lineHeight, double alpha,
        int virtualWidth, int virtualHeight,
        bool showDistance,
        bool isSelected = false)
    {
        int color = GetObjectiveColor(obj);

        // Dim untracked objectives (completed/failed always show at full alpha)
        double entryAlpha = (obj.isTracked || obj.isCompleted || obj.hasFailed) ? alpha : alpha * 0.5;

        // Fixed-width column for tracking indicator so brackets always align
        int trackColWidth = fnt.StringWidth("* ");
        double statusX = x + trackColWidth;

        // Draw selection cursor indicator
        if (isSelected)
        {
            if (objCursor.isValid())
            {
                // Textured cursor: sized smaller to align with text baseline
                Vector2 texSize = TexMan.GetScaledSize(objCursor);
                double cursorH = double(fnt.GetHeight()) * 0.7;
                double cursorW = cursorH * (texSize.X / texSize.Y);
                double cursorX = x - cursorW - 2;
                double cursorY = y;
                screen.DrawTexture(objCursor, false, cursorX, cursorY,
                    DTA_VirtualWidth, virtualWidth,
                    DTA_VirtualHeight, virtualHeight,
                    DTA_KeepRatio, true,
                    DTA_DestWidthF, cursorW,
                    DTA_DestHeightF, cursorH,
                    DTA_Alpha, alpha,
                    DTA_FillColor, Color(255, 200, 0));
            }
            else
            {
                // Procedural fallback: draw ">" character
                screen.DrawText(fnt, Font.CR_GOLD, x - fnt.StringWidth("> "), y, ">",
                    DTA_VirtualWidth, virtualWidth,
                    DTA_VirtualHeight, virtualHeight,
                    DTA_KeepRatio, true,
                    DTA_Alpha, alpha);
            }
        }

        // Draw tracking indicator separately at fixed position (hide for completed/failed)
        if (!obj.isCompleted && !obj.hasFailed && obj.isTracked)
        {
            screen.DrawText(fnt, color, x, y, "*",
                DTA_VirtualWidth, virtualWidth,
                DTA_VirtualHeight, virtualHeight,
                DTA_KeepRatio, true,
                DTA_Alpha, entryAlpha);
        }

        // Build status and description (without tracking indicator)
        String status = obj.hasFailed ? "[X]" : (obj.isCompleted ? "[X]" : "[ ]");
        String description = String.Format("%s %s", status, obj.objectiveDescription);

        // Build distance + timer text (appended after description when drawing)
        String timerText = "";
        if (showDistance && obj.hasWaypoint && !obj.isCompleted && !obj.hasFailed)
        {
            timerText = FormatDistance(obj.GetDistance(consoleplayer));
        }
        if (obj.timeLimit > 0 && !obj.isCompleted && !obj.hasFailed)
        {
            String timeStr = FormatTime(obj.timeRemaining);
            timerText = timerText .. " [" .. timeStr .. "]";
        }

        // Build progress counter
        String progress = "";
        if (obj.targetCount > 1)
        {
            progress = String.Format(" (%d/%d)", obj.currentCount, obj.targetCount);
        }

        // Wrapping width accounts for the tracking indicator column drawn separately
        int descWrapWidth = maxDescWidth - trackColWidth;

        // Check if description needs wrapping (WITHOUT timer for wrapping calculation)
        if (fnt.StringWidth(description) > descWrapWidth)
        {
            Array<String> lines;
            WrapText(fnt, description, descWrapWidth, lines);

            for (int l = 0; l < lines.Size(); l++)
            {
                String lineText = lines[l];
                // Append timer to last line
                if (l == lines.Size() - 1) lineText = lineText .. timerText;

                screen.DrawText(fnt, color, statusX, y, lineText,
                    DTA_VirtualWidth, virtualWidth,
                    DTA_VirtualHeight, virtualHeight,
                    DTA_KeepRatio, true,
                    DTA_Alpha, entryAlpha);

                // Draw progress counter on first line at counterX
                if (l == 0 && progress.Length() > 0)
                {
                    int progressColor = obj.hasFailed ? GetColorCVar('obj_color_failed', Font.CR_RED) : GetColorCVar('obj_color_completed', Font.CR_GREEN);
                    screen.DrawText(fnt, progressColor, counterX, y, progress,
                        DTA_VirtualWidth, virtualWidth,
                        DTA_VirtualHeight, virtualHeight,
                        DTA_KeepRatio, true,
                        DTA_Alpha, entryAlpha);
                }

                y += lineHeight;
            }
        }
        else
        {
            screen.DrawText(fnt, color, statusX, y, description .. timerText,
                DTA_VirtualWidth, virtualWidth,
                DTA_VirtualHeight, virtualHeight,
                DTA_KeepRatio, true,
                DTA_Alpha, entryAlpha);

            if (progress.Length() > 0)
            {
                int progressColor = obj.hasFailed ? GetColorCVar('obj_color_failed', Font.CR_RED) : GetColorCVar('obj_color_completed', Font.CR_GREEN);
                screen.DrawText(fnt, progressColor, counterX, y, progress,
                    DTA_VirtualWidth, virtualWidth,
                    DTA_VirtualHeight, virtualHeight,
                    DTA_KeepRatio, true,
                    DTA_Alpha, entryAlpha);
            }

            y += lineHeight;
        }

        return y;
    }

    // Draw a single objective entry in HUD mode
    // Returns the new Y position after drawing
    ui double DrawHUDEntry(
        Font fnt, VUOS_ObjectiveData obj,
        double x, double y,
        int maxDescWidth, int lineHeight,
        double baseAlpha, bool needsWrapping,
        int virtualWidth, int virtualHeight,
        bool showDistance)
    {
        int color = GetObjectiveColor(obj);

        // Calculate alpha for completion/failure fade
        double alpha = baseAlpha;
        int fadeThird = GetNotificationDuration() / 3;
        if ((obj.isCompleted || obj.hasFailed) && obj.timer > 0 && obj.timer < fadeThird + 1)
        {
            alpha = (obj.timer / double(fadeThird)) * baseAlpha;
        }

        // Build inline text: status + description + timer + progress
        String status = obj.hasFailed ? "[X]" : (obj.isCompleted ? "[X]" : "[ ]");

        String timerText = "";
        if (showDistance && obj.hasWaypoint && !obj.isCompleted && !obj.hasFailed)
        {
            timerText = FormatDistance(obj.GetDistance(consoleplayer));
        }
        if (obj.timeLimit > 0 && !obj.isCompleted && !obj.hasFailed)
        {
            String timeStr = FormatTime(obj.timeRemaining);
            timerText = timerText .. " [" .. timeStr .. "]";
        }

        String progress = "";
        if (obj.targetCount > 1)
        {
            progress = String.Format(" (%d/%d)", obj.currentCount, obj.targetCount);
        }

        String text = String.Format("%s %s%s%s", status, obj.objectiveDescription, timerText, progress);

        // Check if wrapping is needed (only for right-aligned positions)
        if (needsWrapping && fnt.StringWidth(text) > maxDescWidth)
        {
            Array<String> lines;
            WrapText(fnt, text, maxDescWidth, lines);

            for (int l = 0; l < lines.Size(); l++)
            {
                screen.DrawText(fnt, color, x, y, lines[l],
                    DTA_VirtualWidth, virtualWidth,
                    DTA_VirtualHeight, virtualHeight,
                    DTA_KeepRatio, true,
                    DTA_Alpha, alpha);
                y += lineHeight;
            }
        }
        else
        {
            screen.DrawText(fnt, color, x, y, text,
                DTA_VirtualWidth, virtualWidth,
                DTA_VirtualHeight, virtualHeight,
                DTA_KeepRatio, true,
                DTA_Alpha, alpha);
            y += lineHeight;
        }

        return y;
    }

    // Measure the height of a single HUD objective entry (for bottom positioning)
    // Uses worst-case timer/distance widths to prevent jitter
    ui int MeasureHUDEntry(
        Font fnt, VUOS_ObjectiveData obj,
        int maxDescWidth, int lineHeight,
        bool needsWrapping, bool showDistance)
    {
        String status = obj.hasFailed ? "[X]" : (obj.isCompleted ? "[X]" : "[ ]");

        // Use worst-case widths to prevent position jitter
        String timerText = "";
        if (showDistance && obj.hasWaypoint && !obj.isCompleted && !obj.hasFailed)
        {
            timerText = " -99999m- ";
        }
        if (obj.timeLimit > 0 && !obj.isCompleted && !obj.hasFailed)
        {
            timerText = timerText .. " [99:59]";
        }

        String progress = "";
        if (obj.targetCount > 1)
        {
            progress = String.Format(" (%d/%d)", obj.currentCount, obj.targetCount);
        }

        String text = String.Format("%s %s%s%s", status, obj.objectiveDescription, timerText, progress);

        if (needsWrapping && fnt.StringWidth(text) > maxDescWidth)
        {
            Array<String> lines;
            WrapText(fnt, text, maxDescWidth, lines);
            return lineHeight * lines.Size();
        }

        return lineHeight;
    }

    // Measure the worst-case text width of a single HUD objective entry
    // Uses worst-case timer/distance widths to prevent jitter
    ui int MeasureHUDEntryWidth(
        Font fnt, VUOS_ObjectiveData obj,
        int maxDescWidth, bool needsWrapping, bool showDistance)
    {
        String status = obj.hasFailed ? "[X]" : (obj.isCompleted ? "[X]" : "[ ]");

        String timerText = "";
        if (showDistance && obj.hasWaypoint && !obj.isCompleted && !obj.hasFailed)
        {
            timerText = " -99999m- ";
        }
        if (obj.timeLimit > 0 && !obj.isCompleted && !obj.hasFailed)
        {
            timerText = timerText .. " [99:59]";
        }

        String progress = "";
        if (obj.targetCount > 1)
        {
            progress = String.Format(" (%d/%d)", obj.currentCount, obj.targetCount);
        }

        String text = String.Format("%s %s%s%s", status, obj.objectiveDescription, timerText, progress);

        if (needsWrapping && fnt.StringWidth(text) > maxDescWidth)
        {
            return maxDescWidth;
        }

        return fnt.StringWidth(text);
    }

    // Play objective UI sound on ALL active players (multiplayer-safe)
    void PlayObjectiveSound(Sound snd)
    {
        VUOS_ObjectiveHandler.PlaySoundAllPlayers(snd);
    }

    // Handle network events for J and O keys
    override void NetworkProcess(ConsoleEvent e)
    {
        PlayerInfo player = players[e.Player];

        // J key: Toggle Full Objectives Screen (Journal)
        // Only toggles obj_show — never touches the HUD CVar.
        // When journal is open, it takes rendering priority over HUD list.
        // When journal is closed, HUD list reappears if still enabled.
        if (e.Name ~== "toggle_objectives")
        {
            let cvarScreen = CVar.GetCVar('obj_show', player);

            if (cvarScreen)
            {
                bool screenOn = cvarScreen.GetBool();
                cvarScreen.SetBool(!screenOn);
                if (VUOS_ObjectiveHandler.IsDebugEnabled()) Console.Printf("DEBUG [Renderer]: Player %d toggled journal %s", e.Player, screenOn ? "OFF" : "ON");
                PlayObjectiveSound(screenOn ? "switches/exitbutn" : "switches/normbutn");

                // Reset cursor and scroll when closing journal
                if (screenOn)
                {
                    journalSelectedIndex[e.Player] = 0;
                    journalScrollOffset[e.Player] = 0;
                }
            }
        }

        // O key: Toggle HUD Objectives List
        // Only toggles obj_hud_show — never touches the journal CVar.
        else if (e.Name ~== "toggle_objectives_hud")
        {
            let cvarHUD = CVar.GetCVar('obj_hud_show', player);

            if (cvarHUD)
            {
                bool hudOn = cvarHUD.GetBool();
                cvarHUD.SetBool(!hudOn);
                if (VUOS_ObjectiveHandler.IsDebugEnabled()) Console.Printf("DEBUG [Renderer]: Player %d toggled HUD %s", e.Player, hudOn ? "OFF" : "ON");
                PlayObjectiveSound(hudOn ? "switches/exitbutn" : "switches/normbutn");
            }
        }

        // P key (or user-bound key): Cycle HUD Position
        // 0 (top-left) → 1 (top-right) → 2 (bottom-left) → 3 (bottom-right) → back to 0
        else if (e.Name ~== "cycle_hud_position")
        {
            let cvarPosition = CVar.GetCVar('obj_hud_position', player);

            if (cvarPosition)
            {
                int currentPos = cvarPosition.GetInt();
                int newPos = (currentPos + 1) % 4; // Cycle through 0, 1, 2, 3
                cvarPosition.SetInt(newPos);
                if (VUOS_ObjectiveHandler.IsDebugEnabled()) Console.Printf("DEBUG [Renderer]: Player %d cycled HUD position %d -> %d", e.Player, currentPos, newPos);
                PlayObjectiveSound("switches/normbutn");
            }
        }

        // I key: Toggle Waypoint Indicators
        // Toggles between 1 (Always Off) and 2 (Toggle with HUD).
        // Mode 0 (Always On) is only selectable via the options menu.
        else if (e.Name ~== "cycle_waypoint_mode")
        {
            let cvarWpMode = CVar.GetCVar('obj_waypoint_mode', player);
            if (cvarWpMode)
            {
                int currentMode = cvarWpMode.GetInt();
                int newMode = (currentMode == 1) ? 2 : 1;
                cvarWpMode.SetInt(newMode);
                if (VUOS_ObjectiveHandler.IsDebugEnabled()) Console.Printf("DEBUG [Renderer]: Player %d cycled waypoint mode %d -> %d", e.Player, currentMode, newMode);
                PlayObjectiveSound(newMode == 1 ? "switches/exitbutn" : "switches/normbutn");
            }
        }

        // Toggle compass visibility
        else if (e.Name ~== "toggle_compass")
        {
            let cvarCompass = CVar.GetCVar('obj_compass_show', player);
            if (cvarCompass)
            {
                cvarCompass.SetBool(!cvarCompass.GetBool());
                if (VUOS_ObjectiveHandler.IsDebugEnabled()) Console.Printf("DEBUG [Renderer]: Player %d toggled compass %s", e.Player, cvarCompass.GetBool() ? "ON" : "OFF");
                PlayObjectiveSound("switches/normbutn");
            }
        }

        // Journal cursor: move up
        else if (e.Name ~== "journal_cursor_up")
        {
            if (journalSelectedIndex[e.Player] > 0)
            {
                journalSelectedIndex[e.Player]--;
                // Auto-scroll up if cursor is above visible range
                if (journalSelectedIndex[e.Player] < journalScrollOffset[e.Player])
                    journalScrollOffset[e.Player] = journalSelectedIndex[e.Player];
                PlayObjectiveSound("switches/normbutn");
            }
        }

        // Journal cursor: move down
        else if (e.Name ~== "journal_cursor_down")
        {
            if (journalSelectedIndex[e.Player] < journalObjectiveCount[e.Player] - 1)
            {
                journalSelectedIndex[e.Player]++;
                // Auto-scroll down if cursor goes past visible range (estimate ~8 visible)
                if (journalSelectedIndex[e.Player] >= journalScrollOffset[e.Player] + 8)
                    journalScrollOffset[e.Player] = journalSelectedIndex[e.Player] - 7;
                PlayObjectiveSound("switches/normbutn");
            }
        }

        // Journal: toggle tracking on selected objective
        else if (e.Name ~== "journal_toggle_track")
        {
            let handler = VUOS_ObjectiveHandler.GetSetupHandler();
            if (handler)
            {
                let obj = GetJournalObjectiveByIndex(handler, journalSelectedIndex[e.Player]);
                if (obj && !obj.isCompleted && !obj.hasFailed)
                {
                    obj.isTracked = !obj.isTracked;
                    if (VUOS_ObjectiveHandler.IsDebugEnabled()) Console.Printf("DEBUG [Renderer]: Player %d %s objective '%s'", e.Player, obj.isTracked ? "tracked" : "untracked", obj.objectiveDescription);
                    VUOS_ObjectiveHandler.MarkMarkersDirty();
                    PlayObjectiveSound("switches/normbutn");
                }
            }
        }

        // Journal: track all visible objectives on current map
        else if (e.Name ~== "journal_track_all")
        {
            let handler = VUOS_ObjectiveHandler.GetSetupHandler();
            if (handler)
            {
                int skill = G_SkillPropertyInt(SKILLP_ACSReturn);
                for (int i = 0; i < handler.objectives.Size(); i++)
                {
                    let obj = handler.objectives[i];
                    if (obj.IsVisibleForCurrentMap(skill))
                        obj.isTracked = true;
                }
                if (VUOS_ObjectiveHandler.IsDebugEnabled()) Console.Printf("DEBUG [Renderer]: Player %d tracked all objectives", e.Player);
                VUOS_ObjectiveHandler.MarkMarkersDirty();
                PlayObjectiveSound("switches/normbutn");
            }
        }

        // Journal: untrack all visible objectives on current map
        else if (e.Name ~== "journal_untrack_all")
        {
            let handler = VUOS_ObjectiveHandler.GetSetupHandler();
            if (handler)
            {
                int skill = G_SkillPropertyInt(SKILLP_ACSReturn);
                for (int i = 0; i < handler.objectives.Size(); i++)
                {
                    let obj = handler.objectives[i];
                    if (obj.IsVisibleForCurrentMap(skill))
                        obj.isTracked = false;
                }
                if (VUOS_ObjectiveHandler.IsDebugEnabled()) Console.Printf("DEBUG [Renderer]: Player %d untracked all objectives", e.Player);
                VUOS_ObjectiveHandler.MarkMarkersDirty();
                PlayObjectiveSound("switches/normbutn");
            }
        }
    }

    // Helper: get the Nth visible objective in journal order (primary first, then secondary)
    VUOS_ObjectiveData GetJournalObjectiveByIndex(VUOS_ObjectiveHandler handler, int index, int skill = -1)
    {
        int flatIndex = 0;
        if (skill < 0) skill = G_SkillPropertyInt(SKILLP_ACSReturn);
        for (int i = 0; i < handler.objectives.Size(); i++)
        {
            let obj = handler.objectives[i];
            if (obj.IsVisibleForCurrentMap(skill) && obj.isPrimary)
            {
                if (flatIndex == index) return obj;
                flatIndex++;
            }
        }
        for (int i = 0; i < handler.objectives.Size(); i++)
        {
            let obj = handler.objectives[i];
            if (obj.IsVisibleForCurrentMap(skill) && !obj.isPrimary)
            {
                if (flatIndex == index) return obj;
                flatIndex++;
            }
        }
        return null;
    }

    // Intercept keyboard input when journal is open
    override bool InputProcess(InputEvent e)
    {
        // Only intercept when journal is open
        if (!VUOS_ObjectiveHandler.GetCVarBool('obj_show', players[consoleplayer])) return false;

        // Only handle key-down events
        if (e.Type != InputEvent.Type_KeyDown) return false;

        // Up arrow: cursor up
        if (e.KeyScan == InputEvent.Key_UpArrow)
        {
            EventHandler.SendNetworkEvent("journal_cursor_up");
            return true; // Consume input
        }

        // Down arrow: cursor down
        if (e.KeyScan == InputEvent.Key_DownArrow)
        {
            EventHandler.SendNetworkEvent("journal_cursor_down");
            return true;
        }

        // Enter: toggle tracking
        if (e.KeyScan == InputEvent.Key_Enter)
        {
            EventHandler.SendNetworkEvent("journal_toggle_track");
            return true;
        }

        // T: track all (ASCII 116 = 't', 84 = 'T')
        if (e.KeyChar == 116 || e.KeyChar == 84)
        {
            EventHandler.SendNetworkEvent("journal_track_all");
            return true;
        }

        // U: untrack all (ASCII 117 = 'u', 85 = 'U')
        if (e.KeyChar == 117 || e.KeyChar == 85)
        {
            EventHandler.SendNetworkEvent("journal_untrack_all");
            return true;
        }

        return false; // Let other keys pass through
    }

    // Update timers and monitor pickups for dimming
    override void WorldTick()
    {
        // Cache handler reference for performance — avoids EventHandler.Find() lookup every render frame
        cachedSetupHandler = VUOS_ObjectiveHandler.GetSetupHandler();

        // Update journal objective count for cursor clamping (per-player)
        let jHandler = cachedSetupHandler;
        if (jHandler)
        {
            int count = 0;
            int skill = G_SkillPropertyInt(SKILLP_ACSReturn);
            for (int i = 0; i < jHandler.objectives.Size(); i++)
            {
                if (jHandler.objectives[i].IsVisibleForCurrentMap(skill))
                    count++;
            }
            for (int p = 0; p < MAXPLAYERS; p++)
            {
                journalObjectiveCount[p] = count;
                if (journalSelectedIndex[p] >= count)
                    journalSelectedIndex[p] = max(0, count - 1);
            }
        }

        // Update completion message timer
        if (completionTimer > 0)
        {
            completionTimer--;
            // When current message finishes, pop next from queue
            if (completionTimer == 0 && completionQueue.Size() > 0)
            {
                completionMessage = completionQueue[0];
                completionQueue.Delete(0);
                completionTimer = GetNotificationDuration();
            }
        }

        // Update failure message timer
        if (failureTimer > 0)
        {
            failureTimer--;
            // When current message finishes, pop next from queue
            if (failureTimer == 0 && failureQueue.Size() > 0)
            {
                failureMessage = failureQueue[0];
                failureQueue.Delete(0);
                failureTimer = GetNotificationDuration();
            }
        }

        // Update required objectives message timer
        if (requiredTimer > 0)
        {
            requiredTimer--;
        }

        // Update objective completion fade timers
        if (cachedSetupHandler)
        {
            for (int i = 0; i < cachedSetupHandler.objectives.Size(); i++)
            {
                let obj = cachedSetupHandler.objectives[i];
                if (obj && obj.timer > 0)
                {
                    obj.timer--;
                }
            }
        }

        // Pickup monitoring for dimming objectives
        int currentTime = level.maptime;

        // Check if pickup fade is enabled
        PlayerInfo fp = VUOS_ObjectiveHandler.GetFirstPlayer();
        bool fadeEnabled = VUOS_ObjectiveHandler.GetCVarBool('obj_pickup_fade', fp, true);

        if (!fadeEnabled)
        {
            // Fade disabled - keep at max opacity
            objectiveAlpha = FADE_MAX;
            pickupTimes.Clear();
            lastBonusCount = 0;
        }
        else
        {
        // Check LOCAL player for new pickups (each client dims its own HUD independently)
        int currentBonusCount = players[consoleplayer].bonuscount;

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
            if (objectiveAlpha > FADE_MIN)
            {
                objectiveAlpha -= FADE_SPEED;
                if (objectiveAlpha < FADE_MIN)
                {
                    objectiveAlpha = FADE_MIN;
                }
            }
        }
        else
        {
            // 0 or 1 message visible - fade back up
            if (objectiveAlpha < FADE_MAX)
            {
                objectiveAlpha += FADE_SPEED;
                if (objectiveAlpha > FADE_MAX)
                {
                    objectiveAlpha = FADE_MAX;
                }
            }
        }
        } // end fadeEnabled
    }

    // UI scope: all consoleplayer usage throughout this method and its callees is correct —
    // RenderOverlay runs per-client, so consoleplayer always refers to the local player.
    override void RenderOverlay(RenderEvent e)
    {
        // When automap is active, only draw the legend overlay (skip normal HUD/compass/waypoints)
        if (automapactive)
        {
            let amHandler = cachedSetupHandler;
            if (amHandler)
            {
                // Use StatusBar.GetHUDScale() for resolution-aware virtual dimensions
                int amVirtualW = DEFAULT_VIRTUAL_W;
                int amVirtualH = DEFAULT_VIRTUAL_H;
                if (StatusBar)
                {
                    Vector2 hudScale = StatusBar.GetHUDScale();
                    if (hudScale.X > 0 && hudScale.Y > 0)
                    {
                        amVirtualW = int(Screen.GetWidth() / hudScale.X);
                        amVirtualH = int(Screen.GetHeight() / hudScale.Y);
                    }
                }

                VUOS_ObjectiveAutomapOverlay.DrawAutomapLegend(
                    amHandler.objectives, amVirtualW, amVirtualH);
            }
            return;
        }

        if (screenblocks > 11)
        {
            return;
        }

        PlayerInfo player = players[consoleplayer];
        if (!player || !player.mo)
            return;

        // Use cached handler reference (set in WorldTick to avoid per-frame EventHandler.Find lookup)
        let handler = cachedSetupHandler;
        if (!handler)
            return;

        // Get both CVars
        bool showScreen = VUOS_ObjectiveHandler.GetCVarBool('obj_show', players[consoleplayer]);
        bool showHUD = VUOS_ObjectiveHandler.GetCVarBool('obj_hud_show', players[consoleplayer], true); // HUD defaults to ON

        // Use StatusBar.GetHUDScale() for resolution-aware virtual dimensions
        // This derives the virtual resolution from actual screen dimensions,
        // preventing text/graphic stretching on non-4:3 displays
        int virtualWidth = DEFAULT_VIRTUAL_W;
        int virtualHeight = DEFAULT_VIRTUAL_H;
        if (StatusBar)
        {
            Vector2 hudScale = StatusBar.GetHUDScale();
            if (hudScale.X > 0 && hudScale.Y > 0)
            {
                virtualWidth = int(Screen.GetWidth() / hudScale.X);
                virtualHeight = int(Screen.GetHeight() / hudScale.Y);
            }
        }

        // Refresh cached rendering CVars in-place (no per-frame allocation)
        cachedRenderSettings.Refresh();
        let rs = cachedRenderSettings;

        // Compass always draws independently based on its own CVar (obj_compass_show)
        int compassHeight = VUOS_ObjectiveCompass.DrawCompass(
            handler.objectives, virtualWidth, virtualHeight, objectiveAlpha,
            e.ViewAngle, e.ViewPitch, e.ViewPos, rs);

        // Draw 3D waypoint indicators FIRST so objectives render on top
        // 0 = always on, 1 = always off, 2 = toggle with objectives HUD (O key)
        int wpMode = VUOS_ObjectiveHandler.GetCVarInt('obj_waypoint_mode', players[consoleplayer], 2);

        bool drawWaypoints = false;
        if (wpMode == 0) drawWaypoints = true;
        else if (wpMode == 2) drawWaypoints = showHUD;

        if (drawWaypoints)
        {
            VUOS_ObjectiveWaypoints.DrawWaypoints(
                handler.objectives, virtualWidth, virtualHeight, objectiveAlpha,
                e.ViewAngle, e.ViewPitch, e.ViewRoll, e.ViewPos, rs);
        }

        // PRIORITY: Full Screen mode takes precedence over HUD mode
        // Drawn after waypoints so objectives appear on top
        if (showScreen)
        {
            RenderFullScreen(handler.objectives, virtualWidth, virtualHeight, compassHeight);
        }
        else if (showHUD)
        {
            RenderHUD(handler.objectives, virtualWidth, virtualHeight, compassHeight);
        }

        // Draw center screen notifications if enabled
        // Notifications stack vertically from a shared start position to avoid overlap
        bool showCenter = VUOS_ObjectiveHandler.GetCVarBool('obj_center_notifications', players[consoleplayer], true);

        if (showCenter)
        {
            int notifyY = virtualHeight / 2 - NOTIFY_REQUIRED_Y;

            // Draw completion message (always on top, regardless of screen/HUD mode)
            if (completionTimer > 0)
            {
                notifyY += RenderCompletionMessage(virtualWidth, virtualHeight, notifyY);
            }

            // Draw failure message (always on top)
            if (failureTimer > 0)
            {
                notifyY += RenderFailureMessage(virtualWidth, virtualHeight, notifyY);
            }

            // Draw required objectives blocking message
            if (requiredTimer > 0)
            {
                RenderRequiredMessage(virtualWidth, virtualHeight, notifyY);
            }
        }
    }

    // Render completion message in center of screen with fade
    // Returns the total height consumed for stacking with other notifications
    ui int RenderCompletionMessage(int virtualWidth, int virtualHeight, int startY)
    {
        Font fnt = SmallFont;

        // Calculate fade alpha (fade-in first third, hold middle, fade-out last third)
        int duration = GetNotificationDuration();
        double alpha = CalcNotificationFadeAlpha(completionTimer, duration);

        int lineH = fnt.GetHeight();
        double y = startY;

        // Draw "OBJECTIVE COMPLETE" header
        String header = "OBJECTIVE COMPLETE";
        int headerWidth = fnt.StringWidth(header);
        double headerX = (virtualWidth - headerWidth) / 2;

        screen.DrawText(fnt, GetColorCVar('obj_color_complete_notify', Font.CR_GOLD), headerX, y, header,
            DTA_VirtualWidth, virtualWidth,
            DTA_VirtualHeight, virtualHeight,
            DTA_KeepRatio, true,
            DTA_Alpha, alpha);

        // Draw objective description below
        int textWidth = fnt.StringWidth(completionMessage);
        double x = (virtualWidth - textWidth) / 2;
        screen.DrawText(fnt, Font.CR_WHITE, x, y + lineH + NOTIFY_TEXT_GAP, completionMessage,
            DTA_VirtualWidth, virtualWidth,
            DTA_VirtualHeight, virtualHeight,
            DTA_KeepRatio, true,
            DTA_Alpha, alpha);

        return (lineH + NOTIFY_TEXT_GAP) * 2; // header + gap + description + gap
    }

    // Render failure message in center of screen with fade
    // Returns the total height consumed for stacking with other notifications
    ui int RenderFailureMessage(int virtualWidth, int virtualHeight, int startY)
    {
        Font fnt = SmallFont;

        // Calculate fade alpha (fade-in first third, hold middle, fade-out last third)
        int duration = GetNotificationDuration();
        double alpha = CalcNotificationFadeAlpha(failureTimer, duration);

        int lineH = fnt.GetHeight();
        double y = startY;

        // Draw "OBJECTIVE FAILED" header
        String header = "OBJECTIVE FAILED";
        int headerWidth = fnt.StringWidth(header);
        int headerX = (virtualWidth / 2) - (headerWidth / 2);

        screen.DrawText(fnt, GetColorCVar('obj_color_fail_notify', Font.CR_RED), headerX, y, header,
            DTA_VirtualWidth, virtualWidth,
            DTA_VirtualHeight, virtualHeight,
            DTA_KeepRatio, true,
            DTA_Alpha, alpha);

        // Draw the objective description below
        int textWidth = fnt.StringWidth(failureMessage);
        int x = (virtualWidth - textWidth) / 2;
        screen.DrawText(fnt, Font.CR_WHITE, x, y + lineH + NOTIFY_TEXT_GAP, failureMessage,
            DTA_VirtualWidth, virtualWidth,
            DTA_VirtualHeight, virtualHeight,
            DTA_KeepRatio, true,
            DTA_Alpha, alpha);

        return (lineH + NOTIFY_TEXT_GAP) * 2;
    }

    // Render required objectives message in center of screen with fade
    // Returns the total height consumed for stacking with other notifications
    ui int RenderRequiredMessage(int virtualWidth, int virtualHeight, int startY)
    {
        Font fnt = SmallFont;

        // Calculate fade alpha (fade-in first third, hold middle, fade-out last third)
        int duration = GetNotificationDuration();
        double alpha = CalcNotificationFadeAlpha(requiredTimer, duration);

        // Center position
        int textWidth = fnt.StringWidth(requiredMessage);
        double x = (virtualWidth - textWidth) / 2;

        screen.DrawText(fnt, GetColorCVar('obj_color_fail_notify', Font.CR_RED), x, startY, requiredMessage,
            DTA_VirtualWidth, virtualWidth,
            DTA_VirtualHeight, virtualHeight,
            DTA_KeepRatio, true,
            DTA_Alpha, alpha);

        return fnt.GetHeight() + NOTIFY_TEXT_GAP; // single line + gap
    }

    // Render Full Objectives Screen (with background, 2-column, shows all objectives)
    ui void RenderFullScreen(Array<VUOS_ObjectiveData> objectives, int virtualWidth, int virtualHeight, int compassHeight = 0)
    {
        // Read journal offset CVars (applied to both background and text)
        int journalOffX = VUOS_ObjectiveHandler.GetCVarInt('obj_journal_offset_x', players[consoleplayer]);
        int journalOffY = VUOS_ObjectiveHandler.GetCVarInt('obj_journal_offset_y', players[consoleplayer]);

        // Check distance display CVAR
        bool showDistance = VUOS_ObjectiveHandler.GetCVarBool('obj_show_distance', players[consoleplayer], true);

        // Journal scale CVar (0.5-1.5, default 0.75)
        // Scales by adjusting virtual dimensions: larger scale = smaller virtual space = bigger elements
        // This scales BOTH text and background uniformly (same approach as HUD scale)
        double jScale = VUOS_ObjectiveHandler.GetCVarFloat('obj_journal_scale', players[consoleplayer], 0.75);
        if (jScale < 0.5) jScale = 0.5;
        if (jScale > 1.5) jScale = 1.5;

        // Apply scale to virtual dimensions (divide = elements appear larger)
        virtualWidth = int(virtualWidth / jScale);
        virtualHeight = int(virtualHeight / jScale);
        compassHeight = int(compassHeight / jScale);

        // Draw background graphic
        if (objBackground.IsValid())
        {
            Vector2 texsize = TexMan.GetScaledSize(objBackground);
            double bgX = JOURNAL_BG_X + journalOffX;
            double bgY = JOURNAL_BG_Y + journalOffY + compassHeight;
            double targetSize = JOURNAL_BG_SIZE;

            // Calculate dimensions maintaining source aspect ratio
            double aspectRatio = texsize.X / texsize.Y;
            int destWidth = int(targetSize);
            int destHeight = int(targetSize / aspectRatio);

            // Draw with calculated dimensions to maintain aspect ratio
            screen.DrawTexture(objBackground, false, bgX, bgY,
                DTA_VirtualWidth, virtualWidth,
                DTA_VirtualHeight, virtualHeight,
                DTA_KeepRatio, true,
                DTA_DestWidth, destWidth,
                DTA_DestHeight, destHeight,
                DTA_Alpha, 0.9); // Fixed alpha - no dimming on full screen
        }

        Font fnt = SmallFont;
        int lineHeight = fnt.GetHeight() + 2;
        int objectiveSpacing = JOURNAL_OBJ_SPACING;

        // Position text inside the monitor's green screen area
        // Virtual dimension scaling handles uniform sizing of text and background
        double bgX = JOURNAL_BG_X + journalOffX;
        double x = bgX + JOURNAL_TEXT_X;
        double y = (JOURNAL_BG_Y + journalOffY + compassHeight) + JOURNAL_TEXT_Y;

        // Two-column layout with reduced widths for square monitor
        // maxDescWidth accounts for tracking indicator prefix ("* " or "  ")
        int maxDescWidth = JOURNAL_DESC_WIDTH;
        double counterX = bgX + JOURNAL_COUNTER_X;

        // Separate objectives into primary and secondary
        Array<VUOS_ObjectiveData> primaryObjs;
        Array<VUOS_ObjectiveData> secondaryObjs;
        int visibleCount = SeparateObjectives(objectives, primaryObjs, secondaryObjs);

        // Check if we have any visible objectives
        if (visibleCount == 0)
        {
            screen.DrawText(fnt, Font.CR_GRAY, x, y, "No objectives",
                DTA_VirtualWidth, virtualWidth,
                DTA_VirtualHeight, virtualHeight,
                DTA_KeepRatio, true,
                DTA_Alpha, 0.8); // Fixed alpha - no dimming
            return;
        }

        // Build a flat list of all objectives in display order (primary first, then secondary)
        Array<VUOS_ObjectiveData> flatObjs;
        for (int i = 0; i < primaryObjs.Size(); i++) flatObjs.Push(primaryObjs[i]);
        for (int i = 0; i < secondaryObjs.Size(); i++) flatObjs.Push(secondaryObjs[i]);

        // Calculate the maximum Y for content area (leave room for hint line + bottom border)
        double bgYStart = JOURNAL_BG_Y + journalOffY + compassHeight;
        double maxY = bgYStart + JOURNAL_BG_SIZE - JOURNAL_CONTENT_BOTTOM;

        // Determine which section the scroll offset falls in
        int scrollOff = journalScrollOffset[consoleplayer];
        if (scrollOff < 0) scrollOff = 0;
        if (scrollOff >= flatObjs.Size()) scrollOff = max(0, flatObjs.Size() - 1);

        // Show scroll-up indicator if scrolled down
        bool hasMoreAbove = (scrollOff > 0);
        bool hasMoreBelow = false;

        if (hasMoreAbove)
        {
            screen.DrawText(fnt, Font.CR_GOLD, counterX, y - 2, "...",
                DTA_VirtualWidth, virtualWidth,
                DTA_VirtualHeight, virtualHeight,
                DTA_KeepRatio, true,
                DTA_Alpha, 0.7);
        }

        // Determine if we need to draw a section header before the first visible item
        bool inPrimary = (scrollOff < primaryObjs.Size());
        if (inPrimary && primaryObjs.Size() > 0)
        {
            screen.DrawText(fnt, GetColorCVar('obj_color_primary_header', Font.CR_GREEN), x, y, "PRIMARY OBJECTIVES",
                DTA_VirtualWidth, virtualWidth,
                DTA_VirtualHeight, virtualHeight,
                DTA_KeepRatio, true,
                DTA_Alpha, 0.8);
            y += lineHeight + 4;
        }
        else if (!inPrimary && secondaryObjs.Size() > 0)
        {
            screen.DrawText(fnt, GetColorCVar('obj_color_secondary_header', Font.CR_CYAN), x, y, "SECONDARY OBJECTIVES",
                DTA_VirtualWidth, virtualWidth,
                DTA_VirtualHeight, virtualHeight,
                DTA_KeepRatio, true,
                DTA_Alpha, 0.8);
            y += lineHeight + 4;
        }

        // Draw objectives starting from scroll offset
        bool drewSecondaryHeader = !inPrimary; // Already drawn if we started in secondary
        for (int i = scrollOff; i < flatObjs.Size(); i++)
        {
            // Check if we need to draw the secondary header at the transition point
            if (!drewSecondaryHeader && i >= primaryObjs.Size() && secondaryObjs.Size() > 0)
            {
                if (primaryObjs.Size() > 0) y += JOURNAL_SECTION_GAP;

                // Check if header fits
                if (y + lineHeight + 4 > maxY) { hasMoreBelow = true; break; }

                screen.DrawText(fnt, GetColorCVar('obj_color_secondary_header', Font.CR_CYAN), x, y, "SECONDARY OBJECTIVES",
                    DTA_VirtualWidth, virtualWidth,
                    DTA_VirtualHeight, virtualHeight,
                    DTA_KeepRatio, true,
                    DTA_Alpha, 0.8);
                y += lineHeight + 4;
                drewSecondaryHeader = true;
            }

            // Check if this entry would overflow the visible area
            if (y + lineHeight > maxY)
            {
                hasMoreBelow = true;
                break;
            }

            y = DrawFullScreenEntry(fnt, flatObjs[i], x, y, maxDescWidth, counterX,
                lineHeight, 0.8, virtualWidth, virtualHeight, showDistance,
                i == journalSelectedIndex[consoleplayer]);
            y += objectiveSpacing;
        }

        // Show scroll-down indicator if more objectives below
        if (hasMoreBelow)
        {
            screen.DrawText(fnt, Font.CR_GOLD, counterX, maxY - lineHeight + 2, "...",
                DTA_VirtualWidth, virtualWidth,
                DTA_VirtualHeight, virtualHeight,
                DTA_KeepRatio, true,
                DTA_Alpha, 0.7);
        }

        // Draw hint line at fixed position near bottom of background
        double hintY = bgYStart + JOURNAL_BG_SIZE - JOURNAL_HINT_BOTTOM;
        String hint = "UP/DN: Select  ENTER: Track  T: All  U: None";
        screen.DrawText(fnt, Font.CR_WHITE, x - 7, hintY, hint,
            DTA_VirtualWidth, virtualWidth,
            DTA_VirtualHeight, virtualHeight,
            DTA_KeepRatio, true,
            DTA_Alpha, 0.6,
            DTA_ScaleX, 0.75,
            DTA_ScaleY, 0.75);
    }

    // Render Simple HUD Objectives (no background, single column, shows incomplete + fading completed/failed)
    ui void RenderHUD(Array<VUOS_ObjectiveData> objectives, int virtualWidth, int virtualHeight, int compassHeight = 0)
    {
        // HUD scale CVar (0.5-2.0, default 0.75)
        // Scales by adjusting virtual dimensions: larger scale = smaller virtual space = bigger elements
        double hScale = VUOS_ObjectiveHandler.GetCVarFloat('obj_hud_scale', players[consoleplayer], 0.75);
        if (hScale < 0.5) hScale = 0.5;
        if (hScale > 2.0) hScale = 2.0;

        // Apply scale to virtual dimensions (divide = elements appear larger)
        virtualWidth = int(virtualWidth / hScale);
        virtualHeight = int(virtualHeight / hScale);
        compassHeight = int(compassHeight / hScale);

        Font fnt = SmallFont;
        int lineHeight = fnt.GetHeight() + 2;

        // Check distance display CVAR
        bool showDistance = VUOS_ObjectiveHandler.GetCVarBool('obj_show_distance', players[consoleplayer], true);

        // Check if untracked objectives should be shown on HUD
        bool showUntracked = VUOS_ObjectiveHandler.GetCVarBool('obj_hud_show_untracked', players[consoleplayer]);

        // Separate objectives into primary and secondary (with HUD-specific filters)
        Array<VUOS_ObjectiveData> primaryObjs;
        Array<VUOS_ObjectiveData> secondaryObjs;
        int visibleCount = SeparateObjectives(objectives, primaryObjs, secondaryObjs, true, showUntracked);

        // If no visible objectives, don't draw anything
        if (visibleCount == 0) return;

        // Get HUD position CVAR (0=top-left, 1=top-right, 2=bottom-left, 3=bottom-right)
        int hudPosition = VUOS_ObjectiveHandler.GetCVarInt('obj_hud_position', players[consoleplayer]);

        // Define max width for right-aligned positions to prevent text overflow
        int maxDescWidth = HUD_MAX_DESC_WIDTH;
        bool needsWrapping = (hudPosition == 1 || hudPosition == 3); // top-right or bottom-right

        // Calculate total height and max width needed for positioning
        int totalHeight = 0;
        int maxWidth = 0;

        // Measure primary section
        if (primaryObjs.Size() > 0)
        {
            totalHeight += lineHeight + 3; // Header

            int headerWidth = fnt.StringWidth("PRIMARY OBJECTIVES");
            if (headerWidth > maxWidth) maxWidth = headerWidth;

            for (int i = 0; i < primaryObjs.Size(); i++)
            {
                totalHeight += MeasureHUDEntry(fnt, primaryObjs[i], maxDescWidth, lineHeight, needsWrapping, showDistance);
                int entryWidth = MeasureHUDEntryWidth(fnt, primaryObjs[i], maxDescWidth, needsWrapping, showDistance);
                if (entryWidth > maxWidth) maxWidth = entryWidth;
            }
        }

        // Measure secondary section
        if (secondaryObjs.Size() > 0)
        {
            if (primaryObjs.Size() > 0) totalHeight += 5; // Spacing between sections
            totalHeight += lineHeight + 3; // Header

            int headerWidth = fnt.StringWidth("SECONDARY OBJECTIVES");
            if (headerWidth > maxWidth) maxWidth = headerWidth;

            for (int i = 0; i < secondaryObjs.Size(); i++)
            {
                totalHeight += MeasureHUDEntry(fnt, secondaryObjs[i], maxDescWidth, lineHeight, needsWrapping, showDistance);
                int entryWidth = MeasureHUDEntryWidth(fnt, secondaryObjs[i], maxDescWidth, needsWrapping, showDistance);
                if (entryWidth > maxWidth) maxWidth = entryWidth;
            }
        }

        // Calculate starting position based on HUD position CVAR
        // With GetHUDScale(), x=0 is left screen edge, virtualWidth is right edge
        double x, y;
        switch (hudPosition)
        {
            case 1: // Top-right
                x = virtualWidth - maxWidth + HUD_RIGHT_NUDGE;
                y = HUD_MARGIN_Y + compassHeight;
                break;
            case 2: // Bottom-left
                x = HUD_MARGIN_X;
                y = virtualHeight - totalHeight - HUD_BOTTOM_MARGIN;
                break;
            case 3: // Bottom-right
                x = virtualWidth - maxWidth + HUD_RIGHT_NUDGE;
                y = virtualHeight - totalHeight - HUD_BOTTOM_MARGIN;
                break;
            default: // Top-left (0) - original default position
                x = HUD_MARGIN_X;
                y = HUD_MARGIN_Y + compassHeight;
                break;
        }

        // Apply manual offset CVars
        x += VUOS_ObjectiveHandler.GetCVarInt('obj_hud_offset_x', players[consoleplayer]);
        y += VUOS_ObjectiveHandler.GetCVarInt('obj_hud_offset_y', players[consoleplayer]);

        // Draw primary objectives
        if (primaryObjs.Size() > 0)
        {
            screen.DrawText(fnt, GetColorCVar('obj_color_primary_header', Font.CR_GREEN), x, y, "PRIMARY OBJECTIVES",
                DTA_VirtualWidth, virtualWidth,
                DTA_VirtualHeight, virtualHeight,
                DTA_KeepRatio, true,
                DTA_Alpha, objectiveAlpha);

            y += lineHeight + 3;

            for (int i = 0; i < primaryObjs.Size(); i++)
            {
                y = DrawHUDEntry(fnt, primaryObjs[i], x, y, maxDescWidth, lineHeight,
                    objectiveAlpha, needsWrapping, virtualWidth, virtualHeight, showDistance);
            }
        }

        // Draw secondary objectives
        if (secondaryObjs.Size() > 0)
        {
            if (primaryObjs.Size() > 0)
                y += 5;

            screen.DrawText(fnt, GetColorCVar('obj_color_secondary_header', Font.CR_CYAN), x, y, "SECONDARY OBJECTIVES",
                DTA_VirtualWidth, virtualWidth,
                DTA_VirtualHeight, virtualHeight,
                DTA_KeepRatio, true,
                DTA_Alpha, objectiveAlpha);

            y += lineHeight + 3;

            for (int i = 0; i < secondaryObjs.Size(); i++)
            {
                y = DrawHUDEntry(fnt, secondaryObjs[i], x, y, maxDescWidth, lineHeight,
                    objectiveAlpha, needsWrapping, virtualWidth, virtualHeight, showDistance);
            }
        }
    }
}