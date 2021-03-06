origin = new Date()


class ReactorChannel
  constructor: (@url='/__reactor__', @retry_interval=100) ->
    @online = false
    @callbacks = {}
    @original_retry_interval = @retry_interval

  on: (event_name, callback) =>
    @callbacks[event_name] = callback

  trigger: (event_name, args  ...) ->
    @callbacks[event_name]?(args...)

  open: ->
    if @retry_interval < 10000
      @retry_interval += 1000

    if navigator.onLine
      @websocket?.close()

      if window.location.protocol is 'https:'
        protocol = 'wss://'
      else
        protocol = 'ws://'
      @websocket = new WebSocket "#{protocol}#{window.location.host}#{@url}"
      @websocket.onopen = (event) =>
        @online = true
        @trigger 'open', event
        @retry_interval = @original_retry_interval

      @websocket.onclose = (event) =>
        @online = false
        @trigger 'close', event
        setTimeout (=> @open()), @retry_interval or 0

      @websocket.onmessage = (event) =>
        data = JSON.parse event.data
        @trigger 'message', data
    else
      setTimeout (=> @open()), @retry_interval

  send: (command, payload) ->
    data =
      command: command
      payload: payload
    if @online
      @websocket.send JSON.stringify data

  send_join: (tag_name, id, state) ->
    console.log '>>> JOIN', tag_name, state
    @send 'join',
      tag_name: tag_name
      id: id
      state: state

  send_leave: (id) ->
    console.log '>>> LEAVE', id
    @send 'leave', id: id

  send_user_event: (element, name, implicit_args, explicit_args) ->
    console.log(
      '>>> USER_EVENT', element.tag_name, name, implicit_args, explicit_args
    )
    origin = new Date()
    if @online
      @send 'user_event',
        id: element.id
        name: name
        implicit_args: implicit_args
        explicit_args: explicit_args

  reconnect: ->
    @retry_interval = 0
    @websocket?.close()

  close: ->
    console.log 'CLOSE'
    @websocket?.close()



reactor_channel = new ReactorChannel()


reactor_channel.on 'open', ->
  console.log 'ON-LINE'
  for el in document.querySelectorAll '[is]'
    el.classList.remove('reactor-disconnected')
    el.connect?()

reactor_channel.on 'close', ->
  console.log 'OFF-LINE'
  for el in document.querySelectorAll '[is]'
    el.classList.add('reactor-disconnected')


reactor_channel.on 'message', ({type, id, html_diff, url, action, component_types}) ->
  console.log '<<<', type.toUpperCase(), id or url or component_types
  switch type
    when 'components' then declare_components(component_types)
    when 'visit' then reactor.visit url, action: action
    when 'render'
      document.getElementById(id)?.apply_diff?(html_diff)
    when 'remove'
      window.requestAnimationFrame ->
        document.getElementById(id)?.remove()

TRANSPILER_CACHE = {}

transpile = (el) ->
  if el.attributes is undefined
    return

  replacements = []
  for attr in el.attributes
    if attr.name.startsWith('@')
      [name, ...modifiers] = attr.name.split('.')
      start = attr.value.indexOf(' ')
      if start isnt -1
        method_name = attr.value[...start]
        method_args = attr.value[start + 1...]
      else
        method_name = attr.value
        method_args = 'null'

      cache_key = "#{modifiers}.#{method_name}.#{method_args}"
      code = TRANSPILER_CACHE[cache_key]
      if not code
        if method_name is ''
          code = ''
        else
          code = "reactor.send(event.target, '#{method_name}', #{method_args});"

        while modifiers.length
          modifier = modifiers.pop()
          modifier = if modifier is 'space' then ' ' else modifier
          switch modifier
            when 'inlinejs'
              code = attr.value
            when 'debounce'
              _name = modifiers.pop()
              _delay = modifiers.pop()
              code = "reactor.debounce('#{_name}', #{_delay})(function(){ #{code} })()"
            when 'prevent'
              code = "event.preventDefault(); " + code
            when 'stop'
              code = "event.stopPropagation(); " + code
            when 'ctrl'
              code = "if (event.ctrlKey) { #{code} }"
            when 'alt'
              code = "if (event.altKey) { #{code} }"
            else
              code = "if (event.key.toLowerCase() == '#{modifier}') { #{code} }; "
        TRANSPILER_CACHE[cache_key] = code

      replacements.push {
        old_name: attr.name
        name: 'on' + name[1...]
        code: code
      }

  for {old_name, name, code} in replacements
    if old_name
      el.attributes.removeNamedItem old_name
    nu_attr = document.createAttribute name
    nu_attr.value = code
    el.attributes.setNamedItem nu_attr


declare_components = (component_types) ->
  for component_name, base_html_element of component_types
    if customElements.get(component_name)
      continue

    base_element = document.createElement base_html_element
    class Component extends base_element.constructor
      constructor: (...args) ->
        super(...args)
        @tag_name = @getAttribute 'is'
        @_last_received_html = []

      state: -> @getAttribute 'state'

      connectedCallback: ->
        eval @getAttribute 'onreactor-init'
        @deep_transpile()
        @connect()

      disconnectedCallback: ->
        eval @getAttribute 'onreactor-leave'
        reactor_channel.send_leave @id

      deep_transpile: (element=null) ->
        if not element?
          transpile this
          element = this
        for child in element.children
          transpile child
          code = child.getAttribute 'onreactor-init'
          if code
            (-> eval code).bind(child)()
          @deep_transpile(child)

      is_root: -> not @parent_component()

      parent_component: ->
        return @parentElement?.closest('[is]')

      connect: ->
        if @is_root()
          reactor_channel.send_join @tag_name, @id, @state()

      apply_diff: (html_diff) ->
        console.log "#{new Date() - origin}ms"
        html = []
        cursor = 0
        for diff in html_diff
          if typeof diff is 'string'
            html.push diff
          else if diff < 0
            cursor -= diff
          else
            html.push(...@_last_received_html[cursor...cursor + diff])
            cursor += diff
        @_last_received_html = html
        html = html.join ' '
        window.requestAnimationFrame =>
          morphdom this, html,
            onBeforeElUpdated: (from_el, to_el) ->
              # Prevent object from being updated
              if from_el.hasAttribute(':once')
                return false

              if from_el.hasAttribute(':keep')
                to_el.value = from_el.value
                to_el.checked = from_el.checked

              transpile(to_el)

              should_patch = (
                from_el is document.activeElement and
                from_el.tagName in ['INPUT', 'SELECT', 'TEXTAREA'] and
                not from_el.hasAttribute(':override')
              )
              if should_patch
                to_el.getAttributeNames().forEach (name) ->
                  from_el.setAttribute(name, to_el.getAttribute(name))
                from_el.readOnly = to_el.readOnly
                return false

              return true

            onElUpdated: (el) ->
              code = el.getAttribute?('onreactor-updated')
              if code
                (-> eval code).bind(el)()

            onNodeAdded: (el) ->
              transpile el
              code = el.getAttribute?('onreactor-added')
              if code
                (-> eval code).bind(el)()

          @querySelector('[\\:focus]:not([disabled])')?.focus()

      dispatch: (name, form, args) ->
        reactor_channel.send_user_event(
          this
          name
          @serialize(form or this)
          args
        )

      serialize: (form) ->
        for el in form.querySelectorAll('[name]')
          if el.closest('[is]') isnt this
            continue
          el_type = el.type.toLowerCase()
          value = (
            switch el.type.toLowerCase()
              when 'checkbox'
                if el.checked
                  el.value or true
                else
                  null
              when 'radio'
                if el.checked
                  el.value or true
                else
                  null
              when 'select-multiple'
                (option.value for option in el.selectedOptions)
              when el.hasAttribute 'contenteditable'
                if el.hasAttribute ':as-text'
                  el.innerText
                else
                  el.innerHTML.trim()
              else
                el.value
          )
          if value is null
            continue
          [el.getAttribute('name'), value]

    customElements.define(component_name, Component, extends: base_html_element)

window.reactor = reactor = {}

reactor.send = (element, name, args) ->
  component = element.closest('[is]')
  form = element.closest('form')
  if component?
    form = if component.contains(form) then form else null
    component.dispatch(name, form, args)

_timeouts = {}

reactor.debounce = (delay_name, delay) -> (f) -> (...args) ->
  clearTimeout _timeouts[delay_name]
  _timeouts[delay_name] = setTimeout (=> f(...args)), delay

reactor.visit = (url, options) ->
  try
    switch options.action
      when 'replace' then window.history.replaceState {}, document.title, url
      when 'advance'
        if Turbo?
          Turbo.visit url, options
        else
          window.history.pushState {}, document.title, url
  catch
    window.location.assign url


reactor_channel.open()

