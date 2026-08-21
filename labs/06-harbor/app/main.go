// Сервис «Пропуск», учебная версия.
//
// Делает ровно одно: отвечает на HTTP небольшим JSON и сообщает, какая копия его
// обслужила. Ничего лишнего здесь нет намеренно — в этой лабе интересен не код,
// а путь, которым он попадает в кластер: исходник -> образ -> свой реестр -> кластер.
//
// Внешних зависимостей нет: только стандартная библиотека Go. Поэтому сборка не
// ходит в интернет за библиотеками, и собрать образ можно там, где выход наружу
// закрыт, — а именно с этого начинается вся лаба.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

// Поля, которые приложение узнаёт о себе от кластера. Мы их не вычисляем и не
// угадываем — кластер сам кладёт их в переменные окружения (см. deployment,
// блок про downward API).
type identity struct {
	Service   string `json:"service"`
	Version   string `json:"version"`
	Pod       string `json:"pod"`
	Node      string `json:"node"`
	Namespace string `json:"namespace"`
	Registry  string `json:"registry"`
	Time      string `json:"time"`
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	port := env("PORT", "8080")

	mux := http.NewServeMux()

	// Проверка готовности. Кластер стучится сюда и не пускает трафик на копию,
	// пока не получит ответ. Отвечает всегда и быстро, ничего не проверяя:
	// приложению нечего проверять, у него нет ни базы, ни диска.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		body := identity{
			Service:   "passes-api",
			Version:   env("APP_VERSION", "v1"),
			Pod:       env("POD_NAME", "неизвестно"),
			Node:      env("NODE_NAME", "неизвестно"),
			Namespace: env("POD_NAMESPACE", "неизвестно"),
			Registry:  env("IMAGE_REGISTRY", "не указан"),
			Time:      time.Now().UTC().Format(time.RFC3339),
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		// SetEscapeHTML(false), иначе кириллица и символы вроде < уедут в \uXXXX
		// и ответ станет нечитаемым в терминале.
		enc.SetEscapeHTML(false)
		if err := enc.Encode(body); err != nil {
			log.Printf("не удалось отдать ответ: %v", err)
		}
	})

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("passes-api %s слушает порт %s, под %s",
		env("APP_VERSION", "v1"), port, env("POD_NAME", "неизвестно"))
	log.Fatal(srv.ListenAndServe())
}
