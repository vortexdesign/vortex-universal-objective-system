// ObjectiveWaypoints.zs
// On-screen 3D waypoint indicators for objectives with spatial locations
// Uses self-contained world-to-screen projection (no external library dependency)
// Math derived from GZDoom's internal poly renderer FOV calculations

class VUOS_ObjectiveWaypoints ui
{
    // ================================================================
    // WAYPOINT RENDERING CONSTANTS
    // ================================================================

    // Pickup alpha normalization
    const PICKUP_ALPHA_NORM  = 0.8;   // Divisor for pickup alpha scaling
    const ALPHA_MIN          = 0.15;  // Minimum waypoint alpha

    // FOV and projection
    const ASPECT_4_3         = 1.333333; // 4:3 aspect ratio threshold
    const BEHIND_DEPTH_MIN   = 0.1;   // Minimum depth before considered "behind"
    const BEHIND_DEPTH_EPS   = 0.01;  // Epsilon for behind-camera NDC calculation
    const BEHIND_NDC_CLAMP   = 2.0;   // NDC clamp range for behind-camera targets
    const BEHIND_NDC_SCALE   = 0.3;   // Scale factor for behind-camera horizontal spread

    // Edge margin and icon sizing
    const EDGE_MARGIN_BASE   = 30.0;  // Base edge margin (scaled by wpScale)
    const ICON_BASE_SIZE     = 14.0;  // Base diamond icon size (scaled by wpScale)

    // Distance-based alpha fade
    const FADE_DIST_START    = 512;   // Distance where alpha fade begins (map units)
    const FADE_DIST_RANGE    = 7680.0; // Range over which alpha fades
    const FADE_ALPHA_MIN     = 0.3;   // Minimum alpha at far distances

    // Distance-based scale
    const SCALE_DIST_START   = 256;   // Distance where icon scaling begins
    const SCALE_DIST_RANGE   = 10240.0; // Range over which icon shrinks
    const SCALE_MIN          = 0.6;   // Minimum icon scale at far distances

    // Off-screen arrow
    const ARROW_SIZE_MULT    = 1.2;   // Arrow size relative to icon size
    const ARROW_TAIL_RATIO   = 0.6;   // Tail length relative to arrow size
    const ARROW_TAIL_ANGLE   = 140.0; // Tail spread angle (degrees)
    const EDGE_ALPHA_MULT    = 0.85;  // Alpha multiplier for edge indicators

    // Distance text
    const DIST_TEXT_GAP      = 4.0;   // Gap below diamond to distance text
    const DIST_TEXT_NUDGE    = 120.0; // Horizontal nudge for off-screen distance text
    const DIST_TEXT_Y_MULT   = 1.5;   // Vertical offset multiplier for off-screen text
    const TEXT_SCALE_REF     = 640.0; // Reference width for text scale calculation

    // Vertical drift
    const VERTICAL_DRIFT_MAX = 0.10;  // Max vertical drift as fraction of screen height

    // ====================================================================
    // PUBLIC ENTRY POINT - Called from VUOS_ObjectiveRenderer.RenderOverlay()
    // ====================================================================

    static void DrawWaypoints(
        Array<VUOS_ObjectiveData> objectives,
        int virtualWidth,
        int virtualHeight,
        double pickupAlpha,
        double viewAngle,
        double viewPitch,
        double viewRoll,
        vector3 viewPos,
        VUOS_RenderSettings rs)
    {
        // Use pre-cached settings from VUOS_RenderSettings
        double wpScale = rs.waypointScale;
        int distUnits = rs.distanceUnits;
        int maxDistance = rs.waypointMaxDistance;
        double textScale = rs.waypointTextScale;

        // Attempt to load diamond texture if style == 1; fall back to procedural if missing
        bool useTextures = false;
        TextureID texDiamond;
        if (rs.waypointStyle == 1)
        {
            texDiamond = TexMan.CheckForTexture("WPDMND", TexMan.Type_Any);
            useTextures = texDiamond.isValid();
        }

        // Use pre-cached shared settings
        int priColorIdx = rs.primaryColorIdx;
        int secColorIdx = rs.secondaryColorIdx;

        // Scale pickup fade into waypoint opacity
        double baseAlpha = pickupAlpha / PICKUP_ALPHA_NORM;
        if (baseAlpha > 1.0) baseAlpha = 1.0;
        if (baseAlpha < ALPHA_MIN) baseAlpha = ALPHA_MIN;
        
        // Screen dimensions for pixel-space drawing
        double screenW = Screen.GetWidth();
        double screenH = Screen.GetHeight();
        
        // Precompute projection constants
        double baseFOV = players[consoleplayer].FOV;
        double aspect = screenW / screenH;
        
        // GZDoom FOV: baseFOV is horizontal FOV at 4:3 aspect ratio
        // For widescreen, vertical FOV stays constant, horizontal widens
        // fovratio = max(aspect, 4/3) clamped to 4/3 for standard+ displays
        double fovratio = (aspect >= 1.3) ? ASPECT_4_3 : aspect;
        double tanHalfFovY = tan(baseFOV / 2.0) / fovratio;
        double tanHalfFovX = tanHalfFovY * aspect;
        
        // Precompute trig for view rotation
        double ca = cos(-viewAngle);
        double sa = sin(-viewAngle);
        double cp = cos(viewPitch);
        double sp = sin(viewPitch);
        double cr = cos(-viewRoll);
        double sr = sin(-viewRoll);
        
        // Edge margin in pixels (keep indicators away from screen edges)
        double edgeMargin = EDGE_MARGIN_BASE * wpScale;
        
        // Iterate active waypoint objectives
        int skill = G_SkillPropertyInt(SKILLP_ACSReturn);
        for (int i = 0; i < objectives.Size(); i++)
        {
            let obj = objectives[i];

            // Skip non-waypoint, completed, failed, or invisible objectives
            if (!obj.IsVisibleForCurrentMap(skill)) continue;
            if (!obj.hasWaypoint) continue;
            if (obj.isCompleted || obj.hasFailed) continue;
            if (!obj.isTracked) continue;

            // Check max distance cutoff (using cached distance from WorldTick)
            if (maxDistance > 0 && obj.GetDistance(consoleplayer) > maxDistance) continue;
            
            // ============================================================
            // WORLD-TO-SCREEN PROJECTION
            // ============================================================
            
            // Step 1: Portal-safe relative vector from camera to waypoint
            vector3 diff = level.Vec3Diff(viewPos, obj.waypointPos);
            
            // Step 2: Rotate by -viewAngle (yaw) around Z axis
            double rx = diff.x * ca - diff.y * sa;
            double ry = diff.x * sa + diff.y * ca;
            double rz = diff.z;
            
            // Step 3: Rotate by viewPitch around Y axis
            // (GZDoom: positive pitch = looking up)
            double depth = rx * cp + rz * sp;
            double vy = ry;
            double vz = -rx * sp + rz * cp;
            
            // Step 4: Rotate by -viewRoll in the screen plane (Y-Z)
            double finalY = vy * cr - vz * sr;
            double finalZ = vy * sr + vz * cr;
            
            // ============================================================
            // DETERMINE SCREEN POSITION
            // ============================================================
            
            bool isBehind = (depth <= BEHIND_DEPTH_MIN);
            bool isOnScreen = false;
            double screenX, screenY;
            
            if (!isBehind)
            {
                // Perspective divide to NDC [-1, 1]
                double ndcX = -finalY / (depth * tanHalfFovX);
                double ndcY = finalZ / (depth * tanHalfFovY);
                
                // Map NDC to screen pixels
                // Horizontal: full projection tracking
                screenX = (1.0 + ndcX) * 0.5 * screenW;
                // Vertical: center of screen with gentle drift from pitch
                double verticalDrift = ndcY * VERTICAL_DRIFT_MAX;
                screenY = (1.0 - verticalDrift) * 0.5 * screenH;
                
                // Consider "on screen" if the objective is within the camera's horizontal view
                isOnScreen = (screenX >= edgeMargin && screenX <= screenW - edgeMargin);
            }
            
            // Color: use primary/secondary header colors (same as compass diamonds)
            Color wpColor = VUOS_ObjectiveCompass.GetDiamondColor(obj.isPrimary ? priColorIdx : secColorIdx);
            
            // Distance-based alpha fade
            int playerDist = obj.GetDistance(consoleplayer);
            double distFade = 1.0;
            if (playerDist > FADE_DIST_START)
            {
                distFade = 1.0 - (double(playerDist - FADE_DIST_START) / FADE_DIST_RANGE);
                if (distFade < FADE_ALPHA_MIN) distFade = FADE_ALPHA_MIN;
            }
            double alpha = baseAlpha * distFade;

            // Distance-based icon scale
            double distScale = 1.0;
            if (playerDist > SCALE_DIST_START)
            {
                distScale = 1.0 - (double(playerDist - SCALE_DIST_START) / SCALE_DIST_RANGE);
                if (distScale < SCALE_MIN) distScale = SCALE_MIN;
            }
            double iconSize = ICON_BASE_SIZE * wpScale * distScale;
            
            // ============================================================
            // DRAW INDICATOR
            // ============================================================
            
            if (isOnScreen)
            {
                // IN FRONT + ON SCREEN: Draw diamond icon at projected position
                DrawDiamond(screenX, screenY, iconSize, wpColor, alpha, useTextures, texDiamond);
                
                // Distance text directly below diamond bottom edge
                int fontColor = obj.isPrimary ? priColorIdx : secColorIdx;
                double textY = screenY + iconSize + DIST_TEXT_GAP;
                DrawDistanceText(screenX, textY,
                    playerDist, distUnits, fontColor, alpha, textScale);
            }
            else
            {
                // OFF SCREEN or BEHIND: Clamp to screen edge with arrow
                double clampX, clampY;
                double arrowAngle;
                
                if (isBehind)
                {
                    // Behind camera: point down from bottom edge
                    // Use the horizontal direction to position along bottom
                    double behindNdcX = -finalY / (abs(depth) + BEHIND_DEPTH_EPS);
                    // Normalize to screen width range
                    behindNdcX = clamp(behindNdcX, -BEHIND_NDC_CLAMP, BEHIND_NDC_CLAMP);
                    clampX = (1.0 + behindNdcX * BEHIND_NDC_SCALE) * 0.5 * screenW;
                    clampX = clamp(clampX, edgeMargin, screenW - edgeMargin);
                    clampY = screenH - edgeMargin;
                    arrowAngle = 270.0; // Points down = "turn around"
                }
                else
                {
                    // In front but off screen: clamp to nearest edge
                    double ndcX = -finalY / (depth * tanHalfFovX);
                    double ndcY = finalZ / (depth * tanHalfFovY);
                    
                    // Calculate arrow angle pointing toward the objective
                    arrowAngle = atan2(ndcY, ndcX);
                    
                    // Project ray from center to NDC position onto screen edge
                    // Find the scale factor that brings the point to the margin boundary
                    double halfW = screenW * 0.5 - edgeMargin;
                    double halfH = screenH * 0.5 - edgeMargin;
                    
                    // Convert NDC to pixel offset from center
                    double pxOffX = ndcX * screenW * 0.5;
                    double pxOffY = -ndcY * screenH * 0.5;
                    
                    // Scale to fit inside margin box (intersect ray with box edge)
                    double scaleToEdge = 1.0;
                    if (abs(pxOffX) > 0.01)
                    {
                        double sx = halfW / abs(pxOffX);
                        if (sx < scaleToEdge) scaleToEdge = sx;
                    }
                    if (abs(pxOffY) > 0.01)
                    {
                        double sy = halfH / abs(pxOffY);
                        if (sy < scaleToEdge) scaleToEdge = sy;
                    }
                    
                    clampX = screenW * 0.5 + pxOffX * scaleToEdge;
                    clampY = screenH * 0.5 + pxOffY * scaleToEdge;
                    
                    clampX = clamp(clampX, edgeMargin, screenW - edgeMargin);
                    clampY = clamp(clampY, edgeMargin, screenH - edgeMargin);
                }
                
                // Draw arrow at edge
                double arrowSize = iconSize * ARROW_SIZE_MULT;
                DrawArrow(clampX, clampY, arrowSize, arrowAngle, wpColor, alpha * EDGE_ALPHA_MULT);

                // Distance text beside the arrow, nudged toward screen center for readability
                double nudge = (clampX < screenW * 0.5) ? arrowSize + DIST_TEXT_NUDGE : -(arrowSize + DIST_TEXT_NUDGE);
                int fontColor = obj.isPrimary ? priColorIdx : secColorIdx;
                DrawDistanceText(clampX + nudge, clampY - arrowSize * DIST_TEXT_Y_MULT,
                    playerDist, distUnits, fontColor, alpha * EDGE_ALPHA_MULT, textScale);
            }
        }
    }
    
    // ====================================================================
    // DRAWING HELPERS
    // ====================================================================
    
    // Draw a diamond shape (textured or procedural fallback)
    static void DrawDiamond(double cx, double cy, double size, Color col, double alpha,
        bool useTextures, TextureID texDiamond)
    {
        int a = int(alpha * 255);
        if (a < 1) return;

        if (useTextures && texDiamond.isValid())
        {
            // Textured diamond with color tinting (matches compass pattern)
            int texW = int(size * 2);
            int texH = int(size * 2);
            Screen.DrawTexture(texDiamond, false,
                cx - size, cy - size,
                DTA_DestWidthF, double(texW),
                DTA_DestHeightF, double(texH),
                DTA_Alpha, alpha,
                DTA_FillColor, col);
        }
        else
        {
            // Procedural diamond using thick lines
            double top = cy - size;
            double bot = cy + size;
            double left = cx - size;
            double right = cx + size;

            // Four edges of diamond
            Screen.DrawThickLine(int(cx), int(top), int(right), int(cy), 2.0, col, a);
            Screen.DrawThickLine(int(right), int(cy), int(cx), int(bot), 2.0, col, a);
            Screen.DrawThickLine(int(cx), int(bot), int(left), int(cy), 2.0, col, a);
            Screen.DrawThickLine(int(left), int(cy), int(cx), int(top), 2.0, col, a);

            // Inner fill lines for visibility
            for (double d = 0.3; d <= 0.7; d += 0.2)
            {
                double s = size * d;
                Screen.DrawThickLine(
                    int(cx - s), int(cy), int(cx + s), int(cy),
                    1.0, col, int(a * 0.4));
            }
        }
    }
    
    // Draw a directional arrow pointing at the given angle (degrees)
    // 0 = right, 90 = up, 180 = left, 270 = down (screen space)
    static void DrawArrow(double cx, double cy, double size, double angleDeg, Color col, double alpha)
    {
        int a = int(alpha * 255);
        if (a < 1) return;
        
        // Arrow tip direction
        double tipX = cx + cos(angleDeg) * size;
        double tipY = cy - sin(angleDeg) * size;
        
        // Two tail points (spread at ±ARROW_TAIL_ANGLE from tip direction)
        double tailSize = size * ARROW_TAIL_RATIO;
        double tailAngle1 = angleDeg + ARROW_TAIL_ANGLE;
        double tailAngle2 = angleDeg - ARROW_TAIL_ANGLE;
        
        double tail1X = cx + cos(tailAngle1) * tailSize;
        double tail1Y = cy - sin(tailAngle1) * tailSize;
        double tail2X = cx + cos(tailAngle2) * tailSize;
        double tail2Y = cy - sin(tailAngle2) * tailSize;
        
        // Draw arrowhead (3 lines forming a chevron)
        Screen.DrawThickLine(int(tipX), int(tipY), int(tail1X), int(tail1Y), 2.0, col, a);
        Screen.DrawThickLine(int(tipX), int(tipY), int(tail2X), int(tail2Y), 2.0, col, a);
        Screen.DrawThickLine(int(tail1X), int(tail1Y), int(tail2X), int(tail2Y), 1.5, col, int(a * 0.5));
    }
    
    // Draw distance text centered below the indicator (in raw pixel-space to match DrawThickLine)
    static void DrawDistanceText(double cx, double cy, int rawDistance, int distUnits, int fontColor, double alpha, double textScale)
    {
        if (rawDistance <= 0) return;
        
        String distText;
        if (distUnits == 1)
        {
            // Meters: 32 map units ≈ 1 meter
            int meters = rawDistance / 32;
            distText = String.Format("%dm", meters);
        }
        else
        {
            distText = String.Format("%d", rawDistance);
        }
        
        Font fnt = SmallFont;
        int textWidth = fnt.StringWidth(distText);
        int textHeight = fnt.GetHeight();
        
        // Draw in raw pixel space (same as DrawThickLine) using screen dimensions as virtual dims
        // This avoids aspect ratio correction that causes misalignment
        int screenW = Screen.GetWidth();
        int screenH = Screen.GetHeight();
        
        // Scale factor for text size
        double baseScale = double(screenW) / TEXT_SCALE_REF;
        double finalScale = baseScale * textScale;
        
        int scaledWidth = int(textWidth * finalScale);
        int drawX = int(cx) - scaledWidth / 2;
        int drawY = int(cy);
        
        Screen.DrawText(fnt, fontColor, drawX, drawY, distText,
            DTA_VirtualWidth, screenW,
            DTA_VirtualHeight, screenH,
            DTA_ScaleX, finalScale,
            DTA_ScaleY, finalScale,
            DTA_Alpha, alpha);
    }
}