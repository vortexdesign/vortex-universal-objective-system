// ObjectiveCompass.zs
// Horizontal compass ribbon with cardinal markers and objective pointers
// Uses Level.SphericalCoords() for portal-safe angle/distance calculations

class VUOS_ObjectiveCompass ui
{
    // ================================================================
    // COMPASS LAYOUT AND RENDERING CONSTANTS
    // ================================================================

    // Ribbon dimensions (virtual coordinate space, scaled by compassScale)
    const RIBBON_BASE_WIDTH  = 320;   // Base width of the compass ribbon
    const RIBBON_BASE_HEIGHT = 14;    // Base height of the compass ribbon bar
    const RIBBON_TOP_MARGIN  = 8;     // Distance from top of screen to ribbon

    // Opacity limits
    const OPACITY_MIN        = 0.15;  // Minimum opacity when faded
    const PICKUP_ALPHA_NORM  = 0.8;   // Pickup alpha normalization divisor
    const BG_OPACITY_MULT    = 0.7;   // Background/border opacity multiplier

    // Procedural border and tick colors (muted green-gray border)
    const BORDER_R = 100;
    const BORDER_G = 120;
    const BORDER_B = 100;
    // Major tick color
    const TICK_MAJOR_R = 160;
    const TICK_MAJOR_G = 180;
    const TICK_MAJOR_B = 160;
    // Minor tick color
    const TICK_MINOR_R = 80;
    const TICK_MINOR_G = 100;
    const TICK_MINOR_B = 80;
    // Center tick color
    const CENTER_TICK_R = 200;
    const CENTER_TICK_G = 220;
    const CENTER_TICK_B = 200;

    // Tick geometry
    const MAJOR_TICK_HEIGHT  = 3;     // Height of major cardinal tick marks (pixels, scaled)
    const MINOR_TICK_HEIGHT  = 2;     // Height of minor degree tick marks (pixels, scaled)
    const MINOR_TICK_STEP    = 15;    // Degrees between minor tick marks

    // Objective pointer constants
    const DIAMOND_BASE_SIZE  = 4;     // Base diamond size (scaled by compassScale)
    const POINTER_NUDGE_UP   = 5;     // Pixels to nudge pointer area upward
    const POINTER_GAP        = 3;     // Gap below ribbon to pointer area (scaled)
    const CLAMP_FOV_MARGIN   = 3;     // Degrees to inset clamped pointers from FOV edges

    // Logarithmic distance visualization
    const LOG_DIST_SCALE     = 0.05;  // Multiplier before log()
    const LOG_DIST_MULT      = 5;     // Multiplier and offset after log()
    const LOG_DIST_MAX       = 12;    // Maximum vertical offset from distance

    // Chevron (edge indicator) geometry
    const CHEVRON_WIDTH      = 2;     // Horizontal extent (pixels, scaled)
    const CHEVRON_HEIGHT     = 4;     // Vertical extent (pixels, scaled)
    const CHEVRON_GAP        = 3;     // Gap from diamond edge (pixels, scaled)
    const CHEVRON_ALPHA_MULT = 0.8;   // Alpha multiplier for chevrons
    const CHEVRON_TEX_WIDTH  = 8;     // Textured chevron width (pixels, scaled)
    const CHEVRON_TEX_HEIGHT = 12;    // Textured chevron height (pixels, scaled)

    // Distance text
    const DIST_TEXT_GAP      = 4;     // Gap below diamond to distance text (pixels, scaled)
    const DIST_TEXT_ALPHA    = 0.65;  // Alpha multiplier for distance text

    // Total height calculation
    const TOTAL_HEIGHT_PAD   = 25;    // Padding below ribbon for pointer+text area (scaled)

    // Draw the compass ribbon and return the total height consumed (in virtual units)
    // Called from VUOS_ObjectiveRenderer.RenderOverlay() when HUD mode is active
    static int DrawCompass(
        Array<VUOS_ObjectiveData> objectives,
        int virtualWidth,
        int virtualHeight,
        double pickupAlpha,
        double viewAngle,
        double viewPitch,
        vector3 viewPos,
        VUOS_RenderSettings rs)
    {
        // Use pre-cached settings from VUOS_RenderSettings
        if (!rs.compassShow) return 0;

        double baseOpacity = rs.compassOpacity;
        int offsetX = rs.compassOffsetX;
        int offsetY = rs.compassOffsetY;
        int compassFOV = rs.compassFOV;
        double compassScale = rs.compassScale;
        bool showDistance = rs.compassShowDistance;
        double compassTextScale = rs.compassTextScale;

        // Attempt to load textures if style == 1; fall back to procedural if missing
        bool useTextures = false;
        TextureID texRibbon, texDiamond, texTick, texChevron;
        if (rs.compassStyle == 1)
        {
            texRibbon  = TexMan.CheckForTexture("COMPRIB",  TexMan.Type_Any);
            texDiamond = TexMan.CheckForTexture("COMPDMND", TexMan.Type_Any);
            texTick    = TexMan.CheckForTexture("COMPTICK", TexMan.Type_Any);
            texChevron = TexMan.CheckForTexture("COMPCHVR", TexMan.Type_Any);
            useTextures = texRibbon.isValid(); // Ribbon is required; others optional
        }

        // Scale pickup fade into compass opacity
        double opacity = baseOpacity * (pickupAlpha / PICKUP_ALPHA_NORM);
        if (opacity > baseOpacity) opacity = baseOpacity;
        if (opacity < OPACITY_MIN) opacity = OPACITY_MIN;

        // ================================================================
        // COMPASS DIMENSIONS (in virtual coordinate space)
        // ================================================================
        int ribbonWidth = int(RIBBON_BASE_WIDTH * compassScale);
        int ribbonHeight = int(RIBBON_BASE_HEIGHT * compassScale);
        int ribbonX = (virtualWidth / 2) - (ribbonWidth / 2) + offsetX;
        int ribbonY = RIBBON_TOP_MARGIN + offsetY;
        
        // Screen coordinate conversion ratios
        double scaleX = double(Screen.GetWidth()) / virtualWidth;
        double scaleY = double(Screen.GetHeight()) / virtualHeight;
        
        // ================================================================
        // DRAW RIBBON BACKGROUND
        // ================================================================
        if (useTextures)
        {
            // Textured ribbon (includes built-in borders)
            Screen.DrawTexture(texRibbon, false,
                ribbonX * scaleX, ribbonY * scaleY,
                DTA_DestWidthF, ribbonWidth * scaleX,
                DTA_DestHeightF, ribbonHeight * scaleY,
                DTA_Alpha, opacity * BG_OPACITY_MULT);
        }
        else
        {
            Screen.Dim(Color(0, 0, 0), opacity * BG_OPACITY_MULT,
                int(ribbonX * scaleX), int(ribbonY * scaleY),
                int(ribbonWidth * scaleX), int(ribbonHeight * scaleY));

            // Thin border lines (top and bottom of ribbon)
            int borderAlpha = int(opacity * 200);
            Color borderColor = Color(BORDER_R, BORDER_G, BORDER_B);
            Screen.DrawThickLine(
                int(ribbonX * scaleX), int(ribbonY * scaleY),
                int((ribbonX + ribbonWidth) * scaleX), int(ribbonY * scaleY),
                1.0, borderColor, borderAlpha);
            Screen.DrawThickLine(
                int(ribbonX * scaleX), int((ribbonY + ribbonHeight) * scaleY),
                int((ribbonX + ribbonWidth) * scaleX), int((ribbonY + ribbonHeight) * scaleY),
                1.0, borderColor, borderAlpha);
        }

        // Center tick mark (where player is facing)
        int centerScreenX = int((ribbonX + ribbonWidth / 2) * scaleX);
        if (useTextures && texTick.isValid())
        {
            int tickW = int(4 * scaleX);
            int tickH = int(ribbonHeight * scaleY);
            Screen.DrawTexture(texTick, false,
                centerScreenX - tickW / 2, ribbonY * scaleY,
                DTA_DestWidthF, double(tickW),
                DTA_DestHeightF, double(tickH),
                DTA_Alpha, opacity);
        }
        else
        {
            Screen.DrawThickLine(
                centerScreenX, int(ribbonY * scaleY),
                centerScreenX, int((ribbonY + ribbonHeight) * scaleY),
                1.5, Color(CENTER_TICK_R, CENTER_TICK_G, CENTER_TICK_B), int(opacity * 255));
        }
        
        // ================================================================
        // DRAW CARDINAL AND INTERCARDINAL LABELS
        // ================================================================
        Font fnt = SmallFont;
        int textHeight = fnt.GetHeight();
        double halfFOV = compassFOV / 2.0;
        
        // Cardinal directions: angle, label, is-major
        // Doom angles: 0=East, 90=North, 180=West, 270=South
        // We use standard compass convention: N=90, E=0, S=270, W=180
        static const double cardinalAngles[] = { 90, 135, 0, 315, 270, 225, 180, 45 };
        static const string cardinalLabels[] = { "N", "NW", "E", "SE", "S", "SW", "W", "NE" };
        static const int cardinalMajor[] = { 1, 0, 1, 0, 1, 0, 1, 0 };
        
        for (int i = 0; i < 8; i++)
        {
            double delta = Actor.DeltaAngle(viewAngle, cardinalAngles[i]);
            
            // Skip if outside FOV
            if (abs(delta) > halfFOV) continue;
            
            // Position on ribbon: negate delta because DeltaAngle positive = CCW = left on screen
            double fraction = (-delta + halfFOV) / compassFOV;
            double labelX = ribbonX + (fraction * ribbonWidth);
            
            // Choose color: major cardinals brighter
            int labelColor = cardinalMajor[i] ? Font.CR_WHITE : Font.CR_GRAY;
            double labelAlpha = cardinalMajor[i] ? opacity : opacity * 0.7;
            
            // Center the label text in pixel space (uniform scale to avoid stretching)
            String label = cardinalLabels[i];
            int labelWidth = fnt.StringWidth(label);
            int scrW = Screen.GetWidth();
            int scrH = Screen.GetHeight();
            double textScaleVal = scaleY; // Uniform scale matching other compass text
            int scaledLabelW = int(labelWidth * textScaleVal);
            int pixelX = int(labelX * scaleX) - scaledLabelW / 2;
            
            // Centered vertically in the ribbon
            int ribbonCenterY = int((ribbonY + ribbonHeight / 2.0) * scaleY);
            int scaledTextH = int(textHeight * textScaleVal);
            int pixelY = ribbonCenterY - scaledTextH / 2;
            
            Screen.DrawText(fnt, labelColor, pixelX, pixelY, label,
                DTA_VirtualWidth, scrW,
                DTA_VirtualHeight, scrH,
                DTA_ScaleX, textScaleVal,
                DTA_ScaleY, textScaleVal,
                DTA_Alpha, labelAlpha);
            
            // Draw minor tick marks for major cardinals
            if (cardinalMajor[i])
            {
                int tickSX = int(labelX * scaleX);
                Screen.DrawThickLine(
                    tickSX, int(ribbonY * scaleY),
                    tickSX, int(ribbonY * scaleY) + int(MAJOR_TICK_HEIGHT * scaleY),
                    1.0, Color(TICK_MAJOR_R, TICK_MAJOR_G, TICK_MAJOR_B), int(labelAlpha * 180));
                Screen.DrawThickLine(
                    tickSX, int((ribbonY + ribbonHeight) * scaleY) - int(MAJOR_TICK_HEIGHT * scaleY),
                    tickSX, int((ribbonY + ribbonHeight) * scaleY),
                    1.0, Color(TICK_MAJOR_R, TICK_MAJOR_G, TICK_MAJOR_B), int(labelAlpha * 180));
            }
        }
        
        // Draw minor ticks every MINOR_TICK_STEP degrees
        for (int deg = 0; deg < 360; deg += MINOR_TICK_STEP)
        {
            // Skip cardinal/intercardinal positions (already handled above)
            if (deg % 45 == 0) continue;

            double delta = Actor.DeltaAngle(viewAngle, deg);
            if (abs(delta) > halfFOV) continue;

            double fraction = (-delta + halfFOV) / compassFOV;
            int tickSX = int((ribbonX + fraction * ribbonWidth) * scaleX);
            int tickLen = int(MINOR_TICK_HEIGHT * scaleY);

            Screen.DrawThickLine(
                tickSX, int((ribbonY + ribbonHeight) * scaleY) - tickLen,
                tickSX, int((ribbonY + ribbonHeight) * scaleY),
                1.0, Color(TICK_MINOR_R, TICK_MINOR_G, TICK_MINOR_B), int(opacity * 120));
        }
        
        // ================================================================
        // DRAW OBJECTIVE POINTERS (diamonds)
        // ================================================================
        
        // Use pre-cached shared settings
        int distUnits = rs.distanceUnits;
        int priColorIdx = rs.primaryColorIdx;
        int secColorIdx = rs.secondaryColorIdx;
        
        // Screen colors for diamond drawing (matching font color scheme)
        Color priDiamondColor = GetDiamondColor(priColorIdx);
        Color secDiamondColor = GetDiamondColor(secColorIdx);
        
        int pointerY = ribbonY + ribbonHeight + int(POINTER_GAP * compassScale) - POINTER_NUDGE_UP;
        int diamondSize = int(DIAMOND_BASE_SIZE * compassScale);

        int skill = G_SkillPropertyInt(SKILLP_ACSReturn);
        for (int i = 0; i < objectives.Size(); i++)
        {
            let obj = objectives[i];

            // Only show active, tracked waypoint objectives for current map
            if (!obj.IsVisibleForCurrentMap(skill)) continue;
            if (!obj.hasWaypoint) continue;
            if (obj.isCompleted || obj.hasFailed) continue;
            if (!obj.isTracked) continue;

            // Use SphericalCoords: returns (yaw_delta, pitch_delta, distance)
            vector2 viewAngles = (viewAngle, viewPitch);
            vector3 spherical = level.SphericalCoords(viewPos, obj.waypointPos, viewAngles);
            
            double yawDelta = spherical.X;  // Degrees from player's facing
            double distance = spherical.Z;  // Distance in map units
            
            // Determine if within compass FOV
            bool clamped = false;
            double clampedDelta = yawDelta;
            
            if (abs(yawDelta) > halfFOV)
            {
                clamped = true;
                clampedDelta = (yawDelta > 0) ? halfFOV - CLAMP_FOV_MARGIN : -halfFOV + CLAMP_FOV_MARGIN;
            }
            
            // Position on ribbon
            // SphericalCoords .X: positive = target is to the RIGHT, negative = to the LEFT
            // On ribbon: fraction 0.0 = left edge, 0.5 = center, 1.0 = right edge
            double fraction = (clampedDelta + halfFOV) / compassFOV;
            double pointerX = ribbonX + (fraction * ribbonWidth);
            
            // Vertical offset based on distance (logarithmic - closer = higher)
            double logDist = 0;
            if (distance > 0)
            {
                logDist = log(distance * LOG_DIST_SCALE) * LOG_DIST_MULT - LOG_DIST_MULT;
                if (logDist < 0) logDist = 0;
                if (logDist > LOG_DIST_MAX) logDist = LOG_DIST_MAX;
            }
            double yOff = logDist * compassScale;
            
            // Choose color based on primary/secondary
            Color diamondColor = obj.isPrimary ? priDiamondColor : secDiamondColor;
            int fontColor = obj.isPrimary ? priColorIdx : secColorIdx;
            
            // Dim if clamped to edge
            double pointerAlpha = clamped ? opacity * 0.5 : opacity;
            int pointerAlphaInt = int(pointerAlpha * 255);
            
            // Convert pointer position to screen coordinates
            int dCX = int(pointerX * scaleX);
            int dCY = int((pointerY + yOff) * scaleY);
            int dR = int(diamondSize * scaleX);
            int dRY = int(diamondSize * scaleY);
            
            // Draw filled diamond
            if (useTextures && texDiamond.isValid())
            {
                // Textured diamond with color tinting via DTA_FillColor
                int texW = dR * 2;
                int texH = dRY * 2;
                Screen.DrawTexture(texDiamond, false,
                    dCX - dR, dCY - dRY,
                    DTA_DestWidthF, double(texW),
                    DTA_DestHeightF, double(texH),
                    DTA_Alpha, pointerAlpha,
                    DTA_FillColor, diamondColor);
            }
            else
            {
                // Procedural diamond using thick lines
                // Top half
                Screen.DrawThickLine(dCX - dR, dCY, dCX, dCY - dRY, 1.5, diamondColor, pointerAlphaInt);
                Screen.DrawThickLine(dCX, dCY - dRY, dCX + dR, dCY, 1.5, diamondColor, pointerAlphaInt);
                // Bottom half
                Screen.DrawThickLine(dCX + dR, dCY, dCX, dCY + dRY, 1.5, diamondColor, pointerAlphaInt);
                Screen.DrawThickLine(dCX, dCY + dRY, dCX - dR, dCY, 1.5, diamondColor, pointerAlphaInt);
                // Fill center cross
                Screen.DrawThickLine(dCX - dR + 1, dCY, dCX + dR - 1, dCY, 1.0, diamondColor, pointerAlphaInt);
            }
            
            // Draw edge chevron indicator if clamped (geometric, matching waypoint style)
            if (clamped)
            {
                int chevW = int(CHEVRON_WIDTH * scaleY);
                int chevH = int(CHEVRON_HEIGHT * scaleY);
                int chevGap = int(CHEVRON_GAP * scaleX);
                int chevAlpha = int(pointerAlpha * CHEVRON_ALPHA_MULT * 255);

                if (useTextures && texChevron.isValid())
                {
                    // Textured chevron with tinting
                    int cTexW = int(CHEVRON_TEX_WIDTH * scaleX);
                    int cTexH = int(CHEVRON_TEX_HEIGHT * scaleY);
                    if (yawDelta > 0)
                    {
                        // Right-pointing (texture is already right-pointing)
                        int cx = dCX + dR + chevGap;
                        Screen.DrawTexture(texChevron, false,
                            cx, dCY - cTexH / 2,
                            DTA_DestWidthF, double(cTexW),
                            DTA_DestHeightF, double(cTexH),
                            DTA_Alpha, pointerAlpha * CHEVRON_ALPHA_MULT,
                            DTA_FillColor, diamondColor);
                    }
                    else
                    {
                        // Left-pointing (flip horizontally)
                        int cx = dCX - dR - chevGap - cTexW;
                        Screen.DrawTexture(texChevron, false,
                            cx, dCY - cTexH / 2,
                            DTA_DestWidthF, double(cTexW),
                            DTA_DestHeightF, double(cTexH),
                            DTA_Alpha, pointerAlpha * CHEVRON_ALPHA_MULT,
                            DTA_FillColor, diamondColor,
                            DTA_FlipX, true);
                    }
                }
                else
                {
                    if (yawDelta > 0)
                    {
                        // Right-pointing chevron: >
                        int cx = dCX + dR + chevGap + chevW;
                        Screen.DrawThickLine(cx - chevW, dCY - chevH, cx, dCY, 1.5, diamondColor, chevAlpha);
                        Screen.DrawThickLine(cx, dCY, cx - chevW, dCY + chevH, 1.5, diamondColor, chevAlpha);
                    }
                    else
                    {
                        // Left-pointing chevron: <
                        int cx = dCX - dR - chevGap - chevW;
                        Screen.DrawThickLine(cx + chevW, dCY - chevH, cx, dCY, 1.5, diamondColor, chevAlpha);
                        Screen.DrawThickLine(cx, dCY, cx + chevW, dCY + chevH, 1.5, diamondColor, chevAlpha);
                    }
                }
            }
            
            // Draw distance text below diamond
            if (showDistance)
            {
                String distText;
                if (distUnits == 0)
                    distText = String.Format("%d", int(distance));
                else
                    distText = String.Format("%dm", int(distance) / 32);
                
                int distWidth = fnt.StringWidth(distText);
                
                // Draw in pixel space to match diamond position (dCX is pixel-space center)
                // Use screen dimensions as virtual dims to get 1:1 pixel mapping
                int scrW = Screen.GetWidth();
                int scrH = Screen.GetHeight();
                double textScaleVal = scaleY * compassTextScale; // Use uniform scale to avoid horizontal stretching
                int scaledDistWidth = int(distWidth * textScaleVal);
                int distDrawX = dCX - scaledDistWidth / 2;
                int distDrawY = dCY + dRY + int(DIST_TEXT_GAP * scaleY);

                Screen.DrawText(fnt, fontColor, distDrawX, distDrawY, distText,
                    DTA_VirtualWidth, scrW,
                    DTA_VirtualHeight, scrH,
                    DTA_ScaleX, textScaleVal,
                    DTA_ScaleY, textScaleVal,
                    DTA_Alpha, pointerAlpha * DIST_TEXT_ALPHA);
            }
        }

        // Return total height consumed by compass in virtual units
        // (ribbon + pointer area + distance text)
        int totalHeight = ribbonHeight + int(TOTAL_HEIGHT_PAD * compassScale);
        return totalHeight + ribbonY - RIBBON_TOP_MARGIN;
    }
    
    // Map font color index to an actual Color for DrawThickLine
    static Color GetDiamondColor(int fontColorIndex)
    {
        // Match GZDoom Font.CR_ color indices to approximate RGB
        switch (fontColorIndex)
        {
            case 0:  return Color(200, 80, 80);     // Brick
            case 1:  return Color(210, 190, 140);    // Tan
            case 2:  return Color(160, 160, 160);    // Gray
            case 3:  return Color(80, 220, 80);      // Green
            case 4:  return Color(150, 100, 50);     // Brown
            case 5:  return Color(255, 215, 0);      // Gold
            case 6:  return Color(255, 60, 60);      // Red
            case 7:  return Color(80, 80, 255);      // Blue
            case 8:  return Color(255, 160, 40);     // Orange
            case 9:  return Color(240, 240, 240);    // White
            case 10: return Color(255, 255, 80);     // Yellow
            case 13: return Color(130, 180, 255);    // LightBlue
            case 19: return Color(180, 80, 220);     // Purple
            case 21: return Color(80, 240, 240);     // Cyan
            case 22: return Color(160, 220, 255);    // Ice
            case 23: return Color(255, 120, 40);     // Fire
            case 24: return Color(60, 100, 220);     // Sapphire
            case 25: return Color(0, 180, 180);      // Teal
            default: return Color(200, 200, 200);    // Fallback white
        }
    }
    
}
