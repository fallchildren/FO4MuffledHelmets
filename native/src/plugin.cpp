// MuffledHelmetsNative - F4SE plugin for dynamic voice output model overrides.
//
// Completely decoupled from game forms and ESPs: Papyrus passes the exact
// sound output model (SOPM) FormIDs to apply.
//
//   bool MuffledHelmetsNative.SetPlayerVoice(int aiModel2D, int aiModel3D)
//     0, 0 restores vanilla player voice models (0x87E40, 0x87E41).
//
//   bool MuffledHelmetsNative.SetActorVoice(int aiActorFormID, int aiModel3D, int aiLeaseSeconds = 0)
//     0 removes the override. For non-player actors, overrides are leases
//     (default 10s) that expire unless renewed.
//
// How it works:
//   * player: BSAudioManager::outputOverrideMap has two "Root" entries (2D/3D).
//     We swap their values in place (one atomic store per entry).
//   * NPC: voice follows the actor's "Head" node. We insert Head -> SOPM into
//     the audio map as a lease, removing it when expired or cancelled.

#include "F4SE/F4SE.h"
#include "RE/Fallout.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <thread>
#include <variant>
#include <vector>

F4SE_PLUGIN_VERSION = []() noexcept {
	F4SE::PluginVersionData v{};
	v.PluginVersion({ 3, 2, 0, 0 });
	v.PluginName("MuffledHelmetsNative");
	v.AuthorName("fallchildren");
	v.UsesSigScanning(false);
	v.UsesAddressLibrary(true);
	v.HasNoStructUse(false);
	v.IsLayoutDependent(true);
	v.CompatibleVersions({ F4SE::RUNTIME_LATEST });
	v.MinimumRequiredXSEVersion({ 0, 7, 0, 0 });
	return v;
}();

namespace
{
	using clock = std::chrono::steady_clock;

	std::int64_t now_ms()
	{
		return std::chrono::duration_cast<std::chrono::milliseconds>(clock::now().time_since_epoch()).count();
	}

	// The audio map (capacity 8) has 4 entries in use by the player; entries are only
	// ever added while at least 2 slots stay free so it can never rehash while the
	// audio thread reads it, which leaves room for 3 NPCs.
	constexpr std::size_t k_max_npcs = 3;

	// Vanilla player voice models (Fallout4.esm 0x87E40 / 0x87E41)
	constexpr std::uint32_t k_vanilla_player_2d = 0x00087E40;
	constexpr std::uint32_t k_vanilla_player_3d = 0x00087E41;

	// BSISoundOutputModel* of a BGSSoundOutput (SOPM) form, 0 if it is not one
	std::uintptr_t model_ptr(std::uint32_t a_formID)
	{
		if (a_formID == 0) {
			return 0;
		}
		auto* form = RE::TESForm::GetFormByID(a_formID);
		if (!form || form->GetFormType() != RE::ENUM_FORM_ID::kSOPM) {
			return 0;
		}
		const RE::BSISoundOutputModel* base = static_cast<RE::BGSSoundOutput*>(form);
		return reinterpret_cast<std::uintptr_t>(base);
	}

	// ---- raw access to BSAudioManager::outputOverrideMap -----------------------
	// A BSTScatterTable: capacity at +0x0C, free count at +0x10, entries pointer
	// at +0x28, slots of key(8) value(8) next(8); a slot is used when next != 0.
	// Everything is SEH-guarded: the audio thread owns this table.
	namespace amap
	{
		struct Entry
		{
			std::uintptr_t key;
			std::uintptr_t value;
			std::uintptr_t slot;  // address of the slot
		};

		constexpr std::uint32_t kMax = 64;

		struct View
		{
			std::uint32_t capacity;
			std::uint32_t free_count;
			std::uint32_t count;
			Entry         e[kMax];
		};

		bool read(View* o)
		{
			__try {
				auto* am = RE::BSAudioManager::GetSingleton();
				if (!am) {
					return false;
				}
				const auto* base = reinterpret_cast<const std::uint8_t*>(&am->outputOverrideMap);
				o->capacity = *reinterpret_cast<const std::uint32_t*>(base + 0x0C);
				o->free_count = *reinterpret_cast<const std::uint32_t*>(base + 0x10);
				const auto* entries = *reinterpret_cast<const std::uint8_t* const*>(base + 0x28);
				if (!entries || o->capacity == 0 || o->capacity > 4096) {
					return true;
				}
				for (std::uint32_t i = 0; i < o->capacity && o->count < kMax; ++i) {
					const auto* s = entries + i * 24;
					if (!*reinterpret_cast<const std::uintptr_t*>(s + 16)) {
						continue;
					}
					auto& e = o->e[o->count++];
					e.key = *reinterpret_cast<const std::uintptr_t*>(s);
					e.value = *reinterpret_cast<const std::uintptr_t*>(s + 8);
					e.slot = reinterpret_cast<std::uintptr_t>(s);
				}
			} __except (1) {
				return false;
			}
			return true;
		}

		bool insert(std::uintptr_t a_key, std::uintptr_t a_model)
		{
			__try {
				auto* am = RE::BSAudioManager::GetSingleton();
				if (!am) {
					return false;
				}
				using value_type = std::remove_reference_t<decltype(am->outputOverrideMap)>::value_type;
				am->outputOverrideMap.insert(value_type{ reinterpret_cast<const RE::NiAVObject*>(a_key),
					reinterpret_cast<const RE::BSISoundOutputModel*>(a_model) });
			} __except (1) {
				return false;
			}
			return true;
		}

		bool erase(std::uintptr_t a_key)
		{
			__try {
				auto* am = RE::BSAudioManager::GetSingleton();
				if (!am) {
					return false;
				}
				am->outputOverrideMap.erase(reinterpret_cast<const RE::NiAVObject*>(a_key));
			} __except (1) {
				return false;
			}
			return true;
		}

		// replace the value of an existing slot in place (aligned pointer store)
		bool set_value(const Entry& a_e, std::uintptr_t a_model)
		{
			__try {
				auto* s = reinterpret_cast<volatile std::uintptr_t*>(a_e.slot);
				if (s[0] != a_e.key || s[2] == 0) {  // slot was reused or freed meanwhile
					return false;
				}
				__atomic_store_n(reinterpret_cast<std::uintptr_t*>(a_e.slot + 8), a_model, __ATOMIC_RELEASE);
			} __except (1) {
				return false;
			}
			return true;
		}
	}  // namespace amap

	// ---- scene helpers (SEH-guarded, no objects with destructors inside) --------
	RE::BSFixedString* g_head_name = nullptr;  // created once the game data is ready

	std::uintptr_t find_head(RE::Actor* a_actor)
	{
		__try {
			const auto* root = a_actor->Get3D();
			if (!root || !g_head_name) {
				return 0;
			}
			return reinterpret_cast<std::uintptr_t>(const_cast<RE::NiAVObject*>(root)->GetObjectByName(*g_head_name));
		} __except (1) {
			return 0;
		}
	}

	void player_roots(std::uintptr_t* a_1st, std::uintptr_t* a_3rd)
	{
		__try {
			if (auto* pc = RE::PlayerCharacter::GetSingleton()) {
				*a_1st = reinterpret_cast<std::uintptr_t>(pc->Get3D(true));
				*a_3rd = reinterpret_cast<std::uintptr_t>(pc->Get3D(false));
			}
		} __except (1) {
		}
	}

	// "Root" node somewhere below one of the player's 3D roots
	bool is_player_root(std::uintptr_t a_key, std::uintptr_t a_1st, std::uintptr_t a_3rd)
	{
		__try {
			const auto* node = reinterpret_cast<const RE::NiAVObject*>(a_key);
			if (!node) {
				return false;
			}
			const char* name = node->name.c_str();
			if (!name || _stricmp(name, "Root") != 0) {
				return false;
			}
			for (int depth = 0; node && depth < 32; node = node->parent, ++depth) {
				const auto p = reinterpret_cast<std::uintptr_t>(node);
				if (p == a_1st || p == a_3rd) {
					return depth > 0;
				}
			}
			return false;
		} __except (1) {
			return false;
		}
	}

	// ---- shared state --------------------------------------------------------
	struct Npc
	{
		std::uint32_t  id;       // actor form ID
		std::uintptr_t key;      // Head node currently registered (0 = not yet)
		std::uint32_t  model;    // SOPM form ID (0 = remove)
		std::int64_t   expires;  // lease end (ms)
	};

	struct PlayerVoice
	{
		std::uint32_t model2d{ 0 };
		std::uint32_t model3d{ 0 };
		bool          managed{ false };
	};

	std::mutex        g_mx;
	std::vector<Npc>  g_npcs;
	PlayerVoice       g_player;
	std::atomic<bool> g_running{ false };

	void post(void (*a_fn)())
	{
		if (const auto* ti = F4SE::GetTaskInterface()) {
			ti->AddTask([a_fn]() { a_fn(); });
		}
	}

	// ---- main-thread tasks ---------------------------------------------------
	void task_apply_player()
	{
		PlayerVoice pv;
		{
			std::scoped_lock lk{ g_mx };
			if (!g_player.managed) {
				return;
			}
			pv = g_player;
		}
		amap::View v{};
		if (!amap::read(&v)) {
			return;
		}
		std::uintptr_t r1 = 0, r3 = 0;
		player_roots(&r1, &r3);

		const auto ptr2d = model_ptr(pv.model2d ? pv.model2d : k_vanilla_player_2d);
		const auto ptr3d = model_ptr(pv.model3d ? pv.model3d : k_vanilla_player_3d);
		if (!ptr2d || !ptr3d) {
			return;
		}

		int changed = 0;
		for (std::uint32_t i = 0; i < v.count; ++i) {
			const auto& e = v.e[i];
			if (!is_player_root(e.key, r1, r3)) {
				continue;
			}
			const bool is_3rd = (e.key == r3);
			const auto want = is_3rd ? ptr3d : ptr2d;
			if (e.value != want && amap::set_value(e, want)) {
				++changed;
			}
		}
		if (changed) {
			REX::INFO("player voice -> 2D:{:08X} 3D:{:08X} ({} entries updated)",
				pv.model2d, pv.model3d, changed);
		}
	}

	void task_apply_npcs()
	{
		std::scoped_lock lk{ g_mx };
		if (g_npcs.empty()) {
			return;
		}
		amap::View v{};
		if (!amap::read(&v)) {
			return;
		}
		std::uint32_t free_slots = v.free_count;

		for (auto it = g_npcs.begin(); it != g_npcs.end();) {
			auto& n = *it;
			auto* form = RE::TESForm::GetFormByID(n.id);
			auto* actor = form ? form->As<RE::Actor>() : nullptr;
			const auto head = (actor && n.model != 0) ? find_head(actor) : 0;

			// not wanted, gone, or its head node changed: drop the old registration
			if (n.key && (n.model == 0 || !head || head != n.key)) {
				if (amap::erase(n.key)) {
					++free_slots;
				}
				n.key = 0;
			}
			if (n.model == 0 || !head) {
				it = g_npcs.erase(it);
				continue;
			}

			const auto want = model_ptr(n.model);
			if (!n.key) {
				bool engine_has = false;
				for (std::uint32_t i = 0; i < v.count; ++i) {
					engine_has = engine_has || v.e[i].key == head;
				}
				if (!engine_has && free_slots >= 2 && want != 0 && amap::insert(head, want)) {
					n.key = head;
					--free_slots;
					REX::INFO("actor {:08X}: voice override {:08X}", n.id, n.model);
				}
			} else {
				for (std::uint32_t i = 0; i < v.count; ++i) {
					if (v.e[i].key == n.key && v.e[i].value != want && want != 0) {
						amap::set_value(v.e[i], want);
					}
				}
			}
			++it;
		}
	}

	void task_clear_all()
	{
		std::scoped_lock lk{ g_mx };
		for (const auto& n : g_npcs) {
			if (n.key) {
				amap::erase(n.key);
			}
		}
		g_npcs.clear();
		g_player = {};
	}

	// ---- worker: lease expiry + periodic re-validation ------------------------
	void worker()
	{
		std::int64_t last_check = 0;
		while (g_running.load()) {
			std::this_thread::sleep_for(std::chrono::milliseconds(200));
			const auto t = now_ms();

			bool expired = false;
			{
				std::scoped_lock lk{ g_mx };
				for (auto& n : g_npcs) {
					if (n.model != 0 && t >= n.expires) {
						n.model = 0;  // lease ran out: the next task removes the entry
						expired = true;
						REX::INFO("actor {:08X}: lease expired", n.id);
					}
				}
			}
			if (expired) {
				post(task_apply_npcs);
			}

			// every second: re-assert the player's entries and re-validate NPC registrations
			if (t - last_check >= 1000) {
				last_check = t;
				post(task_apply_player);
				bool any;
				{
					std::scoped_lock lk{ g_mx };
					any = !g_npcs.empty();
				}
				if (any) {
					post(task_apply_npcs);
				}
			}
		}
	}

	// ---- Papyrus API -----------------------------------------------------------
	// Sets the voice output models for the player character.
	// Passing 0, 0 restores the vanilla voice models (0x87E40, 0x87E41).
	bool SetPlayerVoice(std::monostate, std::int32_t a_model2D, std::int32_t a_model3D)
	{
		const auto m2d = static_cast<std::uint32_t>(a_model2D);
		const auto m3d = static_cast<std::uint32_t>(a_model3D);
		if ((m2d && !model_ptr(m2d)) || (m3d && !model_ptr(m3d))) {
			return false;
		}

		{
			std::scoped_lock lk{ g_mx };
			g_player.model2d = m2d;
			g_player.model3d = m3d;
			g_player.managed = true;
		}
		post(task_apply_player);
		return true;
	}

	// Sets a voice output model override on an actor (usually an NPC).
	// Passing a_model3D = 0 removes any active override.
	// Overrides are leases (default 10s) that expire unless renewed.
	bool SetActorVoice(std::monostate, std::int32_t a_actorID, std::int32_t a_model3D, std::int32_t a_leaseSeconds)
	{
		const auto id = static_cast<std::uint32_t>(a_actorID);
		if (id == 0x14) {
			// Player character: delegate to SetPlayerVoice (using model3D for both or 0 to clear)
			return SetPlayerVoice(std::monostate{}, a_model3D, a_model3D);
		}

		auto* form = RE::TESForm::GetFormByID(id);
		if (!form || !form->As<RE::Actor>()) {
			return false;
		}

		const auto model = static_cast<std::uint32_t>(a_model3D);
		if (model != 0 && !model_ptr(model)) {
			return false;
		}

		const auto lease_ms = static_cast<std::int64_t>(a_leaseSeconds > 0 ? a_leaseSeconds : 10) * 1000;
		{
			std::scoped_lock lk{ g_mx };
			auto it = std::find_if(g_npcs.begin(), g_npcs.end(), [&](const Npc& n) { return n.id == id; });
			if (it == g_npcs.end()) {
				if (model == 0) {
					return true;
				}
				if (g_npcs.size() >= k_max_npcs) {
					return false;
				}
				REX::INFO("SetActorVoice({:08X}, model {:08X}, lease {}s)", id, model, a_leaseSeconds);
				g_npcs.push_back(Npc{ id, 0, model, now_ms() + lease_ms });
			} else {
				if (it->model != model) {
					REX::INFO("SetActorVoice({:08X}) model {:08X} -> {:08X}", id, it->model, model);
				}
				it->model = model;
				it->expires = now_ms() + lease_ms;
			}
		}
		post(task_apply_npcs);
		return true;
	}

	bool register_papyrus(RE::BSScript::IVirtualMachine* a_vm)
	{
		a_vm->BindNativeMethod("MuffledHelmetsNative", "SetPlayerVoice", SetPlayerVoice, true);
		a_vm->BindNativeMethod("MuffledHelmetsNative", "SetActorVoice", SetActorVoice, true);
		REX::INFO("registered MuffledHelmetsNative (SetPlayerVoice, SetActorVoice)");
		return true;
	}

	// ---- F4SE messaging --------------------------------------------------------
	void on_message(F4SE::MessagingInterface::Message* a_msg)
	{
		if (!a_msg) {
			return;
		}
		switch (a_msg->type) {
		case F4SE::MessagingInterface::kGameDataReady:
			g_head_name = new RE::BSFixedString("Head");
			if (!g_running.exchange(true)) {
				std::thread(worker).detach();
			}
			break;
		case F4SE::MessagingInterface::kPreLoadGame:
		case F4SE::MessagingInterface::kNewGame:
		case F4SE::MessagingInterface::kDeleteGame:
			// the engine rebuilds the audio map for the new game; forget our entries
			task_clear_all();
			break;
		default:
			break;
		}
	}
}  // namespace

F4SE_PLUGIN_LOAD(const F4SE::LoadInterface* a_f4se)
{
	F4SE::Init(a_f4se, { .trampoline = false });
	REX::INFO("MuffledHelmetsNative 3.2.0 loaded");

	if (const auto* msg = F4SE::GetMessagingInterface()) {
		msg->RegisterListener(on_message);
	}
	if (const auto* papyrus = F4SE::GetPapyrusInterface()) {
		papyrus->Register(register_papyrus);
	}
	return true;
}
