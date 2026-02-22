// VUOS_AutoObjectives.zs
// Optional auto-objective generator that scans the map at load time
// and creates objectives for keys, puzzle items, bosses, exits, kills, and secrets.
// Add/remove via one #include line in ZSCRIPT.txt.
// Coexists with manually defined objectives from ObjectiveSetup.

class VUOS_AutoObjectives : EventHandler
{
    // ================================================================
    // EXECUTION ORDER — must run AFTER ObjectiveSetup
    // ================================================================
    // Higher Order value = runs later. ObjectiveSetup uses default (0).

    // ================================================================
    // CONSTANTS
    // ================================================================

    // Objective type constants (match VUOS_ObjectiveHandler)
    const TYPE_KILL    = 0;
    const TYPE_DESTROY = 1;
    const TYPE_COLLECT = 2;
    const TYPE_CUSTOM  = 3;

    // CVAR values for category priority
    const CAT_OFF       = 0;
    const CAT_PRIMARY   = 1;
    const CAT_SECONDARY = 2;

    // Exit line specials (ZDoom internal / Hexen-format only)
    // GZDoom translates all Doom-format specials (11, 52, 51, 124) to these
    // during map loading, so level.Lines[i].special always uses these values.
    const SPECIAL_EXIT_NORMAL  = 243;
    const SPECIAL_EXIT_SECRET  = 244;

    // ================================================================
    // STATE
    // ================================================================

    // Per-map suppression list (set by modders from ObjectiveSetup)
    Array<String> suppressedMaps;

    // Previous CVAR states for immediate response to changes
    bool prevEnabled;
    int prevKeys, prevPuzzle, prevBosses, prevExit, prevSecretExit, prevKills, prevSecrets;
    int prevKillMode;
    bool prevWaypoints;
    bool prevSecretWaypoints;

    // Kill tracking state
    int fixedKillTarget;     // Stored level.total_monsters at map load (fixed mode)
    int lastKillCount;       // Last known kill count (for fixed mode completion check)

    // Secret tracking state
    int lastFoundSecrets;    // Last known level.found_secrets value
    Array<int> secretSectorIndices;    // Sector indices of undiscovered secrets (for waypoint removal)
    Array<double> secretSectorX;       // Stored centerspot X for each secret sector
    Array<double> secretSectorY;       // Stored centerspot Y for each secret sector
    Array<double> secretSectorZ;       // Stored floor Z for each secret sector

    // Track whether we've generated on this map load
    bool hasGenerated;
    int ticksSinceGeneration;  // Delay CVar change detection to avoid false triggers on first tick
    bool cvarCacheReady;       // True once CVar baseline has been captured in WorldTick

    // ================================================================
    // STATIC API — called by modders from ObjectiveSetup
    // ================================================================

    // Find the VUOS_AutoObjectives handler instance
    static VUOS_AutoObjectives GetAutoHandler()
    {
        return VUOS_AutoObjectives(EventHandler.Find("VUOS_AutoObjectives"));
    }

    // Suppress auto-generation on a specific map
    // Call from ObjectiveSetup.WorldLoaded() before AutoObjectives runs
    static void SuppressMap(String mapName)
    {
        let handler = GetAutoHandler();
        if (!handler) return;

        for (int i = 0; i < handler.suppressedMaps.Size(); i++)
        {
            if (handler.suppressedMaps[i] ~== mapName) return; // Already suppressed
        }
        handler.suppressedMaps.Push(mapName);
    }

    static bool IsMapSuppressed(String mapName)
    {
        let handler = GetAutoHandler();
        if (!handler) return false;

        for (int i = 0; i < handler.suppressedMaps.Size(); i++)
        {
            if (handler.suppressedMaps[i] ~== mapName) return true;
        }
        return false;
    }

    // ================================================================
    // PLAYER INFO HELPER
    // ================================================================

    // Get first player info for CVAR reads. Unlike GetFirstPlayer(), this does NOT
    // require players[i].mo to exist, so it works during WorldLoaded when pawns
    // haven't been spawned yet. CVar.GetCVar() only needs the PlayerInfo struct.
    static PlayerInfo GetFirstPlayerForCVars()
    {
        for (int i = 0; i < MAXPLAYERS; i++)
        {
            if (playeringame[i])
                return players[i];
        }
        return null;
    }

    // ================================================================
    // EVENT HANDLER SETUP
    // ================================================================

    override void OnRegister()
    {
        // Order is set via the EventHandler's Order property in MAPINFO or registration order.
        // Since VUOS_AutoObjectives is #included after ObjectiveSetup in ZSCRIPT.txt,
        // it registers later and WorldLoaded fires in registration order.
        hasGenerated = false;
        lastFoundSecrets = 0;
        lastKillCount = 0;
        secretSectorIndices.Clear();
        secretSectorX.Clear();
        secretSectorY.Clear();
        secretSectorZ.Clear();
        fixedKillTarget = 0;
    }

    // ================================================================
    // WORLD LOADED — main scan and generation entry point
    // ================================================================

    override void WorldLoaded(WorldEvent e)
    {
        if (VUOS_ObjectiveHandler.IsDebugEnabled()) Console.Printf("DEBUG AUTO: WorldLoaded fired (isSaveGame=%d)", e.IsSaveGame);

        // On save game load, skip regeneration — objectives are restored from save state
        if (e.IsSaveGame)
        {
            // Restore tracking state from existing auto-objectives
            RestoreTrackingState();
            return;
        }

        // Clear any previously auto-generated objectives (handles map restart)
        ClearAutoObjectives();

        // Check master toggle
        PlayerInfo fp = GetFirstPlayerForCVars();
        if (!fp)
        {
            if (VUOS_ObjectiveHandler.IsDebugEnabled()) Console.Printf("DEBUG AUTO: GetFirstPlayerForCVars returned null - aborting");
            return;
        }
        if (VUOS_ObjectiveHandler.IsDebugEnabled()) Console.Printf("DEBUG AUTO: Got player info OK");

        bool enabled = VUOS_ObjectiveHandler.GetCVarBool('vuos_auto_enabled', fp, true);
        if (VUOS_ObjectiveHandler.IsDebugEnabled()) Console.Printf("DEBUG AUTO: vuos_auto_enabled = %d", enabled);
        if (!enabled) return;

        // Check suppression
        if (IsMapSuppressed(level.MapName))
        {
            if (VUOS_ObjectiveHandler.IsDebugEnabled()) Console.Printf("DEBUG AUTO: Map '%s' is suppressed - aborting", level.MapName);
            return;
        }

        if (VUOS_ObjectiveHandler.IsDebugEnabled()) Console.Printf("DEBUG AUTO: Calling GenerateAll() from WorldLoaded");

        // Generate objectives
        GenerateAll();
        hasGenerated = true;
        ticksSinceGeneration = 0;
        cvarCacheReady = false;

        // Note: CVar caching is deferred to WorldTick to avoid read timing issues
        // that can cause false change detection on the first tick
    }

    // ================================================================
    // GENERATION LOGIC
    // ================================================================

    void GenerateAll()
    {
        PlayerInfo fp = GetFirstPlayerForCVars();
        if (!fp)
        {
            if (VUOS_ObjectiveHandler.IsDebugEnabled()) Console.Printf("DEBUG AUTO: GenerateAll - no player info");
            return;
        }

        bool dbg = VUOS_ObjectiveHandler.IsDebugEnabled();
        bool autoWaypoints = VUOS_ObjectiveHandler.GetCVarBool('vuos_auto_waypoints', fp, true);
        int generatedCount = 0;

        // 1. Keys
        int keyCat = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_keys', fp, CAT_PRIMARY);
        if (dbg) Console.Printf("DEBUG AUTO: Keys CVAR=%d", keyCat);
        if (keyCat != CAT_OFF)
        {
            int keyResult = GenerateKeys(keyCat == CAT_PRIMARY, autoWaypoints);
            if (dbg) Console.Printf("DEBUG AUTO: Keys generated %d objectives", keyResult);
            generatedCount += keyResult;
        }

        // 2. Puzzle Items
        int puzzleCat = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_puzzleitems', fp, CAT_PRIMARY);
        if (dbg) Console.Printf("DEBUG AUTO: PuzzleItems CVAR=%d", puzzleCat);
        if (puzzleCat != CAT_OFF)
        {
            int puzzleResult = GeneratePuzzleItems(puzzleCat == CAT_PRIMARY, autoWaypoints);
            if (dbg) Console.Printf("DEBUG AUTO: PuzzleItems generated %d objectives", puzzleResult);
            generatedCount += puzzleResult;
        }

        // 3. Bosses
        int bossCat = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_bosses', fp, CAT_PRIMARY);
        if (dbg) Console.Printf("DEBUG AUTO: Bosses CVAR=%d", bossCat);
        if (bossCat != CAT_OFF)
        {
            int bossResult = GenerateBosses(bossCat == CAT_PRIMARY, autoWaypoints);
            if (dbg) Console.Printf("DEBUG AUTO: Bosses generated %d objectives", bossResult);
            generatedCount += bossResult;
        }

        // 4. Exit
        int exitCat = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_exit', fp, CAT_PRIMARY);
        if (dbg) Console.Printf("DEBUG AUTO: Exit CVAR=%d", exitCat);
        if (exitCat != CAT_OFF)
        {
            int exitResult = GenerateExits(exitCat == CAT_PRIMARY, autoWaypoints);
            if (dbg) Console.Printf("DEBUG AUTO: Exits generated %d objectives", exitResult);
            generatedCount += exitResult;
        }

        // 5. Secret Exit
        int secExitCat = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_secretexit', fp, CAT_SECONDARY);
        if (dbg) Console.Printf("DEBUG AUTO: SecretExit CVAR=%d", secExitCat);
        if (secExitCat != CAT_OFF)
        {
            int secExitResult = GenerateSecretExits(secExitCat == CAT_PRIMARY, autoWaypoints);
            if (dbg) Console.Printf("DEBUG AUTO: SecretExits generated %d objectives", secExitResult);
            generatedCount += secExitResult;
        }

        // 6. Kills
        int killCat = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_kills', fp, CAT_SECONDARY);
        if (dbg) Console.Printf("DEBUG AUTO: Kills CVAR=%d, total_monsters=%d", killCat, level.total_monsters);
        if (killCat != CAT_OFF)
        {
            int killResult = GenerateKills(killCat == CAT_PRIMARY);
            if (dbg) Console.Printf("DEBUG AUTO: Kills generated %d objectives", killResult);
            generatedCount += killResult;
        }

        // 7. Secrets
        int secretCat = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_secrets', fp, CAT_SECONDARY);
        if (dbg) Console.Printf("DEBUG AUTO: Secrets CVAR=%d, total_secrets=%d", secretCat, level.total_secrets);
        if (secretCat != CAT_OFF)
        {
            int secretResult = GenerateSecrets(secretCat == CAT_PRIMARY);
            if (dbg) Console.Printf("DEBUG AUTO: Secrets generated %d objectives", secretResult);
            generatedCount += secretResult;
        }

        if (dbg) Console.Printf("DEBUG AUTO: Total generated: %d", generatedCount);

        // Show notification
        if (generatedCount > 0)
        {
            bool notify = VUOS_ObjectiveHandler.GetCVarBool('vuos_auto_notify', fp, true);
            if (notify)
            {
                Console.Printf("\c[Gold]%d auto-objective%s generated", generatedCount, generatedCount == 1 ? "" : "s");
            }
        }
    }

    // ================================================================
    // CATEGORY GENERATORS
    // ================================================================

    // Generate key objectives by scanning for Key subclasses
    int GenerateKeys(bool isPrimary, bool autoWaypoints)
    {
        int count = 0;

        // Collect unique key classes
        Array<String> classNames;

        let it = ThinkerIterator.Create("Key");
        Actor act;
        while (act = Actor(it.Next()))
        {
            String cn = act.GetClassName();

            // Check if we already have this class
            bool found = false;
            for (int i = 0; i < classNames.Size(); i++)
            {
                if (classNames[i] == cn) { found = true; break; }
            }
            if (!found)
            {
                classNames.Push(cn);
            }
        }

        // For each unique key class, generate an objective
        for (int c = 0; c < classNames.Size(); c++)
        {
            String cn = classNames[c];

            // Check for duplicate with manual objectives
            if (HasExistingObjectiveForClass(cn)) continue;

            // Collect all instances of this class
            Array<Actor> instances;
            let it2 = ThinkerIterator.Create(cn);
            Actor act2;
            while (act2 = Actor(it2.Next()))
            {
                instances.Push(act2);
            }

            if (instances.Size() == 0) continue;

            // Build description
            String tag = instances[0].GetTag();
            if (tag.Length() == 0 || tag == "" || tag == instances[0].GetClassName())
                tag = CleanClassName(cn);

            String desc;
            if (instances.Size() == 1)
                desc = String.Format("Find the %s", tag);
            else
                desc = String.Format("Find one of the %ss", tag);

            // Add objective (TYPE_COLLECT — tracked via inventory polling)
            AddAutoObjective(desc, cn, 1, TYPE_COLLECT, isPrimary);

            // Set waypoints
            if (autoWaypoints)
            {
                if (instances.Size() == 1)
                {
                    VUOS_ObjectiveHandler.SetWaypoint(desc, instances[0].pos.X, instances[0].pos.Y, instances[0].pos.Z);
                }
                else
                {
                    Array<double> posX, posY, posZ;
                    Array<Actor> actors;
                    for (int i = 0; i < instances.Size(); i++)
                    {
                        posX.Push(instances[i].pos.X);
                        posY.Push(instances[i].pos.Y);
                        posZ.Push(instances[i].pos.Z);
                        actors.Push(instances[i]);
                    }
                    VUOS_ObjectiveHandler.SetWaypointMultiWithActors(desc, posX, posY, posZ, actors);
                }
            }

            count++;
        }

        return count;
    }

    // Generate puzzle item objectives
    int GeneratePuzzleItems(bool isPrimary, bool autoWaypoints)
    {
        int count = 0;

        Array<String> classNames;

        let it = ThinkerIterator.Create("PuzzleItem");
        Actor act;
        while (act = Actor(it.Next()))
        {
            String cn = act.GetClassName();
            bool found = false;
            for (int i = 0; i < classNames.Size(); i++)
            {
                if (classNames[i] == cn) { found = true; break; }
            }
            if (!found) classNames.Push(cn);
        }

        for (int c = 0; c < classNames.Size(); c++)
        {
            String cn = classNames[c];
            if (HasExistingObjectiveForClass(cn)) continue;

            Array<Actor> instances;
            let it2 = ThinkerIterator.Create(cn);
            Actor act2;
            while (act2 = Actor(it2.Next()))
            {
                instances.Push(act2);
            }

            if (instances.Size() == 0) continue;

            String tag = instances[0].GetTag();
            if (tag.Length() == 0 || tag == "" || tag == instances[0].GetClassName())
                tag = CleanClassName(cn);

            String desc;
            if (instances.Size() == 1)
                desc = String.Format("Find the %s", tag);
            else
                desc = String.Format("Find one of the %ss", tag);

            // TYPE_COLLECT — tracked via inventory polling
            AddAutoObjective(desc, cn, 1, TYPE_COLLECT, isPrimary);

            if (autoWaypoints)
            {
                if (instances.Size() == 1)
                {
                    VUOS_ObjectiveHandler.SetWaypoint(desc, instances[0].pos.X, instances[0].pos.Y, instances[0].pos.Z);
                }
                else
                {
                    Array<double> posX, posY, posZ;
                    Array<Actor> actors;
                    for (int i = 0; i < instances.Size(); i++)
                    {
                        posX.Push(instances[i].pos.X);
                        posY.Push(instances[i].pos.Y);
                        posZ.Push(instances[i].pos.Z);
                        actors.Push(instances[i]);
                    }
                    VUOS_ObjectiveHandler.SetWaypointMultiWithActors(desc, posX, posY, posZ, actors);
                }
            }

            count++;
        }

        return count;
    }

    // Generate boss objectives by scanning for actors with +BOSS flag
    int GenerateBosses(bool isPrimary, bool autoWaypoints)
    {
        int count = 0;

        // Collect unique boss classes with instance counts
        Array<String> classNames;
        Array<int> classCounts;

        let it = ThinkerIterator.Create("Actor");
        Actor act;
        while (act = Actor(it.Next()))
        {
            if (!act.bBOSS) continue;
            if (act.Health <= 0) continue; // Skip already-dead bosses

            String cn = act.GetClassName();
            bool found = false;
            for (int i = 0; i < classNames.Size(); i++)
            {
                if (classNames[i] == cn)
                {
                    classCounts[i]++;
                    found = true;
                    break;
                }
            }
            if (!found)
            {
                classNames.Push(cn);
                classCounts.Push(1);
            }
        }

        for (int c = 0; c < classNames.Size(); c++)
        {
            String cn = classNames[c];
            if (HasExistingObjectiveForClass(cn)) continue;

            int bossCount = classCounts[c];

            // Get tag from first instance
            String tag = "";
            Array<Actor> instances;
            let it2 = ThinkerIterator.Create(cn);
            Actor act2;
            while (act2 = Actor(it2.Next()))
            {
                if (act2.bBOSS && act2.Health > 0)
                {
                    if (tag.Length() == 0)
                    {
                        tag = act2.GetTag();
                        if (tag.Length() == 0 || tag == "" || tag == act2.GetClassName())
                            tag = CleanClassName(cn);
                    }
                    instances.Push(act2);
                }
            }

            String desc;
            if (bossCount == 1)
                desc = String.Format("Defeat the %s", tag);
            else
                desc = String.Format("Defeat %d %ss", bossCount, tag);

            AddAutoObjective(desc, cn, bossCount, TYPE_KILL, isPrimary);

            if (autoWaypoints && instances.Size() > 0)
            {
                if (instances.Size() == 1)
                {
                    VUOS_ObjectiveHandler.SetWaypoint(desc, instances[0].pos.X, instances[0].pos.Y, instances[0].pos.Z);
                }
                else
                {
                    Array<double> posX, posY, posZ;
                    Array<Actor> actors;
                    for (int i = 0; i < instances.Size(); i++)
                    {
                        posX.Push(instances[i].pos.X);
                        posY.Push(instances[i].pos.Y);
                        posZ.Push(instances[i].pos.Z);
                        actors.Push(instances[i]);
                    }
                    VUOS_ObjectiveHandler.SetWaypointMultiWithActors(desc, posX, posY, posZ, actors);
                }
            }

            count++;
        }

        return count;
    }

    // Generate exit objective by scanning level.Lines for exit specials
    int GenerateExits(bool isPrimary, bool autoWaypoints)
    {
        Array<double> exitPosX, exitPosY, exitPosZ;

        for (int i = 0; i < level.Lines.Size(); i++)
        {
            let line = level.Lines[i];
            if (IsNormalExitSpecial(line.special))
            {
                // Use the midpoint of the linedef as the waypoint position
                vector2 mid = (line.v1.p + line.v2.p) / 2.0;
                // Use the floor height of the front sector for Z
                double z = line.frontsector ? line.frontsector.floorplane.ZatPoint(mid) : 0;
                exitPosX.Push(mid.X);
                exitPosY.Push(mid.Y);
                exitPosZ.Push(z + 40); // +40 for eye height visibility
            }
        }

        if (exitPosX.Size() == 0) return 0;

        String desc;
        if (exitPosX.Size() == 1)
            desc = "Reach the exit";
        else
            desc = "Reach one of the exits";

        // Use TYPE_CUSTOM since exit completion is tracked via WorldLineActivated
        AddAutoObjective(desc, '', 1, TYPE_CUSTOM, isPrimary);

        if (autoWaypoints)
        {
            if (exitPosX.Size() == 1)
            {
                VUOS_ObjectiveHandler.SetWaypoint(desc, exitPosX[0], exitPosY[0], exitPosZ[0]);
            }
            else
            {
                VUOS_ObjectiveHandler.SetWaypointMulti(desc, exitPosX, exitPosY, exitPosZ);
            }
        }

        return 1;
    }

    // Generate secret exit objective
    int GenerateSecretExits(bool isPrimary, bool autoWaypoints)
    {
        Array<double> exitPosX, exitPosY, exitPosZ;

        for (int i = 0; i < level.Lines.Size(); i++)
        {
            let line = level.Lines[i];
            if (IsSecretExitSpecial(line.special))
            {
                vector2 mid = (line.v1.p + line.v2.p) / 2.0;
                double z = line.frontsector ? line.frontsector.floorplane.ZatPoint(mid) : 0;
                exitPosX.Push(mid.X);
                exitPosY.Push(mid.Y);
                exitPosZ.Push(z + 40);
            }
        }

        if (exitPosX.Size() == 0) return 0;

        String desc;
        if (exitPosX.Size() == 1)
            desc = "Find the secret exit";
        else
            desc = "Find one of the secret exits";

        AddAutoObjective(desc, '', 1, TYPE_CUSTOM, isPrimary);

        if (autoWaypoints)
        {
            if (exitPosX.Size() == 1)
            {
                VUOS_ObjectiveHandler.SetWaypoint(desc, exitPosX[0], exitPosY[0], exitPosZ[0]);
            }
            else
            {
                VUOS_ObjectiveHandler.SetWaypointMulti(desc, exitPosX, exitPosY, exitPosZ);
            }
        }

        return 1;
    }

    // Generate kill all enemies objective
    int GenerateKills(bool isPrimary)
    {
        int totalMonsters = level.total_monsters;
        if (totalMonsters == 0) return 0;

        PlayerInfo fp = GetFirstPlayerForCVars();
        int killMode = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_kill_mode', fp, 0);

        String desc = "Kill all enemies";

        // Store fixed target for kill tracking
        fixedKillTarget = totalMonsters;
        lastKillCount = level.killed_monsters;

        AddAutoObjective(desc, '', totalMonsters, TYPE_CUSTOM, isPrimary);

        // Restore progress if enemies were already killed (e.g. CVar change mid-map)
        if (lastKillCount > 0)
        {
            let handler = VUOS_ObjectiveHandler.GetSetupHandler();
            if (handler)
            {
                VUOS_ObjectiveData killObj = FindAutoObjective(handler, desc);
                if (killObj)
                {
                    killObj.currentCount = lastKillCount;
                    if (lastKillCount >= totalMonsters)
                    {
                        VUOS_ObjectiveHandler.CompleteObjective(killObj);
                    }
                }
            }
        }

        return 1;
    }

    // Generate find all secrets objective
    int GenerateSecrets(bool isPrimary)
    {
        int totalSecrets = level.total_secrets;
        if (totalSecrets == 0) return 0;

        String desc = (totalSecrets == 1) ? "Find the secret" : "Find all secrets";

        lastFoundSecrets = level.found_secrets;

        AddAutoObjective(desc, '', totalSecrets, TYPE_CUSTOM, isPrimary);

        // Restore progress if secrets were already found (e.g. CVar change mid-map)
        if (lastFoundSecrets > 0)
        {
            let handler = VUOS_ObjectiveHandler.GetSetupHandler();
            if (handler)
            {
                VUOS_ObjectiveData secObj = FindAutoObjective(handler, desc);
                if (secObj)
                {
                    secObj.currentCount = lastFoundSecrets;
                    if (lastFoundSecrets >= totalSecrets)
                    {
                        VUOS_ObjectiveHandler.CompleteObjective(secObj);
                    }
                }
            }
        }

        // Set waypoints for secret sector locations if enabled
        PlayerInfo fp = GetFirstPlayerForCVars();
        bool secretWaypoints = fp && VUOS_ObjectiveHandler.GetCVarBool('vuos_auto_secret_waypoints', fp, false);
        if (secretWaypoints)
        {
            ScanSecretSectors();

            if (secretSectorX.Size() > 0)
            {
                if (secretSectorX.Size() == 1)
                {
                    VUOS_ObjectiveHandler.SetWaypoint(desc, secretSectorX[0], secretSectorY[0], secretSectorZ[0]);
                }
                else
                {
                    VUOS_ObjectiveHandler.SetWaypointMulti(desc, secretSectorX, secretSectorY, secretSectorZ);
                }
            }
        }

        return 1;
    }

    // Scan all sectors for undiscovered secrets and store their positions
    void ScanSecretSectors()
    {
        secretSectorIndices.Clear();
        secretSectorX.Clear();
        secretSectorY.Clear();
        secretSectorZ.Clear();

        for (int i = 0; i < level.Sectors.Size(); i++)
        {
            if (level.Sectors[i].IsSecret())
            {
                secretSectorIndices.Push(i);
                double cx = level.Sectors[i].centerspot.X;
                double cy = level.Sectors[i].centerspot.Y;
                double cz = level.Sectors[i].floorplane.ZatPoint((cx, cy));
                secretSectorX.Push(cx);
                secretSectorY.Push(cy);
                secretSectorZ.Push(cz);
            }
        }
    }

    // ================================================================
    // HELPER: Add an auto-generated objective
    // ================================================================

    void AddAutoObjective(String desc, name targetClass, int targetCount, int objType, bool isPrimary)
    {
        let handler = VUOS_ObjectiveHandler.GetSetupHandler();
        if (!handler) return;

        // Use AddObjective to create via the standard path
        if (isPrimary)
            VUOS_ObjectiveHandler.AddPrimaryObjective(desc, targetClass, targetCount, objType);
        else
            VUOS_ObjectiveHandler.AddSecondaryObjective(desc, targetClass, targetCount, objType);

        // Mark the newly added objective as auto-generated
        // It will be the last one in the array
        if (handler.objectives.Size() > 0)
        {
            let obj = handler.objectives[handler.objectives.Size() - 1];
            if (obj.objectiveDescription == desc)
            {
                obj.isAutoGenerated = true;
            }
        }
    }

    // ================================================================
    // TRACKING — WorldTick
    // ================================================================

    override void WorldTick()
    {
        if (!hasGenerated) return;

        let handler = VUOS_ObjectiveHandler.GetSetupHandler();
        if (!handler) return;

        PlayerInfo fp = GetFirstPlayerForCVars();
        if (!fp) return;

        // Phase 1: Wait a few ticks after generation before caching CVar baseline
        // This avoids false triggers from CVar read timing differences at map load
        if (!cvarCacheReady)
        {
            ticksSinceGeneration++;
            if (ticksSinceGeneration >= 5)
            {
                CacheCVarStates();
                cvarCacheReady = true;
                if (VUOS_ObjectiveHandler.IsDebugEnabled()) Console.Printf("DEBUG AUTO: CVar cache ready at tick %d", ticksSinceGeneration);
            }
        }
        else
        {
            // Phase 2: Normal CVar change detection
            CheckCVarChanges();
        }

        // Kill tracking
        int killCat = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_kills', fp, CAT_SECONDARY);
        if (killCat != CAT_OFF)
        {
            int killMode = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_kill_mode', fp, 0);
            TrackKills(handler, killMode);
        }

        // Secret tracking (poll level.found_secrets)
        int secretCat = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_secrets', fp, CAT_SECONDARY);
        if (secretCat != CAT_OFF)
        {
            TrackSecrets(handler);
        }

    }

    void TrackKills(VUOS_ObjectiveHandler handler, int killMode)
    {
        // Find the kills auto-objective
        VUOS_ObjectiveData killObj = FindAutoObjective(handler, "Kill all enemies");
        if (!killObj || killObj.isCompleted) return;

        int currentKills = level.killed_monsters;

        if (killMode == 0)
        {
            // Fixed mode: compare against stored target
            if (currentKills != lastKillCount)
            {
                lastKillCount = currentKills;
                killObj.currentCount = currentKills;

                // Complete at >= target (handles edge cases)
                if (currentKills >= fixedKillTarget)
                {
                    VUOS_ObjectiveHandler.CompleteObjective(killObj);
                }
            }
        }
        else
        {
            // Dynamic mode: poll both values every tick
            int totalMonsters = level.total_monsters;
            killObj.currentCount = currentKills;
            killObj.targetCount = totalMonsters;

            if (currentKills >= totalMonsters && totalMonsters > 0)
            {
                VUOS_ObjectiveHandler.CompleteObjective(killObj);
            }
        }
    }

    void TrackSecrets(VUOS_ObjectiveHandler handler)
    {
        int currentSecrets = level.found_secrets;
        if (currentSecrets != lastFoundSecrets)
        {
            lastFoundSecrets = currentSecrets;

            VUOS_ObjectiveData secObj = FindAutoObjective(handler, "Find all secrets");
            if (!secObj) secObj = FindAutoObjective(handler, "Find the secret");
            if (!secObj || secObj.isCompleted) return;

            secObj.currentCount = currentSecrets;

            // Remove waypoints for newly discovered secret sectors
            if (secretSectorIndices.Size() > 0)
            {
                for (int i = secretSectorIndices.Size() - 1; i >= 0; i--)
                {
                    int idx = secretSectorIndices[i];
                    // Sector was secret but has now been discovered
                    if (!level.Sectors[idx].IsSecret() && level.Sectors[idx].WasSecret())
                    {
                        vector3 pos = (secretSectorX[i], secretSectorY[i], secretSectorZ[i]);
                        secObj.RemoveWaypointByPosition(pos);
                        VUOS_ObjectiveHandler.MarkMarkersDirty();
                        secretSectorIndices.Delete(i);
                        secretSectorX.Delete(i);
                        secretSectorY.Delete(i);
                        secretSectorZ.Delete(i);
                    }
                }
            }

            if (currentSecrets >= secObj.targetCount)
            {
                VUOS_ObjectiveHandler.CompleteObjective(secObj);
            }
        }
    }

    // ================================================================
    // TRACKING — WorldThingDied (for boss waypoint cleanup)
    // ================================================================

    override void WorldThingDied(WorldEvent e)
    {
        if (!e.Thing) return;
        if (!hasGenerated) return;

        let handler = VUOS_ObjectiveHandler.GetSetupHandler();
        if (!handler) return;

        // Check if the dead actor is tracked by any auto-objective for waypoint cleanup
        if (e.Thing.bBOSS)
        {
            for (int i = 0; i < handler.objectives.Size(); i++)
            {
                let obj = handler.objectives[i];
                if (!obj.isAutoGenerated) continue;
                if (obj.isCompleted || obj.hasFailed) continue;

                // Try to remove this actor's waypoint position
                if (obj.RemoveWaypointByActor(e.Thing))
                {
                    VUOS_ObjectiveHandler.MarkMarkersDirty();
                    break;
                }
            }
        }
    }

    // ================================================================
    // TRACKING — WorldThingDestroyed (for key/puzzle item waypoint cleanup)
    // ================================================================

    override void WorldThingDestroyed(WorldEvent e)
    {
        if (!e.Thing) return;
        if (!hasGenerated) return;

        let handler = VUOS_ObjectiveHandler.GetSetupHandler();
        if (!handler) return;

        // Check if the destroyed actor is a key or puzzle item tracked by auto-objectives
        if (e.Thing is "Key" || e.Thing is "PuzzleItem")
        {
            for (int i = 0; i < handler.objectives.Size(); i++)
            {
                let obj = handler.objectives[i];
                if (!obj.isAutoGenerated) continue;
                if (obj.isCompleted || obj.hasFailed) continue;

                // Try to remove by actor reference first, then by position
                if (obj.RemoveWaypointByActor(e.Thing) || obj.RemoveWaypointByPosition(e.Thing.pos))
                {
                    VUOS_ObjectiveHandler.MarkMarkersDirty();
                    break;
                }
            }
        }
    }

    // ================================================================
    // TRACKING — WorldLineActivated (for exit objectives)
    // ================================================================

    override void WorldLineActivated(WorldEvent e)
    {
        if (!e.ActivatedLine) return;
        if (!hasGenerated) return;

        let handler = VUOS_ObjectiveHandler.GetSetupHandler();
        if (!handler) return;

        int special = e.ActivatedLine.special;

        // Check for normal exit
        if (IsNormalExitSpecial(special))
        {
            VUOS_ObjectiveData exitObj = FindAutoObjective(handler, "Reach the exit");
            if (!exitObj) exitObj = FindAutoObjective(handler, "Reach one of the exits");
            if (exitObj && !exitObj.isCompleted)
            {
                VUOS_ObjectiveHandler.CompleteObjective(exitObj);
            }
        }

        // Check for secret exit
        if (IsSecretExitSpecial(special))
        {
            VUOS_ObjectiveData secExitObj = FindAutoObjective(handler, "Find the secret exit");
            if (!secExitObj) secExitObj = FindAutoObjective(handler, "Find one of the secret exits");
            if (secExitObj && !secExitObj.isCompleted)
            {
                VUOS_ObjectiveHandler.CompleteObjective(secExitObj);
            }
        }
    }

    // ================================================================
    // EXIT SPECIAL HELPERS
    // ================================================================

    static bool IsNormalExitSpecial(int special)
    {
        return special == SPECIAL_EXIT_NORMAL;
    }

    static bool IsSecretExitSpecial(int special)
    {
        return special == SPECIAL_EXIT_SECRET;
    }

    // ================================================================
    // CVAR CHANGE DETECTION
    // ================================================================

    void CacheCVarStates()
    {
        PlayerInfo fp = GetFirstPlayerForCVars();
        if (!fp) return;

        prevEnabled = VUOS_ObjectiveHandler.GetCVarBool('vuos_auto_enabled', fp, true);
        prevKeys = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_keys', fp, CAT_PRIMARY);
        prevPuzzle = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_puzzleitems', fp, CAT_PRIMARY);
        prevBosses = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_bosses', fp, CAT_PRIMARY);
        prevExit = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_exit', fp, CAT_PRIMARY);
        prevSecretExit = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_secretexit', fp, CAT_SECONDARY);
        prevKills = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_kills', fp, CAT_SECONDARY);
        prevSecrets = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_secrets', fp, CAT_SECONDARY);
        prevKillMode = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_kill_mode', fp, 0);
        prevWaypoints = VUOS_ObjectiveHandler.GetCVarBool('vuos_auto_waypoints', fp, true);
        prevSecretWaypoints = VUOS_ObjectiveHandler.GetCVarBool('vuos_auto_secret_waypoints', fp, false);
    }

    void CheckCVarChanges()
    {
        PlayerInfo fp = GetFirstPlayerForCVars();
        if (!fp) return;

        bool curEnabled = VUOS_ObjectiveHandler.GetCVarBool('vuos_auto_enabled', fp, true);
        int curKeys = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_keys', fp, CAT_PRIMARY);
        int curPuzzle = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_puzzleitems', fp, CAT_PRIMARY);
        int curBosses = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_bosses', fp, CAT_PRIMARY);
        int curExit = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_exit', fp, CAT_PRIMARY);
        int curSecretExit = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_secretexit', fp, CAT_SECONDARY);
        int curKills = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_kills', fp, CAT_SECONDARY);
        int curSecrets = VUOS_ObjectiveHandler.GetCVarInt('vuos_auto_secrets', fp, CAT_SECONDARY);
        bool curSecretWaypoints = VUOS_ObjectiveHandler.GetCVarBool('vuos_auto_secret_waypoints', fp, false);

        bool changed = (curEnabled != prevEnabled || curKeys != prevKeys || curPuzzle != prevPuzzle
            || curBosses != prevBosses || curExit != prevExit || curSecretExit != prevSecretExit
            || curKills != prevKills || curSecrets != prevSecrets || curSecretWaypoints != prevSecretWaypoints);

        if (changed)
        {
            if (VUOS_ObjectiveHandler.IsDebugEnabled())
            {
                Console.Printf("DEBUG AUTO: CVar change detected! Regenerating...");
                Console.Printf("DEBUG AUTO:   enabled=%d/%d keys=%d/%d puzzle=%d/%d bosses=%d/%d",
                    curEnabled, prevEnabled, curKeys, prevKeys, curPuzzle, prevPuzzle, curBosses, prevBosses);
                Console.Printf("DEBUG AUTO:   exit=%d/%d secExit=%d/%d kills=%d/%d secrets=%d/%d secWp=%d/%d",
                    curExit, prevExit, curSecretExit, prevSecretExit, curKills, prevKills,
                    curSecrets, prevSecrets, curSecretWaypoints, prevSecretWaypoints);
            }

            // Clear all auto-objectives and regenerate
            ClearAutoObjectives();
            if (curEnabled && !IsMapSuppressed(level.MapName))
            {
                GenerateAll();
            }
            CacheCVarStates();
        }
    }

    // ================================================================
    // UTILITY METHODS
    // ================================================================

    // Clear only auto-generated objectives (leave manual objectives untouched)
    void ClearAutoObjectives()
    {
        let handler = VUOS_ObjectiveHandler.GetSetupHandler();
        if (!handler) return;

        for (int i = handler.objectives.Size() - 1; i >= 0; i--)
        {
            let obj = handler.objectives[i];
            if (obj.isAutoGenerated)
            {
                // Destroy markers
                VUOS_ObjectiveHandler.DestroyAllMarkers(obj);
                handler.objectives.Delete(i);
            }
        }

        // Clear secret sector tracking
        secretSectorIndices.Clear();
        secretSectorX.Clear();
        secretSectorY.Clear();
        secretSectorZ.Clear();
    }

    // Find an auto-generated objective by description prefix
    VUOS_ObjectiveData FindAutoObjective(VUOS_ObjectiveHandler handler, String descPrefix)
    {
        for (int i = 0; i < handler.objectives.Size(); i++)
        {
            let obj = handler.objectives[i];
            if (obj.isAutoGenerated && obj.objectiveDescription.IndexOf(descPrefix) == 0)
                return obj;
        }
        return null;
    }

    // Check if a manual objective already exists with the given target class
    bool HasExistingObjectiveForClass(String className)
    {
        let handler = VUOS_ObjectiveHandler.GetSetupHandler();
        if (!handler) return false;

        name targetName = className;
        for (int i = 0; i < handler.objectives.Size(); i++)
        {
            let obj = handler.objectives[i];
            if (!obj.isAutoGenerated && obj.targetClass == targetName
                && obj.mapName ~== level.MapName)
                return true;
        }
        return false;
    }

    // Clean up a class name into readable text
    // e.g., "RedCard" -> "Red Card", "YellowSkull" -> "Yellow Skull"
    static String CleanClassName(String className)
    {
        String result = "";
        for (int i = 0; i < className.Length(); i++)
        {
            String ch = className.CharAt(i);
            int code = className.CharCodeAt(i);

            // Insert space before uppercase letters (but not at start)
            if (i > 0 && code >= 65 && code <= 90)
            {
                // Check if previous char was lowercase
                int prevCode = className.CharCodeAt(i - 1);
                if (prevCode >= 97 && prevCode <= 122)
                {
                    result = result .. " ";
                }
            }
            result = result .. ch;
        }
        return result;
    }

    // Restore tracking state from existing auto-objectives after save load
    void RestoreTrackingState()
    {
        let handler = VUOS_ObjectiveHandler.GetSetupHandler();
        if (!handler) return;

        for (int i = 0; i < handler.objectives.Size(); i++)
        {
            let obj = handler.objectives[i];
            if (!obj.isAutoGenerated) continue;

            // Restore kill tracking state
            if (obj.objectiveDescription.IndexOf("Kill all enemies") == 0)
            {
                fixedKillTarget = obj.targetCount;
                lastKillCount = obj.currentCount;
                hasGenerated = true;
            }
            // Restore secret tracking state
            else if (obj.objectiveDescription.IndexOf("Find all secrets") == 0 || obj.objectiveDescription.IndexOf("Find the secret") == 0)
            {
                lastFoundSecrets = obj.currentCount;
                hasGenerated = true;
            }
            // Any auto-objective means we were active
            else
            {
                hasGenerated = true;
            }
        }

        if (hasGenerated) CacheCVarStates();
    }

    // ================================================================
    // CONSOLE COMMAND — vuos_auto_list
    // ================================================================

    // Dumps detection results and generated objectives for debugging
    static void DumpAutoList()
    {
        let handler = VUOS_ObjectiveHandler.GetSetupHandler();
        if (!handler)
        {
            Console.Printf("No objective handler found");
            return;
        }

        Console.Printf("\c[Gold]===== VUOS Auto-Objectives Debug =====");
        Console.Printf("Map: %s", level.MapName);
        Console.Printf("Suppressed: %s", IsMapSuppressed(level.MapName) ? "YES" : "No");
        Console.Printf("");

        // Count auto vs manual objectives
        int autoCount = 0, manualCount = 0;
        for (int i = 0; i < handler.objectives.Size(); i++)
        {
            if (handler.objectives[i].isAutoGenerated)
                autoCount++;
            else
                manualCount++;
        }

        Console.Printf("Manual objectives: %d", manualCount);
        Console.Printf("Auto-generated objectives: %d", autoCount);
        Console.Printf("");

        // List auto objectives
        if (autoCount > 0)
        {
            Console.Printf("\c[Green]Auto-Generated:");
            for (int i = 0; i < handler.objectives.Size(); i++)
            {
                let obj = handler.objectives[i];
                if (!obj.isAutoGenerated) continue;

                String status = obj.isCompleted ? "\c[Green][DONE]" : (obj.hasFailed ? "\c[Red][FAIL]" : "\c[White][    ]");
                String priority = obj.isPrimary ? "PRI" : "SEC";
                String progress = "";
                if (obj.targetCount > 1)
                    progress = String.Format(" (%d/%d)", obj.currentCount, obj.targetCount);

                String wpInfo = "";
                if (obj.hasWaypoint)
                {
                    int posCount = obj.GetWaypointPositionCount();
                    if (posCount > 1)
                        wpInfo = String.Format(" [%d waypoints]", posCount);
                    else
                        wpInfo = String.Format(" [wp: %.0f,%.0f,%.0f]", obj.waypointPos.X, obj.waypointPos.Y, obj.waypointPos.Z);
                }

                Console.Printf("  %s [%s] %s%s%s", status, priority, obj.objectiveDescription, progress, wpInfo);
            }
        }

        // Map scan info
        Console.Printf("");
        Console.Printf("\c[Cyan]Map Statistics:");
        Console.Printf("  Total monsters: %d (killed: %d)", level.total_monsters, level.killed_monsters);
        Console.Printf("  Total secrets: %d (found: %d)", level.total_secrets, level.found_secrets);

        // Count exit lines
        int normalExits = 0, secretExits = 0;
        for (int i = 0; i < level.Lines.Size(); i++)
        {
            if (IsNormalExitSpecial(level.Lines[i].special)) normalExits++;
            if (IsSecretExitSpecial(level.Lines[i].special)) secretExits++;
        }
        Console.Printf("  Normal exit lines: %d", normalExits);
        Console.Printf("  Secret exit lines: %d", secretExits);

        // Count bosses
        int bossCount = 0;
        let it = ThinkerIterator.Create("Actor");
        Actor act;
        while (act = Actor(it.Next()))
        {
            if (act.bBOSS && act.Health > 0) bossCount++;
        }
        Console.Printf("  Active bosses: %d", bossCount);

        Console.Printf("\c[Gold]===================================");
    }
}
