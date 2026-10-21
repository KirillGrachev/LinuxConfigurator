# Минимальный валидатор JSON Schema на jq.
#
# Зачем свой, а не готовый: у конфигуратора два жёстких требования - никаких зависимостей
# кроме jq (он и так нужен для чтения конфигурации) и внятные сообщения об ошибках
# на русском с полным путём к полю ("$.Ssh.MaxAuthTries: значение 99 больше допустимого
# максимума 10"). Готовые валидаторы либо тянут python/npm, либо печатают сырой дамп схемы.
#
# Поддерживаемое подмножество: type (в том числе массив типов), enum, minimum, maximum,
# pattern, minLength, required, properties, items.
# additionalProperties намеренно НЕ реализован: в config.json разрешено держать $schema
# и собственные пометки, а строгая проверка неизвестных ключей ломала бы совместимость конфигов
# между версиями конфигуратора.
#
# Вход: схема (stdin/файл), конфигурация --argjson config.
# Выход: {valid, errorCount, errors[]}.

def matches_type($t):
  ($t | if type == "array" then . else [.] end) as $types
  | . as $v
  | any($types[]; . as $x
      | if $x == "integer" then ($v | type == "number" and $v == ($v | floor))
        elif $x == "number" then ($v | type == "number")
        elif $x == "null" then ($v == null)
        else ($v | type) == $x end);

def type_label($t):
  if ($t | type) == "array" then ($t | join(" или ")) else ($t | tostring) end;

def validate($schema; $path):
  . as $v
  | if $schema == null then []
    else
      (if ($schema | has("type")) and ($v | matches_type($schema.type) | not)
         then ["\($path): ожидается тип \(type_label($schema.type)), получен \($v | type)"]
         else [] end)
    + (if ($schema | has("enum")) and (($schema.enum | index($v)) == null)
         then ["\($path): значение \($v | tojson) не входит в список допустимых \($schema.enum | tojson)"]
         else [] end)
    + (if ($schema | has("minimum")) and ($v | type == "number") and ($v < $schema.minimum)
         then ["\($path): значение \($v) меньше допустимого минимума \($schema.minimum)"]
         else [] end)
    + (if ($schema | has("maximum")) and ($v | type == "number") and ($v > $schema.maximum)
         then ["\($path): значение \($v) больше допустимого максимума \($schema.maximum)"]
         else [] end)
    + (if ($schema | has("pattern")) and ($v | type == "string") and (($v | test($schema.pattern)) | not)
         then ["\($path): значение \"\($v)\" не соответствует шаблону /\($schema.pattern)/"]
         else [] end)
    + (if ($schema | has("minLength")) and ($v | type == "string") and (($v | length) < $schema.minLength)
         then ["\($path): строка короче \($schema.minLength) символов"]
         else [] end)
    + (if ($schema | has("required")) and ($v | type == "object")
         then [ $schema.required[] as $k
                | select(($v | has($k)) | not)
                | "\($path): отсутствует обязательное поле \"\($k)\"" ]
         else [] end)
    + (if ($schema | has("properties")) and ($v | type == "object")
         then [ $schema.properties | to_entries[] | . as $e
                | select($v | has($e.key))
                | $v[$e.key] | validate($e.value; "\($path).\($e.key)") | .[] ]
         else [] end)
    + (if ($schema | has("items")) and ($v | type == "array")
         then [ $v | to_entries[] | . as $e
                | $e.value | validate($schema.items; "\($path)[\($e.key)]") | .[] ]
         else [] end)
    end;

. as $schema_root
| ($config | validate($schema_root; "$")) as $errors
| { valid: ($errors | length == 0), errorCount: ($errors | length), errors: $errors }
