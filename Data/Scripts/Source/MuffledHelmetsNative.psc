;; MuffledHelmetsNative - generic voice output model override interface.
Scriptname MuffledHelmetsNative Native Hidden

;; Sets the voice output models for the player character.
;; Passing 0, 0 restores the vanilla voice models (0x87E40 2D, 0x87E41 3D).
bool Function SetPlayerVoice(int aiModel2D, int aiModel3D) global native

;; Sets a 3D voice output model override on an actor (e.g. an NPC).
;; Passing aiModel3D = 0 removes the override.
;; Overrides are leases (default 10s) that expire unless periodically renewed.
bool Function SetActorVoice(int aiActorFormID, int aiModel3D, int aiLeaseSeconds = 0) global native
