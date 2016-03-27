_ = require 'underscore-plus'

{CompositeDisposable} = require 'atom'
Base = require './base'
{moveCursorLeft} = require './utils'
settings = require './settings'
{CurrentSelection, Select, MoveToRelativeLine} = {}

class OperationStack
  constructor: (@vimState) ->
    {@editor} = @vimState

    CurrentSelection ?= Base.getClass('CurrentSelection')
    Select ?= Base.getClass('Select')
    MoveToRelativeLine ?= Base.getClass('MoveToRelativeLine')

    # [Experimental] Cache for performance
    @currentSelection = new CurrentSelection(@vimState)
    @select = new Select(@vimState)

    @reset()

  subscribe: (args...) ->
    @subscriptions.add args...

  composeOperation: (operation) ->
    {mode} = @vimState
    switch
      when operation.isOperator()
        if (mode is 'visual') and operation.isRequireTarget()
          operation = operation.setTarget(@currentSelection)
      when operation.isTextObject()
        if mode in ['visual', 'normal']
          operation = @select.setTarget(operation)
      when operation.isMotion()
        if (mode is 'visual')
          operation = @select.setTarget(operation)
    operation

  run: (klass, properties) ->
    klass = Base.getClass(klass) if _.isString(klass)
    try
      # When identical operator repeated, it set target to MoveToRelativeLine.
      #  e.g. `dd`, `cc`, `gUgU`
      klass = MoveToRelativeLine if (@peekTop()?.constructor is klass)

      @stack.push @composeOperation(new klass(@vimState, properties))
      @process()
    catch error
      @handleError(error)

  handleError: (error) ->
    @vimState.reset()
    unless error.instanceof?('OperationAbortedError')
      throw error

  isProcessing: ->
    @processing

  process: ->
    @processing = true
    if @stack.length > 2
      throw new Error('Operation stack must not exceeds 2 length')

    try
      @reduce()
      if @peekTop().isComplete()
        @execute(@stack.pop())
      else
        if @vimState.isMode('normal') and @peekTop().isOperator()
          @vimState.activate('operator-pending')
    catch error
      if error.instanceof?('OperatorError')
        @vimState.activate('reset')
        return
      else
        throw error

  execute: (operation) ->
    execution = operation.execute()
    if execution instanceof Promise
      onResolve = @finish.bind(this, [operation])
      onReject = @handleError.bind(this)
      execution.then(onResolve).catch(onReject)
    else
      @finish(operation)

  cancel: ->
    if @vimState.mode not in ['visual', 'insert']
      @vimState.activate('reset')
    @finish()

  finish: (operation) ->
    @record(operation) if operation?.isRecordable()
    @vimState.emitter.emit 'did-finish-operation'
    if @vimState.isMode('normal')
      unless @editor.getLastSelection().isEmpty()
        if settings.get('throwErrorOnNonEmptySelectionInNormalMode')
          throw new Error("Selection is not empty in normal-mode: #{operation.toString()}")
        else
          @editor.clearSelections()

      # Ensure Cursor is NOT at EndOfLine position
      for cursor in @editor.getCursors() when cursor.isAtEndOfLine()
        moveCursorLeft(cursor, {preserveGoalColumn: true})
    @vimState.updateCursorsVisibility()
    @vimState.reset()

  peekTop: ->
    _.last @stack

  reduce: ->
    until @stack.length is 1
      operation = @stack.pop()
      _.last(@stack).setTarget(operation)

  reset: ->
    @stack = []
    @processing = false
    @subscriptions?.dispose()
    @subscriptions = new CompositeDisposable

  destroy: ->
    @subscriptions?.dispose()
    {@stack, @subscriptions} = {}

  isEmpty: ->
    @stack.length is 0

  record: (@recorded) ->

  getRecorded: ->
    @recorded

module.exports = OperationStack
