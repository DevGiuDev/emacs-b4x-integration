# emacs-b4x-integration — Plan de trabajo

## Objetivo
Crear una integración para Emacs orientada al desarrollo con B4X en Linux, con especial foco en instalaciones bajo Wine.

La idea no es portar la extensión de VSCode tal cual, sino construir una solución propia para Emacs con arquitectura limpia y editor-agnóstica donde sea posible.

---

## Alcance inicial

### Meta MVP
Permitir desde Emacs:

1. abrir un proyecto B4X (`.b4j`, luego `.b4a`)
2. detectar configuración de plataforma (`b4xV5.ini`)
3. resolver módulos y librerías correctamente en Linux/Wine
4. tener navegación e inteligencia vía LSP
5. lanzar build de B4J
6. lanzar ejecución de B4J

### Fuera de alcance inicial
- diseñador visual de layouts
- paridad completa con la UX de VSCode
- B4A install/deploy al dispositivo en la primera fase
- refactors complejos específicos del editor

---

## Principios de diseño

1. **Proyecto nuevo, no port directo**
   - Emacs tendrá su propia integración.
   - Se reutilizarán ideas y lógica útil del trabajo hecho en VSCode, pero no su arquitectura UI.

2. **Separar core e integración Emacs**
   - Conviene extraer o reimplementar un núcleo reutilizable.
   - Emacs no debería depender de APIs de VSCode.

3. **Linux/Wine como caso de primera clase**
   - soporte explícito para `wine`, `winepath`, `WINEPREFIX`
   - resolución de paths Windows ↔ host Linux
   - lectura de configuración sin asumir Windows nativo

4. **MVP primero**
   - código, navegación, build/run
   - dejar el designer para una fase posterior

---

## Arquitectura propuesta

## Opción recomendada

### Capa 1 — core/CLI Node
Un backend independiente con responsabilidades como:

- detectar plataformas B4X
- leer `.b4j` / `.b4a`
- resolver `ModuleN=` y librerías
- traducir rutas Wine ↔ host
- localizar `b4xV5.ini`
- preparar contexto para LSP
- lanzar build/run

Posibles formas:
- librería Node reutilizable
- CLI ejecutable
- ambas

### Capa 2 — LSP
Reutilizar o adaptar el LSP existente:

- arranque desde Emacs
- indexación del workspace
- navegación de símbolos
- diagnósticos
- completado

### Capa 3 — paquete Emacs Lisp
Responsable de:

- major mode o derivado
- integración con `eglot` o `lsp-mode`
- comandos interactivos
- lectura de configuración de usuario
- integración con `compile.el`, `project.el`, `xref`

---

## Componentes funcionales

### 1. Gestión de proyecto B4X
- detectar proyecto actual
- abrir proyecto desde `.b4j` / `.b4a`
- resolver lista real de módulos
- distinguir archivos fuente, proyecto y generados

### 2. Configuración de plataforma
- leer `b4xV5.ini`
- permitir configuración manual desde Emacs
- soporte de prefijo Wine explícito
- no escanear prefijos arbitrarios

### 3. Resolución de rutas
- host → Wine
- Wine → host
- case sensitivity en Linux
- rutas de librerías adicionales

### 4. LSP en Emacs
- definir cómo se arranca el servidor
- pasarle contexto correcto del proyecto
- integrar con `eglot` o `lsp-mode`
- limpiar/evitar diagnósticos falsos conocidos

### 5. Build / Run B4J
- localizar `B4JBuilder.exe`
- lanzar build con `wine`
- capturar salida de compilación
- ejecutar el `jar` generado con `java`
- exponerlo con comandos Emacs

### 6. Navegación útil
- ir a módulos
- saltar desde `LoadLayout("...")` al `.bal`
- saltar a subs/implementaciones
- localizar librerías XML y clases

---

## Fases

## Fase 0 — Bootstrap del proyecto
- crear repo/estructura base
- decidir licencia
- decidir stack:
  - Node para backend/core
  - Emacs Lisp para frontend editor
- documentar objetivos y restricciones

### Entregables
- estructura inicial del repo
- documento de arquitectura
- documento de configuración inicial

---

## Fase 1 — Core de proyecto/configuración
Implementar el núcleo mínimo para:

- leer `.b4j`
- resolver módulos
- detectar `b4xV5.ini`
- traducir rutas Wine
- localizar librerías

### Entregables
- módulo Node `project`
- módulo Node `wine-paths`
- módulo Node `platform-config`
- CLI de prueba para inspección

### Criterio de éxito
Dado un proyecto B4J real en Linux/Wine, el core devuelve:
- módulos correctos
- librerías correctas
- paths host correctos

---

## Fase 2 — Integración básica con Emacs
Implementar el paquete Emacs mínimo:

- comando para abrir/cargar proyecto B4X
- variables de configuración (`defcustom`)
- integración con `project.el`
- buffers reconocidos como B4X

### Entregables
- `b4x.el`
- `b4x-project.el`
- `b4x-custom.el`

### Criterio de éxito
Desde Emacs se puede seleccionar/cargar un proyecto B4J y consultar su metadata.

---

## Fase 3 — LSP MVP
Conectar el backend LSP a Emacs.

### Decisiones a tomar
- `eglot` como primera opción por simplicidad
- evaluar `lsp-mode` después si hace falta

### Trabajo
- comando de arranque del LSP
- asociación de modo/servidor
- indexación del proyecto
- completado y navegación básica

### Criterio de éxito
Abrir un `.bas` o `.b4j` y obtener:
- completado
- goto definition
- referencias
- diagnósticos razonables

---

## Fase 4 — Build / Run B4J
Integrar compilación y ejecución.

### Trabajo
- comando `b4x-build`
- comando `b4x-run`
- salida en buffer de compilación
- configuración de `wine`, `winepath`, `WINEPREFIX`

### Criterio de éxito
Compilar y ejecutar un proyecto B4J real desde Emacs en Linux.

---

## Fase 5 — Navegación y ergonomía
- xref para módulos/subs
- saltos a layouts `.bal`
- comandos rápidos
- menús/transient opcionales
- integración con `compile-mode`

---

## Fase 6 — B4A
Después de estabilizar B4J:
- soporte de configuración B4A
- build bajo Wine
- más adelante install/run si compensa

---

## Fase 7 — Designer
Se deja deliberadamente para el final.

Preguntas pendientes:
- si puede abrirse el diseñador oficial desde fuera del IDE
- si existe protocolo reutilizable
- si merece la pena solo lanzar herramienta externa
- si debe quedar fuera del proyecto

---

## Estructura inicial sugerida del repo

```text
emacs-b4x-integration/
  WORKPLAN.md
  README.md
  docs/
    architecture.md
    roadmap.md
    wine.md
  core/
    package.json
    src/
      project/
      platform/
      wine/
      builder/
      lsp/
  emacs/
    b4x.el
    b4x-project.el
    b4x-lsp.el
    b4x-build.el
    b4x-custom.el
  scripts/
```

---

## Decisiones técnicas pendientes

1. **¿Reutilizar el LSP actual tal cual o bifurcarlo?**
2. **¿Extraer lógica desde el repo VSCode o reimplementar limpio?**
3. **¿CLI primero o librería Node primero?**
4. **¿eglot solo, o compatibilidad opcional con lsp-mode?**
5. **¿Qué formato de configuración usar en Emacs?**
   - `defcustom`
   - `.dir-locals.el`
   - archivo propio opcional

---

## Recomendación inmediata
Orden de ejecución recomendado:

1. crear esqueleto del repo
2. documentar arquitectura mínima
3. implementar core de proyecto/configuración/Wine
4. exponerlo con una CLI pequeña
5. conectar Emacs a esa CLI/core
6. integrar LSP
7. integrar build/run

---

## Primer objetivo práctico
Soportar este escenario:

- Linux
- B4J instalado bajo Wine
- proyecto B4J existente
- edición desde Emacs
- LSP funcional
- build y run desde Emacs

Si eso funciona, ya hay un MVP útil de verdad.
