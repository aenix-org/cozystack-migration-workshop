// Сервис «Пропуск», версия с кешем. Один исполняемый файл, две роли.
//
//	MODE=hr   — заглушка легаси-справочника сотрудников. Отвечает медленно,
//	            ровно так, как отвечает настоящий: HR_DELAY по умолчанию 800 мс.
//	MODE=api  — сам сервис «Пропуск». Ходит в справочник, а если задан REDIS_ADDR,
//	            сначала смотрит в кеш.
//
// Одна роль на оба случая, потому что образ должен быть один: два почти одинаковых
// образа в реестре — это два места, где можно забыть обновить версию.
//
// Внешних зависимостей нет, только стандартная библиотека. Клиент Redis здесь
// свой, на пятьдесят строк, — протокол Redis текстовый и для GET/SET помещается
// в одну функцию. В бою берут готовую библиотеку; тут важнее, чтобы сборка
// не ходила в интернет за пакетами.
//
// Читать на Go уметь не нужно: ниже размечено, где что лежит. Сначала мелкие помощники,
// потом самодельный клиент к Redis, потом две роли — «медленный справочник» и «сам
// сервис». Главное, ради чего затеяна лаба, происходит в setupAPI, ближе к концу файла.
//
// Три соглашения языка, чтобы не спотыкаться при чтении:
//
//	func имя(аргументы) (что вернёт) { ... } — объявление функции;
//	функция часто возвращает несколько значений сразу, и последнее из них — ошибка:
//	err == nil читается «обошлось», err != nil — «не обошлось»;
//	строки, начинающиеся с //, — комментарии, на работу программы они не влияют.
//
// Собирается файл соседним Dockerfile, на виртуалке: docker build ... app/ — см. README.
package main

// Список библиотек, которыми пользуется файл. Все до одной — стандартные, из поставки Go.
// Ни одной сторонней строки: сборка не ходит в интернет и не сломается оттого, что
// чей-то чужой пакет удалили из публичного репозитория.
import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------- окружение

// env читает переменную окружения и, если та пуста или не задана, возвращает запасное
// значение. Отсюда свойство, которое вы видите в манифестах: поведение приложения
// меняется строчкой в YAML и перезапуском пода, а не пересборкой образа.
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envInt — то же самое для чисел. Если в переменной оказалась не цифра, приложение не
// падает: пишет в лог и берёт запасное значение. Опечатка в манифесте не должна класть
// сервис — она должна быть заметна в логе.
func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
		log.Printf("значение %s=%q не число, беру %d", key, v, fallback)
	}
	return fallback
}

// ---------------------------------------------------------------- Redis

// Ошибка, которую прислал сам Redis (строка, начинающаяся с «-»): например
// NOAUTH или WRONGTYPE. Отличать её от сетевой важно: переподключение
// от неверного пароля не спасает, а попытки только маскируют причину.
type redisError struct{ msg string }

func (e *redisError) Error() string { return "redis: " + e.msg }

// redisClient — одно постоянное TCP-соединение до кеша плюс замок mu, чтобы два
// одновременных запроса не писали в это соединение вперемешку. Соединение держим
// открытым: устанавливать новое на каждый запрос дороже, чем сам запрос.
type redisClient struct {
	addr     string
	password string

	mu   sync.Mutex
	conn net.Conn
	rd   *bufio.Reader
}

// connectLocked открывает соединение и, если пароль задан, тут же представляется
// командой AUTH. Суффикс Locked в имени означает «вызывать только тогда, когда замок mu
// уже взят» — это договорённость между этими функциями, а не свойство языка.
func (r *redisClient) connectLocked() error {
	c, err := net.DialTimeout("tcp", r.addr, 3*time.Second)
	if err != nil {
		return err
	}
	r.conn = c
	r.rd = bufio.NewReader(c)
	if r.password != "" {
		if _, _, err := r.commandLocked("AUTH", r.password); err != nil {
			r.closeLocked()
			return err
		}
	}
	return nil
}

func (r *redisClient) closeLocked() {
	if r.conn != nil {
		_ = r.conn.Close()
	}
	r.conn = nil
	r.rd = nil
}

// do выполняет команду и один раз переподключается, если оборвалось соединение.
// Возвращает значение, признак «значение есть» и ошибку.
// Попыток ровно две, не десять: если Redis отвечает отказом, повторы только задержат
// ответ пользователю и размажут причину по логам.
func (r *redisClient) do(args ...string) (string, bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		if r.conn == nil {
			if err := r.connectLocked(); err != nil {
				return "", false, err
			}
		}
		val, found, err := r.commandLocked(args...)
		if err == nil {
			return val, found, nil
		}
		lastErr = err
		var re *redisError
		if errors.As(err, &re) {
			return "", false, err // ответил сам Redis — повтор не поможет
		}
		r.closeLocked() // сеть: рвём и пробуем ещё раз
	}
	return "", false, lastErr
}

// commandLocked отправляет команду в том виде, в каком её понимает Redis: сначала
// сколько дальше идёт кусков, потом длина и содержимое каждого. Дедлайн в три секунды —
// чтобы зависший кеш не задержал ответ дольше, чем поход в сам справочник.
func (r *redisClient) commandLocked(args ...string) (string, bool, error) {
	var b strings.Builder
	fmt.Fprintf(&b, "*%d\r\n", len(args))
	for _, a := range args {
		fmt.Fprintf(&b, "$%d\r\n%s\r\n", len(a), a)
	}
	if err := r.conn.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		return "", false, err
	}
	if _, err := io.WriteString(r.conn, b.String()); err != nil {
		return "", false, err
	}
	return r.readReplyLocked()
}

// readReplyLocked разбирает ответ. Первый символ строки говорит, что именно пришло,
// и вся функция — это разбор пяти случаев. Отдельно важен «$-1»: это не поломка,
// а «такого ключа нет», то есть обычный промах кеша.
func (r *redisClient) readReplyLocked() (string, bool, error) {
	line, err := r.rd.ReadString('\n')
	if err != nil {
		return "", false, err
	}
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return "", false, errors.New("redis: пустой ответ")
	}
	switch line[0] {
	case '+', ':': // простая строка или число
		return line[1:], true, nil
	case '-': // ошибка от сервера
		return "", false, &redisError{msg: line[1:]}
	case '$': // строка известной длины; -1 означает «ключа нет»
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return "", false, err
		}
		if n < 0 {
			return "", false, nil // промах кеша — это не ошибка
		}
		buf := make([]byte, n+2) // +2 на завершающие \r\n
		if _, err := io.ReadFull(r.rd, buf); err != nil {
			return "", false, err
		}
		return string(buf[:n]), true, nil
	default:
		return "", false, fmt.Errorf("redis: непонятный ответ %q", line)
	}
}

// Get и SetTTL — весь набор команд, которым пользуется сервис. Больше от кеша ничего
// не требуется, поэтому и клиент здесь помещается на страницу.
func (r *redisClient) Get(key string) (string, bool, error) { return r.do("GET", key) }

// SetTTL кладёт значение и сразу назначает срок жизни. Одной командой, а не
// SET плюс EXPIRE: между двумя командами соединение может оборваться, и ключ
// останется в кеше навсегда.
func (r *redisClient) SetTTL(key, val string, ttlSeconds int) error {
	_, _, err := r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
	return err
}

// ---------------------------------------------------------------- данные

// employee — то, что сервис отдаёт наружу и кладёт в кеш. Пометки `json:"id"` справа
// задают имена полей в JSON: в Go поля видны снаружи только с большой буквы, а в JSON
// принято с маленькой, и эти пометки их связывают.
type employee struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Dept string `json:"dept"`
}

// Данные выдуманные. Настоящих кадровых сведений в учебном стенде нет и быть не должно.
var surnames = []string{
	"Иванов И. И.", "Петрова А. С.", "Сидоров П. Н.", "Кузнецова М. В.",
	"Смирнов Д. А.", "Попова Е. К.", "Волков С. Ю.", "Морозова Н. Г.",
}

var departments = []string{
	"Служба безопасности", "Бухгалтерия", "Разработка",
	"Логистика", "Отдел кадров", "Административный отдел",
}

// Данные выдуманные, но одинаковые для одного и того же идентификатора:
// иначе по ответу нельзя было бы понять, кеш это или поход в справочник.
func personFor(id string) employee {
	h := 7
	for _, c := range id {
		h = h*31 + int(c)
	}
	if h < 0 {
		h = -h
	}
	return employee{
		ID:   id,
		Name: surnames[h%len(surnames)],
		Dept: departments[(h/13)%len(departments)],
	}
}

// writeJSON отдаёт ответ: заголовок с типом содержимого, код ответа и тело.
// SetEscapeHTML(false) нужен, чтобы русские буквы и кавычки не превращались
// в \u-последовательности, — иначе ответ придётся расшифровывать глазами.
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		log.Printf("не удалось отдать ответ: %v", err)
	}
}

// employeeID достаёт ?id= из строки запроса. Пустой идентификатор превращаем в «0»,
// чтобы у ключа в кеше всегда была определённая форма и не заводилось ключа
// «employee:» без хвоста.
func employeeID(r *http.Request) string {
	id := r.URL.Query().Get("id")
	if id == "" {
		return "0"
	}
	return id
}

// ---------------------------------------------------------------- главное

// main — точка входа: с неё начинается работа программы. Поднимает HTTP-сервер, вешает
// на него /healthz и, глядя на MODE, одну из двух ролей. Роль выбирается один раз
// на старте и в течение жизни пода не меняется.
func main() {
	mode := env("MODE", "api")
	port := env("PORT", "8080")
	pod := env("POD_NAME", "неизвестно")

	mux := http.NewServeMux()
	// /healthz есть в обеих ролях: сюда стучится проба готовности, описанная в манифестах.
	// Он отвечает всегда и ничего не проверяет — задача пробы здесь в том, чтобы понять,
	// что процесс поднялся и слушает порт, а не в том, чтобы оценить здоровье системы.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// Развилка на две роли. Неизвестное значение — не повод запуститься «как-нибудь»:
	// падаем сразу и с внятным сообщением. Молчаливый запуск не в той роли обошёлся бы
	// часом разглядывания логов.
	switch mode {
	case "hr":
		setupHR(mux, pod)
	case "api":
		setupAPI(mux, pod)
	default:
		log.Fatalf("неизвестный MODE=%q, допустимы hr и api", mode)
	}

	// ReadHeaderTimeout закрывает соединение, если клиент начал запрос и замолчал. Без него
	// хватит нескольких таких «клиентов», чтобы занять сервер целиком, ничего не запросив.
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("режим %s, порт %s, под %s", mode, port, pod)
	log.Fatal(srv.ListenAndServe())
}

// setupHR — заглушка легаси-справочника. Единственная её особенность в том,
// что она медленная, и это не случайность, а суть задачи.
func setupHR(mux *http.ServeMux, pod string) {
	delay, err := time.ParseDuration(env("HR_DELAY", "800ms"))
	if err != nil {
		log.Printf("HR_DELAY=%q не разобрался, беру 800ms", os.Getenv("HR_DELAY"))
		delay = 800 * time.Millisecond
	}
	log.Printf("справочник отвечает за %s", delay)

	// Единственный адрес этой роли. time.Sleep и есть вся «легаси-система»: те самые
	// сотни миллисекунд, ради которых в лабе появляется кеш. Поле source в ответе
	// показывает, что данные пришли отсюда, а не из кеша.
	mux.HandleFunc("/employee", func(w http.ResponseWriter, r *http.Request) {
		id := employeeID(r)
		time.Sleep(delay)
		emp := personFor(id)
		writeJSON(w, http.StatusOK, map[string]any{
			"id":     emp.ID,
			"name":   emp.Name,
			"dept":   emp.Dept,
			"source": "hr-legacy",
			"pod":    pod,
		})
	})
}

// setupAPI — сам сервис «Пропуск». Здесь живёт логика кеша, и здесь же лежит ответ
// на вопрос «почему в ответе написано cache: off».
func setupAPI(mux *http.ServeMux, pod string) {
	hrURL := env("HR_URL", "http://hr-legacy")
	ttl := envInt("CACHE_TTL", 60)
	version := env("APP_VERSION", "v2")

	// Кеш включается самим фактом наличия REDIS_ADDR — той переменной, которую добавляет
	// cache-patch.yaml. Переменной нет — cache остаётся пустым, все проверки
	// `if cache != nil` ниже не срабатывают, и сервис работает как работал.
	var cache *redisClient
	if addr := os.Getenv("REDIS_ADDR"); addr != "" {
		cache = &redisClient{addr: addr, password: os.Getenv("REDIS_PASSWORD")}
		log.Printf("кеш включён: %s, срок жизни записи %d с", addr, ttl)
	} else {
		log.Printf("кеш выключен: REDIS_ADDR не задан, каждый запрос пойдёт в справочник")
	}

	// Отдельный клиент с увеличенным пулом соединений: иначе под нагрузкой
	// половина времени уйдёт на установку TCP-соединений к справочнику,
	// и замер покажет не задержку справочника, а нашу собственную неаккуратность.
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConnsPerHost = 64
	hrClient := &http.Client{Timeout: 10 * time.Second, Transport: tr}

	// Корень «/» — визитка сервиса: версия, под, узел, реестр и режим кеша. По полю cache
	// сразу видно off или redis, не заглядывая в логи и не разбирая манифест.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"service":   "passes-api",
			"version":   version,
			"pod":       pod,
			"node":      env("NODE_NAME", "неизвестно"),
			"namespace": env("POD_NAMESPACE", "неизвестно"),
			"registry":  env("IMAGE_REGISTRY", "не указан"),
			"cache":     cacheMode(cache),
			"cache_ttl": ttl,
			"hr_url":    hrURL,
			"time":      time.Now().UTC().Format(time.RFC3339),
		})
	})

	// Главный адрес лабы. Порядок действий: спросить кеш, при промахе сходить в справочник,
	// положить ответ в кеш. Всё, что вы измеряете в этой лабе, происходит на этих сорока
	// строках.
	mux.HandleFunc("/employee", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := employeeID(r)
		// Ключ в кеше — «employee:» плюс идентификатор. Приставка нужна, чтобы разные виды
		// записей не столкнулись: кеш один на всё приложение, а имена в нём плоские.
		key := "employee:" + id

		var emp employee
		fromCache := false

		// Шаг первый: спросить кеш. Три исхода — ошибка, попадание, промах — разбираются
		// по-разному, и разница между ними тут принципиальная.
		if cache != nil {
			raw, found, err := cache.Get(key)
			switch {
			case err != nil:
				// Кеш недоступен — это не повод отдавать ошибку пользователю.
				// Идём в справочник: медленно, но правильно.
				log.Printf("кеш недоступен (%v), иду в справочник", err)
			case found:
				if json.Unmarshal([]byte(raw), &emp) == nil {
					fromCache = true
				} else {
					log.Printf("в кеше по ключу %s лежит мусор, иду в справочник", key)
				}
			}
		}

		// Шаг второй: промах или недоступный кеш — идём в справочник. Медленно, но это
		// единственный источник правды. Ответ кладём в кеш; если положить не вышло,
		// пользователю об этом знать незачем — он свой ответ уже получил, просто
		// следующий запрос снова будет медленным.
		if !fromCache {
			fetched, err := fetchEmployee(hrClient, hrURL, id)
			if err != nil {
				log.Printf("справочник не ответил: %v", err)
				writeJSON(w, http.StatusBadGateway, map[string]any{
					"error": "справочник сотрудников недоступен",
					"pod":   pod,
				})
				return
			}
			emp = fetched
			if cache != nil {
				if b, err := json.Marshal(emp); err == nil {
					if err := cache.SetTTL(key, string(b), ttl); err != nil {
						log.Printf("не удалось положить в кеш: %v", err)
					}
				}
			}
		}

		// Поля cached и took_ms — то, ради чего всё затевалось: по ним видно, попал запрос
		// в кеш или нет и во сколько миллисекунд это обошлось. Их же читает check.sh,
		// когда решает, засчитывать лабу или нет.
		writeJSON(w, http.StatusOK, map[string]any{
			"id":      emp.ID,
			"name":    emp.Name,
			"dept":    emp.Dept,
			"cached":  fromCache,
			"cache":   cacheMode(cache),
			"ttl_s":   ttl,
			"took_ms": time.Since(start).Milliseconds(),
			"pod":     pod,
		})
	})
}

// cacheMode переводит внутреннее состояние в одно слово для ответа: off или redis.
func cacheMode(c *redisClient) string {
	if c == nil {
		return "off"
	}
	return "redis"
}

// fetchEmployee — поход в справочник по HTTP. Идентификатор экранируется
// (url.QueryEscape): без этого пробел или «&» внутри id развалили бы адрес запроса.
// Тело ответа обязательно закрывается (defer), иначе под нагрузкой кончатся соединения.
func fetchEmployee(c *http.Client, base, id string) (employee, error) {
	u := strings.TrimRight(base, "/") + "/employee?id=" + url.QueryEscape(id)
	resp, err := c.Get(u)
	if err != nil {
		return employee{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return employee{}, fmt.Errorf("справочник ответил %s", resp.Status)
	}
	var emp employee
	if err := json.NewDecoder(resp.Body).Decode(&emp); err != nil {
		return employee{}, err
	}
	return emp, nil
}
