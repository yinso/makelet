loglet = require 'loglet'
fs = require 'fs'
utilities = require 'utilities'
_ = require 'underscore'
async = require 'async'
{ EventEmitter } = require 'events'

fileNewerThan = (targetPath, dependPaths, cb) ->
  helper = (target, depends) ->
    res = _.find depends, (dep) ->
      target.mtime < dep.mtime
    if res then true else false
  fs.stat targetPath, (err, target) ->
    if err 
      loglet.debug 'fileNewerThan:no_target', targetPath, err
      cb null, true
    else
      async.map dependPaths, fs.stat, (err, depends) ->
        if err
          loglet.debug 'fileNewerThan:no_depend_file', dependPaths, err 
          cb null, false
        else 
          cb null, helper(target, depends)

# if we want to deal with pattern how do we do so? 
# 1 -> we need to figure out the top level of the directory that doesn't have the wild card... 

patternRootDir = (pat) ->
  segments = pat.split '/'
  res = [] 
  for seg in segments
    if seg.indexOf('%') == -1
      res.push seg 
      continue
    else
      return res.join '/'
  return res.join '/'

patternToRegex = (pat) ->
  regex = pat.replace(/\\/g, '\\\\')
    .replace(/\//g, '\\/')
    .replace('.', '\\.')
    .replace(/%/g, '([^\\\/\\\\]+?)')
  new RegExp regex

patternToReplace = (pat) ->
  i = 0 
  pat.replace /%/g, () ->
    i++ 
    "$#{i}"

patternFiles = (pat) ->
  rootDir = patternRootDir pat
  regex = patternToRegex pat 
  files = utilities.file.readdirR rootDir 
  #loglet.log 'patternFiles.regex', regex
  _.filter files, (file) -> 
    file.match regex

patternFileSubst = (sourcePat, targetPat) ->
  sourceRegex = patternToRegex sourcePat
  targetPat = patternToReplace targetPat
  files = patternFiles sourcePat
  for file in files 
    [ file, file.replace(sourceRegex, targetPat)]

class TaskSpec 
  constructor: (@name, @depends, @work) ->
  make: () ->
    new Task @name, @work
  dependsOn: (name) ->
    @depends.indexOf(name) != -1

# we are doing this because we are trying to have a concept of completed but no run... 
# we will come back to this I guess... 
# for now it's okay we aren't optimizing for this... 
class Task extends EventEmitter
  constructor: (@name, @work) ->
    @depends = {}
    @completes = {} # this is the reason why I think we need something that runs only once...
    @status = {}
  addDepends: (depends) ->
    for task in depends 
      @depends[task.name] = task
      task.once 'done', @onDependDone
  dependsOn: (task) ->
    _.find Object.keys(@depends), (name) -> task.name == name
  dependsKeys: () ->
    Object.keys(@depends)
  onDependDone: (task, err) =>
    # we should return more than one thing... 
    if err
      @status = {error: err} # this makes no sense by the way... we don't need reset anyway since this is toss away.
      @reset()
      @emit 'done', task, err # we keep propagating...
    else 
      if err == false # this is one where the function isn't triggered. 
        @completes[task.name] = false
      else
        @completes[task.name] = true
      # we will try running... 
      @tryRun()
  reset: () ->
    for key, depend of @depends
      depend.removeListener 'done', @onDependDone
  tryRun: () ->
    # a couple states to test. 
    # everything must be finished...
    allFinished = true
    allStopped = true 
    for key, depend of @depends 
      if @completes.hasOwnProperty(key) 
        if @completes[key] == true
          allStopped = false
      else # not everything is finished. 
        allFinished = false
        break 
    loglet.debug 'Task.tryRun', @name, @completes, allFinished, allStopped
    @_startRun allFinished, allStopped
  _startRun: (allFinished, allStopped) ->
    if allFinished
      @reset() # there should be nothing anyway... 
      if not allStopped 
        @_run()
      else # not everything is completed but we have finished... 
        # in this case we will push further saying we are not finished. 
        @status = {stopped: true}
        @emit 'done', @, false
  _run: () ->
    @emit 'start', @name
    @work.call @, {}, @_runCallback
  _runCallback: (err) =>
      if err
        @status = {error: err}
        @emit 'done', @, err
      else if err == false
        @status = {stopped: true}
        @emit 'done', @, false
      else
        @status = {completed: true}
        @emit 'done', @, null
  start: () ->
    @_run()

class FileTask extends Task
  constructor: (name, work, @dependPaths) ->
    super name, work
  addDepends: (depends) ->
    # one of the things to do here is to figure out which list of the depends duplicate with the @dependPaths... 
    dependPaths = []
    for path in @dependPaths
      task = _.find depends, (task) -> task.name == path
      if (not task) or (task instanceof FileTask)
        dependPaths.push path
    @dependPaths = dependPaths
    super depends
  _startRun: (allFinished, allStopped) ->
    if allFinished 
      @reset()
      @_run()
  _run: () ->
    fileNewerThan @name, @dependPaths, (err, res) =>
      if err
        @_runCallback err
      else if res # true - there is something to do... 
        @work {source: @dependPaths[0], sources: @dependPaths, target: @name}, @_runCallback
      else # false - there is nothing to do...
        @_runCallback false

class FileTaskSpec extends TaskSpec
  make: () ->
    new FileTask @name, @work, @depends

class TopLevelTask extends EventEmitter
  constructor: (organizer, taskNames, @cb) ->
    # one thing to keep in mind is that we do not want to create a different sets of tasks... so we will go through one pass
    # and then we will update the depends... 
    tasks = @filterTasks organizer.makeTasks(), taskNames
    @root = @findRoot tasks
    @depends = @findBottom tasks
    loglet.debug 'TopLevelTask.ctor', taskNames, @root, @depends
    @completes = {}
    for key, task of @depends
      task.once 'done', @onDependDone
  reset: () ->
    for key, task of @bottom
      task.removeListener 'done', @onDependDone
  onDependDone: (task, err) =>
    # we should return more than one thing... 
    if err
      #@status = {error: err} # this makes no sense by the way... we don't need reset anyway since this is toss away.
      @reset()
      @cb.call @, err
    else 
      if err == false # this is one where the function isn't triggered. 
        @completes[task.name] = false
      else
        @completes[task.name] = true
      @tryRun()
  tryRun: () ->
    # a couple states to test. 
    # everything must be finished...
    allFinished = true
    allStopped = true 
    for key, depend of @depends 
      if @completes.hasOwnProperty(key) 
        if @completes[key] == true
          allStopped = false
      else # not everything is finished. 
        allFinished = false
        break 
    if allFinished
      @reset() # there should be nothing anyway... 
      if not allStopped
        @cb.call @, null
      else # not everything is completed but we have finished... 
        # in this case we will push further saying we are not finished. 
        @status = {stopped: true}
        @cb.call @, null
        #@emit 'done', @, false
  filterTasks: (tasks, taskNames) ->
    # how do we filter? 
    # tasks will need to be a strict superset of taskNames.
    # i.e. everything that exists in taskNames must exist from task, but we might need more... 
    result = {}
    for name in taskNames 
      if not tasks.hasOwnProperty(name)
        throw {error: 'unknown_task_name', name: name}
      if result.hasOwnProperty(name)
        continue
      else
        @_filterRecurse tasks[name], result
    loglet.debug 'TopLevelTask.filterTasks', taskNames, Object.keys(tasks), Object.keys(result)
    result
  _filterRecurse: (task, result) ->
    name = task.name
    result[name] = task
    for key, depend of task.depends
      @_filterRecurse depend, result
  # the list of the root must belong inside the taskNames??? Not necessarily... 
  # what we want to do is to use the list of 
  findRoot: (tasks) ->
    result = []
    for key, task of tasks 
      loglet.debug 'TopLevelTask.findRoot', task.name, task.dependsKeys()
      if task.dependsKeys().length == 0
        result.push task
    result
  findBottom: (tasks) ->
    # we want to retain the bottom... 
    # bottom are the ones that do not have other tasks depend on them...
    # we'll do N^2 for now... 
    noDepends = {}
    keys = []
    sourceTasks = []
    for key, task of tasks 
      noDepends[key] = task
      keys.push key
      sourceTasks.push task
    for key in keys
      depend = noDepends[key]
      isDepended = _.find sourceTasks, (task) -> 
        loglet.debug 'TopLevelTask.findBottom.depend', key, task.name, task.dependsKeys(), task.dependsOn depend
        task.dependsOn depend
      if isDepended
        delete noDepends[key]
    #loglet.warn 'findBottom:result', Object.keys(noDepends)
    noDepends
  start: () ->
    for task in @root
      task.start()

class Makelet 
  constructor: () ->
    @tasks = {}
    @roots = []
  wildcard: patternFiles
  patsubst: (files, sourcePat, targetPat) ->
    sourceRegex = patternToRegex sourcePat
    targetPat = patternToReplace targetPat
    for file in files 
      file.replace sourceRegex, targetPat
  getTask: (name) ->
    _.find @tasks, (task) -> task.name == name
  task: (name, depends, work) ->
    if arguments.length == 2
      work = depends
      depends = []
    if @tasks.hasOwnProperty(name)
      throw {error: 'duplicate_task_name', name: name}
    @tasks[name] = new TaskSpec name, depends, work
    @_add name, depends, work, (cb) -> 
      work {}, cb
    @
  _add: (name, depends, work, cb) ->
  file: (targetPath, dependPaths, work) ->
    if @tasks.hasOwnProperty(targetPath)
      throw {error: 'duplicate_task_name', name: targetPath}
    loglet.debug 'Makelet.file', targetPath, dependPaths
    @tasks[targetPath] = new FileTaskSpec targetPath, dependPaths, work
    @_add targetPath, [], work, (cb) ->
      fileNewerThan targetPath, dependPaths, (err, res) ->
        if err
          cb err
        else if res
          work {source: dependPaths[0], sources: dependPaths, target: targetPath}, cb
        else
          cb null 
    @
  pattern: (files, targetPattern, sourcePattern, work) ->
    fileMap = @patsubst files, sourcePattern, targetPattern
    for source, i in files 
      loglet.debug 'pattern', fileMap[i], source
      @file fileMap[i], [ source ], work
    @
  rule: (targetPattern, sourcePattern, work) ->
    fileMap = patternFileSubst sourcePattern, targetPattern
    for [ source, target ] in fileMap 
      @file target, [ source ], work 
    @
  makeTasks: () ->
    tasks = 
      for key, spec of @tasks
        spec.make()
    result = {}
    for task in tasks 
      depends = _.filter tasks, (depend) => 
        @tasks[task.name].dependsOn depend.name
      task.addDepends depends
      result[task.name] = task
    result
  run: (targets..., cb) ->
    topLevel = new TopLevelTask @, targets, cb
    topLevel.start()
    @

Makelet.Task = Task

module.exports = Makelet
