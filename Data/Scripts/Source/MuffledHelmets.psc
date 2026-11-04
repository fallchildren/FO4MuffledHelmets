Scriptname MuffledHelmets extends Quest

;; MuffledHelmets: muffles the voice of the player (and nearby NPCs) wearing a
;; helmet, mask or hood.
;;
;; This script decides WHO sounds muffled (keywords, slots, lists) and the F4SE
;; plugin MuffledHelmetsNative.dll changes the actual voice using the sound output
;; models (SOPM) from muffledhelmets.esp:
;;   MuffledHelmetsNative.SetPlayerVoice(som_2d_id, som_3d_id)
;;   MuffledHelmetsNative.SetActorVoice(npc_id, som_3d_id, leaseSeconds)
;; For the player the change stays until it is changed again. For other actors it
;; is a lease of a few seconds that has to be renewed, so it ends by itself when
;; the NPC leaves or takes the item off.

;; set in startup(): is the plugin loaded?
bool native_ok = false

;; constant lists for ignoring and deciding which audio effect chain to use
int[] blacklist
int[] clothlist
int[] forcelist

;; ---- settings (Mod Configuration Menu, optional) --------------------------------
;; Only the NPC scan can be configured. The MCM is a soft dependency: it is used
;; if its F4SE plugin (F4MCM) is loaded; mcm_read is false until the values were
;; read and the functions below return the defaults in that case. (Variables
;; added after a save was made start at false/0 on that save, hence the
;; "read yet?" flag instead of initial values.)
bool mcm_read = false
bool mcm_npc_voices
int mcm_npc_radius_m
float mcm_npc_interval
bool mcm_all_slots

;; muffle NPCs at all (default: yes)
bool Function setting_npc_voices()
    if mcm_read
        return mcm_npc_voices
    endif
    return true
EndFunction

;; check every armor slot of NPCs, not only the head/face ones (default: no)
bool Function setting_all_slots()
    if mcm_read
        return mcm_all_slots
    endif
    return false
EndFunction

;; search radius in game units, about 70 units per metre (default 36 m = 2520)
float Function npc_radius()
    if mcm_read && mcm_npc_radius_m > 0
        return mcm_npc_radius_m * 70.0
    endif
    return 2520.0
EndFunction

;; seconds between two scans for NPCs (default 1.0)
float Function npc_interval()
    if mcm_read && mcm_npc_interval >= 0.2
        return mcm_npc_interval
    endif
    return 1.0
EndFunction

Function read_mcm_settings()
    mcm_read = false
    if F4SE.GetPluginVersion("F4MCM") < 0
        return
    endif
    mcm_npc_voices = MCM.GetModSettingBool("MuffledHelmets", "bNpcVoices:NPCs")
    mcm_npc_radius_m = MCM.GetModSettingInt("MuffledHelmets", "iNpcRadius:NPCs")
    mcm_npc_interval = MCM.GetModSettingFloat("MuffledHelmets", "fNpcInterval:NPCs")
    mcm_all_slots = MCM.GetModSettingBool("MuffledHelmets", "bScanAllSlots:NPCs")
    mcm_read = true
EndFunction

;; called by the MCM (registered in startup) when a setting was changed
Function OnMCMSettingChange(string modName, string id)
    if modName == "MuffledHelmets"
        read_mcm_settings()
        if native_ok
            CancelTimer(3)
            StartTimer(npc_interval(), 3)
        endif
    endif
EndFunction
;; ------------------------------------------------------------------------------

;; forms are looked up once in cache_forms() (called from startup, i.e. on
;; new game and on every load) instead of on every should_muffle() call.
;; the armorkeywords.esm ones may stay None, they are optional
Keyword kw_actor_npc
Keyword kw_force
Keyword kw_force_cloth
Keyword kw_force_ignore

;; Sound output model Form IDs (resolved from muffledhelmets.esp in cache_forms)
int som_muffled_2d = 0
int som_muffled_3d = 0
int som_cloth_2d   = 0
int som_cloth_3d   = 0
Keyword kw_mask_full
Keyword kw_mask_part
Keyword kw_mouth_slot
Keyword kw_eye_slot
Keyword kw_masked_helmet

int Function get_form_id_maybe(int id, string file)
    Form f = Game.GetFormFromFile(id, file)
    if f != None
        return f.GetFormId()
    endif
    return -1
EndFunction

Function cache_forms()
    kw_actor_npc     = Game.GetFormFromFile(0x00013794, "Fallout4.esm") as keyword ;; ActorTypeNPC
    kw_force         = Game.GetFormFromFile(0x0000000D, "muffledhelmets.esp") as keyword
    kw_force_cloth   = Game.GetFormFromFile(0x00000011, "muffledhelmets.esp") as keyword
    kw_force_ignore  = Game.GetFormFromFile(0x0000000C, "muffledhelmets.esp") as keyword

    som_muffled_2d   = get_form_id_maybe(0x00000005, "muffledhelmets.esp")
    som_muffled_3d   = get_form_id_maybe(0x00000006, "muffledhelmets.esp")
    som_cloth_2d     = get_form_id_maybe(0x0000000E, "muffledhelmets.esp")
    som_cloth_3d     = get_form_id_maybe(0x0000000F, "muffledhelmets.esp")

    kw_mask_full     = Game.GetFormFromFile(0x0000083A, "armorkeywords.esm") as keyword ;; _ClothingSlotMaskFull_Slot46
    kw_mask_part     = Game.GetFormFromFile(0x00000801, "armorkeywords.esm") as keyword ;; _ClothingSlotMaskPartial_Slot4849
    kw_mouth_slot    = Game.GetFormFromFile(0x0000083B, "armorkeywords.esm") as keyword ;; _ClothingSlotMouth_Slot49
    kw_eye_slot      = Game.GetFormFromFile(0x0000080C, "armorkeywords.esm") as keyword ;; _ClothingSlotEyewear_Slot47
    kw_masked_helmet = Game.GetFormFromFile(0x00000D0C, "armorkeywords.esm") as keyword ;; _ArmorSlotMaskedHelmet_Slot30
EndFunction

Function initialize_lists()
    int synth_helmet   = 0x00187976
    int eyebot_helmet  = get_form_id_maybe(0x0000864C, "DLCRobot.esm")
    int lobster_helmet = get_form_id_maybe(0x0004FA89, "DLCCoast.esm")

    blacklist    = new int[3]
    blacklist[0] = synth_helmet
    blacklist[1] = eyebot_helmet
    blacklist[2] = lobster_helmet

    ;; mod support request
    int metro_ppm_88 = get_form_id_maybe(0x00000F99, "Metro Gas Masks.esp")
    int metro_m17    = get_form_id_maybe(0x00002672, "Metro Gas Masks.esp")
    int metro_pmk1   = get_form_id_maybe(0x000035A7, "Metro Gas Masks.esp")

    forcelist    = new int[3]
    forcelist[0] = metro_ppm_88
    forcelist[1] = metro_m17
    forcelist[2] = metro_pmk1

    int sack_hood_1    = 0x0018E417
    int sack_hood_2    = 0x0018E419
    int sack_hood_3    = 0x0018E41B
    int red_bandana    = 0x0009C05B
    int surgical_mask  = 0x000787DA
    int dc_helmet      = 0x000AF0F7
    int blue_bandana   = 0x0017E917
    int leo_bandana    = 0x0017E91B
    int monkey_bandana = 0x0017E91C
    int skull_bandana  = 0x0017E91D
    int gun_bandana_2  = 0x0017E922
    int gun_bandana_1  = 0x0017E923
    int stripe_bandana = 0x0017E924
    int stars_bandana  = 0x0017E925
    int hunters_hood   = get_form_id_maybe(0x000540FC, "DLCCoast.esm")
    int disciple_1     = get_form_id_maybe(0x00026BBD, "DLCNukaWorld.esm")
    int disciple_2     = get_form_id_maybe(0x00026BB7, "DLCNukaWorld.esm")
    int disciple_hood  = get_form_id_maybe(0x0003B55D, "DLCNukaWorld.esm")
    int pack_helmet_1  = get_form_id_maybe(0x00027705, "DLCNukaWorld.esm")
    int pack_helmet_2  = get_form_id_maybe(0x00027706, "DLCNukaWorld.esm")
    int pack_helmet_3  = get_form_id_maybe(0x00027707, "DLCNukaWorld.esm")
    int pack_helmet_4  = get_form_id_maybe(0x00027708, "DLCNukaWorld.esm")
    int pack_helmet_5  = get_form_id_maybe(0x0002770A, "DLCNukaWorld.esm")
    int pack_helmet_6  = get_form_id_maybe(0x0002770B, "DLCNukaWorld.esm")

    ; mod support requests
    int balaclava_v1   = get_form_id_maybe(0x00000F9A, "NeoX_Balaclava.esp")
    int balaclava_v2   = get_form_id_maybe(0x00007468, "NeoX_Balaclava.esp")
    int balaclava_v3   = get_form_id_maybe(0x00008D9E, "NeoX_Balaclava.esp")
    int balaclava_v4   = get_form_id_maybe(0x00009608, "NeoX_Balaclava.esp")
    int balaclava_v5   = get_form_id_maybe(0x0000D0D6, "NeoX_Balaclava.esp")
    int balaclava_v6   = get_form_id_maybe(0x00011C70, "NeoX_Balaclava.esp")
    int balaclava_v7   = get_form_id_maybe(0x00011C73, "NeoX_Balaclava.esp")
    int balaclava_v8   = get_form_id_maybe(0x000124DC, "NeoX_Balaclava.esp")

    clothlist     = new int[32]
    clothlist[0]  = sack_hood_1
    clothlist[1]  = sack_hood_2
    clothlist[2]  = sack_hood_3
    clothlist[3]  = red_bandana
    clothlist[4]  = surgical_mask
    clothlist[5]  = dc_helmet
    clothlist[6]  = blue_bandana
    clothlist[7]  = leo_bandana
    clothlist[8]  = monkey_bandana
    clothlist[9]  = skull_bandana
    clothlist[10] = gun_bandana_2
    clothlist[11] = gun_bandana_1
    clothlist[12] = stripe_bandana
    clothlist[13] = stars_bandana
    clothlist[14] = hunters_hood
    clothlist[15] = disciple_1
    clothlist[16] = disciple_2
    clothlist[17] = disciple_hood
    clothlist[18] = pack_helmet_1
    clothlist[19] = pack_helmet_2
    clothlist[20] = pack_helmet_3
    clothlist[21] = pack_helmet_4
    clothlist[22] = pack_helmet_5
    clothlist[23] = pack_helmet_6
    clothlist[24] = balaclava_v1
    clothlist[25] = balaclava_v2
    clothlist[26] = balaclava_v3
    clothlist[27] = balaclava_v4
    clothlist[28] = balaclava_v5
    clothlist[29] = balaclava_v6
    clothlist[30] = balaclava_v7
    clothlist[31] = balaclava_v8
EndFunction

bool Function is_cloth(Form item)
    if item == None
        return false
    endif

    ;; the force cloth keyword must pick the cloth effect, not just
    ;; enable muffling (previously only the hardcoded list was checked)
    if kw_force_cloth != None && item.HasKeyword(kw_force_cloth)
        return true
    endif

    return clothlist.Find(item.GetFormId()) >= 0
EndFunction

bool Function is_blacklisted(Armor h)
    return blacklist.Find(h.GetFormId()) >= 0
EndFunction

bool Function is_force(Armor h)
    return forcelist.Find(h.GetFormId()) >= 0
EndFunction

;; ---- voice ------------------------------------------------------------------

int Function get_npc_voice_model(Armor h)
    if h == None
        return 0
    endif
    if is_cloth(h)
        return som_cloth_3d
    endif
    return som_muffled_3d
EndFunction

Function apply_player_voice_helmet(Armor h)
    if h == None
        MuffledHelmetsNative.SetPlayerVoice(0, 0)
    elseif is_cloth(h)
        MuffledHelmetsNative.SetPlayerVoice(som_cloth_2d, som_cloth_3d)
    else
        MuffledHelmetsNative.SetPlayerVoice(som_muffled_2d, som_muffled_3d)
    endif
EndFunction

;; (re)evaluate what the player wears and set the voice accordingly
Function update_player_voice()
    Actor player = Game.GetPlayer()
    apply_player_voice_helmet(get_armor_that_muffles(player))
EndFunction

;; NPC voices: every npc_interval() seconds the NPCs within npc_radius() are
;; checked with the same rules as the player; those that wear a muffling item get
;; a short lease that the next scan renews. The plugin accepts only a few NPCs at
;; the same time, so the scan stops after 3 and looks at 16 NPCs at most.
Function npc_scan()
    if !native_ok || !setting_npc_voices() || kw_actor_npc == None
        return
    endif

    Actor player = Game.GetPlayer()
    ObjectReference[] refs = player.FindAllReferencesWithKeyword(kw_actor_npc, npc_radius())
    bool head_only = !setting_all_slots()
    int lease = (npc_interval() * 4.0) as int + 1
    int accepted = 0
    int i = 0
    While i < refs.Length && i < 16 && accepted < 3
        Actor a = refs[i] as Actor
        if a != None && a != player && !a.IsDead() && !a.IsDisabled() && a.Is3DLoaded()
            Armor helmet = get_armor_that_muffles(a, head_only)
            if helmet != None && MuffledHelmetsNative.SetActorVoice(a.GetFormID(), get_npc_voice_model(helmet), lease)
                accepted += 1
            endif
        endif
        i += 1
    EndWhile
EndFunction

Event OnTimer(int aiTimerID)
    if aiTimerID == 3
        npc_scan()
        if native_ok
            StartTimer(npc_interval(), 3)
        endif
    endif
EndEvent

Function startup()
    ;; fill caches/lists before registering so no event sees empty state
    cache_forms()
    initialize_lists()
    Actor player = Game.GetPlayer()
    RegisterForRemoteEvent(player, "OnItemUnequipped")
    RegisterForRemoteEvent(player, "OnItemEquipped")
    RegisterForRemoteEvent(player, "OnPlayerLoadGame")

    ;; registrations of older versions (SetRace/Pipboy workaround) that live on in saves
    UnregisterForMenuOpenCloseEvent("PipboyMenu")
    UnregisterForRemoteEvent(player, "OnMenuOpenCloseEvent")
    UnregisterForRemoteEvent(player, "OnRaceSwitchComplete")

    read_mcm_settings()
    if mcm_read
        RegisterForExternalEvent("OnMCMSettingChange|MuffledHelmets", "OnMCMSettingChange")
    endif

    CancelTimer(3)
    native_ok = F4SE.GetPluginVersion("MuffledHelmetsNative") >= 0
    if !native_ok
        Debug.Notification("MuffledHelmets is inactive: MuffledHelmetsNative.dll is not loaded (see f4se.log)")
        return
    endif
    StartTimer(npc_interval(), 3)
EndFunction

Event Actor.OnPlayerLoadGame(Actor a)
    startup()
    if native_ok
        update_player_voice()
    endif
EndEvent

Event Actor.OnItemEquipped(Actor a, Form akBaseObject, ObjectReference akReference)
    if native_ok && should_muffle(akBaseObject)
        apply_player_voice_helmet(akBaseObject as Armor)
    endif
EndEvent

Event Actor.OnItemUnequipped(Actor a, Form akBaseObject, ObjectReference akReference)
    if native_ok
        update_player_voice()
    endif
EndEvent

Event OnQuestInit()
    startup()
    if native_ok
        update_player_voice()
    endif
EndEvent

;; adjusted example code from https://www.creationkit.com/fallout4/index.php?title=GetWornItem_-_Actor
;; slot index = biped slot - 30. head_only restricts the check to the slots where
;; masks, hoods, helmets and similar live: 30, 31, 32 (hair/head), 46-50 (headband,
;; eyes, beard, mouth, neck) and 52 (scalp). Much cheaper for NPCs; the MCM can
;; switch it off for mods that use other slots.
bool Function is_head_slot(int slot)
    return slot <= 2 || (slot >= 16 && slot <= 20) || slot == 22
EndFunction

Armor Function get_armor_that_muffles(Actor a, bool head_only = false)
    int slot = 0
    While (slot <= 22)
        If (!head_only || is_head_slot(slot))
            Actor:WornItem worn = a.GetWornItem(slot)
            If (should_muffle(worn.Item))
                return worn.Item as Armor
            EndIf
        EndIf
        slot += 1
    EndWhile
    return None
EndFunction

bool Function should_muffle(Form item)
    ;; empty slots
    if item == None
        return false
    endif

    ;; internal keywords have highest precedence; as documented,
    ;; the ignore keyword is checked first and stops processing
    if item.HasKeyword(kw_force_ignore)
        return false
    endif

    if item.HasKeyword(kw_force) || item.HasKeyword(kw_force_cloth)
        return true
    endif

    ;; everything below only makes sense for armor (avoids None
    ;; errors in the list lookups when e.g. a weapon is equipped)
    Armor armo = item as Armor
    if armo == None
        return false
    endif

    ;; check lists for early exit
    if is_blacklisted(item as Armor)
        return false
    endif

    if is_cloth(item as Armor) || is_force(item as Armor)
        return true
    endif

    ;; check armor keywords next (if not there these vars will be None so completely optional)
    if kw_mask_full != None && item.HasKeyword(kw_mask_full)
        return true
    endif
    if kw_mask_part != None && item.HasKeyword(kw_mask_part)
        return true
    endif
    if kw_mouth_slot != None && item.HasKeyword(kw_mouth_slot) && item.HasKeyword(kw_eye_slot)
        return true
    endif
    if kw_masked_helmet != None && item.HasKeyword(kw_masked_helmet)
        return true
    endif

    return has_slot_mask(armo, kSlotMask49) && has_slot_mask(armo, kSlotMask47)
EndFunction

bool Function has_slot_mask(Armor armo, int value) Global
    return Math.LogicalAnd(armo.GetSlotMask(), value) == value
EndFunction
