// ObjectiveAutomap.zs
// Automap marker actor for objective waypoints
// X mode: Frame A = Green (primary), Frame B = Cyan (secondary), Frame C = Grey (untracked)
// Numbered mode: VOM1-VOM9 sprites, Frame A = Green, Frame B = Cyan, Frame C = Grey

class VUOS_ObjectiveMarker : MapMarker
{
    Default
    {
        +NOBLOCKMAP
        +NOGRAVITY
        +DONTSPLASH
        +INVISIBLE
        Scale 0.5;
    }

    // Only the Spawn state is entered at runtime — SpawnMarker() then overrides
    // sprite/frame directly. All other labels serve as documentation of available
    // sprite/frame combinations:
    //   Frame A = primary/green
    //   Frame B = secondary/cyan
    //   Frame C = untracked/grey
    //   Frame D = completed/yellow (VOMK only)
    //   Frame E = failed/red (VOMK only)
    States
    {
        // X markers (default)
        Spawn:
            VOMK A -1;
            Stop;
        Secondary:
            VOMK B -1;
            Stop;
        Untracked:
            VOMK C -1;
            Stop;
        Completed:
            VOMK D -1;
            Stop;
        Failed:
            VOMK E -1;
            Stop;
        // Numbered markers (primary = green, secondary = cyan, untracked = grey)
        Num1:
            VOM1 A -1;
            Stop;
        Num1Sec:
            VOM1 B -1;
            Stop;
        Num1Unt:
            VOM1 C -1;
            Stop;
        Num2:
            VOM2 A -1;
            Stop;
        Num2Sec:
            VOM2 B -1;
            Stop;
        Num2Unt:
            VOM2 C -1;
            Stop;
        Num3:
            VOM3 A -1;
            Stop;
        Num3Sec:
            VOM3 B -1;
            Stop;
        Num3Unt:
            VOM3 C -1;
            Stop;
        Num4:
            VOM4 A -1;
            Stop;
        Num4Sec:
            VOM4 B -1;
            Stop;
        Num4Unt:
            VOM4 C -1;
            Stop;
        Num5:
            VOM5 A -1;
            Stop;
        Num5Sec:
            VOM5 B -1;
            Stop;
        Num5Unt:
            VOM5 C -1;
            Stop;
        Num6:
            VOM6 A -1;
            Stop;
        Num6Sec:
            VOM6 B -1;
            Stop;
        Num6Unt:
            VOM6 C -1;
            Stop;
        Num7:
            VOM7 A -1;
            Stop;
        Num7Sec:
            VOM7 B -1;
            Stop;
        Num7Unt:
            VOM7 C -1;
            Stop;
        Num8:
            VOM8 A -1;
            Stop;
        Num8Sec:
            VOM8 B -1;
            Stop;
        Num8Unt:
            VOM8 C -1;
            Stop;
        Num9:
            VOM9 A -1;
            Stop;
        Num9Sec:
            VOM9 B -1;
            Stop;
        Num9Unt:
            VOM9 C -1;
            Stop;
    }
}