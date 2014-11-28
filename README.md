# Makelet - an embeddable make library

`Makelet` is an embeddable make library - that means you can use it to create your own make-like utility. 

## Install 

    npm install makelet

## Usage 

    var Makelet = require('makelet');
    var runner = new Makelet()
    // regular tasks... 
    runner.task('test1', function(done) {
      ...
      done(null);
    });
    // task dependencies
    runner.task('test2', ['test1'], function(done) {
      ...
      done(null)
    });
    // file-based tasks... will only run if the depended files are newer. 
    runner.file('src/test.c', ['include/test.h'], function(done) {
      ... 
      done(null);
    })
    

