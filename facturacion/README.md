# Facturación: suspensión por falta de pago

Sistema de facturación mínimo que **suspende** a los abonados con facturas vencidas y los **rehabilita** cuando pagan, sin tocar el router a mano.

| Pieza | Responsabilidad |
|---|---|
| Facturación (esquema `facturacion`, estos jobs) | decide quién debe |
| FreeRADIUS | decide quién entra (grupos `moroso` / `baja` rechazan) y reenvía las órdenes de corte |
| R1 | ejecuta: corta la sesión (Disconnect, UDP 3799) |

## Flujo

```
Suspender (diario):
  factura vencida e impaga de un servicio activo
  └─ una sentencia SQL: servicio -> moroso  +  radusergroup -> moroso
     └─ si tiene sesión abierta (radacct): Disconnect firmado -> FreeRADIUS :3799 -> R1

Rehabilitar (cada 5 min):
  servicio moroso sin facturas vencidas impagas
  └─ una sentencia SQL: servicio -> activo  +  radusergroup -> grupo de su plan
```

## Modelo

Ver `db/init/04-facturacion.sql`. Puentes con RADIUS: `servicio.radius_username`, `tiposervicio.radius_groupname` y `estadoservicio.radius_groupname` (`NULL` = usar el del plan).

## Permisos (`db/init/05-facturacion-usuario.sh`)

El usuario `facturacion` maneja su esquema (sin `DELETE`). En RADIUS solo puede `UPDATE (groupname)` en `radusergroup` (permiso por columna) y `SELECT` en `radacct`. No ve `radcheck` (contraseñas).

## Uso (en la VM db)

```bash
cp facturacion/.env.example facturacion/.env && chmod 600 facturacion/.env   # completar el secret
facturacion/suspender.sh
# simular un pago:
docker exec -i postgres psql -U facturacion -d radius -c \
  "UPDATE facturacion.factura f SET fecha_pago = CURRENT_DATE FROM facturacion.servicio s
   WHERE s.id = f.servicio_id AND s.radius_username = 'abonado1' AND f.fecha_pago IS NULL;"
facturacion/rehabilitar.sh
```

Programados con `cron`: ver `crontab.txt`. La salida queda en `facturacion/jobs.log`.

Requisitos: `radclient` (paquete `freeradius-utils`), el sitio `coa` en FreeRADIUS y `/radius incoming` habilitado en R1.

## ABM de servicios

El ABM de **cliente** (la persona) es SQL común sobre `facturacion.cliente`. El de **servicio** (cada conexión) toca RADIUS, así que se hace con **funciones de base** (`db/init/07-facturacion-funciones.sql`) que `facturacion` puede ejecutar sin tener permisos directos sobre las tablas de RADIUS (`SECURITY DEFINER`). Cada función es una sola transacción: o queda todo hecho o nada.

| Script | Función | Efecto en RADIUS | Orden a R1 |
|---|---|---|---|
| `alta.sh "<cliente>" <plan> <usuario> <contraseña>` | `alta_servicio` | crea `radcheck` + `radusergroup` | — |
| `cambiar_plan.sh <usuario> <plan>` | `cambiar_plan` | cambia el grupo (si está activo) | **CoA** con la velocidad nueva, en caliente |
| `cambiar_password.sh <usuario> <contraseña>` | `cambiar_password` | actualiza `radcheck` | — (vale en la próxima autenticación) |
| `baja.sh <usuario>` | `baja_servicio` | grupo `baja` (rechaza) | **Disconnect** si está conectado |

Validaciones en las funciones: el plan existe, el usuario no está repetido en RADIUS y la contraseña tiene al menos 8 caracteres. La base no habla RADIUS: las funciones devuelven el NAS (y la velocidad) y el **script** manda el CoA/Disconnect. Los parámetros se pasan como variables de `psql` (`-v` / `:'var'`), no pegados en el SQL, para evitar inyección.
