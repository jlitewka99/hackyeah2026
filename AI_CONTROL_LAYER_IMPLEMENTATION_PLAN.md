# AI Control Layer — plan implementacji krok po kroku

## Jak zlecać i realizować kolejne kroki

Plan opiera się na [AI_CONTROL_LAYER_REQUIREMENTS.md](AI_CONTROL_LAYER_REQUIREMENTS.md), przesłanej propozycji architektury i decyzjach ustalonych w rozmowie. Zachowujemy namespace `AiControl` i rozwijamy istniejącą aplikację Phoenix etapami.

Przykładowe zlecenie:

> Wykonaj krok 1 z AI_CONTROL_LAYER_IMPLEMENTATION_PLAN.md. Sprawdź aktualny stan repozytorium, zaimplementuj zakres tego kroku, dodaj wymagane testy, uruchom mix precommit i zaktualizuj jego status w planie.

Zasady dla agenta implementującego:

- Realizuj wskazany krok; kolejne kroki wymagają osobnego zlecenia.
- Przed pracą przeczytaj `AGENTS.md`, wymagania i aktualny kod. Nie generuj ponownie funkcji, które już istnieją.
- Sprawdź zależności od wcześniejszych kroków. Jeśli brakuje istotnej podstawy, wskaż konkretny brak przed rozpoczęciem zależnej implementacji.
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
- **Pełna roadmapa:** najpierw wymagane MVP, następnie narzędzia, MCP, ochrona workflowów i rozszerzenia.
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

## 2. Status realizacji

Checkboxy oznaczają potwierdzone zakończenie kroku, a nie samą obecność kodu.

- [x] Krok 1 — Logowanie i konto organizatora
- [x] Krok 2 — Organizacje, członkostwa i zaproszenia
- [ ] Krok 3 — Agenci i klucze API
- [ ] Krok 4 — Wspólna domena decyzji i podstawowy audyt
- [ ] Krok 5 — Centralny Policy Engine
- [ ] Krok 6 — Gateway LLM i konfiguracja środowiska
- [ ] Krok 7 — Deterministyczne guardy i sygnatury
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

### Krok 3. Agenci i klucze API

- Dodać rejestr agentów: nazwa, identyfikator, organizacja, status.
- Podłączyć `ResourceResolver` do rejestru agentów i filtrować panel według przydziałów `agents.*` oraz `api_keys.*`; każde działanie ponownie sprawdza scope i przynależność zasobu.
- Klucz API przypisać do jednej organizacji i jednego agenta.
- Generować losowy sekret o co najmniej 256 bitach entropii; pokazywać go tylko przy utworzeniu. Przechowywać hash, identyfikator i bezpieczny prefiks.
- Obsłużyć wygaśnięcie, odwołanie i rotację klucza.
- Uwierzytelniać przez `Authorization: Bearer …`. Organizację i agenta wyznaczać z klucza, a nie z danych przesłanych przez klienta.

**Gotowe, gdy:** poprawny klucz identyfikuje agenta; klucz odwołany lub przypisany do zawieszonej organizacji nie działa.

### Krok 4. Wspólna domena decyzji i podstawowy audyt

- Utworzyć `SecurityContext`, `GuardResult`, `Detection`, `SecurityAssessment` i `Decision`.
- Guardy zwracają wykrycia i sygnały; `Policy.Engine` wyznacza `ALLOW`, `REDACT` lub `BLOCK`.
- Dodać audyt decyzji i zmian administracyjnych od początku prac.
- Zapisywać identyfikatory, etap kontroli, reguły, wersję polityki, czasy i fingerprinty. Wykluczyć surowe prompty, odpowiedzi, argumenty narzędzi i sekrety z logów.
- Zabezpieczyć również logowanie parametrów Phoenix i błędów HTTP.

**Gotowe, gdy:** decyzję można wyjaśnić na podstawie audytu bez ujawnienia sprawdzanej treści.

### Krok 5. Centralny Policy Engine

- Dodać niezmienne wersje polityk i jedną aktywną wersję na organizację.
- Polityka obejmuje guardy, działania dla kategorii wykryć, progi, dozwolone modele, uprawnienia agentów i budżety.
- Połączyć indywidualne przydziały agenta/modelu z ograniczeniami polityki; żaden przydział nie uchyla zakazu organizacji.
- Dodać profile `relaxed`, `balanced`, `strict`; jawne ustawienie konkretnej reguły nadpisuje domyślne ustawienie profilu.
- Import YAML oraz formularze panelu wykorzystują ten sam walidator.
- Po walidacji atomowo aktywować wersję i aktualizować cache ETS. Zapisać checksum, autora i czas aktywacji; umożliwić rollback.
- Każde żądanie zachowuje jeden snapshot polityki przez wszystkie swoje etapy. Nowe żądania używają nowej wersji.

**Gotowe, gdy:** błędna polityka nie zastępuje aktywnej, a zmiana `redact → block` zmienia wynik kolejnego żądania.

### Krok 6. Gateway LLM i konfiguracja środowiska

- Dodać `POST /v1/chat/completions`, `GET /health` i `GET /ready`.
- W pierwszej wersji obsługiwać tekst, wiadomości, definicje narzędzi i `stream: false`. Nieobsługiwane formaty odrzucać jawnie.
- Użyć `Req` do komunikacji z Ollama; ustawić timeouty, limity rozmiaru oraz brak automatycznych ponowień generacji.
- Docelowy adres backendu pochodzi z konfiguracji operatora.
- Dodać sprawdzanie model allowlist przed wywołaniem modelu.
- Podłączyć katalog modeli do `ResourceResolver` i egzekwować dostęp do AI oraz obu wymiarów zasobów dla wywołań użytkownika przed polityką i downstream. Klucze agentów podlegają osobnemu zakresowi klucza i polityce.
- Domyślny model demo: `qwen3.5:4b`. Zapisać używany digest modelu w konfiguracji demo. [Model](https://ollama.com/library/qwen3.5:4b), [kompatybilność API Ollama](https://docs.ollama.com/api/openai-compatibility).

**Gotowe, gdy:** klient z kluczem API otrzymuje odpowiedź lokalnego modelu, a niedozwolony model nie zostaje wywołany.

### Krok 7. Deterministyczne guardy i sygnatury

- Implementować kolejno: PESEL, NIP, REGON, NRB/IBAN, karty płatnicze i email.
- Rozpoznawanie numerów oprzeć na kandydatach, walidacji struktury i sumach kontrolnych.
- Dodać detektory kluczy prywatnych, JWT, tokenów, credentials AWS/GitHub, haseł i connection strings.
- Zbudować wspólny redaction engine z obsługą nakładających się zakresów i tekstu Unicode.
- Dodać wersjonowane sygnatury dla obsługiwanych wzorców exploitów, np. niebezpiecznej deserializacji i wykonania kodu. Każdej sygnaturze przypisać regułę oraz bezpieczny przypadek porównawczy.
- Redagować treść przed przekazaniem do backendu, w tym przed semantycznymi kontrolami, które nie potrzebują surowej wartości.

**Gotowe, gdy:** poprawny PESEL zostaje wykryty, błędna suma kontrolna nie wywołuje redakcji, a wykryty sekret nie pojawia się w logach.

### Krok 8. Output filtering

- Przeskanować wszystkie pola odpowiedzi mogące zawierać treść: odpowiedzi tekstowe i argumenty proponowanych wywołań narzędzi.
- Ponownie zastosować PII, secret detection i sygnatury.
- Wykonać decyzję polityki przed zwróceniem odpowiedzi klientowi.
- Zachować informację, czy naruszenie wystąpiło na wejściu, czy na wyjściu.

**Gotowe, gdy:** sekret wygenerowany przez model zostaje zablokowany lub zredagowany zgodnie z polityką.

### Krok 9. Budżety i rozliczanie użycia

- Wprowadzić limity żądań i tokenów na godzinę dla organizacji i agentów oraz wywołań narzędzi na workflow. Pełne rozliczanie narzędzi i workflowów zostaje podłączone w krokach 12 i 15.
- Okna godzinowe liczyć w UTC. Zmiana polityki nie zeruje zużycia.
- Przed wywołaniem modelu rezerwować tokeny wejścia i maksymalną liczbę tokenów wyjścia; po odpowiedzi rozliczyć rzeczywiste usage.
- Dla twardego limitu wymagać licznika zgodnego z tokenizerem modelu. Przy nieznanym zużyciu pozostawić konserwatywną rezerwację.
- PostgreSQL utrzymuje trwałe liczniki i rezerwacje; transakcje oraz blokady zapewniają atomowość. ETS służy do szybkiego odczytu stanu.
- Dodać rozliczanie kosztów według skonfigurowanego cennika. Bez cennika pokazywać „not configured”.

**Gotowe, gdy:** równoczesne żądania nie przekraczają limitu, a restart aplikacji nie odnawia wykorzystanego budżetu.

### Krok 10. Semantyczne wykrywanie prompt injection

- Wprowadzić zachowanie providera oraz implementacje lokalnego klasyfikatora i mocka.
- Uruchomić Prompt Guard 2 jako sidecar HTTP; rdzeń aplikacji pozostaje w Elixirze.
- Długie treści dzielić na nachodzące fragmenty. Model ma okno 512 tokenów, więc nie można analizować wyłącznie początku promptu. [Model card](https://huggingface.co/meta-llama/Llama-Prompt-Guard-2-86M).
- Zwracać rzeczywisty wynik klasyfikatora; decyzję podejmuje polityka.
- Domyślnie awaria obowiązkowej kontroli blokuje żądanie. Opcjonalne dopuszczenie prostego chatu podczas awarii wymaga jawnej polityki i audytu.

**Gotowe, gdy:** prawdziwy model semantyczny uczestniczy w enforcement, a zmiana progu wpływa na wynik.

### Krok 11. Dashboard i zamknięcie wymaganego MVP

- Zbudować strony: Overview, Events, Policies, Budgets, Agents i Signatures.
- Pokazywać rzeczywiste decyzje, aktywne kontrole, wersję polityki, zużycie i zmierzone opóźnienia.
- Dodać filtry zdarzeń, szczegóły decyzji i eksport JSONL.
- Aktualizować widoki przez PubSub z tematami oddzielnymi dla organizacji.
- Formularze korzystają z `<.input>` i `to_form`; kolekcje z LiveView streams; strony z osobnych `.ex` i `.html.heex`.
- Zakończyć wymagane testy pozytywne i negatywne oraz mapowanie do FR-01–FR-22.

**Kamień milowy MVP:** działają auth, izolacja organizacji, proxy LLM, centralne polityki, kontrole deterministyczne i AI, input/output filtering, budżety, audyt, dashboard i testy.

### Krok 12. Tool firewall i ograniczenia zasobów

- Dodać `ToolRequest` oraz katalog narzędzi ze schematami argumentów.
- Sprawdzać uprawnienia agenta, operację, zasób, argumenty i budżet przed wykonaniem.
- Dodać walidatory ścieżek, domen/IP, operacji bazodanowych, odbiorców email i dozwolonych komend.
- Uwzględnić traversal, symlinki, przekierowania HTTP i prywatne adresy IP. Lokalne usługi demo mają jawne wyjątki operatora.
- Wyniki narzędzi również filtrować.
- Przygotować sandboxowe narzędzia demo i scenariusz indirect injection z próbą odczytu `~/.ssh/id_rsa`.

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
- Parsować wynik zgodnie z formatem modelu; odpowiedź yes/no zachować jako sygnał binarny. [Dokumentacja Granite Guardian](https://www.ibm.com/granite/docs/models/guardian).
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
- Feed sygnatur przechodzi walidację i kompilację przed aktywacją.
- Dodać stronę Tests z wynikami kontrolowanych scenariuszy i oznaczeniem danych testowych.

**Gotowe, gdy:** awaria zadania w tle nie zmienia decyzji bezpieczeństwa ani nie usuwa jej podstawowego audytu.

### Krok 17. Streaming

- Dodać obsługę SSE po ukończeniu filtrowania pełnych odpowiedzi.
- Detektory z ograniczonym oknem wykorzystują bufor kroczący; argumenty narzędzi, kontrole całej odpowiedzi i nieograniczone wzorce wymagają pełnego buforowania.
- Żaden fragment nie zostaje wysłany przed odpowiednią kontrolą.
- Dodać limity bufora, obsługę anulowania, rozliczanie częściowego użycia i zdarzenie błędu przy blokadzie.

**Gotowe, gdy:** sekret rozdzielony między chunkami nie wycieka do klienta.

### Krok 18. RAG, pamięć i rozszerzone PII

- Traktować dokumenty, wyniki wyszukiwania i pamięć jako źródła wymagające kontroli.
- Zachować pochodzenie, właściciela i poziom zaufania zasobu.
- Egzekwować izolację organizacji przy odczycie i zapisie pamięci.
- Skanować treść przed dołączeniem do kontekstu i przed utrwaleniem.
- Dodać opcjonalny recognizer nazw i adresów wykorzystujący lokalny model; sprawdzać poprawność zwracanych zakresów przed redakcją.

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
- Zakończyć pracę przez `mix precommit`, build assetów i istniejące kontrole CI.

**Gotowe, gdy:** całą demonstrację można uruchomić według dokumentacji, testy rzeczywistych modeli przechodzą, a dashboard i eksport pokazują wyniki enforcement.

## 4. Kontrakty techniczne

- Kod domenowy przyjmuje zweryfikowany scope; `organization_id` i właściciele zasobów są ustawiani przez serwer. Izolacja obejmuje również cache, PubSub, joby, metryki i eksporty.
- Kolejność pipeline’u: **identity → walidacja → polityka i uprawnienia → guardy wejścia → decyzja/redakcja → rezerwacja budżetu → downstream → guardy wyjścia → rozliczenie → audyt → odpowiedź**.
- Priorytet decyzji: `BLOCK` przed `REDACT` przed `ALLOW`. Modele AI dostarczają sygnały, które interpretuje deterministyczny silnik.
- API LLM zachowuje wspierany format Chat Completions. Błędy: `401` brak tożsamości, `403` odmowa polityki, `429` budżet, `400/413` niepoprawne wejście, `502/504` awaria upstream.
- Panel działa pod `/organizations/:id/*`, panel organizatora pod `/platform/organizations`. Administracyjne API jest chronione sesją i CSRF; klucze agentów nie dają dostępu administracyjnego.
- Dodać `/v1/tool_calls` w kroku 12 oraz `/v1/runs` w kroku 15. Rozbudowane API workflowów nie jest warunkiem wcześniejszego etapu narzędzi; do limitów narzędzi potrzebny jest już w kroku 12 tenant-scoped identyfikator wykonania i jego licznik.
- Jeśli nie można utrwalić wymaganego audytu, żądanie kończy się błędem `503` i nie rozpoczyna nowego wywołania downstream. Jeśli błąd zapisu wystąpi po rozpoczęciu wywołania, nie można cofnąć wykonanej operacji; odpowiedź klientowi i stan rozliczenia wymagają bezpiecznej obsługi oraz ponowienia samego zapisu.
- Wszystkie połączenia HTTP wykorzystują `Req`. Modele i usługi downstream mają wymienne adaptery; domena nie zależy od konkretnego runtime’u modelu.

## 5. Testy i kryteria odbioru

Testy powstają wraz z każdym etapem. Przyszłe obszary matrycy są realizowane w kroku, który dodaje daną funkcję.

| Obszar | Wymagane scenariusze |
| --- | --- |
| Auth | Poprawne i błędne logowanie, wygasłe zaproszenie, wylogowanie, odwołanie klucza |
| Organizacje | Podmiana identyfikatorów w URL/API, eksportach, workflowach i kanałach aktualizacji |
| Polityki | Niepoprawny YAML, reload, rollback, zmiana progu, jedna wersja przez całe żądanie |
| Guardy | Prawidłowe i błędne numery, nakładające się wykrycia, Unicode, brak sekretów w logach |
| Budżety | Granica limitu, równoczesne rezerwacje, restart, zmiana okna, timeout upstream |
| AI | Atak i bezpieczny tekst porównawczy, długi prompt, niedostępny lub błędnie odpowiadający provider |
| Narzędzia/MCP | Niedozwolona operacja, traversal, symlink, prywatny adres, indirect injection |
| Output/streaming | Sekret wygenerowany przez model, podzielony sekret, filtrowanie argumentów narzędzia |
| Workflow/review | Pętla, delegacja, wygasłe zatwierdzenie, zmiana argumentów, ponowne wykonanie |

ExUnit wykorzystuje `Req.Test`, kontrolowany zegar i `start_supervised!`. Testy LiveView sprawdzają elementy po stabilnych DOM ID. Standardowe testy są powtarzalne bez ciężkich modeli; przed demo obowiązkowo uruchamiane są także testy rzeczywistych modeli.

Skrypt `run_security_tests.sh` powstaje najpóźniej w kroku 11, obsługuje opcję `--live-models`, wyświetla podsumowanie i zwraca niezerowy exit code przy błędzie. Testy nie mogą wymagać płatnej usługi.

Komendy odbioru:

```bash
mix test
./run_security_tests.sh
./run_security_tests.sh --live-models
mix precommit
mix assets.build
```

**MVP jest ukończone po kroku 11. Pełna roadmapa jest ukończona po kroku 20**, gdy wszystkie scenariusze działają, polityki można zmieniać, a dashboard i eksport pokazują rzeczywiste wyniki enforcement.
