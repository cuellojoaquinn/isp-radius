-- Esquema de facturación: reglas de negocio, separadas de las tablas de FreeRADIUS.
-- Los puentes con RADIUS son tiposervicio.radius_groupname, estadoservicio.radius_groupname
-- y servicio.radius_username.

CREATE SCHEMA IF NOT EXISTS facturacion;

-- Personas o empresas que contratan
CREATE TABLE facturacion.cliente (
    id      SERIAL PRIMARY KEY,
    nombre  TEXT NOT NULL
);

-- Catálogo de planes. Cada plan tiene su propio grupo en RADIUS.
CREATE TABLE facturacion.tiposervicio (
    id                SERIAL PRIMARY KEY,
    nombre            TEXT NOT NULL UNIQUE,                     -- "Plan 50 megas"
    precio            NUMERIC(10,2) NOT NULL CHECK (precio >= 0), -- precio vigente
    radius_groupname  TEXT NOT NULL UNIQUE                      -- plan-50m
);

-- Estados posibles de un servicio.
-- radius_groupname NULL = el servicio usa el grupo de su plan.
CREATE TABLE facturacion.estadoservicio (
    id                SERIAL PRIMARY KEY,
    nombre            TEXT NOT NULL UNIQUE,                     -- activo / moroso / inactivo
    radius_groupname  TEXT                                      -- NULL / moroso / baja
);

-- Cada servicio es una conexión (un usuario de RADIUS).
CREATE TABLE facturacion.servicio (
    id                 SERIAL PRIMARY KEY,
    cliente_id         INTEGER NOT NULL REFERENCES facturacion.cliente(id),
    tiposervicio_id    INTEGER NOT NULL REFERENCES facturacion.tiposervicio(id),   -- plan contratado
    estadoservicio_id  INTEGER NOT NULL REFERENCES facturacion.estadoservicio(id),
    radius_username    TEXT NOT NULL UNIQUE                     -- abonado1
);

-- Facturas por servicio. fecha_pago NULL = impaga.
CREATE TABLE facturacion.factura (
    id                 SERIAL PRIMARY KEY,
    servicio_id        INTEGER NOT NULL REFERENCES facturacion.servicio(id),
    monto              NUMERIC(10,2) NOT NULL CHECK (monto >= 0),  -- copia del precio al emitir
    fecha_creacion     DATE NOT NULL DEFAULT CURRENT_DATE,
    fecha_vencimiento  DATE NOT NULL,                              -- editable (prórrogas)
    fecha_pago         DATE,
    CHECK (fecha_vencimiento >= fecha_creacion)
);
