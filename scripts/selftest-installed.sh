#!/bin/bash
# Self-test of the INSTALLED Mowa (no source code or Xcode needed) — for testing on another Mac,
# e.g. an Intel one. Synthesizes test sentences with macOS `say` and runs them through the real
# pipeline (Whisper → cleanup, language instructions, a command on selected text) using the
# models Mowa already downloaded, with the settings in Mowa → Settings.
#
#   bash selftest-installed.sh          report: ~/Desktop/mowa-selftest.txt
#   MOWA_APP=/path/to/Mowa.app bash selftest-installed.sh
#
# Quit Mowa first so it doesn't compete for the CPU. Voices missing from System Settings →
# Accessibility → Spoken Content are skipped (Milena = Russian, Zosia = Polish, Samantha = English,
# Daniel = British English, the "other person" in the voice-filter test).

# Extra audio a clip needs (not run as a clip itself): mkx file-in-extra/ voice "text to speak"
mkx() {
  local file="$1" voice="$2" text="$3"
  if ! grep -q "^$voice " <<<"$VOICES"; then say_ "skip extra/$file: voice '$voice' not installed (System Settings → Accessibility → Spoken Content)"; return; fi
  mkdir -p "$AUD/extra" && say -v "$voice" -o "$AUD/extra/$file" --data-format=LEI16@16000 "$text"
}

# The clip list (also used by selftest.sh): mk name voice "text to speak" "expected result"
mowa_clips() {
mk 01_en_correction Samantha "Um, so I think we should meet on Tuesday, no wait, Wednesday at three." "I think we should meet on Wednesday at 3."
mk 02_en_question   Samantha "Can you tell me what time it is in Tokyo" "Can you tell me what time it is in Tokyo? (must NOT be answered)"
mk 03_en_list       Samantha "Things to buy: first milk, second bread, third eggs." "Things to buy: 1. milk 2. bread 3. eggs (list)"
mk 04_pl_fillers    Zosia    "Yyy, dobra, to wyślij mi ten plik, eee, jutro rano, a nie, sorry, dzisiaj wieczorem." "Dobra, to wyślij mi ten plik dzisiaj wieczorem."
mk 05_pl_newline    Zosia    "Cześć Marek, nowa linia, dzięki za wczoraj, odezwę się w piątek." "Cześć Marek,⏎Dzięki za wczoraj, odezwę się w piątek."
mk 06_ru_slang      Milena   "Малой, скинь мне это в ватсап, чё ты тянешь." "Малой, скинь мне это в ватсап, чё ты тянешь? (slang kept)"
mk 07_ru_correction Milena   "Э-э, встречаемся в пять, нет, в шесть, у метро." "Встречаемся в шесть у метро."
mk 08_es            "Monica|Mónica|Paulina|Marisol"   "Eh, recuérdame comprar leche, pan y, eh, huevos." "Recuérdame comprar leche, pan y huevos."
mk 09_de            Anna     "Ähm, hallo Anna, danke für die schnelle Antwort, ich melde mich morgen." "Hallo Anna, danke für die schnelle Antwort. Ich melde mich morgen."
mk 10_fr            Thomas   "Euh, est-ce que tu peux m'envoyer le rapport avant vendredi ?" "Est-ce que tu peux m'envoyer le rapport avant vendredi ?"
mk 11_pt            Luciana  "Hã, vamos marcar a reunião para quinta-feira às dez." "Vamos marcar a reunião para quinta-feira às 10."
mk 12_it            Alice    "Ehm, ci vediamo domani alle otto davanti al bar." "Ci vediamo domani alle 8 davanti al bar."
mk 13_en_long       Samantha "Okay so here is the plan for next week. Um, on Monday we finish the onboarding screens and send them to the team for review. On Tuesday, uh, we fix whatever comes back and prepare the release notes. Wednesday is for testing on older Macs, especially the ones with eight gigabytes of memory, because that is where most problems will show up. Thursday we record the demo video, and on Friday, if everything goes well, we publish the first public version." "Long dictation → should use the BIG model, paragraphs, fillers removed"
mk 15_pl_list       Zosia    "Na spotkanie przygotuj raport sprzedaży, listę klientów, którzy nie zapłacili, no i plan na przyszły kwartał." "Na spotkanie przygotuj:⏎- Raport sprzedaży⏎- Listę klientów…⏎- Plan… (list)"
mk 16_ru_list       Milena   "Так, во-первых, надо починить логин, во-вторых, обновить дизайн, и в-третьих, написать тесты." "1. Надо починить логин.⏎2. Обновить дизайн.⏎3. Написать тесты. (numbered list)"
mk 17_en_steps      Samantha "To set it up, open the app, then allow the microphone, then pick your languages, and finally download the models." "To set it up: 1. Open the app 2. Allow the microphone 3. … (steps list)"
mk 18_en_punct      Samantha "Hi Anna comma are you coming tonight question mark" "Hi Anna, are you coming tonight? (spoken punctuation)"
mk 19_en_numbers    Samantha "The budget is twelve hundred fifty dollars and the discount is fifteen percent." "The budget is \$1,250 and the discount is 15%."
mk 20_en_spelling   Samantha "Please send it to Marta Nowack, that's N O W A K." "Please send it to Marta Nowak. (spelled name)"
mk 21_en_emoji      Samantha "Great job everyone thumbs up emoji" "Great job everyone 👍"
mk 22_en_restart    Samantha "So the idea is that we, um, okay let me start over, we launch on Monday." "We launch on Monday. (restart)"
mk 23_pl_numbers    Zosia    "Faktura jest na tysiąc dwieście pięćdziesiąt złotych i trzeba ją zapłacić do piętnastego." "Faktura jest na 1250 zł i trzeba ją zapłacić do 15."
# Quick language switches: each short clip must keep its own language (no previous-language bias).
mk 24_en_before    Samantha "Okay, I checked the build and everything looks fine on my side, let's ship it today." "Okay, I checked the build and everything looks fine on my side, let's ship it today."
mk 25_ru_quick     Milena   "Это эта херня так печатает?" "Это эта херня так печатает? (Russian, NOT translated)"
mk 26_en_quick     Samantha "Sounds good, thanks." "Sounds good, thanks. (English after Russian)"
mk 27_ru_quick2    Milena   "Дай пять минут." "Дай пять минут. (Russian after English)"
mk 28_pl_quick     Zosia    "Zadzwonię później." "Zadzwonię później. (short Polish, NOT Russian)"
mk 29_pl_quick2    Zosia    "Dzięki, do jutra." "Dzięki, do jutra. (short Polish after Russian)"
# Spoken language instructions, a command on selected text, and a one-word clip.
mk 30_ru_directive  Milena   "Пиши по-польски. Что такое сырники?" "Czym są syrniki? (Polish, instruction not typed)"
mk 31_ru_directive2 Milena   "По-польски. Что такое сырники?" "Czym są syrniki? (Polish)"
mk 32_ru_cmd        Milena   "Переведи на английский." "So they were recognised. (selection translated)"
mk 33_en_oneword    Samantha "Update." "Update. (English, not Polish)"
mk 34_ru_check      Milena   "Проверка связи." "Проверка связи. (Russian, no '(speaking in foreign language)')"
# Noise reduction (Mowa mixes in loud fan-like noise itself, then runs it without and with) and the
# voice filter (voiceprint learned from Samantha reading the enrollment text; Daniel must be left out).
mk 35_en_noise      Samantha "Let's move the meeting to Thursday afternoon and invite the design team." "Let's move the meeting to Thursday afternoon and invite the design team."
mk 36_en_two        Samantha "Please book a table for two at seven." "Please book a table for two at 7. (voice filter ON: Daniel's words left out)"
mkx 36_en_two.other.wav Daniel "Hey, has anyone seen my keys? I think I left them on the desk."
mkx voice-enroll.wav    Samantha "Mowa is learning how my voice sounds, so I'm reading this at my usual pace. On Saturday morning it's nice to walk along the river, buy fresh bread and a jar of honey, and then call an old friend. We're meeting at half past four by the green bridge next to the market. If it rains, there's always the little café, a cup of hot tea and a long talk about books, travel and work."
# A name at the start must survive translation ("Эва" was dropped as if it were a filler word).
mk 37_ru_name       Milena   "Пиши по-польски. Эва, ты разобралась со своим бассейном?" "Ewa, ogarnęłaś już swój basen? (Polish, name Ewa kept)"
# Translation ("write in …") into each language: names, case endings, natural phrasing.
mk 40_tr_ru_pl      Milena   "Пиши по-польски. Эва, ты разобралась со своим бассейном? Завтра я заеду к твоей сестре." "Ewa, ogarnęłaś już swój basen? Jutro wpadnę do twojej siostry."
mk 41_tr_ru_en      Milena   "Пиши по-английски. Слушай, Миша, давай перенесём созвон на четверг, у меня завал." "Listen, Misha, let's move the call to Thursday, I'm swamped."
mk 42_tr_en_de      Samantha "Write in German. Hi Thomas, could you send me the invoice for the new office chairs by Friday?" "Hallo Thomas, könntest du mir die Rechnung für die neuen Bürostühle bis Freitag schicken?"
mk 43_tr_en_fr      Samantha "Write in French. Marie, I left the keys with your neighbour, the one with the big dog." "Marie, j'ai laissé les clés chez ta voisine, celle qui a le gros chien."
mk 44_tr_en_es      Samantha "Write in Spanish. Carlos, we have to finish the report before the meeting with the new clients." "Carlos, tenemos que terminar el informe antes de la reunión con los nuevos clientes."
mk 45_tr_en_pt      Samantha "In Portuguese: João, can you pick up the kids from school today? I'm stuck at work." "João, você pode buscar as crianças na escola hoje? Estou preso no trabalho."
mk 46_tr_en_it      Samantha "Write in Italian. Giulia, thanks for dinner yesterday, the lasagna was amazing." "Giulia, grazie per la cena di ieri, le lasagne erano fantastiche."
mk 47_tr_pl_ru      Zosia    "Napisz po rosyjsku. Kasiu, czy mogłabyś mi jutro pomóc z przeprowadzką?" "Кася, ты не могла бы завтра помочь мне с переездом?"
mk 48_tr_pl_en      Zosia    "Napisz po angielsku. Dzień dobry, chciałbym przełożyć wizytę na przyszły wtorek." "Good morning, I'd like to move my appointment to next Tuesday."
mk 14_silence       Samantha "[[slnc 2000]]" ""
}

[ "${MOWA_CLIPS_ONLY:-0}" = 1 ] && return 0 2>/dev/null

set -uo pipefail
APP="${MOWA_APP:-/Applications/Mowa.app}"
BIN="$APP/Contents/MacOS/Mowa"
[ -x "$BIN" ] || { echo "Mowa not found at $APP (set MOWA_APP=/path/to/Mowa.app)"; exit 1; }
REPORT="$HOME/Desktop/mowa-selftest.txt"; : > "$REPORT"
AUD="$(mktemp -d)/selftest-audio"; mkdir -p "$AUD"
say_() { echo "$*" | tee -a "$REPORT"; }
VOICES="$(say -v '?' 2>/dev/null)"
mk() { # name "Voice|Fallback voice" "text to speak" "expected result"
  local name="$1" voices="$2" text="$3" expected="$4" voice="" v
  IFS='|' read -ra _mk_voices <<<"$voices"
  for v in "${_mk_voices[@]}"; do grep -q "^$v " <<<"$VOICES" && { voice="$v"; break; }; done
  if [ -z "$voice" ]; then say_ "skip $name: voice '$voices' not installed (System Settings → Accessibility → Spoken Content)"; return; fi
  say -v "$voice" -o "$AUD/$name.wav" --data-format=LEI16@16000 "$text" && printf '%s\n' "$expected" > "$AUD/$name.txt"
}
pgrep -x Mowa >/dev/null && say_ "note: Mowa is running — quit it for clean timings"
say_ "== Mowa $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null) installed-app self-test, $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
mowa_clips
say_ "ok: $(ls "$AUD"/*.wav 2>/dev/null | wc -l | tr -d ' ') clips"
"$BIN" --selftest "$AUD" 2>/dev/null | tee -a "$REPORT"
say_ "Report: $REPORT"
