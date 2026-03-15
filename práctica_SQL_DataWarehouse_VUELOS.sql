-- Explroar el fichero flights, analiza el numero de registros totales:
SELECT COUNT(*) AS total_registros 
FROM flights;

-- El numero de vuelos distintos
	-- solamente contamos el numero de registros bajo esa columna y lo llamamos "vuelos_disntintos"
SELECT COUNT(DISTINCT unique_identifier) AS vuelos_distintos 
FROM flights; -- indicamos que lo coja de la tabla flights

-- Vuelos con más de un registro
-- seguimos la misma lógica que antes
-- pero esta vez decimos que nos muestre solo los que aparezcan más de 1 vez
SELECT COUNT(*) FROM (
    SELECT unique_identifier 
    FROM flights 
    GROUP BY unique_identifier 
    HAVING COUNT(*) > 1
) AS vuelos_duplicados;

-- Enunciado 2: seleccionar vuelos (cojo 2 con los mismos destinos)
-- ver su evolucion temporal:
-- seleccionamos las columnas que nos interesan, en este caso el identificador y las horas de aterrizaje/llegada
-- para ver su evolución temporal, añadimos los retrasos y a la hora en la que se actualizó
SELECT unique_identifier, local_actual_departure, local_actual_arrival, delay_mins, updated_at
FROM flights -- lo sacamos de la tabla flights
WHERE unique_identifier IN ('IB-100-20240124-MAD-JFK', 'AA-102-20241001-JFK-MAD') 
-- seleccionamos el vuelo de MADRID a JFK
ORDER BY unique_identifier, updated_at; -- lo ordenamos por el identificador y la hora de actualizacion


-- Enunciado 3: evaluamos la calidad del dato. 
-- 1) consistencia de info., 2) unica por vuelo, 3)logica updated vs created
-- 1. Criterio: created_at único por vuelo
SELECT unique_identifier, COUNT(DISTINCT created_at) as distintos_created_at
-- seleccionamos vuelos y vemos el numero de fechas que tiene cada uno
-- si tienen mas de 1, la informacion no es unica. Si algunos tienen 2 y otros 1/3/4.. no es consistente
FROM flights 
GROUP BY unique_identifier -- agrupamos todos los identificadores que existen para un mismo vuelo
HAVING COUNT(DISTINCT created_at) > 1; -- filtramos solo para ver los que tienen más de una fecha de creación

-- lógica requested: updated_at >= created_at
SELECT COUNT(*) as registros_incoherentes
FROM flights
WHERE updated_at < created_at; -- comparamos 

-- enunciado 4: el último estado de cada vuelo,  solo ultimo registro por vuelo:
CREATE OR REPLACE VIEW last_flight_status AS -- creamos la vista "last flight status"
-- esto guarda los resultados para que los usemos mas tarde
-- para el siguiente paso, habia probado SELECT DISTINCT ON (unique_identifier) 
-- pero en MySQL al parecer no funciona, asi que pruebo esto:
SELECT * FROM flights -- va a coger todos los datos de la tabla flights
WHERE (unique_identifier, updated_at) IN ( 
-- los filtra para coger solo los que tienen como pareja el ID y la ultima actualizacion
    SELECT unique_identifier, MAX(updated_at) 
    -- le decimos: busca el identificador y su fecha mas reciente de registro (usando MAX)
    FROM flights 
    GROUP BY unique_identifier -- agrupamos los registros por vuelo porque asi sabe de donde sacar la fecha maxima 
); 

-- Enunciado 5: reconstruir valores siguiendo las reglas dadas y creando dos campos nuevos
SELECT 
    unique_identifier,
    -- creamos campo de salida local
    COALESCE(local_departure, created_at) AS effective_local_departure,
    -- creamos campo de salida real local
    COALESCE(local_actual_departure, local_departure, created_at) AS effective_local_actual_departure,
    -- Llegada local
    COALESCE(local_arrival, created_at) AS effective_local_arrival,
    -- Llegada local real
    COALESCE(local_actual_arrival, local_arrival, created_at) AS effective_local_actual_arrival
FROM last_flight_status;

-- analizamos el estado del vuelo usando el apartado 4
SELECT 
    arrival_status, 
    COUNT(*) AS num_vuelos, 
    -- Contamos total de vuelos para cada cateogria dentro de arrival status
    CASE 
        WHEN arrival_status = 'OT' THEN 'On Time (En hora)'
        WHEN arrival_status = 'DY' THEN 'Delayed (Retrasado)'
        -- si pone DY, aparecerá delayed como texto; si aparece OT, el texto muestro En hora
        ELSE 'Otros' -- si no aparece ni OT, ni DY, sale otros como texto 
    END AS significado
FROM last_flight_status -- este es el enunciado 4, donde esta el ultimo estado para cada vuelo
GROUP BY arrival_status, significado; -- aqui he usado IA porque me daba errores y ponia
-- que poner significado evita errores de ejecucion en mySQL

-- enunciado 7: pais de la salida de cada vuelo 
SELECT a.country, COUNT(last_flight_status.flight_row_id) as total_despegues
-- seleccionamos del pais y contamos el numero de registros por vuelo 
-- a ese resultado del numero lo llamamos total despegues
FROM last_flight_status -- la vista que habiamos creado en el apartado 4
JOIN airports ON last_flight_status.departure_airport = airports.airport_code
-- une la tabla de vuelos con aeropuertos pero:
-- donde el codigo del aeropuerto de salida sea el mismo que el de la tabla aeropuertos
GROUP BY airports.country -- agrupamos por pais para contar port separado 
ORDER BY total_despegues DESC; -- ordenamos por los que mas despegues tienen a los que menos

-- Enunciado 8 y el 9: Delay medio, estado de vuelo por país de salida y estacionalidad
SELECT 
    airports.country, -- seleccionamos el pais de la tabla aeropuertos
    CASE -- esta es la logica para agrupar meses de departure por estaciones
        WHEN MONTH(last_flight_status.local_departure) IN (12, 1, 2) THEN 'Invierno'
        WHEN MONTH(last_flight_status.local_departure) IN (3, 4, 5) THEN 'Primavera'
        WHEN MONTH(last_flight_status.local_departure) IN (6, 7, 8) THEN 'Verano'
        ELSE 'Otoño' -- para agilizar la query
    END AS estacion, -- la columna se llamara estacion 
    ROUND(AVG(f.delay_mins), 2) as delay_medio -- calcula el average de los minutos de retraso
    -- los redondea a 2 decimales y los llamamos delay_medio
FROM last_flight_status
JOIN airports ON last_flight_status.departure_airport = airports.airport_code
-- une tabla de vuelos con aeropuertos comparando los codigos de salida 
GROUP BY airports.country, estacion -- para que el promedio se calcule por pais y estacion 
ORDER BY airports.country, delay_medio DESC; 
-- ordenamos por pais (alfabeticamente) y luego por el delay. Ese es el orden de preferencia


-- enunciado 10: con que frecuencia se actualizan los datos de cada vuelo?
SELECT 
    departure_airport, 
    AVG(timestamp_diff_seconds) / 60 AS promedio_minutos_actualizacion
    -- lo divido porque la tabla nos lo da en segundos
FROM ( -- creamos esto para que calcule la diferencia antes de sacar el promedio
    SELECT 
        departure_airport,
        TIMESTAMPDIFF(SECOND, 
            LAG(updated_at) OVER (PARTITION BY unique_identifier ORDER BY updated_at), 
            updated_at -- busca la fecha de actualizacion del registro anterior del mismo vuelo
        ) AS timestamp_diff_seconds
    FROM flights
) AS subquery_actualizaciones
WHERE timestamp_diff_seconds IS NOT NULL -- como al buscar con LAG el primer registro tendremos algunos NULL
-- (si no hay nada registrado anterior a registro X, sale NULL), lo eliminamos
GROUP BY departure_airport; -- Agrupamos para ver la frecuencia media por aeropuerto

-- enunciado 11: comprobar si para cada vuelo la informacion es consistente con las columnas 
SELECT 
    airlines.name AS nombre_aerolinea, -- cambiamos el nomnbre
    COUNT(*) AS vuelos_no_consistentes 
FROM last_flight_status
JOIN airlines ON last_flight_status.airline_code = airlines.airline_code 
WHERE last_flight_status.unique_identifier NOT LIKE CONCAT(
    last_flight_status.airline_code, '-', 
    '%', '-', 
    DATE_FORMAT(last_flight_status.local_departure, '%Y%m%d'), '-', 
    last_flight_status.departure_airport, '-', 
    last_flight_status.arrival_airport
)
GROUP BY airlines.name;




