# AI Control Layer — plan implementacji krok po kroku

## Jak zlecać i realizować kolejne kroki

Plan opiera się na [AI_CONTROL_LAYER_REQUIREMENTS.md](AI_CONTROL_LAYER_REQUIREMENTS.md), przesłanej propozycji architektury i decyzjach ustalonych w rozmowie. Zachowujemy namespace `AiControl` i rozwijamy istniejącą aplikację Phoenix etapami.

**Aktualizacja 2026-10-03:** uwzględniono przesłany research „Executive Summary — Elixir-based AI Safety Gateway”. Kroki **1–7 są ukończone i scalone**, zgodnie z zapisanymi odbiorami; wyniki odbioru gatewaya zapisano przy kroku 6, a guardów, NER i kontenera przy kroku 7. Następna fala pracy to **8, 9, 10 i 12A równolegle → 12B i 11A równolegle → 11B (odbiór MVP)**. Podział i zależności opisuje sekcja 2.1. Numeracja, checkboxy i historia odbiorów pozostają zachowane; podstawowy NER i pełny tool firewall nadal wchodzą do MVP. Zmiana organizacji pracy nie oznacza wykonania nowych funkcji.

Przykładowe zlecenie:

> Wykonaj krok 9 z AI_CONTROL_LAYER_IMPLEMENTATION_PLAN.md na bazie ukończonego i scalonego kroku 7. Przeczytaj zasady pracy równoległej z sekcji 2.1, zaimplementuj budżety i rozliczenia bez ponownej implementacji NER, dodaj wymagane testy, uruchom mix precommit i opisz stan integracji w planie.

Zasady dla agenta implementującego:

- Realizuj wskazany krok; kolejne kroki wymagają osobnego zlecenia.
- Przed pracą przeczytaj `AGENTS.md`, wymagania i aktualny kod. Nie generuj ponownie funkcji, które już istnieją.
- Sprawdź zależności od wcześniejszych kroków. Jeśli brakuje istotnej podstawy, wskaż konkretny brak przed rozpoczęciem zależnej implementacji.
- Numery kroków nie wyznaczają już sekwencyjnej kolejności pracy po kroku 7. Korzystaj z zależności i podziału odpowiedzialności w sekcji 2.1; testy z mockiem potwierdzają kontrakt, ale nie zastępują końcowych testów integracji i rzeczywistych modeli.
- Każdy krok kończy się działającym zachowaniem, odpowiednimi testami i spełnieniem opisanych kryteriów odbioru.
- Oznacz krok jako ukończony dopiero po spełnieniu tych kryteriów. Częściowe wykonanie lub zablokowane sprawdzenie opisz pod danym krokiem, pozostawiając checkbox niezaznaczony.
- Po zmianach uruchom `mix precommit` zgodnie z `AGENTS.md`; po zmianach frontendowych także build assetów. Nie twórz commitów ani PR-ów bez osobnego zlecenia.
- Rozróżniaj wymagania organizatora od decyzji projektowych w tym planie. Wymagania pozostają w osobnym dokumencie.

## 1. Ustalone założenia

- **Wiele organizacji:** oddzielne polityki, agenci, klucze API, budżety i audyt.
- **Jedno konto organizatora:** tworzy, zawiesza i przywraca organizacje oraz zaprasza ich pierwszych superadminów.
- **Konta firm:** użytkownicy logują się emailem i hasłem; aplikacje oraz agenci używają kluczy API.
- **Polityki:** PostgreSQL jako źródło prawdy, edycja w dashboardzie, import i eksport YAML.
- **Modele lokalne:** Ollama oraz lokalny sidecar klasyfikatora.
- **Pełna roadmapa:** MVP obejmuje podstawowy NER i pełny tool firewall; później MCP, ochrona workflowów i dalsze rozszerzenia.
- Interfejs aplikacji, dokumentacja projektu dla użytkowników i komunikaty API pozostają po angielsku. Ten plan roboczy zachowuje język ustalony w rozmowie.
- Pierwsze demo działa na jednej instancji aplikacji. Skalowanie do klastra nie jest warunkiem ukończenia planu.

Role administracyjne są oddzielone od indywidualnych przydziałów funkcji i zasobów:

| Rola | Uprawnienia |
| --- | --- |
| Organizator | Tworzenie, zawieszanie i przywracanie organizacji, zaproszenie pierwszego superadmina, jawny pełny dostęp do wszystkich organizacji |
| Superadmin | Jeden na organizację; pełny dostęp, zarządzanie adminami i użytkownikami oraz atomowe przekazanie roli istniejącemu adminowi |
| Admin | Zarządzanie zwykłymi użytkownikami i delegowanie uprawnień w granicach własnych jawnych przydziałów; bez zmiany własnego dostępu i promowania adminów |
| User | Podstawowy ekran organizacji, ustawienia konta i indywidualnie przyznane funkcje oraz zasoby |

Obserwator to `user` z przydziałami odczytu. Rola admina nie przyznaje automatycznie
dostępu do AI, polityk ani pozostałych funkcji. Zamknięty katalog obejmuje
`ai.use`, `agents.read/manage`, `api_keys.read/manage`, `policies.read/manage`,
`budgets.read/manage`, `signatures.read/manage`, `events.read` i `events.export`.
Brak przydziału oznacza odmowę. Przydziały zasobów obejmują identyfikatory agentów,
nazwy modeli albo jawny wybór wszystkich zasobów danego typu (`["*"]`).
Korzystanie z AI wymaga dostępu do agenta, modelu i spełnienia polityki organizacji.

### 1.1. Wnioski z researchu i decyzje dla istniejącego projektu

Gateway ma dwa obszary: **data plane** pośredniczy w komunikacji klient → LLM i egzekwuje kontrole wejścia/wyjścia; **control plane** zarządza organizacjami, politykami, budżetami i audytem. Control plane oraz kontrakty bezpieczeństwa już powstały w krokach 1–5. Ciężkie modele NLP działają w lokalnych usługach HTTP, a Phoenix/Elixir odpowiada za tożsamość, orkiestrację, decyzje, rozliczenia i audyt. Kontrolery pozostają cienkie; kolejne konteksty powstają pod `AiControl.Gateway`, `AiControl.Guards` i `AiControl.Budgets`, wykorzystując istniejące `Policies`, `Policy`, `Security` i `Audit`.

| Wniosek z researchu | Decyzja projektowa | Kroki |
| --- | --- | --- |
| Regex + checksum dla polskich identyfikatorów | Walidacja struktury i sum kontrolnych; dla PESEL również daty. Redakcja według polityki, bez gwarancji zerowego FPR | 7–8 |
| Regex + entropia + kontekst dla sekretów | Skaner w Elixirze, wzorce znanych dostawców oraz kontrolowane heurystyki; audyt bez dopasowanych wartości | 7–8 |
| Llama Prompt Guard 2 kontra Qwen3Guard | Porównanie na polskim zbiorze; wybór na podstawie jakości, lokalnej latencji, pamięci i dostępności | 10 |
| NER dla nazw i adresów | Lokalny Presidio + Stanza PL/NKJP w MVP, jawne mapowanie etykiet i reguły adresów; dalsze rozszerzenia przy RAG | 7–8; rozszerzenia w 18 |
| Rezerwacja i zwrot niewykorzystanych tokenów | Atomowe rezerwacje organizacji i agenta w PostgreSQL; ETS dla szybkich odczytów i limitera żądań | 6, 9 |
| Fail-closed i profile | Zachować `relaxed`, `balanced`, `strict` oraz obowiązkowość guardów z kroku 5; awaria wymaganej kontroli blokuje | 6–11 |
| Hot reload polityki | Zachować wersjonowanie i aktywację w PostgreSQL, cache ETS i PubSub z kroku 5; YAML jest formatem importu/eksportu | 5 ukończony; integracja runtime w 6 |
| Granite Guardian, Oban i streaming | Analiza wysokiego ryzyka, zadania w tle i SSE po wymaganym MVP | 14, 16–17 |
| Audyt i telemetry | Synchroniczny zapis decyzji, eksport JSONL, pomiary każdego etapu; rozbudowane raporty w tle później | 6–11, 16 |

Priorytety researchu odnosimy do **pozostałej pracy**, bez rozpoczynania projektu od nowa:

- **P0 — kroki 6–9:** gateway, deterministyczne kontrole wejścia/wyjścia, NER, limity i rezerwacje. To działający etap pośredni; wymagane MVP nadal potrzebuje semantycznego enforcement.
- **P1 — kroki 10, 12 i 11:** rzeczywista kontrola AI, polski benchmark, pełny tool firewall, dashboard, eksport i komplet testów. Provider semantyczny i rdzeń narzędzi powstają równolegle z P0; pełny krok 12 musi być odebrany przed końcowym odbiorem 11. **Wymagane MVP kończy się po kroku 11.**
- **P2 — kroki 13–20:** MCP, Granite, workflowy, Oban, streaming, RAG i dalsze rozszerzenia PII oraz zatwierdzanie działań. Minimalne scenariusze demo i instrukcje uruchomienia powstają już wraz z P0/P1; krok 20 scala pełną roadmapę.

Nie przenosimy wprost siedmiodniowego harmonogramu z researchu: auth, organizacje, klucze, audyt i polityki są już gotowe, a terminów pozostałych etapów nie potwierdzono.

### 1.2. Modele i twierdzenia wymagające pomiaru

| Model/usługa | Zastosowanie i ograniczenia | Decyzja |
| --- | --- | --- |
| Llama Prompt Guard 2 86M | Klasyfikator prompt injection/jailbreak, okno 512 tokenów; polski poza opublikowaną listą języków ewaluacji. Licencja wag: **Llama 4 Community License**, nie MIT | Kandydat do kontroli wejścia; lokalny sidecar Transformers. [Model card](https://huggingface.co/meta-llama/Llama-Prompt-Guard-2-86M) |
| Qwen3Guard-Gen-0.6B | Moderacja promptów i odpowiedzi, 119 języków/dialektów, Apache-2.0; generuje etykiety `Safe/Controversial/Unsafe` i kategorie | Pierwszy kandydat do próby dla polskiego; wybór po benchmarku, bez zakładania skalibrowanego score. [Model card](https://huggingface.co/Qwen/Qwen3Guard-Gen-0.6B) |
| Qwen3Guard-Stream-0.6B | Wariant ze specjalną głowicą do klasyfikacji podczas generacji | Osobna próba w kroku 17; adapter wariantu Gen nie zapewnia obsługi Stream. [Repozytorium producenta](https://github.com/QwenLM/Qwen3Guard) |
| Granite Guardian 4.1 8B | Kryteria BYOC, RAG i function calling; Apache-2.0; trening i testy na danych angielskich | P2, selektywnie dla operacji wysokiego ryzyka; polski i koszt lokalny do zmierzenia. [Model card](https://huggingface.co/ibm-granite/granite-guardian-4.1-8b) |
| Presidio + Stanza PL/NKJP | NER w kontekście z polskimi etykietami m.in. `persName`, `placeName`, `geogName`, `orgName`; adresy wymagają dodatkowego kontekstu | Lokalny sidecar w krokach 7–8; jawne mapowanie etykiet i walidacja zakresów przed redakcją. Jakość zmierzyć na danych aplikacji. [Stanza](https://stanfordnlp.github.io/stanza/ner_models.html) |

Wyniki z A100 i szacunki z researchu nie są wynikami naszego Maca M4. Wersję modelu, tokenizer, quantization, runtime, pamięć oraz opóźnienia p50/p95 trzeba zapisać z rzeczywistego pomiaru. MIT dla bazowego mDeBERTa nie określa licencji wag Prompt Guard. Sama deklarowana wielojęzyczność nie potwierdza skuteczności na polskich promptach ani indirect injection.

Checksum potwierdza poprawność numeru, nie jego istnienie, właściciela ani prywatność; przypadkowa liczba może przejść walidację. NER jest kontrolą statystyczną, nie deterministyczną. Prompt Guard wykrywa próby zmiany instrukcji i nie zastępuje ogólnej moderacji odpowiedzi. Karty modeli i licencje należy ponownie sprawdzić przy przypinaniu wersji do demo.

## 2. Status realizacji

Checkboxy oznaczają potwierdzone zakończenie kroku, a nie samą obecność kodu.

- [x] Krok 1 — Logowanie i konto organizatora
- [x] Krok 2 — Organizacje, członkostwa i zaproszenia
- [x] Krok 3 — Agenci i klucze API
- [x] Krok 4 — Wspólna domena decyzji i podstawowy audyt
- [x] Krok 5 — Centralny Policy Engine
- [x] Krok 6 — Gateway LLM i konfiguracja środowiska
- [x] Krok 7 — Deterministyczne guardy, NER i sygnatury
- [ ] Krok 8 — Output filtering
- [ ] Krok 9 — Budżety i rozliczanie użycia
- [ ] Krok 10 — Semantyczne wykrywanie prompt injection
- [ ] Krok 11 — Dashboard i zamknięcie wymaganego MVP
- [ ] Krok 12 — Tool firewall i ograniczenia zasobów
- [ ] Krok 13 — MCP gateway
- [ ] Krok 14 — Głęboka analiza semantyczna
- [ ] Krok 15 — Workflowy, runaway protection i wielu agentów
- [ ] Krok 16 — Oban, raporty i testy w panelu
- [ ] Krok 17 — Streaming
- [ ] Krok 18 — RAG, pamięć i rozszerzone PII
- [ ] Krok 19 — Zatwierdzanie działań przez człowieka
- [ ] Krok 20 — Przygotowanie kompletnego demo

### 2.1. Praca równoległa po ukończeniu kroku 7

Zmiana dotyczy pracy **po ukończeniu i scaleniu kroku 7**. Nie zmienia zakresu ukończonych detektorów, NER i wersjonowania polityki. Cztery branche pierwszej fali startują z tego samego commita obejmującego kroki 1–7, a każdy ma osobny worktree i bazę testową.

```text
1–7 — ukończone i scalone
8, 9, 10, 12A — cztery równoległe branche
12B, 11A — integracja narzędzi i dashboard równolegle
11B — wspólny odbiór MVP
13, 15, 16, 17, 18 — kolejne niezależne obszary po MVP
14, 19 — analiza z kontekstem workflow/RAG i zatwierdzanie
20 — końcowy odbiór pełnej roadmapy
```

`A` i `B` oznaczają części istniejącego kroku, nie nowe funkcje ani dodatkowe checkboxy. Krok 12 pozostaje nieukończony do odbioru 12B, a krok 11 do odbioru 11B. Grupy opisują zalecane fale; implementacja funkcji i końcowy odbiór całego MVP są osobnymi punktami synchronizacji.

| Branch / zakres | Co można wykonać niezależnie po 7 | Zależność końcowa |
| --- | --- | --- |
| `JL/step-8-output-filtering` — 8 | Kontrola wszystkich pól odpowiedzi i argumentów narzędzi, NER wyjścia, walidacja JSON po redakcji, bezpieczna odmowa i audyt | Własny odbiór używa detektorów z 7; wspólny test rozliczenia zablokowanego wyjścia po scaleniu 9 |
| `JL/step-9-budgets` — 9 | Trwałe liczniki i rezerwacje, tokenizer, rozliczenie usage, koszty, restart, współbieżność i obsługa niepewnego wykonania | W testach awarii wyjścia używa kontraktu guardu; rzeczywiste output filtering z 8 i semantyka z 10 są sprawdzane po integracji |
| `JL/step-10-semantic-guards` — 10 | Provider injection i opcjonalnej moderacji odpowiedzi, sidecary, fragmentacja, polski benchmark i wersjonowane rozszerzenia polityki | Wykorzystuje kontrakt guardu gatewaya z 6 oraz aktualną treść po redakcji z 7; moderacja wszystkich pól odpowiedzi jest sprawdzana wspólnie z 8 |
| `JL/step-12-tool-firewall` — 12A | `ToolRequest`, katalog i schematy argumentów, autoryzacja polityką, walidatory zasobów i sandboxowe adaptery | Endpoint i pełne wykonanie z budżetem oraz filtrowaniem wyników dopiero w 12B po scaleniu 8, 9 i 10 |

Nie ma twardej zależności **8 → 9 → 10** dla implementacji tych modułów. Gateway z 6, rozszerzony w 7, ma już `AiControl.Gateway.Guard.assess/4`, `ready?/1`, typowane wyniki, snapshot i ocenę obu etapów. Krok 8 rozwija kontrolę odpowiedzi, 9 utrwala zużycie, a 10 dostarcza sygnały AI; żaden z nich nie powinien ponownie implementować pozostałych.

#### Wspólne kontrakty i odpowiedzialność

- Zachować kontrakt `assess(fields, context, policy_snapshot, config)` z kroku 7 oraz `GuardResult`, `Detection`, indeksy pól i offsety UTF-8. Każdy guard dostaje ten sam snapshot polityki i analizuje bieżącą wersję tekstu; brak obowiązkowej kontroli nadal kończy żądanie odmową.
- Wykonawca 8 odpowiada za kontrolę i reprezentację wyjścia w `Gateway.Stages`, `Response` i `Content`. Wykonawca 10 dostarcza adaptery semantyczne przez ten kontrakt; uzgodnione zmiany rejestracji guardów scala wykonawca 8, bez tworzenia drugiego pipeline'u.
- Wykonawca 9 odpowiada za kontekst `Budgets`, migracje liczników oraz punkty naliczania, rezerwacji i rozliczenia w `Gateway`. Rezerwacja tokenów korzysta z treści po kontrolach wejścia, a usage jest rozliczane także przy późniejszej blokadzie wyjścia. NER wyjścia należy wyłącznie do 8.
- Nowe kategorie/moderacja z 10 zachowują zgodność z wersjami polityki ukończonymi w 7; rozszerzenie walidatora, formularzy i checksumów ma jednego właściciela na branchu 10. Krok 12 korzysta z przygotowanego w 7 schematu narzędzi.
- Każdy branch rozwija własne testy i fixtures. Zmiany wspólnej konfiguracji, supervisora, zależności i routera scalać pojedynczo; nie przenosić globalnego formatowania ani zmian należących do innego kroku.
- Mocki używane do izolacji testów przestrzegają produkcyjnego kontraktu. Testowa polityka może jawnie wyłączać kontrolę spoza badanego zakresu; nie zmienia to domyślnych profili, gotowości ani kryteriów odbioru rzeczywistych modeli.

Po pierwszej fali scalać kolejno **8 → 9 → 10 → 12A**, sprawdzając integrację wspólnego gatewaya; jest to kolejność scalania, nie wykonywania pracy. Wykonawca 12 kontynuuje 12B, a osobny branch `JL/step-11-dashboard` realizuje 11A. Przy konflikcie etapów gatewaya właścicielem integracji pozostaje wykonawca 8.

| Część | Zakres | Warunek zakończenia |
| --- | --- | --- |
| 12B | `POST /v1/tool_calls`, trwały tenant-scoped licznik wykonania, autoryzacja przed wykonaniem, kontrole treści/semantyki, filtrowanie wyników, audyt i wszystkie sandboxowe scenariusze | Pełne kryteria odbioru kroku 12; żadnego wykonania przed kontrolą tożsamości, polityki, zasobu, budżetu i wymaganych guardów |
| 11A | Rozbudowa istniejących stron, metryki z 8–10, Events, eksport JSONL, filtry i PubSub oraz prezentacja dostępnych wyników narzędzi | Testy stron i eksportu używają rzeczywistych kontekstów i fixtures; końcowa matryca narzędzi czeka na 12B |
| 11B | Integracja 12B z dashboardem, skrypt testów bezpieczeństwa, mapowanie wymagań, pełne scenariusze i testy rzeczywistych modeli | Ukończone 8, 9, 10, pełny 12 oraz wszystkie kryteria MVP; dopiero wtedy zaznaczyć checkbox 11 |

Testy po scaleniu obejmują także interakcje między branchami: tokenizację treści po redakcji, rozliczenie zablokowanej odpowiedzi, timeout NER/semantyki bez downstream, poprawność JSON argumentów po redakcji, snapshot podczas zmiany polityki oraz liczniki narzędzi przy równoczesnych wykonaniach. Każdy zakres kończy się `mix precommit`; frontend także `mix assets.build`, a 11B rzeczywistymi modelami i testami bezpieczeństwa z sekcji 5.

Po MVP grupy nie znoszą wspólnych kontraktów: 14 korzysta z kontekstu workflowów z 15 i RAG z 18, a przed równoległą implementacją 14 i 19 trzeba uzgodnić obsługę `REVIEW` w kontrakcie decyzji. Krok 20 ma końcowy odbiór po wszystkich rozszerzeniach; jego dokumentację można uzupełniać wraz z funkcjami.

## 3. Kolejność implementacji

### Krok 1. Logowanie i konto organizatora

- Wygenerować podstawę przez `mix phx.gen.auth Accounts User users --live --binary-id --no-agents-md`. Wykorzystać mechanizmy haseł, sesji i tokenów Phoenix. [Dokumentacja generatora](https://phoenix.hexdocs.pm/Mix.Tasks.Phx.Gen.Auth.html).
- Przenieść markup wygenerowanych stron do osobnych `.html.heex`.
- Wyłączyć publiczną rejestrację. Konta firm powstają przez zaproszenia; link email służy aktywacji konta i odzyskaniu dostępu. Mechanizm zaproszeń powstaje w kroku 2.
- Dodać idempotentną komendę bootstrapującą jedyne konto organizatora z danych środowiskowych. Nie umieszczać domyślnych poświadczeń w repozytorium ani logach.
- Zachować zabezpieczenia sesji i CSRF; dodać limit prób logowania.

**Gotowe, gdy:** organizator może się zalogować i wylogować, a anonimowy użytkownik nie otworzy panelu.

**Odbiór 2026-10-03:** ukończono na gałęzi `JL/step-1-organizer-auth`, bez commita
i PR-a. Działa bootstrap jedynego organizatora, logowanie hasłem i remember-me,
odzyskiwanie dostępu przez jednorazowy link ważny 15 minut, zmiana danych konta,
unieważnianie sesji oraz ochrona panelu w HTTP i LiveView. Publiczna rejestracja
jest wyłączona. Zgodnie z późniejszą decyzją użytkownika limiter używa Hammera
z ETS: 5 prób/email i 20 prób/IP w oknie 15 minut od pierwszej próby, wspólne
limity logowania i odzyskiwania oraz HTTP 429 z `Retry-After`.

`mix precommit` przeszedł (116 testów, brak ostrzeżeń kompilacji i uwag Credo),
podobnie `mix assets.build`. Testy limitera sprawdzają równoczesność i granice
przez sterowanie terminami wygaśnięcia w rzeczywistym ETS, bez usypiania;
Hammer korzysta z własnego zegara. Zweryfikowano desktop/mobile i oba motywy.
Detektor `impeccable` nie zgłosił problemów; niezależny przegląd wskazał trzy
poprawki i potwierdził ich rozwiązanie werdyktem `ship` dla tej listy.
Bootstrap i odzyskiwanie opisano w README, a tokeny i komponenty w DESIGN.md
oraz `.impeccable/design.json`. Testy i podgląd korzystały z osobnej, tymczasowej
bazy PostgreSQL, bez zmian w lokalnej bazie użytkownika.

**Naprawa P2 2026-10-03:** potwierdzanie zmiany emaila blokuje rekord użytkownika
przez `FOR UPDATE` przed sprawdzeniem tokenu. Token jest powiązany z aktualnym
adresem i identyfikatorem konta; nieaktualny użytkownik oraz token innego konta
są odrzucane. Równoczesne użycie tego samego tokenu lub dwóch tokenów dla
dotychczasowego adresu dopuszcza dokładnie jedną zmianę. Nieudana zmiana
pozostawia dane konta i tokeny bez zmian.

Ujednolicono okno autoryzacji ustawień do 10 minut w HTTP i LiveView. Po jego
wygaśnięciu zapis z otwartej strony przekierowuje do logowania z komunikatem,
bez awarii LiveView, wysłania emaila ani uruchomienia formularza zmiany hasła.
Dodano testy współbieżności na osobnych połączeniach PostgreSQL z kontrolowaną
barierą blokady oraz testy formularzy po 11 i 21 minutach, granicy 10 minut,
powiązania tokenu z kontem i rollbacku. Testy nie używają usypiania procesów.

Weryfikacja naprawy: `mix precommit` przeszedł (127 testów, brak ostrzeżeń
kompilacji i uwag Credo), podobnie `mix assets.build`. Sprawdzenia korzystały
z osobnej, tymczasowej instancji PostgreSQL, bez zmian w lokalnej bazie użytkownika.
Oba testy współbieżności przeszły również przy jednym schedulerze BEAM.

### Krok 2. Organizacje, członkostwa i zaproszenia

- Dodać kontekst `AiControl.Organizations`, organizacje `active/suspended`, unikalne członkostwa, indywidualne przydziały i jednorazowe zaproszenia ważne 24 godziny. Zachować UUID i istniejące konta.
- Zbudować panel organizatora: utworzenie, zawieszenie i przywrócenie organizacji oraz zaproszenie pierwszego superadmina. Przed akceptacją organizacja może nie mieć superadmina; baza wymusza maksymalnie jednego.
- Rozdzielić superadmina, admina i usera zgodnie z tabelą. Przekazanie roli do istniejącego admina jest atomowe; poprzedni superadmin zachowuje jawne przydziały jako admin.
- Admin zarządza tylko userami, nie może promować adminów ani zmieniać własnego dostępu. Deleguje funkcje i zasoby w granicach własnych przydziałów; zachowuje pozostały dostęp edytowanego użytkownika.
- Token zaproszenia ma 32 losowe bajty i jest przechowywany jako hash. GET pokazuje formularz, POST z CSRF atomowo tworzy nowe konto z hasłem i potwierdzeniem emaila, członkostwo, przydziały oraz zużywa token. Istniejące konto wymaga logowania na zaproszony email i zachowuje dane oraz inne członkostwa.
- Akceptacja ponownie sprawdza autora i status organizacji. Odwołanie oraz ponowienie unieważniają token; błąd Swoosh pozostawia odwołane zaproszenie do ponowienia. Zawieszenie nie przedłuża 24 godzin. Trasy tokenów nie trafiają do logów.
- Rozszerzyć `current_scope` o organizację z URL, członkostwo, przydziały i jawny tryb organizatora. Konto może należeć do wielu organizacji; karty przeglądarki działają niezależnie.
- Wspólny `Access` odświeża stan z bazy i sprawdza funkcje oraz zasoby. Operacje zmieniające dostęp blokują organizację w transakcji; PubSub publikuje po zatwierdzeniu w tematach organizacji i użytkownika.
- Sprawdzać dostęp w kontekstach, plugach HTTP oraz hookach LiveView przy parametrach, zdarzeniach i aktualizacjach. Usunięcie członkostwa, odebranie prawa lub zawieszenie odbiera dostęp w otwartym widoku, zachowując sesję i pozostałe organizacje.
- Dodać wybór organizacji, overview, członków i edycję dostępu. Zachować obecny system wizualny, angielski UI, oba motywy, responsywność, osobne `.ex`/`.html.heex`, `to_form`, `<.input>`, streams i stabilne DOM ID; przeprowadzić odbiór `impeccable`.
- Dostarczyć model zasobów i adapter `ResourceResolver`; konkretny przydział wymaga potwierdzenia przynależności do organizacji. Rejestry i egzekwowanie runtime pozostają w krokach 3, 5 i 6.

**Gotowe, gdy:** testy potwierdzają izolację URL i identyfikatorów, hierarchię oraz
ograniczenia delegacji, domyślną odmowę, granicę ważności i jednorazowość zaproszeń,
odwołanie i błąd mailera, nowe oraz istniejące konto, równoczesną akceptację i
przekazanie superadmina, odebranie dostępu w LiveView i regresje kont. Przechodzą
`mix precommit`, `mix assets.build` i odbiór desktop/mobile, jasnego/ciemnego motywu,
klawiatury oraz stanów formularzy na osobnej bazie testowej, bez usypiania testów.

**Odbiór 2026-10-03:** ukończono na gałęzi `JL/step-2-organizations-access`,
utworzonej z aktualnej `main` po `git fetch origin` i aktualizacji fast-forward.
Baza zawiera scalony krok 1 z [PR #2](https://github.com/jlitewka99/hackyeah2026/pull/2).
Wdrożono organizacje, role, przydziały, zaproszenia i panel opisane powyżej.

`mix precommit` przeszedł: 161 testów, brak ostrzeżeń kompilacji i uwag Credo.
`mix assets.build` przeszedł. Testy obejmują izolację i delegację, akceptację,
wygaśnięcie, ponowienie i błąd dostarczenia zaproszeń, równoczesne przyjęcie
tokenu oraz przekazanie superadmina na osobnych połączeniach PostgreSQL,
odebranie dostępu w otwartym LiveView oraz regresje ustawień i logowania.
Granice czasu są ustawiane w danych testowych; synchronizacja współbieżności
wykorzystuje blokady i wiadomości, bez usypiania procesów.

Przegląd `impeccable` objął sześć ekranów, desktop 1440 px i mobile 390 px,
oba motywy oraz fokus klawiatury. Detektor nie wykazał problemów blokujących;
pozostała zastana uwaga o kroju wielkości `1rem`. Niezależny reviewer wskazał
brak stanu oczekiwania w czterech rodzajach akcji; po poprawce i ponownych
24 zrzutach potwierdził rozwiązanie tej listy werdyktem `ship`.
README opisuje migrację, role, zaproszenia i adapter zasobów. Zachowano
istniejący system wizualny. Testy i podgląd korzystały z osobnej, tymczasowej
instancji PostgreSQL; końcowe testy użyły wydzielonej bazy bez danych podglądu.

Przydziały konkretnych agentów i modeli wymagają przyszłych rejestrów oraz
adaptera potwierdzającego przynależność do organizacji. Do tego czasu UI
udostępnia jawne selektory wszystkich zasobów; wywołania AI i niezweryfikowane
konkretne przydziały są odrzucane. Integracja polityki i gatewaya pozostaje
w krokach 3, 5 i 6.

**Naprawa regresji kroku 2 — 2026-10-03:** akceptacja zaproszenia przez
uwierzytelnione, istniejące konto zachowuje token sesji, dokładny
`authenticated_at`, remember-me, CSRF i identyfikator LiveView. Usuwa
`user_return_to` i przekierowuje do przyjętej organizacji bez tworzenia
dodatkowej sesji. Nowe konto nadal otrzymuje sesję po atomowej aktywacji.
Rozróżnienie korzysta z uwierzytelnionego `current_scope`.

Niepoprawny changeset zaproszenia otrzymuje `action: :insert`, dzięki czemu
oba formularze pokazują komunikat pola i `aria-invalid`. Po udanym wysłaniu
formularz zachowuje wysłany email i rolę, usuwa poprzednie błędy oraz zachowuje
wybór organizacji i zaznaczone przydziały. Nie zmieniono publicznego API ani
schematu bazy.

**Weryfikacja naprawy:** 11 testów kontrolera i formularzy przeszło;
`mix precommit` przeszedł z 166 testami, bez ostrzeżeń kompilacji i uwag Credo.
`mix assets.build` przeszedł. Regresje obejmują sesje uwierzytelnione 1, 11
i 21 minut wcześniej, brak dodatkowej sesji, dokładny czas uwierzytelnienia,
remember-me, identyfikator LiveView, pozostałe członkostwa oraz żądania z
rzeczywistym tokenem CSRF. Dla sesji sprzed 11 i 21 minut ustawienia nadal
wymagają logowania, a zmiana hasła zostaje odrzucona bez zmiany hasha.
Zachowano testy nowego konta, niewłaściwego konta i jednorazowości zaproszeń.
Email dłuższy niż 160 znaków nie zapisuje zaproszenia ani nie wysyła emaila;
poprawienie danych pozwala wysłać zaproszenie i usuwa błąd. Czas ustawiono
w danych testowych, bez usypiania procesów.

Odbiór w przeglądarce objął oba formularze w ośmiu wariantach: desktop
1440 px / mobile 390 px, jasny / ciemny motyw, błąd → sukces. Zapisano
16 zrzutów; potwierdzono widoczny fokus, obsługę Tab/Enter, komunikaty,
`aria-invalid`, zachowanie wyborów i brak poziomego przewijania. W bazie
podglądu powstało dokładnie osiem poprawnych zaproszeń z właściwymi rolami
i przydziałami. Testy i podgląd użyły dwóch wydzielonych baz tymczasowej
instancji PostgreSQL; mailer podglądu był lokalny.

Ograniczony odbiór `impeccable` nie wykazał regresji w badanych stanach.
Detektor: 0 błędów, 1 zastana uwaga o rozmiarze `1rem` legendy przydziałów.
Sprawdzenie mobile dotyczyło viewportu przeglądarki; urządzenia fizyczne
iOS nie były testowane, a zastane pola zachowują rozmiar 14 px. Odświeżenie
sidecara pozostaje osobnym zadaniem.

### Krok 3. Agenci i klucze API

- Dodać rejestr agentów: nazwa, identyfikator, organizacja, status.
- Podłączyć `ResourceResolver` do rejestru agentów i filtrować panel według przydziałów `agents.*` oraz `api_keys.*`; każde działanie ponownie sprawdza scope i przynależność zasobu.
- Klucz API przypisać do jednej organizacji i jednego agenta.
- Generować losowy sekret o co najmniej 256 bitach entropii; pokazywać go tylko przy utworzeniu. Przechowywać hash, identyfikator i bezpieczny prefiks.
- Obsłużyć wygaśnięcie, odwołanie i rotację klucza.
- Uwierzytelniać przez `Authorization: Bearer …`. Organizację i agenta wyznaczać z klucza, a nie z danych przesłanych przez klienta.

**Gotowe, gdy:** poprawny klucz identyfikuje agenta; klucz odwołany lub przypisany do zawieszonej organizacji nie działa.

**Odbiór 2026-10-03:** zaimplementowano na gałęzi
`JL/step-3-agents-api-keys`, opartej na aktualnym `main` wraz ze scalonymi
poprawkami kroku 2, przełącznikiem organizacji i infrastrukturą audytu kroku 4
(`main` na commicie `c29b07f`). Rejestr obsługuje utworzenie, zmianę nazwy, zawieszenie
i przywrócenie. Klucze mają sekret z 32 losowych bajtów, hash SHA-256 całego
tokenu i prefiks z publicznego UUID. Domyślna ważność wynosi 90 dni;
dostępne są przyszła data UTC i brak wygaśnięcia. Rotacja w jednej transakcji
tworzy następcę i odwołuje poprzedni klucz. Zgodność organizacji klucza
i agenta wymusza złożony klucz obcy.

`GET /v1/auth` zwraca wyłącznie trzy identyfikatory principalu. Wszystkie
błędy poświadczenia dają jednakowe 401, `WWW-Authenticate: Bearer`
i `Cache-Control: no-store`. Każde żądanie sprawdza aktualny stan bazy;
klucz pozostaje tożsamością agenta po usunięciu członkostwa autora.
Operacje panelu sprawdzają aktualne uprawnienia i selektory. Domyślny
resolver weryfikuje rzeczywistych agentów; przydziały konkretnych modeli
pozostają zamknięte do kroku 6. Formularze zaproszeń i dostępu pozwalają
wybrać kilku agentów w granicach delegacji.

**Weryfikacja po integracji z najnowszym `main`:** `mix precommit` przeszedł
z 259 testami, bez ostrzeżeń
kompilacji i uwag Credo; `mix assets.build`, Dialyzer, Sobelow oraz audyt
zależności przeszły. Testy użyły wydzielonej instancji PostgreSQL
na porcie 54883 i bazy `ai_control_teststep3`. Obejmują izolację,
uprawnienia, wildcard i konkretne selektory, delegację, złożony klucz obcy,
Bearer, granicę wygaśnięcia, odwołanie, zawieszenie/przywrócenie,
rollback oraz konkurujące rotacje na osobnych połączeniach, bez usypiania.
Sprawdzono też usuwanie sekretu po zmianie dostępu i jego brak w logach,
powiadomieniach oraz późniejszych odpowiedziach; zachowano regresje
sesji i formularzy zaproszeń kroku 2. Dodatkowy test sprawdza aktualizację
przełącznika organizacji w otwartych panelach agentów i kluczy.

Odbiór w przeglądarce objął desktop 1440×1000 i mobile 390×844,
oba motywy, listy, filtrowanie, walidację, widoczny fokus klawiatury,
kopiowanie, zamknięcie oraz utratę połączenia. Po rozłączeniu wartość
sekretu i atrybut `value` znikały z DOM; ponowne połączenie nie odtwarzało
sekretu. Zapisano 21 końcowych zrzutów na syntetycznych danych
w oddzielnej bazie podglądu; nie było poziomego overflow. Recenzent
impeccable wskazał ucinanie nazw w selektorze przydziałów; po zamianie
na zawijane checkboxy ocenił tę poprawkę jako rozwiązaną z werdyktem
`ship` dla ocenianych poprawek. Fizyczne urządzenia mobilne nie były
testowane. Przegląd dokumentacyjny impeccable zachował istniejący
system wizualny; zastanego driftu sidecara nie naprawiano w tym rozszerzeniu.
Gateway, pełne zarządzanie politykami i rejestr modeli pozostają
w kolejnych krokach. Istniejące kontrakty decyzji, minimalnego silnika polityk
i audytu kroku 4 są zachowane; audyt administracji agentów i kluczy
pozostaje poza zakresem tej zmiany.

### Krok 4. Wspólna domena decyzji i podstawowy audyt

- Utworzyć `SecurityContext`, `GuardResult`, `Detection`, `SecurityAssessment` i `Decision`.
- Guardy zwracają wykrycia i sygnały; `Policy.Engine` wyznacza `ALLOW`, `REDACT` lub `BLOCK`.
- Dodać audyt decyzji i zmian administracyjnych od początku prac.
- Zapisywać identyfikatory, etap kontroli, reguły, wersję polityki, czasy i fingerprinty. Wykluczyć surowe prompty, odpowiedzi, argumenty narzędzi i sekrety z logów.
- Zabezpieczyć również logowanie parametrów Phoenix i błędów HTTP.

**Gotowe, gdy:** decyzję można wyjaśnić na podstawie audytu bez ujawnienia sprawdzanej treści.

**Odbiór 2026-10-03:** ukończono na gałęzi `JL/step-4-security-audit`, na bazie
scalonego kroku 2. Powstały walidowane kontrakty w
`AiControl.Security`, minimalny czysty `AiControl.Policy.Engine`, snapshot
z checksumem obliczanym z reguł oraz synchroniczny, tenant-scoped `AiControl.Audit`.
Audyt przechowuje działania, progi, wymagane guardy, wykrycia bez wartości,
kody przyczyn, czasy i fingerprinty HMAC, co pozwala wyjaśnić również dopuszczenie
wykrycia poniżej progu bez pobierania sprawdzanej treści.

Zmiany organizacji, członkostw, przekazania superadmina i zaproszeń są audytowane
w tej samej transakcji. Błąd zapisu wycofuje zmianę; PubSub działa po zatwierdzeniu.
Wydawanie zaproszeń zapisuje audyt przed wysłaniem emaila; błąd dostarczenia
pozostawia audytowany odwołany token, a błąd tego audytu wycofuje nowe zaproszenie.
Zapisy decyzji są idempotentne, a zmiana danych przy ponowieniu jest odrzucana.
Odczyt odświeża `events.read` oraz izolację organizacji. Identyfikatory agentów
i kluczy są opcjonalnymi UUID bez zależności od schematów kroku 3.

Zastąpiono surowe logi HTTP bezpiecznymi metadanymi i serwerowymi UUID,
wyłączono debugger oraz RequestLogger, logi wyjątków Bandita i domyślne logi
ponowień/przekierowań Req. Produkcyjne uruchomienie wymaga osobnego
`AUDIT_FINGERPRINT_KEY`; środowisko rozwojowe używa lokalnego klucza z
`config/dev.exs`. Konfigurację i kontrakty opisano w README.

`mix precommit` przeszedł: 203 testy po dołączeniu poprawek kroku 2 z `main`,
brak ostrzeżeń kompilacji aplikacji i uwag
Credo. `mix assets.build` przeszedł. Testy obejmują priorytet decyzji, granice
progów, awarie guardów, integralność snapshotu, izolację i odebranie dostępu,
idempotencję, rzeczywiste odrzucenia zapisu w PostgreSQL i rollback, błędy mailera,
pojedynczy audyt przy współbieżnej akceptacji i przekazaniu roli oraz brak sekretów
w rekordach, logach DEBUG i odpowiedziach rzeczywistego serwera Bandit.
Użyto osobnej tymczasowej instancji PostgreSQL, bez zmian w lokalnej bazie
użytkownika i bez usypiania procesów w testach. Pełne zarządzanie politykami,
gateway, detektory, wykonanie redakcji, dashboard i eksport pozostają
w odpowiednich kolejnych krokach.

### Krok 5. Centralny Policy Engine

- Dodać niezmienne wersje polityk i jedną aktywną wersję na organizację.
- Polityka obejmuje guardy, działania dla kategorii wykryć, progi, dozwolone modele, uprawnienia agentów i budżety.
- Połączyć indywidualne przydziały agenta/modelu z ograniczeniami polityki; żaden przydział nie uchyla zakazu organizacji.
- Dodać profile `relaxed`, `balanced`, `strict`; jawne ustawienie konkretnej reguły nadpisuje domyślne ustawienie profilu.
- Import YAML oraz formularze panelu wykorzystują ten sam walidator.
- Zapis tworzy niezmienną, nieaktywną wersję; aktywacja i rollback są osobnymi operacjami z oczekiwaną rewizją. Aktywację, historię i audyt zapisać w jednej transakcji, a po commit uzupełnić ETS i opublikować PubSub.
- Każde żądanie zachowuje jeden snapshot polityki przez wszystkie swoje etapy. Nowe żądania używają nowej wersji.

**Gotowe, gdy:** błędna polityka nie zastępuje aktywnej, a zmiana `redact → block` zmienia wynik kolejnego żądania.

**Status odbioru (2026-10-03):** wdrożono globalną politykę organizatora,
dziedziczenie oraz pełne polityki organizacji, wersje, aktywacje, rollback,
historię, wspólny walidator formularza/YAML, eksport i nadzorowany cache ETS.
Migracja inicjalizuje systemową wersję `balanced`, model `qwen3.5:4b`, wszystkich
aktywnych agentów organizacji oraz nieskonfigurowane budżety. Panel organizacji
i platformy zachowuje istniejący system wizualny, pokazuje różnice przed aktywacją
i zachowuje edycję przy PubSub. PostgreSQL wymusza przynależność wersji do zestawu;
blokady i rewizje chronią przed utratą równoczesnych zmian. Audyt platformowy jest
dostępny tylko organizatorowi, a odczyty organizacji pozostają izolowane.
Testy potwierdzają `redact → block` dla nowego żądania z zachowaniem starej decyzji
w rozpoczętym wcześniej żądaniu, współbieżną aktywację, rollback przy błędzie
audytu, opóźniony cache, odbudowę ETS oraz przecięcie polityki i bieżących
przydziałów. Odbiór wykonano na oddzielnej instancji PostgreSQL. Gateway,
detektory, wykonanie redakcji i liczniki budżetowe pozostają w kolejnych krokach;
ten krok dostarcza ich konfigurację i kontrakty.

`mix precommit` przeszedł: 298 testów ExUnit, 3 testy JavaScript, brak uwag
Credo i ostrzeżeń kompilacji. Przeszły również `mix assets.build`, Dialyzer,
Sobelow, audyt zależności i sprawdzenie lockfile wymagane przez CI. Przykładowy
`priv/policies/balanced.yaml` przeszedł wspólny walidator.

Odbiór `impeccable` objął desktop 1440 px, mobile 390 px, widok 1280 px,
oba motywy, klawiaturę, długie wartości, edycję, błędy i podgląd zmian.
Niezależny przegląd wskazał nieaktualne porównanie po zmianie polityki oraz
odległy komunikat błędu YAML. Po poprawkach reviewer zamknął obie uwagi
werdyktem `ship` dla tej listy. Końcowa dokumentacja zachowuje istniejący
system wizualny i opisuje uwagi detektora bez rozszerzania jego zasad.

### Krok 6. Gateway LLM i konfiguracja środowiska

- Dodać `POST /v1/chat/completions`, uwierzytelniane `GET /v1/models`, `GET /health` i `GET /ready`. Katalog zwraca tylko modele dostępne dla bieżącej tożsamości i polityki, nie całą konfigurację backendu.
- W pierwszej wersji obsługiwać tekst, wiadomości, definicje narzędzi i `stream: false`. Nieobsługiwane formaty odrzucać jawnie.
- Użyć `Req` do komunikacji z Ollama; ustawić timeouty, limity rozmiaru oraz brak automatycznych ponowień generacji.
- Docelowy adres backendu pochodzi z konfiguracji operatora.
- Przygotować wymienny adapter providera oraz pipeline korzystający z `SecurityContext`, `GuardResult`, `SecurityAssessment`, snapshotu i audytu kroków 4–5. Pobrać snapshot raz na żądanie; deklarowane przez klienta `user_id` nie zastępuje tożsamości z Bearer/scope.
- Dodać prosty limiter wejściowy na istniejącym Hammer/ETS, przed kosztownymi kontrolami, oraz ograniczenie równoczesnych wywołań LLM/sidecarów. Rezerwacje i trwałe limity organizacji/agenta powstają w kroku 9. Zwolnić slot również po timeout, anulowaniu i zakończeniu procesu żądania.
- Dodać sprawdzanie model allowlist przed wywołaniem modelu.
- Podłączyć katalog modeli do `ResourceResolver` i egzekwować dostęp do AI oraz obu wymiarów zasobów dla wywołań użytkownika przed polityką i downstream. Klucze agentów podlegają osobnemu zakresowi klucza i polityce.
- `/health` sprawdza żywotność aplikacji, `/ready` gotowość bazy, aktywnej polityki, backendu i wymaganych usług guardów; odpowiedzi nie ujawniają adresów ani sekretów. Niedostępna wymagana kontrola nie jest zastępowana wynikiem `:ok`.
- Emitować zdarzenia `:telemetry` dla żądań, odmów, audytu, kontrolowanych błędów i latencji upstream. Metadane zawierają zamknięte identyfikatory, bez promptów, odpowiedzi i nagłówków Authorization.
- Domyślny model demo: `qwen3.5:4b`. Zapisać używany digest modelu w konfiguracji demo. [Model](https://ollama.com/library/qwen3.5:4b), [kompatybilność API Ollama](https://docs.ollama.com/api/openai-compatibility).

**Gotowe, gdy:** klient z kluczem API otrzymuje odpowiedź lokalnego modelu przy jawnej polityce testowej, niedozwolony model nie zostaje wywołany, a błędy upstream/guardów/audytu mają kontrolowane odpowiedzi. Do ukończenia wymaganych guardów test proxy używa wydzielonej organizacji z jawną konfiguracją nieobowiązkowych, wyłączonych kontroli. Nie osłabia domyślnej polityki `balanced` ani nie udaje gotowego enforcement; brak obowiązkowej kontroli nadal blokuje. Testy obejmują timeout, limit rozmiaru i współbieżności, izolację katalogu oraz brak wywołania backendu po odmowie lub błędzie audytu.

**Odbiór 2026-10-03:** ukończono na gałęzi `JL/step-6-llm-gateway`, po
pobraniu aktualnego `main`. `AiControl.Gateway` łączy wymienny provider,
adapter Ollama oparty na `Req`, katalog operatora i filtrowane API.
Autoryzacja odświeża tożsamość, `ai.use` i oba przydziały zasobów; klucz
pozostaje przypisany do własnego agenta i organizacji. Każde żądanie zachowuje
jeden snapshot. Audyt wejścia poprzedza wszystkie wywołania backendu, a ocena
i audyt wyjścia poprzedzają odpowiedź. Kontrakty etapów i redakcja UTF-8
umożliwiają analizę semantyczną aktualnej treści po redakcji deterministycznej.

Dodano terminalny audyt odrzucenia, błędu i zakończenia, bezpieczną telemetry,
limiter Hammer/ETS 60/min na aktora w organizacji oraz nadzorowane sloty
1 LLM / 2 guardy, z natychmiastowym `429` i sprzątaniem po timeout/anulowaniu.
Transport ogranicza wejście do 1 MiB i odpowiedź do 4 MiB, nie ponawia generacji
ani nie podąża za przekierowaniami. Konfiguracja obejmuje timeouty i pojemność.
`/health` oraz `/ready` zwracają bezpieczne wyniki żywotności i gotowości.
Formularze zaproszeń i dostępu pokazują konkretne modele z katalogu,
zachowując wildcard, delegację, stan błędu i przydziały poza zakresem admina.

Pobrano i uruchomiono `qwen3.5:4b` w Ollama 0.35.1; pełny digest manifestu:
`2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd`.
Rzeczywisty test Bearer/API z polską odpowiedzią i audytem obu etapów przeszedł
na wydzielonej bazie oraz organizacji z jawną polityką wyłączonych guardów.
Domyślna `balanced` pozostała bez zmian i odmawia przez `503`, gdy brakuje
wymaganej kontroli. Nie zaimplementowano detektorów ani wykonania narzędzi.

`mix precommit`: **330 testów ExUnit, 3 testy JavaScript**, brak uwag Credo
i ostrzeżeń kompilacji aplikacji; 1 test rzeczywistego modelu wyłączony z CI.
Ten test uruchomiony osobno przeszedł. Przeszły `mix assets.build`, Dialyzer,
Sobelow i audyt zależności oraz rollback/up migracji na osobnej bazie testowej.
Testy obejmują aktualne przydziały i izolację, allowlist oraz digest, snapshot
podczas aktywacji, brak downstream po odmowie/błędzie audytu, redakcję przed
semantyką, blokadę wyjścia, limity i sprzątanie slotów. Przegląd `impeccable`
desktop 1440 px / mobile 390 px i obu motywów zakończył się `ship` dla
selektorów modeli. Przegląd dokumentacyjny zachował istniejące pliki systemu
wizualnego; zastanego driftu nie naprawiano w tym rozszerzeniu.

### Krok 7. Deterministyczne guardy, NER i sygnatury

- Implementować kolejno: PESEL, NIP, REGON, NRB/IBAN, karty płatnicze i email.
- Rozpoznawanie numerów oprzeć na ograniczonych wzorcach kandydatów, walidacji struktury i sumach kontrolnych. Obsłużyć udokumentowane separatory, zachowując mapowanie do oryginalnego tekstu; nie łączyć dowolnych cyfr z odległych fragmentów.
- PESEL: 11 cyfr, wagi `1,3,7,9,1,3,7,9,1,3`, dekodowanie stulecia i rzeczywistej daty, również lat przestępnych. NIP: 10 cyfr i checksum; REGON: jawnie obsługiwane warianty 9 i 14 cyfr. [Opis PESEL](https://www.gov.pl/web/gov/czym-jest-numer-pesel).
- NRB/IBAN: polski NRB 26 cyfr, IBAN `PL` + 26 cyfr, kontrola mod-97; zagraniczny IBAN wymaga jawnego katalogu długości krajowych. [Rejestr IBAN](https://www.swift.com/standards/data-standards/iban-international-bank-account-number). Karty: Luhn, dozwolona długość i kontekst; sam Luhn nie odróżnia karty od przypadkowego numeru.
- W MVP uruchomić lokalny sidecar Presidio + Stanza PL/NKJP i osobny guard `ner`. Mapować `persName` na osobę, `placeName` i `geogName` na typy miejsc oraz `orgName` na organizację; pełne adresy wymagają dodatkowych reguł kontekstowych.
- Sidecar zwraca typ i zakres encji; Elixir waliduje zakresy UTF-8 dla bieżącej wersji tekstu i egzekwuje decyzję. Redakcja deterministyczna poprzedza NER i injection; wymagane awarie kończą przetwarzanie.
- Wprowadzić nową wersję schematu polityki dla NER i narzędzi, zachowując walidację i checksumy wersji 1. Nowe kontrole wymagają utworzenia i jawnej aktywacji nowej wersji.
- Testować polskie odmiany, Unicode, osoby/miejsca/organizacje, adresy i awarie sidecara; nie przenosić F1 NKJP na jakość PII w aplikacji.
- Dodać detektory kluczy prywatnych, JWT, tokenów, credentials AWS/GitHub/Google, haseł i connection strings. Wzorce dostawców przypiąć do wersjonowanego zestawu; skanować także nagłówki PEM i wartości po etykietach `password`, `secret`, `api_key`.
- JWT w wariancie JWS compact rozpoznawać jako trzy segmenty rozdzielone **dwoma** kropkami, z walidacją formatu base64url/header; nie logować payloadu. Format JWT lub identyfikator klucza jest wykryciem według polityki, nie dowodem aktywnego poświadczenia.
- Heurystyka entropii uwzględnia długość, alfabet i kontekst. Dodać bezpieczne przypadki dla hashy, UUID, kodu i danych technicznych; nie blokować każdej losowej wartości. Wzorce można adaptować z [detect-secrets](https://github.com/Yelp/detect-secrets), zachowując licencję i pochodzenie; bez wysyłania znalezionych sekretów do usług weryfikujących.
- Zbudować wspólny redaction engine z obsługą nakładających się zakresów i tekstu Unicode.
- Wyniki używają indeksu pola treści i offsetów bajtowych UTF-8 z kroku 4. Skanowanie działa na oryginale; po redakcji kolejne detektory wyznaczają zakresy względem aktualnego tekstu. Audyt nie zawiera wartości, snippetów ani całych wyjątków; ewentualne fingerprinty wykorzystują istniejący tenant-scoped HMAC.
- Dodać wersjonowane sygnatury dla obsługiwanych wzorców exploitów, np. niebezpiecznej deserializacji i wykonania kodu. Każdej sygnaturze przypisać regułę oraz bezpieczny przypadek porównawczy.
- Redagować treść przed przekazaniem do backendu, w tym przed semantycznymi kontrolami, które nie potrzebują surowej wartości.

**Gotowe, gdy:** każdy obsługiwany typ ma poprawny przykład i bezpieczny przypadek porównawczy; poprawny PESEL zostaje wykryty, błędna data lub checksum nie wywołuje wykrycia PESEL, a sekret nie pojawia się w logach. Podstawowy NER działa z rzeczywistym sidecarem na polskich odmianach i rozróżnia osoby, miejsca oraz organizacje; reguły uzupełniają adresy. Testy sprawdzają separatory, granice kandydatów, nakładające się zakresy, Unicode, treść faktycznie przesłaną po redakcji i zatrzymanie po awarii wymaganej warstwy. Nowa wersja polityki jest jawnie aktywowana; historyczne checksumy wersji 1 pozostają poprawne. Inne detektory mogą niezależnie zaklasyfikować ten sam tekst.

**Odbiór — 2026-10-03:** guardy `AiControl.Guards`, trzy fazy ze wspólnym snapshotem, walidacja zakresów i redakcja, lokalny Presidio/Stanza PL/NKJP, schemat v2 i rozszerzenie edytorów, katalogi offline z checksumami i licencjami oraz wieloetapowy kontener Phoenix + NER są zaimplementowane. PostgreSQL/Ollama pozostają zewnętrzne. `mix precommit`: 354 testy Elixir i 3 JavaScript; `mix check.all`, build assetów, 4 testy Python z rzeczywistymi modelami i osobny test gatewaya z rzeczywistym HTTP NER przechodzą. Pomiar 40 krótkich syntetycznych analiz na Mac ARM64: ładowanie 5142,5 ms, mediana 40,7 ms, p95 62,9 ms, szczyt RSS 1 031 028 736 B. Szczegóły: [odbiór kroku 7](docs/acceptance/step7.md).

**Odbiór kontenera i UI:** [Linux CI 37155097455](https://github.com/jlitewka99/hackyeah2026/actions/runs/37155097455) na `46d50c3` zakończył wszystkie pięć jobów sukcesem, w tym build obrazu, rzeczywisty NER i transport release, bootstrap, awarie obu procesów oraz SIGTERM. Pomiar Linux x86_64: ładowanie 7856,8 ms, mediana 105,4 ms, p95 155,5 ms, szczyt RSS 1 049 505 792 B. Lokalny daemon Docker pozostaje niedostępny. Impeccable zwrócił `ship` po odbiorze desktop/mobile, obu motywów i klawiatury; przegląd dokumentacyjny potwierdził zachowanie istniejącego systemu. Pełny output filtering, semantyczny guard, panel Signatures i wykonywanie narzędzi pozostają w krokach 8, 10, 11 i 12. Odświeżenie istniejącego `.impeccable/design.json` komendą `document` jest osobnym zadaniem. Coolify nie wdrażano.

### Krok 8. Output filtering

**Praca równoległa:** po ukończeniu 7 realizować równolegle z 9, 10 i 12A. Ten krok jest właścicielem NER wyjścia, reprezentacji odpowiedzi i walidacji redagowanych argumentów; rozliczenia i provider AI należą do osobnych branchy.

- Przeskanować wszystkie pola odpowiedzi mogące zawierać treść: odpowiedzi tekstowe i argumenty proponowanych wywołań narzędzi.
- Ponownie zastosować PII, secret detection, sygnatury i osobny `ner`, konfigurowany również dla wyjścia.
- Wykonać decyzję polityki przed zwróceniem odpowiedzi klientowi.
- Zachować informację, czy naruszenie wystąpiło na wejściu, czy na wyjściu.
- Buforować całą odpowiedź dla `stream: false`; żadna treść ani argumenty narzędzia nie trafiają do klienta przed oceną i wymaganym audytem. Redakcja argumentów musi zachować poprawny JSON i schemat; gdy nie może, blokować propozycję wywołania.
- Przy blokadzie zwracać stały komunikat odmowy i identyfikator żądania, bez cytowania naruszenia. Nie ponawiać generacji ani nie przełączać modelu automatycznie. Usage naliczać również za zablokowaną odpowiedź po podłączeniu kroku 9.
- Przygotować etap dla moderacji AI z kroku 10; klasyfikator prompt injection nie jest domyślnie klasyfikatorem szkodliwości odpowiedzi.

**Gotowe, gdy:** sekret wygenerowany przez model zostaje zablokowany lub zredagowany zgodnie z polityką, audyt rozróżnia oba etapy, a tekst i argumenty narzędzi nie wyciekają przy blokadzie, błędzie guardu lub zapisu audytu. Bezpieczna odpowiedź zachowuje wspierany format API.

### Krok 9. Budżety i rozliczanie użycia

**Praca równoległa:** po ukończeniu 7 realizować równolegle z 8, 10 i 12A. Nie wymaga ukończenia 8 do budowy liczników i integracji z istniejącym gatewayem; wspólne scenariusze blokady wyjścia są sprawdzane po scaleniu.

- Wprowadzić limity żądań i tokenów na godzinę dla organizacji i agentów oraz wywołań narzędzi na workflow. Pełne rozliczanie narzędzi i workflowów zostaje podłączone w krokach 12 i 15.
- Okna godzinowe liczyć w UTC. Zmiana polityki nie zeruje zużycia.
- Zachować schema budżetów kroku 5; konfiguracje minutowe/per-user z researchu są ewentualnym późniejszym rozszerzeniem, a nie zmianą istniejących jednostek.
- Trwały limit liczby żądań sprawdzać atomowo po autoryzacji zasobów i przed kosztownymi guardami. Udokumentować, które odrzucone żądania nalicza ten limit; limiter wejściowy chroni również próby bez skutecznej autoryzacji.
- Przed wywołaniem modelu rezerwować tokeny wejścia i maksymalną liczbę tokenów wyjścia; po odpowiedzi rozliczyć rzeczywiste usage.
- Dla twardego limitu wymagać licznika zgodnego z tokenizerem modelu. Przy nieznanym zużyciu pozostawić konserwatywną rezerwację.
- PostgreSQL utrzymuje trwałe liczniki i rezerwacje; transakcje oraz blokady zapewniają atomowość. ETS służy do szybkiego odczytu stanu.
- Rezerwować oba poziomy limitu w jednej transakcji, ze stałą kolejnością blokad i identyfikatorem rezerwacji. Check-then-decrement ani sam `:ets.update_counter` nie zapewnia trwałego, atomowego warunku dla wielu limitów.
- Przykład: przy limicie 5000 i rezerwacji 4000 równoczesne żądanie wymagające kolejnych 4000 dostaje 429; po usage 2200 zwrócić 1800. Rozliczenie jest idempotentne i zwalnia tylko niewykorzystaną część. Żądanie odrzucone przed generacją nie zużywa tokenów, ale nadal podlega limiterowi wejściowemu.
- Na potwierdzonym braku wysłania żądania zwalniać rezerwację; przy timeout/anulowaniu po wysłaniu lub braku usage utrzymać bezpieczne obciążenie do uzgodnienia. Restart/TTL nie zwraca automatycznie tokenów za potencjalnie wykonaną generację. Jeśli usage przekroczy rezerwację, zapisać całe użycie i zatrzymać kolejne żądania; nie ukrywać przekroczenia.
- Rezerwacja należy do okna rozpoczęcia także po zmianie godziny. Obniżenie limitu poniżej zużycia blokuje nowe rezerwacje, nie zeruje liczników. Rozdzielić liczniki żądań, tokenów i aktywnych wywołań; 429 zawiera `Retry-After` zgodny z przyczyną odmowy.
- Rozliczać usage niezależnie od końcowej decyzji output filtering; NER i reguły adresowe wyjścia należą do kroku 8, nie do kontekstu budżetów.
- Dodać rozliczanie kosztów według skonfigurowanego cennika. Bez cennika pokazywać „not configured”.

**Gotowe, gdy:** równoczesne rezerwacje nie przekraczają limitu organizacji ani agenta, a restart aplikacji nie odnawia wykorzystanego budżetu. Testy obejmują podwójne rozliczenie, timeout przed/po wysłaniu, brak usage, blokadę outputu, zmianę okna i obniżenie limitu. Wynik estymacji i warunki twardego limitu są opisane, a zużycie guardów AI mierzone oddzielnie od usage modelu docelowego.

### Krok 10. Semantyczne wykrywanie prompt injection

**Praca równoległa:** po ukończeniu 7 realizować równolegle z 8, 9 i 12A przez istniejący kontrakt guardu z 6. Wspólna integracja moderacji wyjścia korzysta z reprezentacji utrzymywanej w 8; benchmark providera nie czeka na budżety ani narzędzia.

- Wprowadzić zachowanie providera oraz implementacje lokalnego klasyfikatora i mocka.
- Porównać `Llama-Prompt-Guard-2-86M` i `Qwen3Guard-Gen-0.6B` na wspólnym polskim zbiorze z sekcji 5.1. Najpierw sprawdzić dostępność wag, licencję i uruchomienie lokalne. Prompt Guard 22M jest opcjonalnym wariantem wydajnościowym, nie zamiennikiem o potwierdzonej jakości polskiego.
- Uruchomić wybrany model jako lokalną usługę HTTP wywoływaną przez `Req`; rdzeń pozostaje w Elixirze. Sidecar nie jest publicznym endpointem aplikacji i nie zapisuje treści żądań. Przypiąć wersję wag, tokenizer i format odpowiedzi; Ollama/GGUF wymaga potwierdzenia poprawnego template i wyników po quantization.
- Długie treści dzielić według tokenizera modelu na nachodzące fragmenty; Prompt Guard ma okno 512 tokenów. Sprawdzać wszystkie pola i cały tekst, także końcówkę. Równoległe skanowanie ma ograniczoną współbieżność oraz timeout całego żądania; przekroczenie limitu pracy nie oznacza pominięcia kontroli.
- Zwracać rzeczywisty wynik klasyfikatora; decyzję podejmuje polityka. Numeric score Prompt Guard pozwala stroić próg; etykiety Qwen wymagają jawnego mapowania kategorii/severity i nie są prawdopodobieństwem. Jeśli adapter korzysta z `confidence` do reprezentacji sygnału binarnego, oznaczyć tę semantykę w kontrakcie i audycie; nie przedstawiać jej jako skalibrowanej pewności modelu.
- Nie uznawać kategorii `Jailbreak` Qwen za dowód pełnej ochrony indirect injection. Wybrać provider dopiero po porównaniu direct/indirect injection oraz FPR na bezpiecznych tekstach; w razie potrzeby zachować oddzielny klasyfikator injection i opcjonalny moderator odpowiedzi.
- Dodać moderację wyjścia przy użyciu modelu przeznaczonego do odpowiedzi, np. Qwen3Guard-Gen, jeśli aktywna polityka ją wymaga. Kategorie ogólnego safety nie mieszczą się automatycznie w katalogu `pii/secret/exploit/prompt_injection` z kroku 5: rozszerzenie wymaga walidatora, wersjonowania, formularzy i testów zgodności starych polityk. Nie mapować wszystkich szkodliwych odpowiedzi na prompt injection.
- Wspólne fail-closed obejmuje timeout, brakujące pola, nieznaną etykietę, uszkodzony JSON i niepełne skanowanie. Nie próbować „sanityzować” injection przez usuwanie przypadkowych instrukcji; blokować zgodnie z polityką.
- Domyślnie awaria obowiązkowej kontroli blokuje żądanie. Opcjonalne dopuszczenie prostego chatu podczas awarii wymaga jawnej polityki i audytu.

**Gotowe, gdy:** prawdziwy model semantyczny uczestniczy w enforcement, polski benchmark ma zapisane wyniki i uzasadnia wybór providera. Zmiana progu rzeczywistego score lub jawnego mapowania etykiet zmienia decyzję; blokada działa również dla ataku na końcu długiego tekstu. Testy mocków pokrywają błędy i fail-closed, a suite `--live-models` potwierdza działanie wybranych wag oraz moderacji wyjścia, jeśli ją włączono.

### Krok 11. Dashboard i zamknięcie wymaganego MVP

**Zależności odbioru:** kroki 6–10, podstawowy NER z 7–8 i pełny krok 12 muszą być ukończone. Krok 12 wykonujemy przed tym odbiorem.

**Praca równoległa:** 11A (strony, metryki i eksport) realizować po scaleniu 8–10 równolegle z 12B. 11B obejmuje wspólny odbiór po pełnym 12; budowa dashboardu nie wymaga czekania na ukończenie firewalla.

- Zbudować strony: Overview, Events, Policies, Budgets, Agents i Signatures.
- Pokazywać rzeczywiste decyzje, aktywne kontrole, wersję polityki, zużycie i zmierzone opóźnienia.
- Rozdzielić opóźnienia guardów, rezerwacji, upstream i całego żądania; pokazywać p50/p95, wykrycia według guardu/etapu, odmowy budżetowe i błędy usług. Nie tworzyć nieuzasadnionego „security score”.
- Dodać filtry zdarzeń, szczegóły decyzji i eksport JSONL.
- Eksport zawiera identyfikatory żądania/etapu, politykę i checksum, działania, rule/detector IDs, rzeczywiste sygnały oraz bezpieczne dane usage; bez surowych wartości, promptów i odpowiedzi. Odczyt i eksport ponownie sprawdzają `events.read`/`events.export` oraz organizację.
- Aktualizować widoki przez PubSub z tematami oddzielnymi dla organizacji.
- Formularze korzystają z `<.input>` i `to_form`; kolekcje z LiveView streams; strony z osobnych `.ex` i `.html.heex`.
- Zakończyć wymagane testy pozytywne i negatywne oraz mapowanie do FR-01–FR-22.
- Dostarczyć minimalne demo: safe allow, PESEL redact/block, secret block na wejściu i wyjściu, injection z bezpiecznym porównaniem, exploit i 429 przy limicie; pokazać zmianę aktywnej polityki bez restartu. Scenariusze narzędzi/RAG dołączają dopiero odpowiednie kroki.

**Kamień milowy MVP:** działają auth, izolacja organizacji, proxy LLM, centralne polityki, kontrole deterministyczne, NER i AI, input/output filtering, budżety, pełny tool ACL, audyt, dashboard i testy.

### Krok 12. Tool firewall i ograniczenia zasobów

**Praca równoległa:** 12A (katalog, autoryzacja, walidatory i sandboxowe adaptery) realizować po ukończeniu 7 równolegle z 8–10. 12B łączy te moduły z endpointem, budżetami, kontrolami wyników i semantyką po scaleniu pierwszej fali; dopiero wtedy odbierać pełny krok 12.

**Plan implementacji 12A — 2026-10-03:**

1. Dodać zamknięty katalog identyfikatorów operacji i schematów argumentów oraz
   `AiControl.Tools.ToolRequest`. Przyjmować wyłącznie nazwę narzędzia i argumenty;
   organizację/agenta/klucz przypisywać ze zweryfikowanego `Principal`.
2. Przygotować żądanie na jednym snapshotcie istniejącej polityki v2. Przeciąć
   `allowed_agents` i `tools.allowed_tools` z zasobami dopuszczonymi przez operatora
   sandboxa dla konkretnego agenta. Polityka v1 i brak przydziału oznaczają odmowę.
3. Walidować kanoniczne ścieżki, symlinki, dokładne adresy HTTP z przypiętym IP,
   operacje/tabele bazy, pojedynczych odbiorców i zamknięte komendy bez powłoki.
   HTTP przez `Req`, bez redirectów, retry, proxy ani rozwiązywania DNS podczas
   połączenia; prywatne IP tylko przy jawnym wyjątku operatora dla endpointu demo.
4. Dodać izolowany sandbox per organizacja: wirtualne pliki, tabele demo,
   lokalna skrzynka i komendy zaimplementowane w Elixirze. Pliki/baza/email/komendy
   nie korzystają z zasobów hosta. Jedynym zewnętrznym I/O jest jawny endpoint HTTP.
5. Testować dozwolone wykonania, odmowy bez efektów, podmianę tożsamości,
   unieważnienie klucza/agenta/organizacji, snapshot, schematy i ataki na zasoby.
   Uruchomić `mix precommit`, zapisać odbiór i stworzyć PR z opisem po angielsku.

12A nie wprowadza zmian frontendowych ani publicznej ścieżki wykonywania narzędzi.
Sandbox jest adapterem demo dla zaufanego kodu; produkcyjne wykonanie, trwałe
liczniki, wymagane guardy, audyt i filtrowanie wyników pozostają w 12B. Checkbox
całego kroku 12 pozostaje niezaznaczony do odbioru 12B.

**Odbiór 12A — 2026-10-04:** zaimplementowano `AiControl.Tools`, `ToolRequest`,
zamknięty katalog siedmiu operacji i schematy argumentów, autoryzację na istniejącym
snapshotcie v2 oraz dokładne przydziały zasobów operatora per organizacja/agent.
Sandbox udostępnia wirtualne pliki, odczyt tabel demo, lokalną skrzynkę, komendy
Elixira bez powłoki i rzeczywisty HTTP przez `Req` z przypiętym IP. Walidatory
odmawiają traversal, symlinków, SSRF, redirectów i nieuprawnionych operacji;
klucz, agent i organizacja są ponownie sprawdzane przed efektem. Argumenty
i polityka nie są ujawniane przez `Inspect` żądania. Instrukcje i granice integracji:
[sandbox narzędzi](docs/tools.md).

Przeszło **30 testów 12A** oraz `mix precommit`: **384 testy Elixir i 3 JavaScript**,
bez uwag Credo i ostrzeżeń kompilacji aplikacji. Dwa istniejące testy rzeczywistych
modeli/NER pozostają standardowo wyłączone z tego zestawu; 12A ich nie zmienia.
Testy obejmują odmowy bez efektów, podmianę tożsamości, wygaśnięcie/unieważnienie
klucza, zawieszenie, snapshot przy zmianie polityki, Unicode/limity rozmiaru
i rzeczywisty lokalny HTTP również przez pełną ścieżkę sandboxa. Bez zmian
frontendu, migracji ani zależności. **12A jest ukończone; 12B i pełny krok 12
pozostają nieukończone**: endpoint, trwałe liczniki, wymagane guardy, audyt wykonania
i filtrowanie wyników wymagają osobnej integracji po scaleniu 8–10.

**Ponowny przegląd 12A — 2026-10-04:** odtworzono i poprawiono dwie luki:
ponowna autoryzacja zmienionych argumentów nie sprawdzała całkowitego limitu JSON,
a globalne opcje `Req` mogły dołączyć dane uwierzytelniające/parametry lub podmienić
transport. Limit 64 KiB jest teraz sprawdzany przed efektem; surowe żądanie `Req`
pomija globalne opcje i middleware. Dodano trzy testy regresji oraz rzeczywisty
test HTTPS dla przypiętego IP, poprawnego CA/hosta i odmowy obcego CA/błędnego
hosta. `mix precommit` przeszedł: **388 testów Elixir (w tym 34 testy 12A) i 3
JavaScript**, bez uwag Credo i ostrzeżeń kompilacji aplikacji; dwa istniejące testy
modeli/NER pozostają wyłączone. Granica 12B pozostaje bez zmian.

- Dodać `ToolRequest`, katalog narzędzi ze schematami argumentów i `POST /v1/tool_calls`. Organizacja i agent pochodzą wyłącznie ze zweryfikowanej tożsamości; domyślna odmowa jest niezależna od oceny modelu.
- Dodać tenant-scoped identyfikator wykonania i trwały licznik wywołań narzędzi z kroku 9. Pełna orkiestracja workflowów pozostaje w kroku 15.
- Sprawdzać uprawnienia agenta, operację, zasób, argumenty i budżet przed wykonaniem.
- Dodać walidatory ścieżek, domen/IP, operacji bazodanowych, odbiorców email i dozwolonych komend.
- Uwzględnić traversal, symlinki, przekierowania HTTP i prywatne adresy IP. Lokalne usługi demo mają jawne wyjątki operatora.
- Wyniki narzędzi również filtrować.
- Przygotować sandboxowe narzędzia demo: pliki, HTTP, baza demo, lokalna skrzynka email i zamknięta lista komend. Scenariusz indirect injection próbuje odczytać `~/.ssh/id_rsa` lub wyprowadzić dane; ACL zatrzymuje akcję przed wykonaniem.
- Testować podmianę organizacji/agenta, traversal, symlinki, SSRF, przekierowania, operacje bazy, odbiorców email, komendy i filtrowanie wyników.

**Gotowe, gdy:** agent może użyć dozwolonego narzędzia na dozwolonym zasobie, a zabroniony zasób zostaje zatrzymany przed wykonaniem.

### Krok 13. MCP gateway

- Dodać `/mcp` jako adapter do istniejącego pipeline’u.
- Przypiąć wspieraną wersję protokołu `2025-11-25` i transport Streamable HTTP; zaimplementować inicjalizację, ping, listowanie i wywoływanie narzędzi oraz odczyt zasobów. [Specyfikacja transportu](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).
- Uwierzytelniać klientów kluczami API; izolować stan protokołu według organizacji i agenta.
- Walidować Origin oraz wersję protokołu.
- Pokazywać klientowi wyłącznie dozwolony katalog; każde wywołanie ponownie autoryzować.

**Gotowe, gdy:** klient MCP wykonuje dozwolone operacje przez gateway, a niedozwolone nie trafiają do downstream.

### Krok 14. Głęboka analiza semantyczna

- Dodać provider `granite4.1-guardian:8b` uruchamiany przez Ollama.
- Włączać analizę dla podejrzanego wejścia, uprzywilejowanych zasobów i operacji wysokiego ryzyka.
- Przekazywać cel workflow, tożsamość agenta, uprawnienia, działanie i konkretne kryterium.
- Użyć BYOC do sprawdzenia zgodności proponowanych wywołań narzędzi; po podłączeniu RAG w kroku 18 oceniać groundedness. Kontrole ścieżek, schematów i uprawnień z kroku 12 wykonują się wcześniej.
- Parsować wynik zgodnie z formatem modelu; odpowiedź yes/no zachować jako sygnał binarny. [Dokumentacja Granite Guardian](https://www.ibm.com/granite/docs/models/guardian).
- Ustalić kierunek kryterium: `yes` oznacza spełnienie zadanego kryterium, a nie zawsze zgodę na działanie. Nie zapisywać reasoning traces; poprawność polskich kryteriów i lokalne opóźnienia wymagają oddzielnej ewaluacji.
- Przy awarii operacje wysokiego ryzyka są blokowane.

**Gotowe, gdy:** semantyczna ocena działania może zaostrzyć decyzję, a deterministyczny zakaz zawsze pozostaje skuteczny.

### Krok 15. Workflowy, runaway protection i wielu agentów

- Dodać rejestr workflowów z celem, właścicielem, czasem startu i stanem.
- Uruchamiać proces workflow pod nazwanym `DynamicSupervisor` i `Registry`.
- Egzekwować maksymalny czas, liczbę wywołań, tokeny, głębokość delegacji i powtarzanie tej samej akcji.
- Delegacja agent→agent zachowuje organizację oraz wspólny nadrzędny budżet; agent docelowy nadal podlega własnym uprawnieniom.
- Przekroczenie limitu kończy workflow i zatrzymuje następne operacje.

**Gotowe, gdy:** pętla lub delegacja nie pozwala obejść budżetu.

### Krok 16. Oban, raporty i testy w panelu

- Dodać Oban dla raportów, eksportów, enrichmentu, odświeżania feedów i uruchamiania scenariuszy testowych.
- Każde zadanie przenosi zweryfikowany kontekst organizacji.
- Podstawowy audyt decyzji pozostaje zapisywany synchronicznie.
- Przygotować workerów `AuditExport`, `MetricsReport`, `GuardRefresh` i uruchamiania benchmarków. Eksporty ograniczać cursorami/partiami, retry i deduplikacją; ponownie sprawdzać uprawnienia przy wykonaniu oraz pobraniu wyniku. Joby nie przenoszą promptów ani sekretów w argumentach.
- Ewentualny `PolicyReload` importuje i waliduje kandydacką wersję; aktywacja nadal korzysta z transakcji i oczekiwanej rewizji kroku 5. Oban ani Phoenix code reloader nie zastępują procesu aktywacji polityki.
- Dodać metryki kolejek, błędów i czasu pracy oraz opcjonalny eksport Prometheus/Grafana. Nie używać treści, kluczy API ani per-request UUID jako etykiet Prometheus; dostęp do endpointu metryk ogranicza konfiguracja operatora.
- Feed sygnatur przechodzi walidację i kompilację przed aktywacją.
- Dodać stronę Tests z wynikami kontrolowanych scenariuszy i oznaczeniem danych testowych.

**Gotowe, gdy:** awaria zadania w tle nie zmienia decyzji bezpieczeństwa ani nie usuwa jej podstawowego audytu.

### Krok 17. Streaming

- Dodać obsługę SSE po ukończeniu filtrowania pełnych odpowiedzi.
- Osobno porównać Qwen3Guard-Stream z buforowanym Gen; potwierdzić wspierany runtime, tokenizer i integrację specjalnej głowicy. Dostępność wariantu Stream nie oznacza gotowej obsługi przez zwykłe `/chat/completions` w Ollama.
- Detektory z ograniczonym oknem wykorzystują bufor kroczący; argumenty narzędzi, kontrole całej odpowiedzi i nieograniczone wzorce wymagają pełnego buforowania.
- Żaden fragment nie zostaje wysłany przed odpowiednią kontrolą.
- Dodać limity bufora, obsługę anulowania, rozliczanie częściowego użycia i zdarzenie błędu przy blokadzie.

**Gotowe, gdy:** sekret rozdzielony między chunkami nie wycieka do klienta.

### Krok 18. RAG, pamięć i rozszerzone PII

- Traktować dokumenty, wyniki wyszukiwania i pamięć jako źródła wymagające kontroli.
- Zachować pochodzenie, właściciela i poziom zaufania zasobu.
- Egzekwować izolację organizacji przy odczycie i zapisie pamięci.
- Skanować treść przed dołączeniem do kontekstu i przed utrwaleniem.
- Rozszerzyć istniejący `NerGuard` i sidecar Presidio + Stanza PL/NKJP z kroków 7–8 o potrzeby RAG i pamięci. Podstawowy NER jest już częścią MVP; dalsza jakość PII wymaga pomiarów. Wywołania HTTP używają `Req`, timeoutów i kontrolowanej współbieżności.
- Przypiąć model i mapowanie etykiet do kategorii polityki. Osoba, miejscowość i pełny adres mają różne znaczenie; do adresów dodać kontekstowe reguły ulicy/numeru/kodu pocztowego. Słownik imion nie jest samodzielną podstawą blokady.
- Sidecar zwraca tylko typ i zakres encji oraz score, jeśli model go udostępnia. Przeliczać indeksy znaków na offsety bajtowe UTF-8 dla dokładnie tej samej treści; błędne, niepełne lub niezgodne zakresy odrzucać przed redakcją. Wymagany NER podlega fail-closed.
- Testować polskie odmiany, diakrytyki i kontekst: „Jan Kowalski”, „Romana Kowalskiego”, nazwy firm, miejscowości oraz słowa zbieżne z imionami. Mierzyć precision/recall encji i poprawność redakcji, nie zakładać, że wynik F1 na NKJP opisuje prompty aplikacji.

**Gotowe, gdy:** dokument lub pamięć nie pozwala ominąć autoryzacji zasobów ani przenieść danych między organizacjami.

### Krok 19. Zatwierdzanie działań przez człowieka

- Rozszerzyć decyzję o `REVIEW` dla wskazanych operacji wysokiego ryzyka.
- Administrator organizacji zatwierdza konkretną operację z niezmiennym fingerprintem argumentów.
- Zatwierdzenie jest jednorazowe, ważne 15 minut i nie może uchylić twardego zakazu.
- Przed wykonaniem ponownie sprawdzić aktualną politykę, tożsamość i budżet.
- Zabezpieczyć wykonanie przed powtórzeniem tego samego zatwierdzenia.

**Gotowe, gdy:** zmienione argumenty lub wygasłe zatwierdzenie nie uruchamiają działania.

### Krok 20. Przygotowanie kompletnego demo

- Dodać instrukcję uruchomienia PostgreSQL, Ollama, sidecara i aplikacji oraz bootstrapu organizatora.
- Przygotować przykładowe polityki, dane demo, diagram architektury i ograniczenia poszczególnych detektorów.
- Zweryfikować licencje zależności i modeli.
- Przygotować scenariusze demo, pomiary opóźnień oraz materiały do prezentacji.
- Scenariusze rozszerzają zestaw z kroku 11: indirect injection w dokumencie, zabronione narzędzie, runaway/delegacja, NER i filtr odpowiedzi. Wszystkie używają syntetycznych danych; do wywołań narzędzi służy sandbox, nie zasoby hosta.
- Dostarczyć tabelę wyboru modeli z wynikami polskiego benchmarku, zużyciem pamięci i opóźnieniami na docelowym sprzęcie. Osobno opisać cold start/warm run oraz koszt pracy modelu docelowego i guardów.
- Zakończyć pracę przez `mix precommit`, build assetów i istniejące kontrole CI.

**Gotowe, gdy:** całą demonstrację można uruchomić według dokumentacji, testy rzeczywistych modeli przechodzą, a dashboard i eksport pokazują wyniki enforcement.

## 4. Kontrakty techniczne

- Kod domenowy przyjmuje zweryfikowany scope; `organization_id` i właściciele zasobów są ustawiani przez serwer. Izolacja obejmuje również cache, PubSub, joby, metryki i eksporty.
- Kolejność pipeline’u: **identity → walidacja i limiter wejściowy → snapshot polityki i uprawnienia → trwały limit żądań → guardy wejścia → decyzja/redakcja i synchroniczny audyt wejścia → rezerwacja tokenów → downstream → guardy wyjścia → decyzja/redakcja → rozliczenie użycia i audyt wyjścia → odpowiedź**. Odrzucone oraz nieudane żądania również mają bezpieczny zapis; nie ma wywołania LLM po błędzie audytu wejścia.
- Guardy deterministyczne działają przed modelami AI; zakresy po redakcji odnoszą się do bieżącej treści. Nie scalać zakresów dla różnych wersji tekstu w jednej decyzji: zachować mapowanie do oryginału albo osobne oceny kolejnych redakcji. Snapshot pozostaje ten sam na wszystkich etapach, a tożsamość i status organizacji/agenta są ponownie sprawdzane przed rozpoczęciem nowego działania downstream.
- Priorytet decyzji: `BLOCK` przed `REDACT` przed `ALLOW`. Modele AI dostarczają sygnały, które interpretuje deterministyczny silnik.
- API LLM zachowuje wspierany format Chat Completions. Błędy: `401` brak tożsamości, `403` odmowa polityki, `429` limiter/budżet, `400/413` niepoprawne wejście, `502/504` awaria upstream, `503` niedostępny audyt lub wymagana usługa kontroli. Wszystkie komunikaty są stałe, bez treści naruszenia.
- Panel działa pod `/organizations/:id/*`, panel organizatora pod `/platform/organizations`. Administracyjne API jest chronione sesją i CSRF; klucze agentów nie dają dostępu administracyjnego.
- Dodać `/v1/tool_calls` w kroku 12 oraz `/v1/runs` w kroku 15. Rozbudowane API workflowów nie jest warunkiem wcześniejszego etapu narzędzi; do limitów narzędzi potrzebny jest już w kroku 12 tenant-scoped identyfikator wykonania i jego licznik.
- Jeśli nie można utrwalić wymaganego audytu, żądanie kończy się błędem `503` i nie rozpoczyna nowego wywołania downstream. Jeśli błąd zapisu wystąpi po rozpoczęciu wywołania, nie można cofnąć wykonanej operacji; odpowiedź klientowi i stan rozliczenia wymagają bezpiecznej obsługi oraz ponowienia samego zapisu.
- Wszystkie połączenia HTTP wykorzystują `Req`. Modele i usługi downstream mają wymienne adaptery; domena nie zależy od konkretnego runtime’u modelu.
- Nazwy `/policy`, `/usage` i `/tools/invoke` z researchu opisują funkcje, nie nowe równoległe API. Zachować istniejący panel/polityki, dodać opisany katalog `/v1/models`, eksport w kroku 11 i `/v1/tool_calls` w kroku 12; publiczne API administracyjne wymaga osobnego zakresu tożsamości i uprawnień.
- Profile nie zmieniają się na podstawie dostępności modelu. `relaxed` zachowuje deterministyczne kontrole PII/secrets/exploit; wyłączenie lub opcjonalność guardu wymaga jawnej, wersjonowanej polityki i widocznego audytu. Reasoning ani surowe przykłady audytu z researchu nie są danymi do zapisania w istniejącym schemacie.

## 5. Testy i kryteria odbioru

Testy powstają wraz z każdym etapem. Przyszłe obszary matrycy są realizowane w kroku, który dodaje daną funkcję.

| Obszar | Wymagane scenariusze |
| --- | --- |
| Auth | Poprawne i błędne logowanie, wygasłe zaproszenie, wylogowanie, odwołanie klucza |
| Organizacje | Podmiana identyfikatorów w URL/API, eksportach, workflowach i kanałach aktualizacji |
| Polityki | Niepoprawny YAML, reload, rollback, zmiana progu, jedna wersja przez całe żądanie |
| Guardy | Prawidłowe i błędne numery/daty, separatory, kontekst Luhn/entropii, nakładające się wykrycia, Unicode, brak sekretów w logach |
| Budżety | Limity organizacji i agenta, równoczesne rezerwacje, podwójne rozliczenie, restart, zmiana okna/polityki, timeout przed/po wysłaniu, brak usage |
| AI | Polski atak i bezpieczny tekst porównawczy, direct/indirect injection, atak na końcu długiego promptu, nieznane etykiety, timeout/fail-closed |
| Narzędzia/MCP | Niedozwolona operacja, traversal, symlink, prywatny adres, indirect injection |
| Output/streaming | Sekret wygenerowany przez model, podzielony sekret, filtrowanie argumentów narzędzia |
| Workflow/review | Pętla, delegacja, wygasłe zatwierdzenie, zmiana argumentów, ponowne wykonanie |
| NER | Odmiana i diakrytyki, niejednoznaczne imiona, osoba versus miejsce/adres, mapowanie offsetów, awaria sidecara |
| Audyt/telemetry | Zapis przed downstream, awaria po generacji, izolacja eksportu/metryk, brak surowej treści i sekretów |

ExUnit wykorzystuje `Req.Test`, kontrolowany zegar i `start_supervised!`. Testy LiveView sprawdzają elementy po stabilnych DOM ID. Standardowe testy są powtarzalne bez ciężkich modeli; przed demo obowiązkowo uruchamiane są także testy rzeczywistych modeli.

Skrypt `run_security_tests.sh` powstaje najpóźniej w kroku 11, obsługuje opcję `--live-models`, wyświetla podsumowanie i zwraca niezerowy exit code przy błędzie. Testy nie mogą wymagać płatnej usługi.

### 5.1. Polski benchmark i wybór modeli — krok 10

Przygotować wersjonowany zestaw **200 syntetycznych przypadków** z identyfikatorem, językiem, źródłem/typem treści, oczekiwanymi kategoriami i działaniem dla wskazanej polityki:

| Grupa | Liczba | Zakres |
| --- | --- | --- |
| Bezpieczne | 50 | Q&A, kod, zwykłe instrukcje i cytowanie ataków do analizy; teksty podobne do numerów, nazw i sekretów |
| Direct injection | 50 | Próba zmiany instrukcji, przejęcia roli, wydobycia system promptu lub obejścia zasad |
| Indirect/obfuscated injection | 50 | Dokument/wynik narzędzia, code block, mieszane języki, odstępy, Unicode i fragmentacja; część ataków poza pierwszym oknem modelu |
| PII i prywatność | 50 | Poprawne/błędne PESEL, NIP, REGON, IBAN, karty, email, nazwiska i adresy; oczekiwane zakresy redakcji |

PII nie jest automatycznie injection. Etykiety obejmują każdy kontrolowany typ zagrożenia osobno; porównanie modeli injection nie liczy wykrycia PESEL jako wykrycia ataku. Dodatkowe przypadki output moderation i sekretów mają osobne etykiety oraz bezpieczne odpowiedzi porównawcze.

- Podzielić zbiór przed strojeniem na część kalibracyjną i odłożoną część testową, z równą reprezentacją grup. Podobne parafrazy tego samego ataku pozostają w jednej części. Wersja i checksum datasetu trafiają do raportu.
- Dla score liczbowego sprawdzić progi, np. `0.5–0.9`; dla etykiet Qwen porównać jawne mapowania severity/kategorii. Progi profili z kroku 5 są ustawieniami początkowymi, nie wynikiem tej ewaluacji. Każdą zmianę wdrożyć jako nową politykę.
- Raportować TP/FP/TN/FN, precision, recall i FPR oddzielnie dla direct injection, indirect/obfuscated, PII i moderacji wyjścia. Raportować liczebność grup i błędy usług; mała próba nie uzasadnia twierdzenia „zero false positives”.
- Mierzyć p50/p95 guardu i całego pipeline'u, cold/warm start, RAM, timeouty i wpływ równoczesności. Porównywać na tym samym sprzęcie, tych samych danych i udokumentowanych ustawieniach runtime/quantization.
- Zapisać kryteria wyboru jakości i latencji przed końcową ewaluacją; odłożonego zbioru nie używać do strojenia. Wynik wyboru opisuje słabości na polskich danych i różnicę między wykryciem injection a ogólnym safety.
- Dodać powtarzalną komendę benchmarku w kroku 10, wywołującą sidecary przez `Req` i zapisującą raport JSONL/CSV według ID przypadków, bez surowej treści w logach. Standardowy CI używa mocków; testy rzeczywistych modeli i raport są wymagane przed odbiorem MVP.

### 5.2. Scenariusze demonstracyjne

| Scenariusz | Wynik i dowód | Dostępny po |
| --- | --- | --- |
| Bezpieczny polski prompt | ALLOW, odpowiedź lokalnego modelu i polityka w audycie; rozliczone usage po kroku 9 | 6; pełne kontrole po 10 |
| Poprawny PESEL / błędna suma lub data | REDACT/BLOCK według profilu; bezpieczny przypadek porównawczy; do backendu trafia tekst po redakcji | 7 |
| Syntetyczny klucz API na wejściu i wyjściu | BLOCK/REDACT bez wartości w odpowiedzi odmowy, logach lub eksporcie | 8 |
| Równoczesne żądania przekraczają limit | 429, brak kolejnej generacji i trwały stan rezerwacji | 9 |
| Polski injection i zwykłe cytowanie instrukcji | Rzeczywista decyzja modelu, bezpieczny przypadek porównawczy i raport jakości | 10 |
| Zmiana polityki `redact → block` | Następne żądanie używa nowej wersji, rozpoczęte zachowuje snapshot; dashboard i JSONL wyjaśniają obie decyzje | 11 |
| Dokument sugeruje odczyt klucza SSH lub usunięcie pliku | Tool firewall odmawia przed wykonaniem; sandbox nie zmienia pliku | 12; pobieranie dokumentu przez RAG po 18 |
| Pętla lub delegacja agentów | Wspólny budżet i limity zatrzymują następne operacje | 15 |
| Nazwisko/adres w kontekście | NER mapuje encje i zakresy, redakcja zachowuje tekst Unicode; przykład niejednoznacznego imienia | 18 |

Komendy odbioru:

```bash
mix test
./run_security_tests.sh
./run_security_tests.sh --live-models
mix precommit
mix assets.build
```

**MVP jest ukończone po kroku 11, po uprzednim wykonaniu podstawowego NER i pełnego kroku 12. Pełna roadmapa jest ukończona po kroku 20**, gdy wszystkie scenariusze działają, polityki można zmieniać, a dashboard i eksport pokazują rzeczywiste wyniki enforcement.
