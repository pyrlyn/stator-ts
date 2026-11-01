# TODO: параллелизм в stator-ts

Все проценты ниже — грубые оценки по чтению кода, а не замеры. Перед каждым изменением нужен бенчмарк до/после.

## 1. Общий неизменяемый слой типов из lib.d.ts + разбиение по связным группам импортов

**Что исправить.** `checkProgram` (checker.zig) создаёт в `runGroup` для каждого потока свой `Checker.new` и заново вызывает `d.initGlobals(c)`. Каждый поток заново строит глобальные типы и заполняет свою таблицу `interned` (types.zig). `partition` раскладывает файлы только по размеру (`src.len`) и не учитывает граф импортов.

**Почему (оценка 20–40% на проверке).** Типы из lib.d.ts и общих .d.ts вычисляются N раз, по разу на каждый поток. Когда связанные файлы попадают в разные группы, тяжёлые общие модули тоже разрешаются несколько раз.

**Как.**
```zig
// checker.zig
pub fn checkProgram(a: Allocator, p: *project.Program) []Diag {
    // 1) один раз, однопоточно: базовый Checker для lib-слоя
    var base_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    const base = Checker.new(base_arena.allocator(), p);
    d.initGlobals(base);
    base.freeze(); // после этого interned/global_cache только читаются
    // 2) группы по компонентам связности графа sf.resolved
    var w = Work{ .prog = p, .base = base, .groups = partitionByImports(a, p, files.items, n), ... };
    pool.parallelFor(n, n, &w, runGroup);
}

fn runGroup(w: *Work, _: usize, i: usize) void {
    const c = Checker.newChild(a, w.prog, w.base); // поиск: сначала свой interned, потом base.interned
    ...
}
```
`partitionByImports`: union-find по `sf.resolved`, отдельно файлы lib/.d.ts. Затем компоненты раскладываются жадно, как в нынешнем `partition`: самые большие идут в наименее загруженный поток.

## 2. mmap при чтении + следующая волна без барьера

**Что исправить.** `loadOne` (project.zig) читает файл через `readFile` (`readFileAlloc` в арену). `load` ждёт конца всей волны в `pool.parallelFor` и только потом в одном потоке вызывает `add` для новых файлов.

**Почему (оценка 10–30% на холодном старте).** Один медленный файл держит всю волну. Копирование больших .d.ts (lib.dom.d.ts и пр.) лишнее.

**Как.**
```zig
// project.zig
fn readFile(a: Allocator, io: Io, path: []const u8) ![]const u8 {
    // для файлов > 64 KiB: std.posix.mmap(null, size, PROT.READ, .{ .TYPE = .PRIVATE }, fd, 0)
    // иначе как сейчас readFileAlloc
}
// load: вместо волн — общая очередь задач
fn loadOne(l: *Loading, w: usize, i: usize) void {
    ... parse/bind/resolve ...
    for (sf.pending) |rp| if (rp) |path| l.enqueue(path); // dedup через by_path под мьютексом
}
```
`orderFiles` уже восстанавливает детерминированный порядок, поэтому порядок загрузки на результат не влияет.

## 3. Создать все выходные папки заранее + пакетная запись

**Что исправить.** `emitOne` (driver.zig) на каждый файл вызывает `createDirPath` и `writeFile`. `copyAssets` (testrun.zig) работает последовательно.

**Почему (оценка 10–20% на emit).** Повторяется лишний `mkdir -p` в одни и те же папки, и на каждый файл идёт отдельный набор системных вызовов.

**Как.**
```zig
// driver.zig
pub fn emitFiles(j: *EmitJob) void {
    const dirs = uniqueOutputDirs(a, j);          // StringHashMap путей dirname(out)
    for (dirs) |d| Io.Dir.cwd().createDirPath(j.io, d) catch {};
    pool.parallelFor(j.prog.jobs, j.files.len, j, emitOne); // emitOne без createDirPath
}
```
Вывод перед записью можно копить в буфере потока и писать пачками. `copyAssets` стоит перевести на `parallelFor`.

## 4. Один постоянный пул потоков на запуск

**Что исправить.** `parallelFor` (pool.zig) на каждый вызов делает `std.Thread.spawn` со стеком `stack_size = 256 MiB` и потом `join`. Его вызывают обход каталогов, каждая волна `load`, `checkProgram`, `emitFiles`, scan и тесты. Работа раздаётся через `next.fetchAdd(1, .monotonic)`, по одному индексу за раз.

**Почему.** На каждой волне потоки создаются заново: резервируется виртуальная память под стеки и тратится время на spawn/join. На мелких файлах атомарный счётчик с шагом 1 упирается в одну кэш-линию. В `checkProgram` раздача статическая (n групп на n потоков), поэтому балансировки там нет вообще.

**Как.**
```zig
pub const Pool = struct {
    threads: []std.Thread,
    // очередь задач + std.Thread.ResetEvent / Condition для пробуждения
    pub fn init(jobs: usize) !*Pool;    // один раз в main.zig
    pub fn parallelFor(self: *Pool, count: usize, ctx: anytype, comptime work: anytype) void;
    pub fn deinit(self: *Pool) void;
};
```
Раздача кусками: `fetchAdd(chunk)`, `chunk = max(1, count / (jobs * 8))`. Позже можно добавить work-stealing: у каждого потока своя очередь, а пустой поток забирает задачи из хвоста чужой.

## 5. Риск гонок: emitOne → isTypeAlias → resolveAlias

**Проверено в коде.** `isTypeAlias` (driver.zig) вызывает `Program.resolveAlias` (project.zig). Функция принимает `*const Program`, кэша нет: она только читает `decls`, `moduleOfDecl`, `exportOf`, `resolveModuleName` и `Symbol.resolve` (binder.zig, проход по `merged`). Гонки сейчас нет. Это держится только на том, что функция чистая. Если добавить в неё мемоизацию, понадобится атомарная запись или кэш на поток.

**Checker и общие символы.** Найденные ленивые записи (`s.ret`, `s.pred`, `s.erased`, `p.ty` в decls.zig и relate.zig) идут в `Sig` и в параметры, которые создаёт сам Checker в своей арене. Записей в общие `Symbol` из binder я не нашёл. Чтобы это не сломалось незаметно, стоит добавить проверку, например debug-assert, что Checker не пишет в символы из `Program`. Отдельно нужно перепроверить кэши, если появится общий слой из п.1: после `freeze()` он должен быть строго read-only.

## 6. Однопоточные участки

**Что исправить.**
- `Program.add` и цикл между волнами в `load` (project.zig): `realPathFileAlloc` (системный вызов на каждый импорт), `packageKey`, `readPackageId` (чтение и парсинг package.json) и вставки в `by_path`/`by_file`/`by_root`.
- `driver.run`: сбор всех диагностик, `std.mem.sort(..., lessDiag)` и последовательный вывод с `lineCol` и `fspath.relative` на каждую строку.

**Почему.** На больших проектах с node_modules `realpath` и package.json становятся заметной последовательной частью. Сортировка и вывод важны только при тысячах ошибок.

**Как.** Делать `realpath` и `readPackageId` в `loadOne`, параллельно, и класть результат в `sf.pending`. В `add` останется только вставка в хэш-таблицы. Диагностики сортировать внутри каждой группы в `runGroup` и потом сливать k-way merge. Вывод собирать в один буфер и делать один `writeAll`.

## 7. Декомпозиция pool.zig

Факт: в pool.zig сейчас 47 строк: `stack_size`, `jobCount`, `parallelFor` и один тест. Цифра «~18 600 строк в 18 файлах» относится ко всему src/, а не к pool.zig. Делить стоит не ради размера, а чтобы разнести ответственность, когда появятся пул и стратегии раздачи (п.4).

### 7.1. Модуль постоянного пула потоков (`pool/threads.zig`)

**Что вынести.** Создание и join потоков, `stack_size`, `jobCount`, ожидание и пробуждение рабочих потоков.

**Почему.** Жизненный цикл потоков отделяется от того, как делится работа. Пул создаётся один раз в main.zig.

**Пример API.**
```zig
pub const stack_size = 256 * 1024 * 1024;
pub fn jobCount(requested: usize) usize;
pub const ThreadPool = struct {
    pub fn init(gpa: Allocator, jobs: usize) !*ThreadPool;
    pub fn run(self: *ThreadPool, task: Task) void; // раздать задачу всем потокам и дождаться
    pub fn deinit(self: *ThreadPool) void;
};
```

### 7.2. Модуль раздачи работы (`pool/schedule.zig`)

**Что вынести.** Атомарный счётчик (сейчас `next.fetchAdd(1, .monotonic)` в `Run.loop`), раздачу кусками, позже work-stealing, а также статическое разбиение по весам (сейчас `partition` в checker.zig).

**Почему.** Стратегию можно менять и тестировать отдельно, без потоков: шаг 1 для тяжёлых файлов, куски для мелких.

**Пример API.**
```zig
pub const Strategy = union(enum) { single, chunked: usize, stealing };
pub const Cursor = struct {
    next: std.atomic.Value(usize),
    total: usize,
    pub fn claim(self: *Cursor, chunk: usize) ?struct { start: usize, end: usize };
};
pub fn partitionByWeight(a: Allocator, weights: []const u64, n: usize) [][]usize;
```

### 7.3. Тонкие обёртки parallelFor (`pool.zig`)

**Что оставить.** Только публичный фасад, через который его зовут project.zig, driver.zig, checker.zig, testrun.zig и main.zig. Сигнатура вызова в местах использования почти не меняется.

**Почему.** Вызывающий код не знает ни о потоках, ни о стратегии. Существующий тест «parallelFor visits every index once» остаётся тут.

**Пример структуры.**
```zig
// pool.zig
pub const threads = @import("pool/threads.zig");
pub const schedule = @import("pool/schedule.zig");
pub fn parallelFor(tp: *threads.ThreadPool, count: usize, ctx: anytype, comptime work: anytype) void; // .chunked по умолчанию
pub fn parallelForEach(tp: *threads.ThreadPool, count: usize, ctx: anytype, comptime work: anytype) void; // шаг 1, для тяжёлых задач
pub fn parallelGroups(tp: *threads.ThreadPool, groups: [][]usize, ctx: anytype, comptime work: anytype) void; // для checkProgram
```

## 8. Реструктуризация: два пакета рядом в `packages/`

### Что сделать
- Всё текущее содержимое репозитория `stator` (`~/GitHub/listepo/apps/stator`) перенести во внутреннюю папку `packages/stator-native`.
- Папку `stator-ts` (`~/GitHub/listepo/apps/stator-ts`) перенести туда же, в `packages/stator-ts`.
- В итоге в `packages/` лежат две соседние папки: `stator-native` и `stator-ts`.

### Почему
- Чище разделение: компилятор на Zig и монорепо TypeScript-компилятора с runtime, std и плагином Vite живут отдельными пакетами с отдельными сборками, CI и зависимостями.
- Один корень: общие `mise.toml`, CI, `AGENTS.md` и документация лежат в одном месте, а не дублируются в двух репозиториях.
- Проще сравнивать и делить тесты между двумя реализациями.

Важно: сейчас код на Zig лежит в `stator-ts`, а в `stator` монорепо на TypeScript и pnpm. Перед переносом нужно проверить, что названия `stator-native` и `stator-ts` стоят на нужных папках.

### Как
1. Переносить через `git mv`, чтобы сохранилась история. Для второго репозитория использовать `git subtree add` или `git filter-repo --to-subdirectory-filter`.
2. Обновить пути в `pnpm-workspace.yaml`, `ci.sh`, `mise.toml`, `build.zig`, CI и `AGENTS.md`.
3. Делать отдельным PR, после него прогнать полную сборку и тесты обоих пакетов.

### Итоговое дерево
```
stator/
├── packages/
│   ├── stator-native/      # бывшее содержимое stator
│   │   ├── packages/       # compiler, runtime, std, node, tests, vite-stator
│   │   ├── docs/
│   │   ├── package.json
│   │   └── pnpm-workspace.yaml
│   └── stator-ts/          # бывший stator-ts (Zig)
│       ├── build.zig
│       ├── build.zig.zon
│       └── src/            # main.zig, parser.zig, checker.zig, pool.zig, ...
├── mise.toml
└── README.md
```

## 9. Архитектура: пошаговый план переноса в `packages/`

### Целевая раскладка
В корне репозитория `stator` есть папка `packages/` с двумя соседними пакетами:
- `packages/stator-native` — всё нынешнее содержимое `stator`;
- `packages/stator-ts` — нынешний `stator-ts`.

### Почему так правильно
- **Изоляция.** Компилятор на Zig и TypeScript-монорепо (compiler, runtime, std, node, tests, vite-stator) не смешиваются. У каждого свой тулчейн, своя сборка и свои тесты.
- **Явные зависимости.** Если один пакет использует другой (общие тесты, бенчмарки, `lib.d.ts`), это видно по путям `../stator-native/...` и записям в workspace, а не по неявным абсолютным путям `~/GitHub/listepo/apps/...`.
- **Проще сборка и CI.** Один корень, один `mise.toml`, один набор workflow с фильтрами по путям: изменения в `packages/stator-ts/**` гоняют только сборку на Zig, изменения в `packages/stator-native/**` гоняют только pnpm.

Проверить до начала: Zig-код сейчас лежит в `stator-ts`, а в `stator` TypeScript и pnpm. Решить, какое имя какой папке достаётся, до любых переносов.

### Порядок действий
1. **Подготовка.** Обе папки чистые (`git status` пустой), все ветки запушены или в PR. Работать в новой ветке от свежего `main` репозитория `stator`.
2. **Перенос `stator` внутрь себя.** `mkdir -p packages/stator-native`, затем `git mv` для каждого элемента верхнего уровня, кроме `.git`, в `packages/stator-native/`. История сохраняется.
3. **Подключение `stator-ts`.** `git subtree add --prefix=packages/stator-ts <путь-или-remote-stator-ts> main` с полной историей. Альтернатива: `git filter-repo --to-subdirectory-filter packages/stator-ts` в копии `stator-ts`, затем merge с `--allow-unrelated-histories`.
4. **Корень.** Вынести на верх общие файлы: `mise.toml`, `README.md`, `AGENTS.md`, `.github/`, `renovate.json`, `hk.pkl`. Корневой `pnpm-workspace.yaml` указывает на `packages/stator-native/packages/*`, либо `pnpm` остаётся только внутри `stator-native`.
5. **Исправить пути** (список ниже).
6. **Проверка.** Полная сборка и тесты обоих пакетов локально, затем CI зелёный. Один PR, без смешивания с изменениями кода.
7. **После мержа.** Старый репозиторий `stator-ts` архивировать (не удалять) со ссылкой на новый путь в README.

### На что обратить внимание
- **Ссылки на старые пути** (найдены через `rg`): `stator-ts/README.md`, `build.zig`, `src/main.zig`, `src/testrun.zig`, `src/harness.mjs`, `AGENTS.md`, `plan/README.md`, `plan/T3/task.md`; в `stator` это `done.md`.
- **CI.** В `stator/.github/workflows/` лежат `ci.yml`, `nightly.yml`, `pipeline.yml`, `pages.yml`, `sync-docs.yml` и `dependabot.yml`. В них нужно поправить `working-directory`, `paths:`, пути кэша и артефактов, а также `directory` в dependabot.
- **Скрипты.** В `ci.sh`, `scripts/` и `package.json` проверить относительные пути и `cd`.
- **Инструменты.** Обновить пути в `sonar-project.properties`, `renovate.json`, `hk.pkl` (хуки на пути), `skills-lock.json`.
- **Zig.** `build.zig.zon` с локальными `.path`-зависимостями, плюс `zig-out` и `.zig-cache` в `.gitignore` на новом уровне.
- **Node.** После переноса пересоздать `node_modules` (`pnpm install`), иначе симлинки сломаются. Сам `node_modules` не переносить.
- **Внешние ссылки.** Обновить GitHub Pages, бейджи в README и ссылки из других репозиториев и с лендинга.

### Итоговое дерево
```
stator/
├── .github/workflows/        # ci.yml и др., с фильтрами paths по пакетам
├── packages/
│   ├── stator-native/        # бывшее содержимое stator
│   │   ├── packages/         # compiler, runtime, std, node, tests, vite-stator
│   │   ├── docs/
│   │   ├── scripts/
│   │   ├── ci.sh
│   │   ├── package.json
│   │   └── pnpm-workspace.yaml
│   └── stator-ts/            # бывший stator-ts (Zig)
│       ├── build.zig
│       ├── build.zig.zon
│       ├── plan/
│       └── src/              # main.zig, parser.zig, checker.zig, pool.zig, ...
├── AGENTS.md
├── mise.toml
└── README.md
```

## 10. Идеи фич (записаны со слов Ивана, не реализовывать без отдельного решения)

### 10.1. Генерация строгого TypeScript
**Что просил:** stator должен уметь генерировать строгий TypeScript, в сгенерированном коде не должно быть `any`.

**Зачем:** сгенерированный код можно проверить тем же строгим чекером (`--mode=ts`, где `any` — ошибка компиляции). Его можно читать, класть в репозиторий и использовать как вход для `stator --mode=ts` и нативной компиляции с неупакованными значениями. Это мост из нетипизированного JS в типизированный TS.

**Что затронет:**
- В stator-ts: новый эмиттер рядом с `src/emit.zig` (сейчас выдаёт только JavaScript), который печатает аннотации типов из `types.zig` и `checker.zig`. Нужен отдельный printer типов в `print.zig`.
- Строгость чекера: на местах, где тип вывести не удалось, нужна явная ошибка или `unknown` с сужением, а не молчаливый `any`. Нужен флаг вида `--emit=ts --strict-no-any`.
- В stator: `packages/compiler/src/codegen` и `hir`, если генерировать из HIR. Тесты golden плюс прогон результата через строгий чекер.

### 10.2. Генерация Zig-кода
**Что просил:** stator должен уметь генерировать код на Zig, а не только на C и не только JavaScript.

**Зачем:** runtime и std уже частично на Zig (`packages/runtime/src/jsrt_*.zig`, `packages/std/zig`). Zig-бэкенд даёт кросс-компиляцию из коробки, единый тулчейн, comptime, явные аллокаторы, отладочные проверки safety и прямой вызов Zig-частей рантайма без C ABI.

**Что затронет:**
- В stator: новый бэкенд в `packages/compiler/src/codegen` рядом с C-бэкендом, общий lowering из `lower` и `hir`. Привязки к рантайму сделать через Zig-модули вместо `include/*.h`, а сборку бинарника — через `zig build` или `zig build-exe`.
- В stator-ts: опциональный `--emit=zig` в `emit.zig` и `driver.zig`, если нативную генерацию решат переносить сюда.
- Тесты: differential-прогон C-бэкенда против Zig-бэкенда на `packages/tests/golden` и `subset`.
