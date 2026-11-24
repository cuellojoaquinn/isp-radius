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
