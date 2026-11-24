-- ABM de servicios: funciones que tocan facturación y RADIUS en una sola transacción.
-- SECURITY DEFINER: corren con los permisos del dueño (postgres), así facturacion puede
-- dar de alta abonados SIN tener permisos directos sobre radcheck/radusergroup.
-- search_path fijo + tablas con esquema explícito: evita "tablas trampa" con el mismo nombre.
-- Solo el rol facturacion puede ejecutarlas.

-- ===== Alta =====
CREATE OR REPLACE FUNCTION facturacion.alta_servicio(
    p_cliente_id integer, p_plan text, p_username text, p_password text
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_tipo_id integer; v_estado_id integer; v_servicio_id integer;
BEGIN
    SELECT id INTO v_tipo_id FROM facturacion.tiposervicio WHERE radius_groupname = p_plan;
    IF v_tipo_id IS NULL THEN
        RAISE EXCEPTION 'El plan % no existe', p_plan;
    END IF;
    IF EXISTS (SELECT 1 FROM public.radcheck WHERE username = p_username) THEN
        RAISE EXCEPTION 'El usuario % ya existe en RADIUS', p_username;
    END IF;
    IF length(p_password) < 8 THEN
        RAISE EXCEPTION 'La contraseña debe tener al menos 8 caracteres';
    END IF;

    SELECT id INTO v_estado_id FROM facturacion.estadoservicio WHERE nombre = 'activo';

    INSERT INTO facturacion.servicio (cliente_id, tiposervicio_id, estadoservicio_id, radius_username)
    VALUES (p_cliente_id, v_tipo_id, v_estado_id, p_username)
    RETURNING id INTO v_servicio_id;

    INSERT INTO public.radcheck (username, attribute, op, value)
    VALUES (p_username, 'Cleartext-Password', ':=', p_password);
    INSERT INTO public.radusergroup (username, groupname, priority)
    VALUES (p_username, p_plan, 1);

    RETURN v_servicio_id;
END;
$$;

-- ===== Cambio de plan =====
-- Cambia el plan contratado. Si el servicio está activo, cambia también el grupo en RADIUS
-- y devuelve (nas, rate_limit) de la sesión abierta para mandar un CoA en caliente.
-- Si está moroso o de baja, sigue rechazado; al rehabilitarse toma el plan nuevo.
CREATE OR REPLACE FUNCTION facturacion.cambiar_plan(p_username text, p_plan text)
RETURNS TABLE (nas text, rate_limit text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_tipo_id integer; v_grupo_estado text;
BEGIN
    SELECT id INTO v_tipo_id FROM facturacion.tiposervicio WHERE radius_groupname = p_plan;
    IF v_tipo_id IS NULL THEN
        RAISE EXCEPTION 'El plan % no existe', p_plan;
    END IF;

    UPDATE facturacion.servicio SET tiposervicio_id = v_tipo_id WHERE radius_username = p_username;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El servicio % no existe', p_username;
    END IF;

    SELECT e.radius_groupname INTO v_grupo_estado
    FROM facturacion.servicio s
    JOIN facturacion.estadoservicio e ON e.id = s.estadoservicio_id
    WHERE s.radius_username = p_username;

    IF v_grupo_estado IS NULL THEN
        UPDATE public.radusergroup SET groupname = p_plan WHERE username = p_username;

        RETURN QUERY
        SELECT host(a.nasipaddress), g.value::text
        FROM public.radacct a
        JOIN public.radgroupreply g ON g.groupname = p_plan AND g.attribute = 'Mikrotik-Rate-Limit'
        WHERE a.username = p_username AND a.acctstoptime IS NULL
        LIMIT 1;
    END IF;
END;
$$;

-- ===== Cambio de contraseña =====
CREATE OR REPLACE FUNCTION facturacion.cambiar_password(p_username text, p_password text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF length(p_password) < 8 THEN
        RAISE EXCEPTION 'La contraseña debe tener al menos 8 caracteres';
    END IF;
    UPDATE public.radcheck SET value = p_password
    WHERE username = p_username AND attribute = 'Cleartext-Password';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El usuario % no existe en RADIUS', p_username;
    END IF;
END;
$$;

-- ===== Baja =====
-- Estado inactivo + grupo baja (rechaza). No borra la contraseña ni las facturas.
-- Devuelve el NAS con sesión abierta (o NULL): el Disconnect lo manda el script.
CREATE OR REPLACE FUNCTION facturacion.baja_servicio(p_username text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_estado_id integer; v_grupo text; v_nas text;
BEGIN
    SELECT id, radius_groupname INTO v_estado_id, v_grupo
    FROM facturacion.estadoservicio WHERE nombre = 'inactivo';

    UPDATE facturacion.servicio SET estadoservicio_id = v_estado_id WHERE radius_username = p_username;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El servicio % no existe', p_username;
    END IF;

    UPDATE public.radusergroup SET groupname = v_grupo WHERE username = p_username;

    SELECT host(nasipaddress) INTO v_nas
    FROM public.radacct WHERE username = p_username AND acctstoptime IS NULL LIMIT 1;
    RETURN v_nas;
END;
$$;

REVOKE ALL ON FUNCTION facturacion.alta_servicio(integer, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION facturacion.cambiar_plan(text, text)                 FROM PUBLIC;
REVOKE ALL ON FUNCTION facturacion.cambiar_password(text, text)             FROM PUBLIC;
REVOKE ALL ON FUNCTION facturacion.baja_servicio(text)                      FROM PUBLIC;
GRANT EXECUTE ON FUNCTION facturacion.alta_servicio(integer, text, text, text) TO facturacion;
GRANT EXECUTE ON FUNCTION facturacion.cambiar_plan(text, text)                 TO facturacion;
GRANT EXECUTE ON FUNCTION facturacion.cambiar_password(text, text)             TO facturacion;
GRANT EXECUTE ON FUNCTION facturacion.baja_servicio(text)                      TO facturacion;
