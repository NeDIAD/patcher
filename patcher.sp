/*
    /ᐠ. ｡.ᐟ\ᵐᵉᵒʷˎˊ˗ 
    Credits: NeDIAD, imi-tat0r, dragos112 (hiraeeth), r4klatif, kRatoss
        https://forums.alliedmods.net/showthread.php?t=327591
        https://github.com/r4klatif/extended-angle-fix
        https://github.com/Alyx-Network/HvH-Essentials
        https://github.com/HvH-gg/CSGO-Essentials

    © Copyright 2026 NeDIAD    | GNU/GPL-3.0 License
    © Copyright 2026 hiraeeth  | GNU/GPL-3.0 License
    © Copyright 2024 imi-tat0r | MIT         License
    © Copyright 2022 r4klatif  | GNU/GPL-3.0 License
*/

#pragma semicolon 1
#pragma newdecls  required

#include <sourcemod>
#include <sdktools>
#include <dhooks>

public Plugin myinfo =
{
    name        = "Patcher",
    author      = "NeDIAD, imi-tat0r, r4klatif, dragos112, kRatoss, unknowncheats, other developers",
    description = "All-In-One patcher for most of CS:GO HvH exploits.",
    version     = "1.0.0",
    url         = "github.com/NeDIAD/Patcher"
}

/*
    Variables
*/

#define INT_MAX 2147483647

// convars, 1 = patch this exploit, 0 = do nothing
ConVar g_cvUntrustedAngles;
ConVar g_cvExtendedAngles;
ConVar g_cvAntiExploit;         // AX
ConVar g_cvAirStuck;
ConVar g_cvFakeDuck;            // FD
ConVar g_cvLagPeek;             // DT/Defensive-AA/LC
ConVar g_cvRoll;                // Roll / Body Lean

// air stuck
int g_iAirStuckTicks[MAXPLAYERS + 1];

// lagpeek
#define TELEPORT_MAX   256.0
#define SHOT_RECENT    0.5
#define TICK_TOLERANCE 64
#define AIRSTUCK_TICKS 16

DynamicDetour g_ddRecordDataIntoTrack;

int g_iTickOffset[MAXPLAYERS + 1];

float g_fLastSimulation[MAXPLAYERS + 1];
float g_fLastOrigin[MAXPLAYERS + 1][3];

/*
    Plugin Start
*/

public void OnPluginStart()
{
    g_cvUntrustedAngles = CreateConVar("patch_untrusted_angles", "0", "Set to '1', to clamp untrusted angles." , FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvExtendedAngles  = CreateConVar("patch_extended_angles" , "0", "Set to '1', to disable extended angles.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvAntiExploit     = CreateConVar("patch_anti_exploit"    , "0", "Set to '1', to disable anti-exploit."   , FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvAirStuck        = CreateConVar("patch_air_stuck"       , "0", "Set to '1', to prohibit air-stuck."     , FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvFakeDuck        = CreateConVar("patch_fake_duck"       , "0", "Set to '1', to disable fake duck."      , FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvLagPeek         = CreateConVar("patch_lagpeek"         , "0", "Set to '1', to disable lagpeek."        , FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvRoll            = CreateConVar("patch_roll"            , "0", "Set to '1', to disable body lean."      , FCVAR_NONE, true, 0.0, true, 1.0);

    SetupDetours();
    HookEvent("player_death", OnPlayerDeath);
}

/*
    Helpers
*/

stock float Clamp(float value, float min, float max)
{
    return value < min ? min : (value > max ? max : value);
}

bool IsValidClient(int client)
{
    return client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client);
}

bool IsAirStucking(float velocity[3], int buttons, int tickcount, int cmdnum)
{
    if ((cmdnum != INT_MAX || tickcount != INT_MAX) && tickcount != 0) return false;
    if (buttons & IN_ATTACK) return false;
    
    return velocity[0] == 0.0 && velocity[1] == 0.0 && velocity[2] == 0.0;
}

float GetShotTime(int client)
{
    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    return weapon != -1 ? GetEntPropFloat(weapon, Prop_Send, "m_fLastShotTime") : 0.0;
}


void ResetClient(int client)
{
    g_iAirStuckTicks[client]  = 0;
    g_iTickOffset[client]     = 0;
    g_fLastSimulation[client] = 0.0;
    
    g_fLastOrigin[client][0] = 0.0;
    g_fLastOrigin[client][1] = 0.0;
    g_fLastOrigin[client][2] = 0.0;
}

/*
    Functions
*/

void SetupDetours()
{
    GameData signatures = new GameData("patcher.games"); // gamedata/patcher.games.txt
    if (signatures == null)
        SetFailState("Failed to load gamedata! Please put 'patcher.games.txt' into 'gamedata' folder.");

    Address address = signatures.GetMemSig("RecordDataIntoTrack");
    if (address == Address_Null)
        SetFailState("Failed to find signature! 'RecordDataIntoTrack' is missing / wrong.");

    g_ddRecordDataIntoTrack = new DynamicDetour(address, CallConv_THISCALL, ReturnType_Void, ThisPointer_Ignore);

    g_ddRecordDataIntoTrack.AddParam(HookParamType_CBaseEntity);
    g_ddRecordDataIntoTrack.AddParam(HookParamType_Int);
    g_ddRecordDataIntoTrack.AddParam(HookParamType_Bool);

    g_ddRecordDataIntoTrack.Enable(Hook_Pre, RecordDataIntoTrackPre);
}

/*
    Events
*/

// long ass arguments
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (!IsValidClient(client) || !IsPlayerAlive(client)) return Plugin_Continue; // skip dead
    
    // untrusted angles fix
    if (g_cvUntrustedAngles.BoolValue)
    {
        angles[0] = Clamp(angles[0], -89.0,  89.0);     // pitch
        angles[1] = Clamp(angles[1], -180.0, 180.0);    // yaw
        angles[2] = Clamp(angles[2], -90.0,  90.0);     // roll
    }
    
    // anti exploit fix
    if (g_cvAntiExploit.BoolValue && !GetEntProp(client, Prop_Data, "m_bLagCompensation"))
        SetEntProp(client, Prop_Data, "m_bLagCompensation", 1);

    // fake duck fix
    if (g_cvFakeDuck.BoolValue && buttons & IN_BULLRUSH)
        buttons &= ~IN_BULLRUSH;

    // roll fix
    if (g_cvRoll.BoolValue && angles[2] != 0)
        angles[2] = 0.0;

    // air stuck fix
    if (!g_cvAirStuck.BoolValue || !IsAirStucking(vel, buttons, tickcount, cmdnum))
        g_iAirStuckTicks[client] = 0;
    else if (++g_iAirStuckTicks[client] >= AIRSTUCK_TICKS) {
        ForcePlayerSuicide(client);
        g_iAirStuckTicks[client] = 0;
    }

    // lagpeek
    g_iTickOffset[client] = tickcount - GetGameTickCount();
        
    return Plugin_Changed;
}

// long ass arguments x2
public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
    if (!g_cvExtendedAngles.BoolValue || !IsValidClient(client)) return; // skip disabled

    float eye_angles[3];
    float v_angle[3];

    GetEntPropVector(client, Prop_Data, "v_angle", v_angle);

    eye_angles[0] = GetEntPropFloat(client, Prop_Send, "m_angEyeAngles[0]");
    eye_angles[1] = GetEntPropFloat(client, Prop_Send, "m_angEyeAngles[1]");
    eye_angles[2] = v_angle[2];

    SetEntPropVector(client, Prop_Data, "v_angle", eye_angles);
}

public MRESReturn RecordDataIntoTrackPre(DHookParam params)
{
    if (!g_cvLagPeek.BoolValue) return MRES_Ignored;

    int client = params.Get(1);
    if (!IsValidClient(client)) return MRES_Ignored;

    float sim = GetEntPropFloat(client, Prop_Data, "m_flSimulationTime");

    float origin[3];
    GetEntPropVector(client, Prop_Send, "m_vecOrigin", origin);

    float dx = origin[0] - g_fLastOrigin[client][0];
    float dy = origin[1] - g_fLastOrigin[client][1];
    float dz = origin[2] - g_fLastOrigin[client][2];
    
    float move_sq = dx * dx + dy * dy;

    bool defensive = sim <= g_fLastSimulation[client]
        && (move_sq > 0.0 || dz != 0.0)
        && move_sq < TELEPORT_MAX * TELEPORT_MAX
        && g_iTickOffset[client] > TICK_TOLERANCE;

    if (defensive)
    {
        float shot = GetShotTime(client);
        if (shot <= 0.0 || GetGameTime() - shot >= SHOT_RECENT)
        {
            sim = g_fLastSimulation[client] + GetTickInterval();
            SetEntPropFloat(client, Prop_Data, "m_flSimulationTime", sim);
        }
    }

    g_fLastSimulation[client] = sim;

    g_fLastOrigin[client][0] = origin[0];
    g_fLastOrigin[client][1] = origin[1];
    g_fLastOrigin[client][2] = origin[2];

    return MRES_Ignored;
}

public Action OnPlayerDeath(Event event, const char[] name, bool broadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsValidClient(client)) return Plugin_Continue;

    g_iAirStuckTicks[client] = 0;
    return Plugin_Continue;
}

public void OnClientConnected(int client)
{
    ResetClient(client);
}

public void OnClientDisconnect(int client)
{
    ResetClient(client);
}