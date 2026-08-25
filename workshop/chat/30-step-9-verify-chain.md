## 30. Шаг 9: проверяем всю цепочку

**Момент истины**

⚠️ **Сначала — внутри виртуалки — погасите firewalld.** Мигрированный CentOS принёс
правила из прошлой жизни и наружу отдаёт только SSH. Порт приложения закрыт, и проброс
с ноутбука упрётся в `no route to host` — а выглядеть это будет как «приложение не работает».

```bash
systemctl stop firewalld
systemctl disable firewalld
```

Проверьте прямо там же, изнутри машины, что приложение живо:

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

`200` — можно пробрасывать. `503` — вернитесь к шагу с сетью.

📍 **Дальше — на ноутбуке.** Пробрасываем порт приложения к себе:
```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```
Окно с этой командой не закрывайте: туннель живёт, пока она работает.

⚠️ **Здесь `vmi/` обязателен, а в `virtctl console` — наоборот, мешает.** Это не
опечатка и не наша прихоть: у двух команд разный синтаксис цели. `port-forward` требует
`тип/имя` и без префикса отвечает `target must contain type and name separated by '/'`.
`console` ждёт просто имя и с префиксом отвечает `forbidden`, потому что принимает
слово `vmi` за имя машины.

Если virtctl ругается на разницу версий клиента и кластера — это предупреждение,
а не ошибка, работать не мешает.

Если проброс всё равно не поднимается, тот же туннель делается через под машины:
```bash
kubectl get pod -n tenant-workshopXX -l vm.kubevirt.io/name=vm-instance-app-1
kubectl port-forward -n tenant-workshopXX <имя-пода-из-вывода> 8080:8080
```

В другом окне терминала:
```bash
# здоровье
curl -s http://localhost:8080/actuator/health

# создаём заказ
curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# смотрим, что он записался
curl -s http://localhost:8080/api/orders
```

Если заказ создался — вы прошли путь целиком. Приложение приехало из VMware, работает
в кластере, пишет в управляемую базу и отправляет события в управляемую очередь.

Полчаса назад эта система жила на ESXi.
