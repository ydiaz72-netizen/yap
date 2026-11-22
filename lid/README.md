# Leben in Deutschland / Einbürgerungstest practice data

- `questions.json`: the official BAMF catalogue ("Gesamtfragenkatalog zum Test „Leben in Deutschland“ und zum „Einbürgerungstest“", Stand 07.05.2025):
  300 general + 160 state questions (10 per Bundesland), official numbering, answers in the official order, `c` = index of the correct answer.
  The catalogue is Anlage 1 of the Einbürgerungstestverordnung (EinbTestV), an official work (§ 5 UrhG).
- `img/`: the pictures from the catalogue (coats of arms, maps, flags).
- `tr/<lang>.json`: translations and short explanations (en, tr, ru, fr, ar, uk, hi) from the open-source
  project github.com/bitesinbyte/leben-in-deutschland (MIT licence, see LICENSE-translations.txt), re-ordered to the official answer order.

PonteTalk is not affiliated with the BAMF. When the BAMF publishes a new catalogue, replace these files.
