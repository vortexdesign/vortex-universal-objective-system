// ObjectiveAutomapOverlay.zs
// Draws an objective legend overlay when the automap is active.
// Adapts to marker style: shows numbered entries when numbered markers
// are enabled, plain color-coded entries when X markers are used.

class VUOS_ObjectiveAutomapOverlay ui
{
    // ================================================================
    // LEGEND LAYOUT CONSTANTS
    // ================================================================

    const LEGEND_MARGIN_X    = 12;    // Right margin from screen edge
    const LEGEND_MARGIN_Y    = 12;    // Top margin from screen edge
    const LEGEND_PADDING_X   = 8;     // Horizontal padding inside background
    const LEGEND_PADDING_Y   = 6;     // Vertical padding inside background
    const LEGEND_LINE_GAP    = 2;     // Extra gap between lines
    const LEGEND_SECTION_GAP = 6;     // Gap between primary and secondary sections
    const LEGEND_BG_ALPHA    = 0.55;  // Background box opacity
    const LEGEND_TEXT_ALPHA   = 0.9;  // Text opacity
    const LEGEND_MAX_DESC    = 200;   // Max description width before truncation

    // Background color (dark translucent)
    const BG_R = 0;
    const BG_G = 0;
    const BG_B = 0;

    // ================================================================
    // MAIN DRAW METHOD — called from ObjectiveRenderer.RenderOverlay
    // ================================================================

    // Draws the automap legend overlay.
    // Returns the height consumed (for potential future use).
    static int DrawAutomapLegend(
        Array<VUOS_ObjectiveData> objectives,
        int virtualWidth, int virtualHeight)
    {
        // Check if legend is enabled
        if (!VUOS_ObjectiveHandler.GetCVarBool('obj_automap_legend', players[consoleplayer], true)) return 0;

        // Legend scale CVar (0.5-2.0, default 0.95)
        // Scales by adjusting virtual dimensions: larger scale = smaller virtual space = bigger elements
        double legendScale = VUOS_ObjectiveHandler.GetCVarFloat('obj_automap_legend_scale', players[consoleplayer], 0.95);
        if (legendScale < 0.5) legendScale = 0.5;
        if (legendScale > 2.0) legendScale = 2.0;
        virtualWidth = int(virtualWidth / legendScale);
        virtualHeight = int(virtualHeight / legendScale);

        // Check marker style (0 = X, 1 = numbered)
        int markerStyle = VUOS_ObjectiveHandler.GetCVarInt('obj_automap_marker_style', players[consoleplayer]);

        // Get header colors from CVars
        int primaryColorIdx = VUOS_ObjectiveHandler.GetCVarInt('obj_color_primary_header', players[consoleplayer], 3); // CR_GREEN
        int secondaryColorIdx = VUOS_ObjectiveHandler.GetCVarInt('obj_color_secondary_header', players[consoleplayer], 21); // CR_CYAN

        // Separate objectives into primary and secondary (current map, visible, valid skill)
        Array<VUOS_ObjectiveData> primaryObjs;
        Array<VUOS_ObjectiveData> secondaryObjs;
        int visibleCount = VUOS_ObjectiveRenderer.SeparateObjectives(
            objectives, primaryObjs, secondaryObjs);

        // Only show active (incomplete, non-failed) objectives with waypoints in the legend
        // since only those have markers on the automap
        Array<VUOS_ObjectiveData> activePrimary;
        Array<VUOS_ObjectiveData> activeSecondary;
        for (int i = 0; i < primaryObjs.Size(); i++)
        {
            let obj = primaryObjs[i];
            if (!obj.isCompleted && !obj.hasFailed && obj.hasWaypoint)
                activePrimary.Push(obj);
        }
        for (int i = 0; i < secondaryObjs.Size(); i++)
        {
            let obj = secondaryObjs[i];
            if (!obj.isCompleted && !obj.hasFailed && obj.hasWaypoint)
                activeSecondary.Push(obj);
        }

        // Collect completed/failed objectives with waypoints (if CVar enabled)
        bool showCompleted = VUOS_ObjectiveHandler.GetCVarBool('obj_automap_show_completed', players[consoleplayer], true);
        Array<VUOS_ObjectiveData> completedObjs;
        Array<VUOS_ObjectiveData> failedObjs;
        if (showCompleted)
        {
            // Completed/failed can come from either primary or secondary pools
            for (int i = 0; i < primaryObjs.Size(); i++)
            {
                let obj = primaryObjs[i];
                if (obj.hasWaypoint)
                {
                    if (obj.isCompleted) completedObjs.Push(obj);
                    else if (obj.hasFailed) failedObjs.Push(obj);
                }
            }
            for (int i = 0; i < secondaryObjs.Size(); i++)
            {
                let obj = secondaryObjs[i];
                if (obj.hasWaypoint)
                {
                    if (obj.isCompleted) completedObjs.Push(obj);
                    else if (obj.hasFailed) failedObjs.Push(obj);
                }
            }
        }

        int totalEntries = activePrimary.Size() + activeSecondary.Size()
            + completedObjs.Size() + failedObjs.Size();
        if (totalEntries == 0) return 0;

        Font fnt = SmallFont;
        int lineHeight = fnt.GetHeight() + LEGEND_LINE_GAP;

        // Fixed-width column for tracking indicator so text always aligns
        int trackColWidth = fnt.StringWidth("* ");

        // ---- Measure pass: calculate legend box dimensions ----
        int maxTextWidth = 0;
        int totalHeight = 0;
        int numberIndex = 1; // Running number assignment

        // Measure primary section
        if (activePrimary.Size() > 0)
        {
            int headerW = fnt.StringWidth("PRIMARY");
            if (headerW > maxTextWidth) maxTextWidth = headerW;
            totalHeight += lineHeight; // Header line

            for (int i = 0; i < activePrimary.Size(); i++)
            {
                String entry = BuildEntryText(activePrimary[i], markerStyle, numberIndex);
                int entryW = trackColWidth + fnt.StringWidth(entry);
                if (entryW > LEGEND_MAX_DESC)
                    entryW = LEGEND_MAX_DESC;
                if (entryW > maxTextWidth) maxTextWidth = entryW;
                totalHeight += lineHeight;
                numberIndex++;
            }
        }

        // Measure secondary section
        if (activeSecondary.Size() > 0)
        {
            if (activePrimary.Size() > 0)
                totalHeight += LEGEND_SECTION_GAP;

            int headerW = fnt.StringWidth("SECONDARY");
            if (headerW > maxTextWidth) maxTextWidth = headerW;
            totalHeight += lineHeight; // Header line

            for (int i = 0; i < activeSecondary.Size(); i++)
            {
                String entry = BuildEntryText(activeSecondary[i], markerStyle, numberIndex);
                int entryW = trackColWidth + fnt.StringWidth(entry);
                if (entryW > LEGEND_MAX_DESC)
                    entryW = LEGEND_MAX_DESC;
                if (entryW > maxTextWidth) maxTextWidth = entryW;
                totalHeight += lineHeight;
                numberIndex++;
            }
        }

        // Measure completed section
        if (completedObjs.Size() > 0)
        {
            if (activePrimary.Size() > 0 || activeSecondary.Size() > 0)
                totalHeight += LEGEND_SECTION_GAP;

            String completedHeader = String.Format("COMPLETED (%d)", completedObjs.Size());
            int headerW = fnt.StringWidth(completedHeader);
            if (headerW > maxTextWidth) maxTextWidth = headerW;
            totalHeight += lineHeight; // Header line

            for (int i = 0; i < completedObjs.Size(); i++)
            {
                String entry = String.Format("X  %s", completedObjs[i].objectiveDescription);
                int entryW = fnt.StringWidth(entry);
                if (entryW > LEGEND_MAX_DESC)
                    entryW = LEGEND_MAX_DESC;
                if (entryW > maxTextWidth) maxTextWidth = entryW;
                totalHeight += lineHeight;
            }
        }

        // Measure failed section
        if (failedObjs.Size() > 0)
        {
            if (activePrimary.Size() > 0 || activeSecondary.Size() > 0 || completedObjs.Size() > 0)
                totalHeight += LEGEND_SECTION_GAP;

            String failedHeader = String.Format("FAILED (%d)", failedObjs.Size());
            int headerW = fnt.StringWidth(failedHeader);
            if (headerW > maxTextWidth) maxTextWidth = headerW;
            totalHeight += lineHeight; // Header line

            for (int i = 0; i < failedObjs.Size(); i++)
            {
                String entry = String.Format("X  %s", failedObjs[i].objectiveDescription);
                int entryW = fnt.StringWidth(entry);
                if (entryW > LEGEND_MAX_DESC)
                    entryW = LEGEND_MAX_DESC;
                if (entryW > maxTextWidth) maxTextWidth = entryW;
                totalHeight += lineHeight;
            }
        }

        // ---- Draw background box (top-right corner) ----
        int boxW = maxTextWidth + (LEGEND_PADDING_X * 2);
        int boxH = totalHeight + (LEGEND_PADDING_Y * 2);
        double boxX = virtualWidth - boxW - LEGEND_MARGIN_X;
        double boxY = LEGEND_MARGIN_Y;

        // Draw semi-transparent background
        Screen.Dim(Color(255, BG_R, BG_G, BG_B), LEGEND_BG_ALPHA,
            int(boxX * Screen.GetWidth() / virtualWidth),
            int(boxY * Screen.GetHeight() / virtualHeight),
            int(boxW * Screen.GetWidth() / virtualWidth),
            int(boxH * Screen.GetHeight() / virtualHeight));

        // ---- Draw pass: render text entries ----
        double textX = boxX + LEGEND_PADDING_X;
        double textY = boxY + LEGEND_PADDING_Y;
        numberIndex = 1; // Reset for draw pass

        // Draw primary section
        if (activePrimary.Size() > 0)
        {
            Screen.DrawText(fnt, primaryColorIdx, textX, textY, "PRIMARY",
                DTA_VirtualWidth, virtualWidth,
                DTA_VirtualHeight, virtualHeight,
                DTA_KeepRatio, true,
                DTA_Alpha, LEGEND_TEXT_ALPHA);
            textY += lineHeight;

            for (int i = 0; i < activePrimary.Size(); i++)
            {
                DrawLegendEntry(fnt, activePrimary[i], markerStyle, numberIndex,
                    primaryColorIdx, textX, textY, trackColWidth,
                    virtualWidth, virtualHeight);
                textY += lineHeight;
                numberIndex++;
            }
        }

        // Draw secondary section
        if (activeSecondary.Size() > 0)
        {
            if (activePrimary.Size() > 0)
                textY += LEGEND_SECTION_GAP;

            Screen.DrawText(fnt, secondaryColorIdx, textX, textY, "SECONDARY",
                DTA_VirtualWidth, virtualWidth,
                DTA_VirtualHeight, virtualHeight,
                DTA_KeepRatio, true,
                DTA_Alpha, LEGEND_TEXT_ALPHA);
            textY += lineHeight;

            for (int i = 0; i < activeSecondary.Size(); i++)
            {
                DrawLegendEntry(fnt, activeSecondary[i], markerStyle, numberIndex,
                    secondaryColorIdx, textX, textY, trackColWidth,
                    virtualWidth, virtualHeight);
                textY += lineHeight;
                numberIndex++;
            }
        }

        // Draw completed section
        if (completedObjs.Size() > 0)
        {
            if (activePrimary.Size() > 0 || activeSecondary.Size() > 0)
                textY += LEGEND_SECTION_GAP;

            String completedHeader = String.Format("COMPLETED (%d)", completedObjs.Size());
            Screen.DrawText(fnt, Font.CR_YELLOW, textX, textY, completedHeader,
                DTA_VirtualWidth, virtualWidth,
                DTA_VirtualHeight, virtualHeight,
                DTA_KeepRatio, true,
                DTA_Alpha, LEGEND_TEXT_ALPHA);
            textY += lineHeight;

            for (int i = 0; i < completedObjs.Size(); i++)
            {
                String entry = String.Format("X  %s", completedObjs[i].objectiveDescription);
                while (fnt.StringWidth(entry) > LEGEND_MAX_DESC && entry.Length() > 4)
                {
                    entry = entry.Left(entry.Length() - 4) .. "...";
                }

                Screen.DrawText(fnt, Font.CR_YELLOW, textX, textY, entry,
                    DTA_VirtualWidth, virtualWidth,
                    DTA_VirtualHeight, virtualHeight,
                    DTA_KeepRatio, true,
                    DTA_Alpha, LEGEND_TEXT_ALPHA * 0.7);
                textY += lineHeight;
            }
        }

        // Draw failed section
        if (failedObjs.Size() > 0)
        {
            if (activePrimary.Size() > 0 || activeSecondary.Size() > 0 || completedObjs.Size() > 0)
                textY += LEGEND_SECTION_GAP;

            String failedHeader = String.Format("FAILED (%d)", failedObjs.Size());
            Screen.DrawText(fnt, Font.CR_RED, textX, textY, failedHeader,
                DTA_VirtualWidth, virtualWidth,
                DTA_VirtualHeight, virtualHeight,
                DTA_KeepRatio, true,
                DTA_Alpha, LEGEND_TEXT_ALPHA);
            textY += lineHeight;

            for (int i = 0; i < failedObjs.Size(); i++)
            {
                String entry = String.Format("X  %s", failedObjs[i].objectiveDescription);
                while (fnt.StringWidth(entry) > LEGEND_MAX_DESC && entry.Length() > 4)
                {
                    entry = entry.Left(entry.Length() - 4) .. "...";
                }

                Screen.DrawText(fnt, Font.CR_RED, textX, textY, entry,
                    DTA_VirtualWidth, virtualWidth,
                    DTA_VirtualHeight, virtualHeight,
                    DTA_KeepRatio, true,
                    DTA_Alpha, LEGEND_TEXT_ALPHA * 0.7);
                textY += lineHeight;
            }
        }

        return boxH;
    }

    // ================================================================
    // HELPER: Draw a single legend entry with tracking indicator
    // ================================================================

    // Draws the tracking diamond (if tracked) and the entry text.
    // Untracked entries are dimmed to half alpha, matching the journal pattern.
    static void DrawLegendEntry(
        Font fnt, VUOS_ObjectiveData obj, int markerStyle, int number,
        int colorIdx, double textX, double textY, int trackColWidth,
        int virtualWidth, int virtualHeight)
    {
        // Dim untracked entries (same pattern as journal's DrawFullScreenEntry)
        double entryAlpha = obj.isTracked ? LEGEND_TEXT_ALPHA : LEGEND_TEXT_ALPHA * 0.5;

        // Draw tracking indicator at fixed position (diamond for tracked)
        if (obj.isTracked)
        {
            Screen.DrawText(fnt, colorIdx, textX, textY, "*",
                DTA_VirtualWidth, virtualWidth,
                DTA_VirtualHeight, virtualHeight,
                DTA_KeepRatio, true,
                DTA_Alpha, entryAlpha);
        }

        // Build and truncate entry text
        String entry = BuildEntryText(obj, markerStyle, number);
        int maxEntryWidth = LEGEND_MAX_DESC - trackColWidth;
        while (fnt.StringWidth(entry) > maxEntryWidth && entry.Length() > 4)
        {
            entry = entry.Left(entry.Length() - 4) .. "...";
        }

        // Draw entry text offset by tracking column width
        // Untracked objectives use CR_DARKGRAY to match the grey automap marker
        int drawColor = obj.isTracked ? colorIdx : Font.CR_DARKGRAY;
        Screen.DrawText(fnt, drawColor, textX + trackColWidth, textY, entry,
            DTA_VirtualWidth, virtualWidth,
            DTA_VirtualHeight, virtualHeight,
            DTA_KeepRatio, true,
            DTA_Alpha, entryAlpha);
    }

    // ================================================================
    // HELPER: Build the display text for a single legend entry
    // ================================================================

    // When numbered mode: "1. Kill all Imps"
    // When X mode: "X  Kill all Imps"
    static String BuildEntryText(VUOS_ObjectiveData obj, int markerStyle, int number)
    {
        if (markerStyle == 1 && number >= 1 && number <= 9)
            return String.Format("%d. %s", number, obj.objectiveDescription);
        else
            return String.Format("X  %s", obj.objectiveDescription);
    }
}