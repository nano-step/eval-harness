Output docs/assets/demo.gif
Output docs/assets/demo.webm
Output docs/assets/demo.mp4

Set Shell "bash"
Set FontSize 14
Set Width 1100
Set Height 720
Set Theme "Catppuccin Mocha"
Set Padding 24
Set TypingSpeed 35ms
Set PlaybackSpeed 1.0

# --- Scene 1: edit the skill ---
Type "# 1) inject a regression into a baselined skill"
Enter
Sleep 600ms
Type "vim .opencode/skills/omo-session-distiller/SKILL.md"
Sleep 1500ms
Ctrl+C
Type "clear"
Enter
Sleep 200ms

# --- Scene 2: push triggers pre-push hook ---
Type "# 2) push fires the eval-harness pre-push hook"
Enter
Sleep 600ms
Type "git push origin main"
Enter
Sleep 600ms

Type "[eval-harness] pre-push: detected change in .opencode/skills/omo-session-distiller/**"
Enter
Sleep 200ms
Type "[eval-harness] running 3 cases (skills-only scope, smoke tier)"
Enter
Sleep 400ms
Type "[eval-harness] Case 1/3 atom-shape-basic                       PASS (3.9s, $0.0012)"
Enter
Sleep 400ms
Type "[eval-harness] Case 2/3 atom-tags-decision-architecture        FAIL"
Enter
Sleep 400ms
Type "[eval-harness] Case 3/3 atom-redaction-pii                     PASS (3.1s, $0.0009)"
Enter
Sleep 600ms
Type "[eval-harness] Stability check: 3 samples byte-identical → real FAIL"
Enter
Sleep 400ms
Type "[eval-harness] Attribution: SKILL_CHANGED (skill_sha 7f3a2c1 → 9d4e1b8)"
Enter
Sleep 400ms
Type "[eval-harness] FAIL 1/3 — see runs/2026-05-30T11-42-08/diff.md"
Enter
Sleep 200ms
Type '[eval-harness] fix_proposal: missing tag "architecture" in $.atoms[].tags[]'
Enter
Sleep 400ms
Type "[eval-harness] WARN-ONLY MODE: push proceeding. Promote with `eval-harness promote`."
Enter
Sleep 1500ms

# --- Scene 3: inspect ---
Type "cat runs/2026-05-30T11-42-08/diff.md | head -40"
Enter
Sleep 800ms

Type "# 6-field FAIL detail:"
Enter
Type "failed_check_id:    atom-tags-decision-architecture"
Enter
Sleep 200ms
Type 'expected:           $.atoms[].tags[] contains "architecture"'
Enter
Sleep 200ms
Type 'actual:             ["redux","redaction"]'
Enter
Sleep 200ms
Type 'diff_hint:          tag "architecture" missing from atom #2'
Enter
Sleep 200ms
Type "transcript_span:    lines 142-158 of opencode.log"
Enter
Sleep 200ms
Type "env_delta:          skill_sha 7f3a2c1 → 9d4e1b8 (only delta)"
Enter
Sleep 1200ms

Type "# fix_proposal:"
Enter
Type "patch_snippet:"
Enter
Type '  In .opencode/skills/omo-session-distiller/SKILL.md line 87,'
Enter
Type '  the "architecture" tag was removed from the tag examples.'
Enter
Type '  Revert that line or update the case fixture if intentional.'
Enter
Sleep 2500ms
