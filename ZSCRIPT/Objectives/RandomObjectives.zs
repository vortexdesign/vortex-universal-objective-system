// RandomObjectives.zs
// Seeded random layer on top of AutoObjectives. Owns:
//   - Per-map seed derivation (FNV-1a hash of map name + skill + user salt)
//   - Deterministic LCG RNG for category chance rolls, subset sampling, elite picks
//   - Modder override APIs: ForceCategoryRoll, ForceEliteClass (per-map overrides)
//   - Roll result cache for debug introspection and stable queries
//   - Mid-map CVar change detection for vuos_random_* group
//
// Registration order: ObjectiveSetup (0) -> VUOS_RandomObjectives (5) -> VUOS_AutoObjectives (10)
// The split handler design means removing this file's #include and ZMAPINFO entry
// fully disables the random layer with zero behavior change in AutoObjectives.

class VUOS_RandomObjectives : EventHandler
{
    // ================================================================
    // CATEGORY CONSTANTS (for categoryRollPassed array indices and
    // ResolveCategoryRoll lookups)
    // ================================================================
    const CAT_IDX_KEYS        = 0;
    const CAT_IDX_PUZZLEITEMS = 1;
    const CAT_IDX_BOSSES      = 2;
    const CAT_IDX_EXIT        = 3;
    const CAT_IDX_SECRETEXIT  = 4;
    const CAT_IDX_KILLS       = 5;
    const CAT_IDX_SECRETS     = 6;
    const CAT_COUNT           = 7;

    // ================================================================
    // STATE
    // ================================================================

    // Seeded RNG state. EventHandler fields serialize with savegames.
    uint randomSeedState;
    uint randomSeedOriginal;
    bool randomSeedInitialized;

    // Cached roll results for this map. Populated lazily by ResolveCategoryRoll.
    Array<bool> categoryRollPassed;
    Array<bool> categoryRollResolved;  // Per-slot flag so we only roll once per category per map
    bool eliteRollPassed;
    bool eliteRollResolved;
    String eliteSelectedClass;

    // Modder overrides (parallel arrays keyed by mapName)
    Array<String> forcedEliteMapNames;
    Array<String> forcedEliteClassNames;

    // Modder overrides (parallel arrays keyed by mapName + categoryName)
    Array<String> forcedRollMapNames;
    Array<String> forcedRollCategories;
    Array<bool> forcedRollResults;

    // CVar change detection for mid-map regeneration
    int prevSeedSalt;
    int prevEliteChance;
    int prevElitePriority;
    int prevMinFloor;
    bool prevSkillWeighting;
    Array<int> prevCategoryChances;
    Array<int> prevSampleCounts;
    bool randomCVarCacheReady;
    bool prevEnabled;

    // ================================================================
    // INITIALIZATION
    // ================================================================

    override void OnRegister()
    {
        // Initialize arrays to fixed size so index lookups are safe before
        // first roll resolution
        categoryRollPassed.Resize(CAT_COUNT);
        categoryRollResolved.Resize(CAT_COUNT);
        prevCategoryChances.Resize(CAT_COUNT);
        prevSampleCounts.Resize(3);  // Only keys, puzzle, bosses have sample counts

        for (int i = 0; i < CAT_COUNT; i++)
        {
            categoryRollPassed[i] = false;
            categoryRollResolved[i] = false;
        }

        eliteRollResolved = false;
        eliteRollPassed = false;
        eliteSelectedClass = "";
        randomSeedInitialized = false;
        randomCVarCacheReady = false;
    }

    // ================================================================
    // CATEGORY NAME LOOKUP
    // ================================================================

    // Map a category name string to its array index, or -1 if unknown
    static int CategoryNameToIndex(String categoryName)
    {
        String cat = categoryName.MakeLower();
        if (cat ~== "keys")        return CAT_IDX_KEYS;
        if (cat ~== "puzzleitems") return CAT_IDX_PUZZLEITEMS;
        if (cat ~== "bosses")      return CAT_IDX_BOSSES;
        if (cat ~== "exit")        return CAT_IDX_EXIT;
        if (cat ~== "secretexit")  return CAT_IDX_SECRETEXIT;
        if (cat ~== "kills")       return CAT_IDX_KILLS;
        if (cat ~== "secrets")     return CAT_IDX_SECRETS;
        return -1;
    }

    // Map a category name string to its chance CVar name. Returns 'none' if unknown.
    static name CategoryNameToChanceCVar(String categoryName)
    {
        String cat = categoryName.MakeLower();
        if (cat ~== "keys")        return 'vuos_random_chance_keys';
        if (cat ~== "puzzleitems") return 'vuos_random_chance_puzzleitems';
        if (cat ~== "bosses")      return 'vuos_random_chance_bosses';
        if (cat ~== "exit")        return 'vuos_random_chance_exit';
        if (cat ~== "secretexit")  return 'vuos_random_chance_secretexit';
        if (cat ~== "kills")       return 'vuos_random_chance_kills';
        if (cat ~== "secrets")     return 'vuos_random_chance_secrets';
        return 'none';
    }

    // ================================================================
    // HANDLER LOOKUP (clearscope so UI code can use it too if needed)
    // ================================================================

    clearscope static VUOS_RandomObjectives GetHandler()
    {
        return VUOS_RandomObjectives(EventHandler.Find("VUOS_RandomObjectives"));
    }

    // ================================================================
    // DEBUG INTROSPECTION
    // ================================================================

    static uint GetCurrentSeed()
    {
        let h = GetHandler();
        return h ? h.randomSeedOriginal : 0;
    }

    static bool DidCategoryRoll(String categoryName)
    {
        let h = GetHandler();
        if (!h) return false;
        int idx = CategoryNameToIndex(categoryName);
        if (idx < 0) return false;
        return h.categoryRollPassed[idx];
    }

    // ================================================================
    // RESET TO DEFAULTS - now handled in KEYCONF.txt
    // ================================================================
    //
    // The ZScript ResetToDefaults static method has been removed because
    // CVar.SetInt() and CVar.ResetToDefault() called from a netevent context
    // do not reliably persist user-scope CVars across game restarts. The
    // userinfo CVar wrapper (returned by CVar.GetCVar with a PlayerInfo) does
    // not propagate the change through to the INI write path the same way
    // the console `set` command does.
    //
    // The vuos_random_reset alias in KEYCONF.txt now emits chained `set`
    // commands directly, which uses the same code path the user uses when
    // typing `set vuos_random_chance_kills 60` manually (and that path is
    // known to persist correctly).
    //
    // If new CVars are added to the random layer, update the chained alias
    // in KEYCONF.txt to include them.

    // ================================================================
    // STUBS (filled in subsequent rollout steps)
    // ================================================================
    //
    // These return safe defaults so AutoObjectives calls during early
    // testing behave exactly like vuos_random_enabled was off. Actual
    // logic lands in later rollout steps.

    // ================================================================
    // SEEDING (FNV-1a hash for derivation, LCG for rolling)
    // ================================================================
    //
    // Why custom RNG and not GZDoom's random(): the global random stream
    // cannot be seeded from ZScript and would be polluted by unrelated
    // mod calls so we own the state explicitly. FNV-1a + LCG gives us
    // deterministic, reproducible rolls keyed to map name + skill + salt.

    // Pure function. Derives a uint32 seed from the inputs using FNV-1a hash.
    static uint ComputeSeed(String mapName, int skill, int userSalt)
    {
        uint hash = 2166136261;  // FNV offset basis
        for (int i = 0; i < mapName.Length(); i++)
        {
            hash ^= uint(mapName.CharCodeAt(i));
            hash *= 16777619;     // FNV prime
        }
        hash ^= uint(skill);
        hash *= 16777619;
        hash ^= uint(userSalt);
        hash *= 16777619;
        return hash;
    }

    // Reseed for the current map, skill, and user salt. Called from WorldLoaded
    // on fresh map load and from CVar change detection when the salt changes.
    static void Reseed()
    {
        let h = GetHandler();
        if (!h) return;

        PlayerInfo fp = VUOS_AutoObjectives.GetFirstPlayerForCVars();
        int salt = fp ? VUOS_ObjectiveHandler.GetCVarInt('vuos_random_seed_salt', fp, 0) : 0;
        int skill = G_SkillPropertyInt(SKILLP_ACSReturn);

        h.randomSeedOriginal = ComputeSeed(level.MapName, skill, salt);
        h.randomSeedState = h.randomSeedOriginal;
        h.randomSeedInitialized = true;

        // Clear roll cache so next ResolveCategoryRoll calls re-roll with new seed
        for (int i = 0; i < CAT_COUNT; i++)
        {
            h.categoryRollPassed[i] = false;
            h.categoryRollResolved[i] = false;
        }
        h.eliteRollResolved = false;
        h.eliteRollPassed = false;
        h.eliteSelectedClass = "";

        if (VUOS_ObjectiveHandler.IsDebugEnabled())
            Console.Printf("VUOS RANDOM: Reseeded for map=%s skill=%d salt=%d -> seed=%u",
                level.MapName, skill, salt, h.randomSeedOriginal);
    }

    // Advance the LCG and return an int in [min, max] inclusive.
    // Numerical Recipes constants (multiplier 1664525, increment 1013904223).
    static int SeededRangeRoll(int min, int max)
    {
        let h = GetHandler();
        if (!h) return min;
        if (max <= min) return min;

        h.randomSeedState = h.randomSeedState * 1664525 + 1013904223;
        uint range = uint(max - min + 1);
        return min + int(h.randomSeedState % range);
    }

    // Returns true with `percent`% probability (0-100). Edge cases:
    //   percent <= 0  -> always false (no advance of stream)
    //   percent >= 100 -> always true (no advance of stream)
    // Note: short-circuiting at the extremes means the LCG state doesn't
    // advance for those calls, which keeps roll outcomes stable when CVars
    // are at default extremes vs slight tweaks
    static bool SeededChanceRoll(int percent)
    {
        if (percent <= 0) return false;
        if (percent >= 100) return true;
        return SeededRangeRoll(1, 100) <= percent;
    }

    // ================================================================
    // CATEGORY ROLL RESOLUTION
    // ================================================================
    //
    // Returns true if AutoObjectives should generate this category on the
    // current map, false if it should skip. Resolution order:
    //   1. If vuos_random_enabled is false, always return true (no-op pass-through)
    //   2. Return cached result if this category was already resolved this map
    //   3. Check ForceCategoryRoll override - if set, use that and cache
    //   4. Otherwise roll the chance CVar with the seeded LCG and cache
    //
    // Unknown category names always return true (safe fallback) and log a debug warning

    static bool ResolveCategoryRoll(String categoryName)
    {
        let h = GetHandler();
        if (!h) return true;  // No random handler = no-op pass-through

        PlayerInfo fp = VUOS_AutoObjectives.GetFirstPlayerForCVars();
        if (!fp) return true;

        bool enabled = VUOS_ObjectiveHandler.GetCVarBool('vuos_random_enabled', fp, false);
        if (!enabled) return true;  // Random layer disabled = no-op pass-through

        int idx = CategoryNameToIndex(categoryName);
        if (idx < 0)
        {
            if (VUOS_ObjectiveHandler.IsDebugEnabled())
                Console.Printf("VUOS RANDOM: ResolveCategoryRoll unknown category '%s' (returning true)", categoryName);
            return true;
        }

        // Return cached result if already resolved this map
        if (h.categoryRollResolved[idx]) return h.categoryRollPassed[idx];

        // Check modder override first
        int forced = GetForcedCategoryRoll(level.MapName, categoryName);
        bool result;
        if (forced == 1)
        {
            result = true;
            if (VUOS_ObjectiveHandler.IsDebugEnabled())
                Console.Printf("VUOS RANDOM: %s forced PASS by modder override", categoryName);
        }
        else if (forced == 2)
        {
            result = false;
            if (VUOS_ObjectiveHandler.IsDebugEnabled())
                Console.Printf("VUOS RANDOM: %s forced SKIP by modder override", categoryName);
        }
        else
        {
            // Standard chance roll
            name chanceCVar = CategoryNameToChanceCVar(categoryName);
            int chance = VUOS_ObjectiveHandler.GetCVarInt(chanceCVar, fp, 100);
            result = SeededChanceRoll(chance);
            if (VUOS_ObjectiveHandler.IsDebugEnabled())
                Console.Printf("VUOS RANDOM: %s chance roll %d%% -> %s", categoryName, chance, result ? "PASS" : "SKIP");
        }

        h.categoryRollPassed[idx] = result;
        h.categoryRollResolved[idx] = true;
        return result;
    }

    // ================================================================
    // ELITE TIER RESOLUTION
    // ================================================================
    //
    // Returns the class name to use as the elite (bounty) target, or "" if no
    // elite this map. Sentinel value "_KILLALL_" means "no candidates of any
    // tier exist, fall back to a clear-the-map bounty."
    //
    // Resolution order:
    //   1. If already resolved this map, return cached value
    //   2. If random layer disabled or roll fails, cache "" and return ""
    //   3. If modder ForceEliteClass override is set AND that class is on map, use it
    //   4. Otherwise tier priority: boss > key > puzzle > _KILLALL_ sentinel
    //
    // Skill weighting (vuos_random_skill_weighting): if enabled, multiplies the
    // base elite chance by 0.5 (skill 0/ITYTD) to 1.75 (skill 4/Nightmare) linearly.

    static String ResolveEliteClass(Array<String> bossCandidates, Array<String> keyCandidates, Array<String> puzzleCandidates)
    {
        let h = GetHandler();
        if (!h) return "";

        // Return cached result if already resolved this map
        if (h.eliteRollResolved) return h.eliteSelectedClass;

        h.eliteRollResolved = true;

        PlayerInfo fp = VUOS_AutoObjectives.GetFirstPlayerForCVars();
        if (!fp) return "";

        bool enabled = VUOS_ObjectiveHandler.GetCVarBool('vuos_random_enabled', fp, false);
        if (!enabled) return "";

        // Roll elite chance with optional skill weighting
        int baseChance = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_elite_chance', fp, 10);
        bool skillWeight = VUOS_ObjectiveHandler.GetCVarBool('vuos_random_skill_weighting', fp, true);
        int effectiveChance = baseChance;
        if (skillWeight)
        {
            int skill = G_SkillPropertyInt(SKILLP_ACSReturn);
            // Skill 0 (ITYTD) -> 0.5x, Skill 4 (Nightmare) -> 1.75x, linear
            double mult = 0.5 + (double(skill) / 4.0) * 1.25;
            effectiveChance = int(double(baseChance) * mult);
            if (effectiveChance > 100) effectiveChance = 100;
            if (effectiveChance < 0) effectiveChance = 0;
        }

        h.eliteRollPassed = SeededChanceRoll(effectiveChance);

        if (VUOS_ObjectiveHandler.IsDebugEnabled())
            Console.Printf("VUOS RANDOM: Elite roll %d%% (base %d%%, skillWeight=%d) -> %s",
                effectiveChance, baseChance, skillWeight, h.eliteRollPassed ? "PASS" : "SKIP");

        if (!h.eliteRollPassed) return "";

        // Check modder override and verify the forced class is actually on this map
        String forced = GetForcedEliteClass(level.MapName);
        if (forced.Length() > 0)
        {
            bool found = false;
            for (int i = 0; i < bossCandidates.Size(); i++)
                if (bossCandidates[i] ~== forced) { found = true; break; }
            if (!found) for (int i = 0; i < keyCandidates.Size(); i++)
                if (keyCandidates[i] ~== forced) { found = true; break; }
            if (!found) for (int i = 0; i < puzzleCandidates.Size(); i++)
                if (puzzleCandidates[i] ~== forced) { found = true; break; }

            if (found)
            {
                h.eliteSelectedClass = forced;
                if (VUOS_ObjectiveHandler.IsDebugEnabled())
                    Console.Printf("VUOS RANDOM: Elite forced to %s by modder override", forced);
                return forced;
            }

            if (VUOS_ObjectiveHandler.IsDebugEnabled())
                Console.Printf("VUOS RANDOM: Forced elite class '%s' not on map, falling back to tier selection", forced);
        }

        // Tier-based random selection: boss > key > puzzle > _KILLALL_ sentinel
        if (bossCandidates.Size() > 0)
        {
            int idx = SeededRangeRoll(0, bossCandidates.Size() - 1);
            h.eliteSelectedClass = bossCandidates[idx];
        }
        else if (keyCandidates.Size() > 0)
        {
            int idx = SeededRangeRoll(0, keyCandidates.Size() - 1);
            h.eliteSelectedClass = keyCandidates[idx];
        }
        else if (puzzleCandidates.Size() > 0)
        {
            int idx = SeededRangeRoll(0, puzzleCandidates.Size() - 1);
            h.eliteSelectedClass = puzzleCandidates[idx];
        }
        else
        {
            h.eliteSelectedClass = "_KILLALL_";
        }

        if (VUOS_ObjectiveHandler.IsDebugEnabled())
            Console.Printf("VUOS RANDOM: Elite selected: %s", h.eliteSelectedClass);

        return h.eliteSelectedClass;
    }

    // ================================================================
    // SUBSET SAMPLING (Fisher-Yates partial shuffle, seeded)
    // ================================================================
    //
    // Shuffles the first k elements of arr in place using SeededRangeRoll
    // and truncates to k entries. Picks K random elements without replacement
    // from the original N elements.
    //
    // If k >= arr.Size() or k <= 0, returns arr unchanged so callers can pass
    // user CVar values without bounds checking. If random handler is missing,
    // arr is left unchanged (no shuffle).

    static void SeededPartialShuffle(in out Array<String> arr, int k)
    {
        let h = GetHandler();
        if (!h) return;

        // No-op when random layer is disabled. Caller gets full unshuffled array
        // so existing deterministic behavior is preserved.
        PlayerInfo fp = VUOS_AutoObjectives.GetFirstPlayerForCVars();
        if (!fp) return;
        if (!VUOS_ObjectiveHandler.GetCVarBool('vuos_random_enabled', fp, false)) return;

        int n = arr.Size();
        if (k <= 0 || k >= n) return;

        for (int i = 0; i < k; i++)
        {
            int j = i + SeededRangeRoll(0, n - i - 1);
            if (j != i)
            {
                String tmp = arr[i];
                arr[i] = arr[j];
                arr[j] = tmp;
            }
        }
        arr.Resize(k);

        if (VUOS_ObjectiveHandler.IsDebugEnabled())
            Console.Printf("VUOS RANDOM: Subset sampled %d of %d candidates", k, n);
    }

    // ================================================================
    // MODDER OVERRIDE: ForceCategoryRoll
    // ================================================================
    //
    // Pin a category roll outcome on a specific map. Called from
    // ObjectiveSetup.WorldLoaded.
    //
    // Parameters:
    //   mapName: target map (e.g. "MAP30", "E1M8")
    //   categoryName: keys, puzzleitems, bosses, exit, secretexit, kills, secrets
    //   result: true = always pass (force generate), false = always skip
    //
    // The player's vuos_auto_<category> on/off CVar still controls whether the
    // category is enabled at all. ForceCategoryRoll only overrides the random
    // chance roll, not the master category toggle.

    static void ForceCategoryRoll(String mapName, String categoryName, bool result)
    {
        let h = GetHandler();
        if (!h) return;

        // Validate category name early so unknown values get logged
        int idx = CategoryNameToIndex(categoryName);
        if (idx < 0)
        {
            if (VUOS_ObjectiveHandler.IsDebugEnabled())
                Console.Printf("VUOS RANDOM: ForceCategoryRoll unknown category '%s' (ignored)", categoryName);
            return;
        }

        String catLower = categoryName.MakeLower();

        // Overwrite existing entry if present
        for (int i = 0; i < h.forcedRollMapNames.Size(); i++)
        {
            if (h.forcedRollMapNames[i] ~== mapName
                && h.forcedRollCategories[i] ~== catLower)
            {
                h.forcedRollResults[i] = result;
                return;
            }
        }
        h.forcedRollMapNames.Push(mapName);
        h.forcedRollCategories.Push(catLower);
        h.forcedRollResults.Push(result);
    }

    // Returns: 0 = no override set, 1 = forced pass, 2 = forced skip
    static int GetForcedCategoryRoll(String mapName, String categoryName)
    {
        let h = GetHandler();
        if (!h) return 0;
        String catLower = categoryName.MakeLower();
        for (int i = 0; i < h.forcedRollMapNames.Size(); i++)
        {
            if (h.forcedRollMapNames[i] ~== mapName
                && h.forcedRollCategories[i] ~== catLower)
            {
                return h.forcedRollResults[i] ? 1 : 2;
            }
        }
        return 0;
    }

    // ================================================================
    // MODDER OVERRIDE: ForceEliteClass (stubs filled in step 9)
    // ================================================================

    static void ForceEliteClass(String mapName, String className)
    {
        let h = GetHandler();
        if (!h) return;

        for (int i = 0; i < h.forcedEliteMapNames.Size(); i++)
        {
            if (h.forcedEliteMapNames[i] ~== mapName)
            {
                h.forcedEliteClassNames[i] = className;
                return;
            }
        }
        h.forcedEliteMapNames.Push(mapName);
        h.forcedEliteClassNames.Push(className);
    }

    static String GetForcedEliteClass(String mapName)
    {
        let h = GetHandler();
        if (!h) return "";
        for (int i = 0; i < h.forcedEliteMapNames.Size(); i++)
        {
            if (h.forcedEliteMapNames[i] ~== mapName)
                return h.forcedEliteClassNames[i];
        }
        return "";
    }

    // ================================================================
    // WORLD LOADED
    // ================================================================

    override void WorldLoaded(WorldEvent e)
    {
        if (VUOS_ObjectiveHandler.IsDebugEnabled())
            Console.Printf("VUOS RANDOM: WorldLoaded fired (isSaveGame=%d, map=%s)", e.IsSaveGame, level.MapName);

        // Reset per-map roll cache on fresh map load
        if (!e.IsSaveGame)
        {
            for (int i = 0; i < CAT_COUNT; i++)
            {
                categoryRollPassed[i] = false;
                categoryRollResolved[i] = false;
            }
            eliteRollResolved = false;
            eliteRollPassed = false;
            eliteSelectedClass = "";
            randomSeedInitialized = false;

            // Compute seed for this map. Roll resolution happens lazily as
            // AutoObjectives queries ResolveCategoryRoll and ResolveEliteClass.
            Reseed();

            // Reset CVar change detection so we re-cache baseline after the
            // initial AutoObjectives generation completes
            randomCVarCacheReady = false;
        }
        // Save load: skip Reseed because saved seedState restores from the savegame,
        // and AutoObjectives skips regeneration on save load anyway (objectives
        // come back from saved state). categoryRollPassed values also restore.
    }

    // ================================================================
    // MID-MAP CVAR CHANGE DETECTION
    // ================================================================
    //
    // Polls vuos_random_* CVars in WorldTick and triggers a full regeneration
    // when any of them change. Mirrors the same pattern AutoObjectives uses
    // for vuos_auto_* CVars (delayed cache + per-tick comparison).
    //
    // On detected change:
    //   1. Reseed (recomputes seed from map+skill+salt, clears roll cache)
    //   2. Call VUOS_AutoObjectives.TriggerRegenerate() which clears auto
    //      objectives and regenerates with the new seed and chance values
    //   3. Re-cache CVar baseline so the next change is detectable

    override void WorldTick()
    {
        // Skip until baseline is cached and seed is initialized
        if (!randomSeedInitialized) return;

        if (!randomCVarCacheReady)
        {
            // Wait a few ticks after WorldLoaded so the CVar reads are stable
            // (matches AutoObjectives' 5-tick delay pattern)
            if (level.maptime < 8) return;
            CacheRandomCVarStates();
            randomCVarCacheReady = true;
            if (VUOS_ObjectiveHandler.IsDebugEnabled())
                Console.Printf("VUOS RANDOM: CVar baseline cached at tick %d", level.maptime);
            return;
        }

        CheckRandomCVarChanges();
    }

    void CacheRandomCVarStates()
    {
        PlayerInfo fp = VUOS_AutoObjectives.GetFirstPlayerForCVars();
        if (!fp) return;

        prevEnabled = VUOS_ObjectiveHandler.GetCVarBool('vuos_random_enabled', fp, false);
        prevSeedSalt = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_seed_salt', fp, 0);
        prevMinFloor = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_min_floor', fp, 1);
        prevSkillWeighting = VUOS_ObjectiveHandler.GetCVarBool('vuos_random_skill_weighting', fp, true);
        prevEliteChance = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_elite_chance', fp, 10);
        prevElitePriority = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_elite_priority', fp, 2);

        prevCategoryChances[CAT_IDX_KEYS]        = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_chance_keys', fp, 90);
        prevCategoryChances[CAT_IDX_PUZZLEITEMS] = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_chance_puzzleitems', fp, 90);
        prevCategoryChances[CAT_IDX_BOSSES]      = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_chance_bosses', fp, 75);
        prevCategoryChances[CAT_IDX_EXIT]        = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_chance_exit', fp, 100);
        prevCategoryChances[CAT_IDX_SECRETEXIT]  = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_chance_secretexit', fp, 50);
        prevCategoryChances[CAT_IDX_KILLS]       = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_chance_kills', fp, 60);
        prevCategoryChances[CAT_IDX_SECRETS]     = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_chance_secrets', fp, 60);

        prevSampleCounts[0] = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_sample_keys', fp, 0);
        prevSampleCounts[1] = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_sample_puzzleitems', fp, 0);
        prevSampleCounts[2] = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_sample_bosses', fp, 0);
    }

    void CheckRandomCVarChanges()
    {
        PlayerInfo fp = VUOS_AutoObjectives.GetFirstPlayerForCVars();
        if (!fp) return;

        bool curEnabled = VUOS_ObjectiveHandler.GetCVarBool('vuos_random_enabled', fp, false);
        int curSeedSalt = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_seed_salt', fp, 0);
        int curMinFloor = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_min_floor', fp, 1);
        bool curSkillWeighting = VUOS_ObjectiveHandler.GetCVarBool('vuos_random_skill_weighting', fp, true);
        int curEliteChance = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_elite_chance', fp, 10);
        int curElitePriority = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_elite_priority', fp, 2);

        bool changed = (curEnabled != prevEnabled
            || curSeedSalt != prevSeedSalt
            || curMinFloor != prevMinFloor
            || curSkillWeighting != prevSkillWeighting
            || curEliteChance != prevEliteChance
            || curElitePriority != prevElitePriority);

        // Check per-category chances
        if (!changed)
        {
            int curKeys        = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_chance_keys', fp, 90);
            int curPuzzle      = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_chance_puzzleitems', fp, 90);
            int curBosses      = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_chance_bosses', fp, 75);
            int curExit        = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_chance_exit', fp, 100);
            int curSecExit     = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_chance_secretexit', fp, 50);
            int curKills       = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_chance_kills', fp, 60);
            int curSecrets     = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_chance_secrets', fp, 60);

            changed = (curKeys != prevCategoryChances[CAT_IDX_KEYS]
                || curPuzzle != prevCategoryChances[CAT_IDX_PUZZLEITEMS]
                || curBosses != prevCategoryChances[CAT_IDX_BOSSES]
                || curExit != prevCategoryChances[CAT_IDX_EXIT]
                || curSecExit != prevCategoryChances[CAT_IDX_SECRETEXIT]
                || curKills != prevCategoryChances[CAT_IDX_KILLS]
                || curSecrets != prevCategoryChances[CAT_IDX_SECRETS]);
        }

        // Check sample counts
        if (!changed)
        {
            int curSampleK = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_sample_keys', fp, 0);
            int curSampleP = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_sample_puzzleitems', fp, 0);
            int curSampleB = VUOS_ObjectiveHandler.GetCVarInt('vuos_random_sample_bosses', fp, 0);

            changed = (curSampleK != prevSampleCounts[0]
                || curSampleP != prevSampleCounts[1]
                || curSampleB != prevSampleCounts[2]);
        }

        if (!changed) return;

        if (VUOS_ObjectiveHandler.IsDebugEnabled())
            Console.Printf("VUOS RANDOM: CVar change detected, reseeding and regenerating");

        // Recompute seed (uses new salt if changed) and clear roll cache
        Reseed();

        // Trigger AutoObjectives to clear and regenerate using the new state
        VUOS_AutoObjectives.TriggerRegenerate();

        // Re-cache so the next change is detectable
        CacheRandomCVarStates();
    }
}
