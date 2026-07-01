# Shadowed Unit Frames — enhanced fork

A fork of [ShadowedUnitFrames](https://github.com/NoSelph/ShadowedUnitFrames) that adds
**click-to-cancel for your buffs** and fixes several aura bugs. Everything below sits on top of
stock SUF — nothing else about the addon changes.

---

## ✨ Click-to-cancel personal buffs

Click one of your own buffs on the **player** frame to cancel it — food, flasks, Well Fed,
weapon oils, anything the game lets you cancel — the way the default Blizzard buff bar works,
but on your SUF auras, with all your filtering and layout kept intact.

**How to use**
1. Enable the player **Buffs** frame and make sure it is **not** set to click-through
   (Units → Player → Auras → Buffs).
2. Out of combat, click a buff icon to remove it.

**Good to know**
- **Out of combat only.** WoW blocks buff cancellation during combat — a hard Blizzard
  restriction; the default frames can't cancel most buffs mid-fight either.
- **Your buffs only.** Debuffs on yourself aren't player-cancelable, so they're left untouched,
  and other units' auras are never affected.
- Tooltips still work through it, and it respects each aura frame's click-through setting.

**How it works** (for the curious): SUF's aura icons are left exactly as they are, so you keep
all of SUF's filtering, multi-frame layout, and in-combat updates. A pool of invisible *secure*
buttons is laid over your cancelable buff icons out of combat, each carrying a `/cancelaura`
macro; a secure state driver hides them in combat so nothing is ever done to a protected frame
mid-fight (no taint). Lives in `modules/auracancel.lua`. Approach adapted from the
[JustAC](https://github.com/wealdly) addon's precombat click overlay.

---

## 🐛 Aura fixes

- **Anchor position sticks again.** Choosing e.g. *Bottom Left* for an aura frame now docks
  where it should. A stale "forced anchor" left over from the buffs/debuffs *anchor-on* pairing
  was overriding your choice until the next reload.
- **Sequential anchor mode preview.** In test / unlock mode, *Sequential* now visibly merges the
  two aura types into one continuous queue instead of looking identical to *New row*; appended
  auras also use the parent frame's layout so the preview matches live behavior.
- **Global panel actually applies.** In the **Global** section, aura-frame settings (enable,
  position, size, filter, …) and **Test mode** now fan out to every selected unit — previously
  they silently did nothing.
- **Icon artwork masked.** Aura icons get rounded corners so the square art no longer pokes past
  the border.

---

## Upstream

These changes are proposed back to NoSelph/ShadowedUnitFrames as two independent pull requests —
the aura fixes and the buff-cancel feature — so each can be reviewed and taken separately.
