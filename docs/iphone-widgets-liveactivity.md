# iPhone: actividad en vivo, widget y accesos rápidos

Implementación aditiva para iOS 17, Swift 6 y sin dependencias externas. No cambia `HostRuntime`,
`PhoneWatchService`, `GimbalController`, `GotoNavigator`, `NavigationSafety`, `OMDevice` ni `GimbalKitDJI`.
Los intents de Atajos existentes se mantienen intactos.

## Actividad en vivo y PARADA

- `Sources/GimbalWidgetSupport/GimbalActivityAttributes.swift`: atributos y `ContentState` compartidos,
  con conexión, batería, carga, zona con control activo y última zona observada.
- `Sources/GimbalHostSupport/GimbalActivityContent.swift`: transformación del estado público del runtime.
  Un lease activo muestra «Mirando a X»; sin lease, «Quieta». Al desconectar elimina la telemetría actual.
  «Última zona» significa última zona con lease observada, no una confirmación de llegada.
- `Sources/GimbalHostSupport/LiveActivityCoordinator.swift`: protocolo inyectable `LiveActivityControlling`,
  inicio al conectar, actualizaciones agrupadas (como máximo una por segundo), renovación de frescura en
  reposo cada 15 segundos y cierre inmediato al observar desconexión, sin esperar el debounce.
  Un único escritor serializa start/update/end; conserva también una desconexión breve seguida de reconexión.
  El cierre limpia actividades restauradas de procesos anteriores. Un fallo al iniciar permite reintentar
  con observaciones posteriores, con el mismo límite de frecuencia.
- `Sources/GimbalHostSupport/PhoneActivityObserver.swift`: observa el runtime cada 250 ms fuera del ciclo de
  vida de las vistas. Refleja también órdenes de Atajos y del reloj. No inicia ni cambia conexiones/movimientos.
- `Apps/GimbalPhone/PhoneLiveActivityController.swift`: adaptador ActivityKit, recuperación de actividades
  existentes y finalización con `.immediate`.
- `Apps/GimbalPhoneShared/StopActivityIntents.swift`: `StopGimbalLiveActivityIntent`, compilado en app y extensión,
  con `openAppWhenRun = false`; su implementación en la app llama directamente a
  `PhoneHostEnvironment.shared.runtime.humanStop()`. La extensión solo tiene la definición del intent y
  rechaza su ejecución local: no enlaza el runtime ni Bluetooth.
- `Apps/GimbalPhoneWidgets/GimbalLiveActivityWidget.swift`: pantalla de bloqueo y Dynamic Island expandida,
  compacta y mínima. PARADA aparece en bloqueo e isla expandida; contraste y acentos de `Neumorphism.swift`.
- `Apps/GimbalPhone/GimbalPhoneApp.swift`: retiene e inicia el observador junto a los servicios existentes.
  Recupera la última zona del snapshot compartido al relanzar la app, si hay App Group disponible.
  `Apps/GimbalPhone/Info.plist`: `NSSupportsLiveActivities` y esquema `gimbalkit://`.

El proceso que posee BLE es la app. Apple documenta que `Button(intent:)` ejecuta por defecto en la
extensión, y que `LiveActivityIntent` ejecuta en el proceso de la app:
[interactividad en widgets y actividades](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities).
No se usa el `StopGimbalIntent` normal como botón de widget.

La garantía de cierre se refiere a la lógica ejecutándose y a la observación de desconexión. ActivityKit
no mantiene viva la app: si iOS la suspende/termina o desactiva las actividades, no podemos ejecutar un
callback a voluntad. Se marca el contenido como desactualizado a los 30 segundos. El inicio en segundo
plano puede ser rechazado por iOS; las siguientes observaciones reintentan (por ejemplo al volver a primer plano).
Cerrar/deslizar una actividad no ordena una parada al estabilizador.

## Widget informativo

- `Sources/GimbalWidgetSupport/GimbalWidgetSnapshot.swift`: snapshot Codable fechado y archivo JSON atómico
  en `group.dev.gimbalkit.phone`, con caducidad de 30 segundos y lectura segura si falta/se corrompe el archivo.
- `PhoneWidgetPublisher` en `Apps/GimbalPhone/PhoneLiveActivityController.swift`: publica cambios y un heartbeat
  cada 15 segundos; limita solicitudes de recarga a una cada 15 segundos.
- `Apps/GimbalPhoneWidgets/GimbalStatusWidget.swift`: familias pequeña, mediana y accesorios inline,
  circular y rectangular. Muestra conexión, batería y última zona; `widgetURL` abre la app.
  La timeline incluye una entrada de caducidad y pide una nueva timeline a los 15 minutos.
  WidgetKit decide cuándo aceptar las recargas; la información se presenta como última lectura.

No hay botones de movimiento o parada en el widget estático: una extensión no posee la conexión BLE,
y ejecutar un `AppIntent` normal allí crearía un runtime distinto. Tocar el widget abre GimbalKit.

### App Groups y cuenta gratuita: desviación necesaria

Compartir snapshots entre los dos procesos requiere App Groups. Un Personal Team gratuito no permite
provisionar esa capacidad; véanse las
[capacidades según membresía](https://developer.apple.com/help/account/reference/supported-capabilities-ios) y la
[configuración de App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups).
Para conservar la instalación gratuita, `Apps/project.yml` deja **sin entitlement de App Groups los builds
de dispositivo por defecto**. La actividad y PARADA/ControlWidget no dependen de App Groups y siguen funcionando.
El widget sin contenedor muestra «Sin actualizar» / «Sin datos» y abre la app: **no puede mostrar la batería
y zona reales con la configuración gratuita**, y no se finge un estado conectado.

En simulador se seleccionan automáticamente `Apps/GimbalPhone/GimbalPhone.entitlements` y
`Apps/GimbalPhoneWidgets/GimbalPhoneWidgets.entitlements`. Con un equipo de pago:

1. Registra `group.dev.gimbalkit.phone` y habilítalo en ambos identificadores/perfiles.
2. Configura `GIMBAL_SHARED_ENTITLEMENTS = GimbalPhone/GimbalPhone.entitlements` en ambos targets
   (el mismo archivo sirve porque los entitlements son idénticos), y habilita la firma con tu equipo.
3. Regenera desde `Apps/project.yml` si cambias la especificación; no edites solo el proyecto generado.

No se han registrado identificadores ni modificado perfiles en esta tarea. La extensión añade el identificador
`dev.gimbalkit.phone.widgets`: ten en cuenta los límites indicados en el encargo (3 apps instaladas y 10
identificadores por semana); conserva los identificadores existentes para no consumir otros nuevos.

## Accesos rápidos y ControlWidget

- `Apps/GimbalPhone/PhoneSettingsView.swift`: tarjeta «Accesos rápidos», instrucciones breves para crear
  el atajo con `GimbalKit → Parar`, asignarlo al botón de acción o al Centro de control y botón «Abrir Atajos».
- `Apps/GimbalPhoneWidgets/GimbalStopControl.swift`: control «Parada» de iOS 18; el intent
  `OpenAndStopGimbalIntent` usa `openAppWhenRun = true`, abre la app y llama a `humanStop()` allí,
  sin esperar a una nueva conexión. **Abre la app**, a diferencia del botón de la actividad.
- `Apps/GimbalPhoneWidgets/GimbalPhoneWidgets.swift`: bundle de widgets, actividad y control; el control
  está protegido con `@available(iOS 18.0, *)` y `if #available`, manteniendo mínimo iOS 17.

Apple confirma el proceso de ejecución con `openAppWhenRun` y la pertenencia del intent a los dos targets
en [interactividad](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
y [controles](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system).

## Proyecto y comprobaciones

`Apps/project.yml` añade `GimbalPhoneWidgets` (`app-extension`, `com.apple.widgetkit-extension`), lo embebe
en `GimbalPhone`, configura Swift 6 estricto y mantiene la firma desactivada. Se regeneró con
`xcodegen generate --spec Apps/project.yml`. `Package.swift` añade el módulo compartido ligero, la dependencia
de HostSupport y exclusiones para que SwiftPM no compile las vistas de iOS como pruebas de macOS.

`Tests/GimbalHostSupportTests/LiveActivityCoordinatorTests.swift`: 15 pruebas nuevas con Swift Testing,
falso del controlador y reloj manual: contenido/última zona, desconexión, batería desconocida/rangos,
inicio único, coalescing y actualización final, cancelación del debounce, carreras durante inicio/actualización,
desconexión breve, restauración, reconexión, reintento limitado, frescura en reposo, persistencia/caducidad/corrupción
y observación del runtime sin una vista.

Suite completa con el comando del encargo: **208 pruebas, 204 pasan, 4 fallan exclusivamente por EPERM
al abrir loopback** (las mismas cuatro preexistentes). Las 193 pruebas originales no se han editado.
`git diff --check` correcto; sin `git add` ni commits.

El único intento de `xcodebuild` salió con 74 antes de compilar por cachés de SwiftPM/Clang y servicios de
simulador no permitidos en el sandbox. No se repitió. La validación de compilación/instalación completa,
metadata de intents, UI de bloqueo/isla, ejecución real de PARADA y firma quedan para Claude fuera del sandbox.
Se comprobó además con `swiftc` el tipado de **todas las fuentes de la app y de la extensión** contra el SDK
de iOS Simulator con objetivo iOS 17, Swift 6 y concurrencia estricta: correcto. Para las macros del módulo
de observación se usó `swiftc -disable-sandbox` (el sandbox del compilador anidado se rechazaba con EPERM).
Esto verifica los tipos y disponibilidad de API; no sustituye la compilación de Xcode ni la prueba en dispositivo.
Solo aparece una advertencia preexistente de deprecación de `requestConfirmation` en los intents originales,
que no se han modificado.
