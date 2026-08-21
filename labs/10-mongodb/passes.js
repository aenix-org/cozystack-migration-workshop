// Четыре пропуска — четыре разные формы документа.
// Ни одной таблицы заранее создавать не нужно: коллекция появится сама.
db.passes.insertMany([
  {
    type: "разовый",
    guest: "Иванов Иван Иванович",
    host: "petrov@corp.ru",
    entrance: "Северная",
    valid_on: ISODate("2026-09-01T09:00:00Z"),
    purpose: "собеседование"
  },
  {
    type: "недельный",
    guest: "Сидорова Анна Петровна",
    host: "petrov@corp.ru",
    entrances: ["Северная", "Южная"],
    valid_from: ISODate("2026-09-01T00:00:00Z"),
    valid_to: ISODate("2026-09-07T23:59:59Z"),
    purpose: "внешний аудит",
    badge_returned: false
  },
  {
    type: "автомобильный",
    guest: "Кузнецов Виктор Сергеевич",
    host: "logistics@corp.ru",
    entrance: "Западная",
    valid_on: ISODate("2026-09-02T07:30:00Z"),
    car: {
      plate: "А123ВС174",
      model: "ГАЗель Next",
      trailer: false,
      weight_kg: 3500
    },
    parking: "P2"
  },
  {
    type: "групповой",
    organization: "Гимназия № 1",
    contact: "Смирнова Ольга Владимировна",
    host: "hr@corp.ru",
    entrance: "Северная",
    valid_on: ISODate("2026-09-03T10:00:00Z"),
    escort: "Петров Алексей Алексеевич",
    members: [
      { name: "Орлов Пётр", age: 16 },
      { name: "Волкова Мария", age: 15 },
      { name: "Зайцев Илья", age: 17 }
    ]
  }
]);

print("документов в коллекции: " + db.passes.countDocuments({}));
