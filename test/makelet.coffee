Makelet = require '../src/makelet'
assert = require 'assert'
funclet = require 'funclet'
loglet = require 'loglet'
fs = require 'fs'
path = require 'path'
jsYaml = require 'js-yaml'

describe 'makelet test', ->
  
  it 'can organize task dependency', (done) ->
    runner = new Makelet()
    result = []
    runner
      .task 'test1', (args, cb) ->
        result.push 1 
        cb null 
      .task 'test2', ['test1'], (args, cb) ->
        result.push 2
        cb null 
      .task 'test3', ['test1', 'test2'], (args, cb) ->
        result.push 3 
        cb null 
      .run 'test3', (err) ->
        if err 
          done err
        else
          try 
            assert.deepEqual result, [1, 2, 3]
            done null 
          catch e
            done e
  it 'can have file dependency', (done) ->
    runner = new Makelet()
    srcPath = path.join __dirname, '..', 'example', 'data', 'test.yml'
    destPath = path.join __dirname, '..', 'example', 'parsed', 'test.json'
    runner.file destPath, [ srcPath ], (args, cb) ->
      funclet
        .bind(fs.readFile, args.source, 'utf8')
        .then (data, next) ->
          next null, jsYaml.safeLoad(data, {skipInvalid: true})
        .then (obj, next) ->
          fs.writeFile args.target, JSON.stringify(obj), 'utf8', next
        .catch(done)
        .done(cb)
    runner.run destPath, (err) ->
      loglet.log 'file saved to', destPath
      done null 
  ####