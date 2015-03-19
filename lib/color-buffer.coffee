{Emitter, CompositeDisposable, Task, Range} = require 'atom'
Color = require './color'
ColorMarker = require './color-marker'
VariableMarker = require './variable-marker'

module.exports =
class ColorBuffer
  constructor: (params={}) ->
    {@editor, @project, variableMarkers, colorMarkers} = params
    {@id} = @editor
    @emitter = new Emitter
    @subscriptions = new CompositeDisposable

    @colorMarkersByMarkerId = {}
    @variableMarkersByMarkerId = {}

    @subscriptions.add @editor.onDidDestroy => @destroy()
    @subscriptions.add @editor.onDidStopChanging =>
      @project.reloadVariablesForPath(@editor.getPath()).then =>
        @scanBufferForColors().then (results) => @updateColorMarkers(results)

    @subscriptions.add @project.onDidUpdateVariables =>
      resultsForBuffer = @project.getVariables().filter (r) =>
        r.path is @editor.getPath()
      @updateVariableMarkers(resultsForBuffer)

    if variableMarkers? and colorMarkers?
      @restoreMarkersState(variableMarkers, colorMarkers)

    @initialize()

  onDidUpdateColorMarkers: (callback) ->
    @emitter.on 'did-update-color-markers', callback

  onDidUpdateVariableMarkers: (callback) ->
    @emitter.on 'did-update-variable-markers', callback

  onDidDestroy: (callback) ->
    @emitter.on 'did-destroy', callback

  initialize: ->
    return Promise.resolve() if @variableMarkers? and @colorMarkers?
    return @initializePromise if @initializePromise?

    @initializePromise = @scanBufferForColors().then (results) =>
      @colorMarkers = @createColorMarkers(results)

    @variablesAvailable()
    @initializePromise

  restoreMarkersState: (variableMarkers, colorMarkers) ->
    @variableMarkers = variableMarkers.map (state) =>
      bufferRange = Range.fromObject(state.bufferRange)
      marker = @editor.markBufferRange(bufferRange, {
        type: 'pigments-variable'
        invalidate: 'touch'
      })
      variable = @project.getVariableByName(state.variable)
      variable.bufferRange ?= bufferRange
      new VariableMarker {marker, variable}

    @colorMarkers = colorMarkers.map (state) =>
      marker = @editor.markBufferRange(state.bufferRange, {
        type: 'pigments-color'
        invalidate: 'touch'
      })
      color = new Color(state.color)
      color.variables = state.variables
      new ColorMarker {
        marker
        color
        text: state.text
      }

  variablesAvailable: ->
    return @variablesPromise if @variablesPromise?
    @variablesPromise = @project.initialize().then (results) =>
      return if @destroyed
      return unless results?

      resultsForBuffer = results.filter (r) => r.path is @editor.getPath()
      @variableMarkers = @createVariableMarkers(resultsForBuffer)

      @scanBufferForColors().then (results) => @updateColorMarkers(results)

  destroy: ->
    @subscriptions.dispose()
    @emitter.emit 'did-destroy'
    @variableMarkers?.forEach (marker) -> marker.destroy()
    @colorMarkers?.forEach (marker) -> marker.destroy()
    @destroyed = true

  ##    ##     ##    ###    ########
  ##    ##     ##   ## ##   ##     ##
  ##    ##     ##  ##   ##  ##     ##
  ##    ##     ## ##     ## ########
  ##     ##   ##  ######### ##   ##
  ##      ## ##   ##     ## ##    ##
  ##       ###    ##     ## ##     ##
  ##
  ##    ##     ##    ###    ########  ##    ## ######## ########   ######
  ##    ###   ###   ## ##   ##     ## ##   ##  ##       ##     ## ##    ##
  ##    #### ####  ##   ##  ##     ## ##  ##   ##       ##     ## ##
  ##    ## ### ## ##     ## ########  #####    ######   ########   ######
  ##    ##     ## ######### ##   ##   ##  ##   ##       ##   ##         ##
  ##    ##     ## ##     ## ##    ##  ##   ##  ##       ##    ##  ##    ##
  ##    ##     ## ##     ## ##     ## ##    ## ######## ##     ##  ######

  getVariableMarkers: -> @variableMarkers

  getVariableMarkerByName: (name) ->
    return unless @variableMarkers?
    for marker in @variableMarkers
      return marker if marker.variable.name is name

  createVariableMarkers: (results) ->
    return if @destroyed
    results.map (result) =>
      bufferRange = Range.fromObject [
        @editor.getBuffer().positionForCharacterIndex(result.range[0])
        @editor.getBuffer().positionForCharacterIndex(result.range[1])
      ]
      result.bufferRange ?= bufferRange
      marker = @editor.markBufferRange(bufferRange, {
        type: 'pigments-variable'
        invalidate: 'touch'
      })
      @variableMarkersByMarkerId[marker.id] =
      new VariableMarker {marker, variable: result}

  updateVariableMarkers: (results) ->
    newMarkers = []
    toCreate = []
    for result in results
      if marker = @findVariableMarker(variable: result)
        newMarkers.push(marker)
      else
        toCreate.push(result)

    createdMarkers = @createVariableMarkers(toCreate)
    newMarkers = newMarkers.concat(createdMarkers)

    toDestroy = @variableMarkers.filter (marker) -> marker not in newMarkers

    toDestroy.forEach (marker) =>
      delete @variableMarkersByMarkerId[marker.marker.id]
      marker.destroy()

    @variableMarkers = newMarkers
    @emitter.emit 'did-update-variable-markers', {
      created: createdMarkers
      destroyed: toDestroy
    }

    @scanBufferForColors().then (results) => @updateColorMarkers(results)

  findVariableMarker: (properties) ->
    for marker in @variableMarkers
      return marker if marker.match(properties)

  scanBufferForVariables: ->
    return if @destroyed
    results = []
    taskPath = require.resolve('./tasks/scan-buffer-variables-handler')
    editor = @editor
    buffer = @editor.getBuffer()
    config =
      buffer: @editor.getText()

    new Promise (resolve, reject) ->
      task = Task.once(
        taskPath,
        config,
        -> resolve(results)
      )

      task.on 'scan-buffer:variables-found', (variables) ->
        results = results.concat variables.map (variable) ->
          variable.path = editor.getPath()
          variable.bufferRange = Range.fromObject [
            buffer.positionForCharacterIndex(variable.range[0])
            buffer.positionForCharacterIndex(variable.range[1])
          ]
          variable

  ##     ######   #######  ##        #######  ########
  ##    ##    ## ##     ## ##       ##     ## ##     ##
  ##    ##       ##     ## ##       ##     ## ##     ##
  ##    ##       ##     ## ##       ##     ## ########
  ##    ##       ##     ## ##       ##     ## ##   ##
  ##    ##    ## ##     ## ##       ##     ## ##    ##
  ##     ######   #######  ########  #######  ##     ##
  ##
  ##    ##     ##    ###    ########  ##    ## ######## ########   ######
  ##    ###   ###   ## ##   ##     ## ##   ##  ##       ##     ## ##    ##
  ##    #### ####  ##   ##  ##     ## ##  ##   ##       ##     ## ##
  ##    ## ### ## ##     ## ########  #####    ######   ########   ######
  ##    ##     ## ######### ##   ##   ##  ##   ##       ##   ##         ##
  ##    ##     ## ##     ## ##    ##  ##   ##  ##       ##    ##  ##    ##
  ##    ##     ## ##     ## ##     ## ##    ## ######## ##     ##  ######

  getColorMarkers: -> @colorMarkers

  getValidColorMarkers: -> @getColorMarkers().filter (m) -> m.color.isValid()

  createColorMarkers: (results) ->
    return if @destroyed
    results.map (result) =>
      marker = @editor.markBufferRange(result.bufferRange, {
        type: 'pigments-color'
        invalidate: 'touch'
      })
      @colorMarkersByMarkerId[marker.id] =
      new ColorMarker {marker, color: result.color, text: result.match}

  updateColorMarkers: (results) ->
    newMarkers = []
    toCreate = []
    for result in results
      if marker = @findColorMarker(result)
        newMarkers.push(marker)
      else
        toCreate.push(result)

    createdMarkers = @createColorMarkers(toCreate)
    newMarkers = newMarkers.concat(createdMarkers)

    if @colorMarkers?
      toDestroy = @colorMarkers.filter (marker) -> marker not in newMarkers
      toDestroy.forEach (marker) =>
        delete @colorMarkersByMarkerId[marker.marker.id]
        marker.destroy()
    else
      toDestroy = []

    @colorMarkers = newMarkers
    @emitter.emit 'did-update-color-markers', {
      created: createdMarkers
      destroyed: toDestroy
    }

  findColorMarker: (properties) ->
    for marker in @colorMarkers
      return marker if marker?.match(properties)

  findColorMarkers: (properties) ->
    properties.type = 'pigments-color'
    markers = @editor.findMarkers(properties)
    markers.map (marker) => @colorMarkersByMarkerId[marker.id]

  scanBufferForColors: ->
    return if @destroyed
    results = []
    taskPath = require.resolve('./tasks/scan-buffer-colors-handler')
    buffer = @editor.getBuffer()
    config =
      buffer: @editor.getText()
      variables: @project.getVariables()?.map (v) -> v.serialize()

    new Promise (resolve, reject) ->
      task = Task.once(
        taskPath,
        config,
        -> resolve(results)
      )

      task.on 'scan-buffer:colors-found', (colors) ->
        results = results.concat colors.map (res) ->
          res.color = new Color(res.color)
          res.bufferRange = Range.fromObject [
            buffer.positionForCharacterIndex(res.range[0])
            buffer.positionForCharacterIndex(res.range[1])
          ]
          res

  serialize: ->
    {
      @id
      path: @editor.getPath()
      variableMarkers: @variableMarkers?.map (marker) -> marker.serialize()
      colorMarkers: @colorMarkers?.map (marker) -> marker.serialize()
    }
