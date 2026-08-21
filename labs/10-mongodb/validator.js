// Правило, которому обязан соответствовать каждый документ коллекции.
// Обратите внимание, чего в required НЕТ: guest. У группового пропуска
// вместо гостя организация, и правило обязано быть достаточно широким,
// чтобы законная форма документа через него проходила.
db.runCommand({
  collMod: "passes",
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["type", "host"],
      properties: {
        type: {
          enum: ["разовый", "недельный", "автомобильный", "групповой"],
          description: "тип пропуска, только из списка"
        },
        host: {
          bsonType: "string",
          description: "кто из сотрудников заказал"
        },
        guest: {
          bsonType: "string"
        },
        car: {
          bsonType: "object",
          required: ["plate"],
          properties: {
            plate: { bsonType: "string" },
            model: { bsonType: "string" },
            trailer: { bsonType: "bool" },
            weight_kg: { bsonType: "int" }
          }
        },
        members: {
          bsonType: "array",
          items: {
            bsonType: "object",
            required: ["name"],
            properties: {
              name: { bsonType: "string" },
              age: { bsonType: "int" }
            }
          }
        }
      }
    }
  },
  validationLevel: "strict",
  validationAction: "error"
});

print("правило установлено");
