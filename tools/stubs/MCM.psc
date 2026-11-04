Scriptname MCM Native Hidden

;; Compile-time declaration of the parts of the Mod Configuration Menu (F4SE plugin
;; F4MCM) script interface that MuffledHelmets uses. Only used as an import for the
;; compiler; NOT part of the package (the real script comes with the MCM mod).

bool Function GetModSettingBool(string asModName, string asSetting) native global
int Function GetModSettingInt(string asModName, string asSetting) native global
float Function GetModSettingFloat(string asModName, string asSetting) native global
