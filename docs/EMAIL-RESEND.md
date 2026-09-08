# Envío de correo electrónico (Resend)

Runbook de la integración de correo transaccional con **Resend** vía SMTP para las instancias del SGD.

## Estado actual

- **Proveedor**: Resend (SMTP: `smtp.resend.com:587`, STARTTLS).
- **Dominio verificado**: `aviliontech.com`.
- **From global**: `noreply@aviliontech.com` (opción A).
  - La **dirección** from es siempre la global (`config('mail.from.address')`).
  - El **nombre** del from se personaliza con el del funcionario (`DocumentEmail` / `CitizenNotificationEmail`).
  - El `replyTo` es el correo del funcionario (dinámico).
- **Config**: `MAIL_*` presente en los servicios `app`, `worker-default` y `worker-pqrsd` de `docker-compose.dockploy.yml` y `docker-compose.yml`.

### Flujos de envío (SDG-Back-api)

| Flujo | Mailable | Mecanismo |
|---|---|---|
| `POST /v1/emails/send-document` (envío desde la app) | `DocumentEmail` | `->queue()` (cola Redis, worker-default) |
| Confirmación PQRSD portal público | `CitizenNotificationEmail` | `->queue()` |
| Confirmación correspondencia portal público | `CitizenNotificationEmail` | `->queue()` |
| Prueba dev | `TestEmail` | `->send()` síncrono |

Los dos flujos del portal público se cambiaron de `->send()` a `->queue()` en el commit `c6d74b3` (rama `roraima.0.0.1`).

El footer institucional se resuelve por Branch/Entity vía `ConfigurationResolver::getEmailFooter()` y las imágenes inline se sirven desde B2 usando CID (`Attachment::fromData`).

### Límites del plan free de Resend

- **3.000 emails/mes** y **100/día** (el cupo diario resetea a medianoche UTC = 7 PM hora Colombia).
- **1 dominio verificado** por cuenta.
- No requiere tarjeta; es gratuito permanente.
- Cada destinatario en `To`/`CC`/`BCC` cuenta como un email.
- Volumen típico de un municipio categoría 6 (≤10.000 habitantes): decenas de correos/mes → el free alcanza con margen amplio. Si algún día se supera → Pro a $20/mes.

## Runbook: agregar un nuevo municipio

> Modelo actual: **un municipio = una instancia (VPS)**. El cambio se reduce a configuración de entorno, sin tocar código.

### Decisión de cuentas Resend

| Opción | Cómo | Costo | Cuándo |
|---|---|---|---|
| **A. Una cuenta Resend por municipio** (recomendada) | El municipio crea su cuenta free, verifica SU dominio y entrega su API key | $0 por municipio (3.000/mes c/u) | Cada municipio dueño de su dominio/API key |
| **B. Una cuenta centralizada en Pro** | Subir tu cuenta a Pro ($20/mes, 10 dominios) y agregar todos los dominios | $20/mes | Centralizar todo en una sola cuenta |

### Requisito previo: acceso al DNS

Se necesita que quien administra el dominio del municipio (p. ej. `mapiripan-meta.gov.co`, gestionado por el `.gov.co` de Colombia) agregue los registros DNS. **Sin acceso al DNS no se puede verificar el dominio.**

### Pasos

1. **DNS del municipio**: agregar los registros que genera el dashboard de Resend al agregar el dominio (tipos: SPF, DKIM, DMARC; en CNAME no usar proxy/CDN "orange cloud"). La verificación tarda 5-15 min (a veces hasta 72 h por propagación).
2. **Resend**: Domains → Add Domain → `mapiripan-meta.gov.co` → verificar → Settings → API Keys → crear key con permisos *Sending access* (`re_...`).
3. **`.env` de la instancia del municipio** (`/home/deploy/sgd-infra/.env` en su VPS) — solo 3 variables cambian, los compose ya usan defaults parametrizables:
   ```
   MAIL_FROM_ADDRESS=noreply@mapiripan-meta.gov.co
   MAIL_PASSWORD=re_XXXX  # API key del dominio del municipio
   MAIL_FROM_NAME=Alcaldía de Mapiripán
   ```
4. **Recrear contenedores** (los `MAIL_*` están en app + ambos workers):
   ```
   cd /home/deploy/sgd-infra
   docker compose up -d --force-recreate app worker-default worker-pqrsd
   bash scripts/healthcheck.sh
   ```
5. **Prueba real de envío**:
   - Desde la app: enviar un documento por correo a una cuenta real.
   - O vía tinker (desde SDG-Back-api local, sin tocar `.env`):
     ```php
     config(["mail.default" => "smtp"]);
     config(["mail.mailers.smtp" => [
       "transport" => "smtp", "host" => "smtp.resend.com", "port" => 587,
       "encryption" => "tls", "username" => "resend",
       "password" => "re_XXXX", "timeout" => null,
       "local_domain" => "dominio-del-municipio",
     ]]);
     config(["mail.from" => ["address" => "noreply@dominio-del-municipio", "name" => "SGD"]]);
     Mail::to("destinatario@gmail.com")->send(new App\Mail\TestEmail());
     ```
   - Verificar el estado en la API de Resend (debe salir `delivered`):
     ```
     curl -s -H "Authorization: Bearer re_XXXX" "https://api.resend.com/emails?limit=5"
     ```
   - Si rebota (`bounced`), revisar el detalle con `GET /emails/{id}` (p. ej. destinatario inexistente, 550-5.1.1).

### Consideración al validar en Gmail

Si el correo llega con `mailed-by` y `signed-by` = dominio verificado, SPF/DKIM pasaron correctamente. Si el from es de un dominio no verificado, Resend rechaza el envío.

## Mejoras opcionales (futuro)

- **From-name por entidad** para las confirmaciones PQRSD (que diga "Alcaldía de Mapiripán" en vez de "SGD"): parametrizar en `EntityConfiguration` y resolver en el `envelope()` de `CitizenNotificationEmail`.
- **From 100% personalizado por funcionario** (`ramon@dominio`): solo viable para funcionarios cuyo correo sea del dominio verificado; correos `@gmail.com`/`@alcaldia.gov.co` fallarían.
- **Multi-tenant real en una sola instancia** (una instancia enviando desde varios dominios): requiere parametrizar `smtp_from_address`/API key por entidad en código. No necesario con el modelo "un municipio = una instancia".

## Seguridad

- **La API key NUNCA va a git**: solo en el `.env` del VPS. `.env.example` lleva placeholders.
- Si una API key se expone en un chat/log/correo, **rotarla** en Resend (Settings → API Keys) y actualizar el `.env` de la instancia.